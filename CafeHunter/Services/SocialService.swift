import AVFoundation
import Combine
import CoreLocation
@preconcurrency import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import UIKit

@MainActor
@Observable
final class SocialService {

    private(set) var profile: UserProfile?
    private(set) var friendIds: [String] = []
    private(set) var incomingRequests: [FriendRequestModel] = []
    private(set) var outgoingRequests: [FriendRequestModel] = []
    private(set) var feedPosts: [FriendPost] = []
    private(set) var blockedUserIds: Set<String> = []
    private(set) var isLoadingProfile = true
    var errorMessage: String?

    /// Raw posts from Firestore before blocked-user filtering. Kept private
    /// so callers always see the filtered `feedPosts`. Re-applied through
    /// `applyBlockedFilter()` whenever either input changes.
    private var rawFeedPosts: [FriendPost] = []
    /// Sources merged into `rawFeedPosts`: "everyone" posts by me + friends
    /// (Q1) and restricted posts directed at me (Q2). Kept separate so each
    /// listener updates independently before `mergeFeeds()` recombines them.
    private var rawOpenPosts: [FriendPost] = []
    private var rawRestrictedPosts: [FriendPost] = []

    var needsUsername: Bool {
        guard let p = profile else { return true }
        return p.username == nil || p.username?.isEmpty == true
    }

    private let db = Firestore.firestore()
    private var feedListener: ListenerRegistration?
    /// Q2 listener for restricted posts directed at me (recipientUids contains me).
    private var restrictedFeedListener: ListenerRegistration?
    private var friendsListener: ListenerRegistration?
    private var requestsListener: ListenerRegistration?
    private var outgoingRequestsListener: ListenerRegistration?
    private var profileListener: ListenerRegistration?
    private var blockedListener: ListenerRegistration?

    private var uid: String? { Auth.auth().currentUser?.uid }

    func start(for user: FirebaseAuth.User?) {
        reset()
        guard let user else {
            isLoadingProfile = false
            return
        }
        isLoadingProfile = true
        ensureUserDocument(user: user)
        let ref = db.collection("users").document(user.uid)
        profileListener = ref.addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self else { return }
                defer { self.isLoadingProfile = false }
                guard let data = snap?.data() else {
                    self.profile = UserProfile(username: nil, usernameLower: nil, displayName: nil, photoURL: nil)
                    return
                }
                self.profile = UserProfile(
                    username: data["username"] as? String,
                    usernameLower: data["usernameLower"] as? String,
                    displayName: data["displayName"] as? String,
                    photoURL: data["photoURL"] as? String,
                    optedOutOfDiscovery: data["optedOutOfDiscovery"] as? Bool ?? false,
                    publicKey: data["publicKey"] as? String
                )
            }
        }
        attachFriendsListener(uid: user.uid)
        attachIncomingRequestsListener(uid: user.uid)
        attachOutgoingRequestsListener(uid: user.uid)
        attachBlockedUsersListener(uid: user.uid)
        ensureIdentityKey()
    }

    /// Generate (if needed) the device's E2EE identity keypair and publish the
    /// public half to `users/{uid}.publicKey`. Idempotent and runs for every
    /// user on every launch (existing users predate the username-reservation
    /// hook). On reinstall the Keychain is wiped → a new keypair is generated
    /// and republished (the key rotation that makes prior ciphertext in a
    /// thread unreadable — see MessageCrypto). Failures are non-fatal: sends
    /// fall back to plaintext when no key is available.
    func ensureIdentityKey() {
        guard let uid else { return }
        Task {
            do {
                let priv = try MessageCrypto.loadOrCreateIdentityKey(uid: uid)
                let pub = MessageCrypto.publicKeyBase64(for: priv)
                let snap = try await db.collection("users").document(uid).getDocument()
                let stored = snap.data()?["publicKey"] as? String
                if stored != pub {
                    try await db.collection("users").document(uid)
                        .setData(["publicKey": pub], merge: true)
                }
                // Mirror the key into the shared keychain group so the
                // Notification Service Extension can decrypt message
                // notifications on-device (only while unlocked).
                MessageCrypto.mirrorIdentityKeyToSharedGroup(uid: uid)
            } catch {
                #if DEBUG
                print("[SocialService] ensureIdentityKey failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    func reset() {
        feedListener?.remove()
        restrictedFeedListener?.remove()
        friendsListener?.remove()
        requestsListener?.remove()
        outgoingRequestsListener?.remove()
        profileListener?.remove()
        blockedListener?.remove()
        feedListener = nil
        restrictedFeedListener = nil
        friendsListener = nil
        requestsListener = nil
        outgoingRequestsListener = nil
        profileListener = nil
        blockedListener = nil
        profile = nil
        friendIds = []
        incomingRequests = []
        outgoingRequests = []
        feedPosts = []
        rawFeedPosts = []
        rawOpenPosts = []
        rawRestrictedPosts = []
        blockedUserIds = []
    }

    private func ensureUserDocument(user: FirebaseAuth.User) {
        let uid = user.uid
        let displayName = user.displayName ?? ""
        let photoURL = user.photoURL?.absoluteString
        let ref = db.collection("users").document(uid)
        // Idempotent mirror of Auth → public user doc, async/await variant.
        // Friends' UIs (map pin avatars, friend list, chat header) read from
        // the doc, not Auth, so drift between them means stale data on other
        // devices. Failures are non-critical — log but don't surface.
        Task {
            do {
                let snap = try await ref.getDocument()
                var update: [String: Any] = ["displayName": displayName]
                if let photoURL { update["photoURL"] = photoURL }
                if !snap.exists {
                    update["createdAt"] = FieldValue.serverTimestamp()
                }
                try await ref.setData(update, merge: true)
            } catch {
                print("[SocialService] ensureUserDocument failed: \(error)")
            }
        }
    }

    private func attachFriendsListener(uid: String) {
        friendsListener?.remove()
        friendsListener = db.collection("users").document(uid).collection("friends")
            .addSnapshotListener { [weak self] snap, err in
                if let err {
                    // A swallowed error here is how ghost friends end up in
                    // `friendIds` — the listener stops reflecting reality but
                    // the UI keeps showing a friend who was unfriended /
                    // blocked / cascaded away. Surface to console so we
                    // notice. `refreshFriendsFromServer()` below is the
                    // recovery path when this happens in production.
                    #if DEBUG
                    print("[SocialService] friends listener error: \(err.localizedDescription)")
                    #endif
                }
                Task { @MainActor in
                    guard let self else { return }
                    self.friendIds = snap?.documents.map(\.documentID) ?? []
                    self.attachFeedListener()
                }
            }
    }

    /// One-shot server read of the friend collection. Bypasses the listener
    /// cache. Use when there's a strong signal that `friendIds` has gone
    /// out of sync with the server — e.g. a conversation create just got
    /// rejected for a user that the local listener still thinks is a friend.
    func refreshFriendsFromServer() async {
        guard let uid else { return }
        do {
            let snap = try await db.collection("users").document(uid)
                .collection("friends")
                .getDocuments(source: .server)
            self.friendIds = snap.documents.map(\.documentID)
        } catch {
            #if DEBUG
            print("[SocialService] refreshFriendsFromServer failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func attachIncomingRequestsListener(uid: String) {
        requestsListener?.remove()
        requestsListener = db.collection("friendRequests")
            .whereField("toUid", isEqualTo: uid)
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snap, err in
                if let err {
                    // Silent failures here are the worst kind — friend
                    // requests appear stuck in the UI with no signal to
                    // the user or the dev. Surface to console so we
                    // notice. Common cause: missing composite index.
                    #if DEBUG
                    print("[SocialService] incoming-requests listener error: \(err.localizedDescription)")
                    #endif
                }
                Task { @MainActor in
                    guard let self else { return }
                    self.incomingRequests = snap?.documents.compactMap { FriendRequestModel(document: $0) } ?? []
                }
            }
    }

    /// Mirror of the incoming listener for requests *this* user has sent and
    /// are still pending — powers the "Sent requests" list so they can be
    /// cancelled. Needs the (fromUid, status) composite index.
    private func attachOutgoingRequestsListener(uid: String) {
        outgoingRequestsListener?.remove()
        outgoingRequestsListener = db.collection("friendRequests")
            .whereField("fromUid", isEqualTo: uid)
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snap, err in
                if let err {
                    #if DEBUG
                    print("[SocialService] outgoing-requests listener error: \(err.localizedDescription)")
                    #endif
                }
                Task { @MainActor in
                    guard let self else { return }
                    self.outgoingRequests = snap?.documents.compactMap { FriendRequestModel(document: $0) } ?? []
                }
            }
    }

    private func attachFeedListener() {
        feedListener?.remove()
        restrictedFeedListener?.remove()
        guard let myUid = uid else { return }
        var chunk: [String] = Array(friendIds.prefix(29))
        if !chunk.contains(myUid) {
            chunk.append(myUid)
        }
        if chunk.count > 30 {
            chunk = Array(chunk.prefix(30))
        }

        // Q1 — "everyone" posts by me + friends. `restricted == false` excludes
        // friends' audience-limited posts I may not be a recipient of: Firestore
        // fails the WHOLE query if any matched doc is unreadable, so they must be
        // filtered out here (they arrive via Q2 only when they're for me).
        if !chunk.isEmpty {
            feedListener = db.collection("posts")
                .whereField("authorId", in: chunk)
                .whereField("restricted", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 50)
                .addSnapshotListener { [weak self] snap, err in
                    Task { @MainActor in
                        guard let self else { return }
                        if let err {
                            // Transient network errors used to wipe feedPosts
                            // here, which cascaded into the map showing no
                            // pins until the listener reconnected. Keep the
                            // last-known feed in place; the listener will
                            // emit a fresh snapshot once Firestore reconnects.
                            self.errorMessage = err.localizedDescription
                            return
                        }
                        guard let docs = snap?.documents else { return }
                        self.rawOpenPosts = docs.compactMap { FriendPost(document: $0) }
                            .filter { !$0.mediaURL.isEmpty }
                        self.mergeFeeds()
                    }
                }
        } else {
            rawOpenPosts = []
        }

        // Q2 — restricted posts directed at me. `recipientUids` always includes
        // the author, so this also returns my OWN restricted posts. Every doc it
        // matches lists me as a recipient, so it's always readable.
        restrictedFeedListener = db.collection("posts")
            .whereField("recipientUids", arrayContains: myUid)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .addSnapshotListener { [weak self] snap, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let err {
                        self.errorMessage = err.localizedDescription
                        return
                    }
                    guard let docs = snap?.documents else { return }
                    self.rawRestrictedPosts = docs.compactMap { FriendPost(document: $0) }
                        .filter { !$0.mediaURL.isEmpty }
                    self.mergeFeeds()
                }
            }
    }

    /// Merge the two feed sources (open + restricted-to-me), dedup by id,
    /// sort newest-first, cap at 50, then apply the block filter. Called from
    /// either listener's snapshot.
    private func mergeFeeds() {
        var seen = Set<String>()
        let merged = (rawOpenPosts + rawRestrictedPosts)
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert($0.id).inserted }
        rawFeedPosts = Array(merged.prefix(50))
        applyBlockedFilter()
    }

    /// Subscribes to my `blockedUsers` subcollection. The block list is the
    /// source-of-truth for filtering the feed and the inbox; both surfaces
    /// hide content from any uid that appears here.
    private func attachBlockedUsersListener(uid: String) {
        blockedListener?.remove()
        blockedListener = db.collection("users").document(uid)
            .collection("blockedUsers")
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.blockedUserIds = Set(snap?.documents.map(\.documentID) ?? [])
                    self.applyBlockedFilter()
                }
            }
    }

    /// Recomputes the published `feedPosts` from `rawFeedPosts` minus posts
    /// authored by anyone in `blockedUserIds`. Called whenever either input
    /// changes.
    private func applyBlockedFilter() {
        feedPosts = rawFeedPosts.filter { !blockedUserIds.contains($0.authorId) }
    }

    /// Inserts a row immediately after posting so the feed updates before the next snapshot (and covers listener edge cases).
    func prependOptimisticFeedPost(_ post: FriendPost) {
        guard !feedPosts.contains(where: { $0.id == post.id }) else { return }
        feedPosts = [post] + feedPosts
    }

    /// Author-only override on the classifier's verdict. Setting false
    /// pulls the post out of Discover immediately (the rule check
    /// `resource.data.discoverable == true` short-circuits). Setting
    /// true is allowed by the rules but discouraged — the classifier's
    /// face-gate exists for a reason.
    func setDiscoverable(postId: String, _ value: Bool) async throws {
        // A restricted (audience-limited) post must never become discoverable —
        // that would expose it to strangers via the `discoverable == true` read
        // gate. The security rules also reject this; guard client-side so the UI
        // never attempts it. (If the post isn't in the loaded feed we let the
        // server rule be the backstop.)
        if value,
           let post = rawFeedPosts.first(where: { $0.id == postId }) ?? feedPosts.first(where: { $0.id == postId }),
           post.restricted {
            throw SocialError.notAuthorized
        }
        try await db.collection("posts").document(postId).setData([
            "discoverable": value,
        ], merge: true)
    }

    /// Per-user opt-out from CONTRIBUTING to friend-of-friend Discover. When
    /// true, this user's visits are not surfaced to others via the `discoverFeed`
    /// Cloud Function. The UI exposes the inverse ("Help your circle discover")
    /// — default-falsey here so an absent field is treated as opted in.
    func setOptedOutOfDiscovery(_ value: Bool) async throws {
        guard let u = uid else { throw SocialError.notSignedIn }
        try await db.collection("users").document(u).setData([
            "optedOutOfDiscovery": value,
        ], merge: true)
    }

    func reserveUsername(_ raw: String) async throws {
        guard let u = uid else { throw SocialError.notSignedIn }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 20 else { throw SocialError.invalidUsername }
        guard trimmed.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil else {
            throw SocialError.invalidUsername
        }
        let lower = trimmed.lowercased()
        let userRef = db.collection("users").document(u)
        let nameRef = db.collection("usernames").document(lower)

        do {
            _ = try await db.runTransaction { txn, errorPointer in
                do {
                    let snap = try txn.getDocument(nameRef)
                    if snap.exists {
                        errorPointer?.pointee = NSError(
                            domain: "CafeHunter",
                            code: 409,
                            userInfo: [NSLocalizedDescriptionKey: "Username taken"]
                        )
                        return nil
                    }
                    txn.setData(["uid": u], forDocument: nameRef)
                    txn.setData([
                        "username": trimmed,
                        "usernameLower": lower,
                        "displayName": Auth.auth().currentUser?.displayName ?? "",
                    ], forDocument: userRef, merge: true)
                    return nil
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }
        } catch {
            let ns = error as NSError
            if ns.domain == "CafeHunter" && ns.code == 409 { throw SocialError.usernameTaken }
            if ns.code == 409 { throw SocialError.usernameTaken }
            throw error
        }
    }

    func myReactionEmoji(for post: FriendPost) async -> String? {
        guard let uid else { return nil }
        let snap = try? await db.collection("posts").document(post.id).collection("reactions").document(uid).getDocument()
        return snap?.data()?["emoji"] as? String
    }

    func sendFriendRequest(toUsername raw: String) async throws {
        guard let fromUid = uid else { throw SocialError.notSignedIn }
        var lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lower = lower.replacingOccurrences(of: "@", with: "")
        guard !lower.isEmpty else { throw SocialError.invalidUsername }
        let nameSnap = try await db.collection("usernames").document(lower).getDocument()
        guard let toUid = nameSnap.data()?["uid"] as? String else { throw SocialError.userNotFound }
        guard toUid != fromUid else { throw SocialError.cannotAddSelf }
        // Block re-adding someone who's already a friend. The autocomplete
        // dropdown already filters them out, but a user could still type a
        // full username by hand. We check the local listener cache here for
        // a fast path; the Cloud-Function-side accept rules wouldn't reject
        // a duplicate `pending` request the way the rules reject self-adds,
        // so the only place to catch this cleanly is the client.
        if friendIds.contains(toUid) {
            throw SocialError.alreadyFriends(username: lower)
        }
        let fromName = profile?.username ?? (Auth.auth().currentUser?.email ?? "user")
        try await db.collection("friendRequests").addDocument(data: [
            "fromUid": fromUid,
            "toUid": toUid,
            "fromUsername": fromName,
            "toUsername": lower,
            "status": "pending",
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    func acceptRequest(_ request: FriendRequestModel) async throws {
        guard let myUid = uid else { throw SocialError.notSignedIn }
        guard request.toUid == myUid else { return }
        // Phase 4: server-side enforcement. The callable runs in a
        // transaction, checks each side against the 20-friend cap, and
        // writes both friend docs atomically. Direct client writes here
        // would now be denied by the rules anyway.
        let callable = Functions.functions().httpsCallable("acceptFriendRequest")
        do {
            _ = try await callable.call(["requestId": request.id])
        } catch {
            // Surface the cap error specifically — the UI can show it
            // inline. Other errors propagate as-is.
            let ns = error as NSError
            if ns.domain == "com.firebase.functions" {
                let code = ns.userInfo["FIRFunctionsErrorDetailsKey"] as? String
                    ?? ns.localizedDescription
                if ns.localizedDescription.lowercased().contains("limit")
                    || code.lowercased().contains("limit") {
                    throw SocialError.friendsCapReached
                }
            }
            throw error
        }
        // Optimistic local removal. The incoming-requests listener filters
        // on status=="pending" and *should* drop this doc when the
        // callable's transaction commits status=="accepted", but Firestore
        // listener cache can lag a few seconds (or fail silently if a rule
        // ever rejects). Dropping locally guarantees the UI updates the
        // instant the user sees the accept "succeed".
        incomingRequests.removeAll { $0.id == request.id }
    }

    /// Symmetric unfriend. Routed through the `removeFriend` callable so
    /// both sides of the friendship are deleted server-side using the
    /// admin SDK — the Phase 4 rules deny direct client writes, so this
    /// is the only path that works. The friend listener fires the local
    /// `friendIds` update on commit, so the UI refreshes automatically.
    func removeFriend(uid otherUid: String) async throws {
        guard let myUid = uid else { throw SocialError.notSignedIn }
        guard otherUid != myUid else { return }
        let callable = Functions.functions().httpsCallable("removeFriend")
        _ = try await callable.call(["uid": otherUid])
    }

    // MARK: - Moderation (App Store Guideline 1.2)

    /// Blocks a user. Server cascade removes any existing friendship and
    /// writes the `users/{me}/blockedUsers/{otherUid}` record. The listener
    /// picks it up and re-filters feedPosts; the views consult
    /// `blockedUserIds` to suppress chat threads + map pins on top.
    func blockUser(uid otherUid: String) async throws {
        guard let myUid = uid else { throw SocialError.notSignedIn }
        guard otherUid != myUid else { return }
        let callable = Functions.functions().httpsCallable("blockUser")
        _ = try await callable.call(["uid": otherUid])
    }

    /// Removes a block, restoring the user as an ordinary stranger (they
    /// still aren't a friend unless one of them re-sends a request).
    func unblockUser(uid otherUid: String) async throws {
        let callable = Functions.functions().httpsCallable("unblockUser")
        _ = try await callable.call(["uid": otherUid])
    }

    /// Writes a moderation flag. Server validates the shape and stamps the
    /// record into `reports/{auto}`. We commit to reviewing reports within
    /// 24 hours per our EULA / App Store Connect notes.
    func reportContent(
        targetType: ReportTargetType,
        targetId: String,
        reason: ReportReason,
        details: String? = nil
    ) async throws {
        var payload: [String: Any] = [
            "targetType": targetType.rawValue,
            "targetId": targetId,
            "reason": reason.rawValue,
        ]
        if let details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["details"] = details
        }
        let callable = Functions.functions().httpsCallable("reportContent")
        _ = try await callable.call(payload)
    }

    func rejectRequest(_ request: FriendRequestModel) async throws {
        guard let myUid = uid else { throw SocialError.notSignedIn }
        guard request.toUid == myUid else { return }
        try await db.collection("friendRequests").document(request.id).updateData([
            "status": "rejected",
        ])
        // Same optimistic-remove rationale as acceptRequest — listener
        // will reconcile when it fires, we don't wait.
        incomingRequests.removeAll { $0.id == request.id }
    }

    /// Cancels an outgoing pending request the current user sent, by deleting
    /// the `friendRequests` doc. The rules permit the sender to delete their
    /// own pending request; deleting it also clears the recipient's incoming
    /// list (their listener filters status=="pending"). Optimistic local
    /// removal mirrors accept/reject — the listener reconciles on commit.
    func cancelRequest(_ request: FriendRequestModel) async throws {
        guard let myUid = uid else { throw SocialError.notSignedIn }
        guard request.fromUid == myUid else { return }
        try await db.collection("friendRequests").document(request.id).delete()
        outgoingRequests.removeAll { $0.id == request.id }
    }

    /// Back-compat shim — a single image OR video becomes a one-item draft.
    func uploadAndCreatePost(image: UIImage?,
                             videoURL: URL?,
                             caption: String,
                             place: PlaceSelection? = nil) async throws {
        let source: MediaDraft.Source
        if let image {
            source = .image(image)
        } else if let videoURL {
            source = .video(videoURL)
        } else {
            throw SocialError.uploadFailed
        }
        let draft = MediaDraft(source: source, place: place,
                               caption: caption.isEmpty ? nil : caption)
        try await uploadAndCreatePost(drafts: [draft])
    }

    /// Creates a post from 1…6 ordered media drafts, each with an optional
    /// place tag and caption. Uploads every item, mirrors item 0 to the
    /// top-level fields (back-compat + feed filter + Discover index), writes
    /// the `media` array, and optimistically prepends the post.
    /// `recipientUids` nil/empty = an "everyone" post (visible to all friends,
    /// Discover-eligible). A non-empty set restricts the post to those friends
    /// — the author is always added so they see their own restricted post, and
    /// the post is forced non-discoverable.
    func uploadAndCreatePost(drafts: [MediaDraft], recipientUids: [String]? = nil) async throws {
        guard let authorUid = uid else { throw SocialError.notSignedIn }
        guard let username = profile?.username else { throw SocialError.needsUsername }
        guard !drafts.isEmpty, drafts.count <= 6 else { throw SocialError.uploadFailed }

        let isRestricted = (recipientUids?.isEmpty == false)
        // Materialize selected friends + author; the rule requires the author
        // present and the Q2 feed query is `recipientUids array-contains me`.
        let finalRecipients: [String] = isRestricted
            ? Array(Set((recipientUids ?? []) + [authorUid]))
            : []

        let postRef = db.collection("posts").document()
        let postId = postRef.documentID
        // Client `Timestamp` so `orderBy(createdAt)` includes the doc immediately.
        let createdAt = Timestamp(date: .now)

        // Resolve each DISTINCT place once (sequential — usually 0-1 places;
        // dedup means a single findOrCreatePlace call even when photos share
        // a cafe, avoiding the concurrent-create race).
        var resolvedByKey: [String: (id: String, name: String)] = [:]
        for sel in dedupPlaceSelections(drafts.compactMap(\.place)) {
            resolvedByKey[placeKey(sel)] = try await resolvePlace(sel)
        }
        func resolved(_ sel: PlaceSelection?) -> (id: String, name: String)? {
            guard let sel else { return nil }
            return resolvedByKey[placeKey(sel)]
        }

        // Upload each item in order → build the media array. A thrown error
        // aborts BEFORE any doc is written, so no half-post lands (already-
        // uploaded blobs are orphaned but harmless).
        var media: [PostMedia] = []
        var firstImageForClassify: UIImage?
        for (i, draft) in drafts.enumerated() {
            let place = resolved(draft.place)
            let cap: String? = {
                guard let c = draft.caption, !c.isEmpty else { return nil }
                return String(c.prefix(25))
            }()
            switch draft.source {
            case .image(let image):
                let processed = CameraCaptureProcessing.preparePhotoForUpload(image) ?? image
                guard let data = processed.jpegData(compressionQuality: 0.82) else { throw SocialError.uploadFailed }
                let ref = Storage.storage().reference().child("social/\(authorUid)/\(postId)_\(i).jpg")
                _ = try await ref.putDataAsync(data)
                let url = try await ref.downloadURL()
                media.append(PostMedia(type: "image", url: url.absoluteString,
                                       placeId: place?.id, placeName: place?.name, caption: cap))
                if firstImageForClassify == nil { firstImageForClassify = processed }
            case .video(let videoURL):
                let squareURL: URL = videoURL.lastPathComponent.contains("_sq")
                    ? videoURL
                    : ((try? await CameraCaptureProcessing.exportSquareVideo(from: videoURL)) ?? videoURL)
                let ref = Storage.storage().reference().child("social/\(authorUid)/\(postId)_\(i).mp4")
                _ = try await ref.putFileAsync(from: squareURL)
                let url = try await ref.downloadURL()
                let thumb = try? await generateVideoThumbnail(videoURL: squareURL,
                                                              postId: "\(postId)_\(i)", authorUid: authorUid)
                media.append(PostMedia(type: "video", url: url.absoluteString, thumbnailURL: thumb,
                                       placeId: place?.id, placeName: place?.name, caption: cap))
            }
        }
        guard let first = media.first else { throw SocialError.uploadFailed }

        // Firestore payload: the media[] array + mirror of item 0 to the
        // top-level fields the feed filter / Discover index / legacy readers need.
        let mediaPayload: [[String: Any]] = media.map { m in
            var d: [String: Any] = ["type": m.type, "url": m.url]
            if let t = m.thumbnailURL { d["thumbnailURL"] = t }
            if let p = m.placeId { d["placeId"] = p }
            if let pn = m.placeName { d["placeName"] = pn }
            if let c = m.caption { d["caption"] = c }
            return d
        }
        var payload: [String: Any] = [
            "authorId": authorUid,
            "authorUsername": username,
            "caption": first.caption ?? "",
            "mediaType": first.type,
            "mediaURL": first.url,
            "createdAt": createdAt,
            "media": mediaPayload,
        ]
        if let t = first.thumbnailURL { payload["thumbnailURL"] = t }
        if let pid = first.placeId {
            payload["placeId"] = pid
            payload["placeName"] = first.placeName ?? ""
        }
        // Audience gate. Always stamp `restricted` (so the Q1 `restricted == false`
        // feed query matches every new everyone-post). A restricted post carries
        // its recipients and is forced non-discoverable up front.
        payload["restricted"] = isRestricted
        if isRestricted {
            payload["recipientUids"] = finalRecipients
            payload["discoverable"] = false
        }

        // Optimistic feed insert (media-aware) so the caller's spinner stops now.
        prependOptimisticFeedPost(FriendPost(
            id: postId,
            authorId: authorUid,
            authorUsername: username,
            caption: first.caption ?? "",
            mediaType: first.type,
            mediaURL: first.url,
            thumbnailURL: first.thumbnailURL,
            createdAt: createdAt.dateValue(),
            placeId: first.placeId,
            placeName: first.placeName,
            restricted: isRestricted,
            recipientUids: finalRecipients,
            media: media
        ))

        // Fire-and-forget the doc write (SDK caches locally + retries) — the
        // detached Task lets the caller's spinner stop the moment the
        // optimistic prepend lands above, without awaiting the round-trip.
        let postRefCopy = postRef
        Task.detached {
            do {
                try await postRefCopy.setData(payload)
            } catch {
                #if DEBUG
                print("[SocialService] post setData failed: \(error.localizedDescription)")
                #endif
            }
        }

        // Background Discover classification on the first image (the bytes a
        // stranger would see). Skipped for video-only posts AND for restricted
        // posts — those are never discoverable, so there's nothing to classify
        // and we must not let the verdict patch flip `discoverable` true.
        if let img = firstImageForClassify, !isRestricted {
            let postRefForVerdict = postRef
            Task.detached(priority: .utility) {
                let verdict = await PostClassifier.classify(img)
                #if DEBUG
                print("[Discover] post \(postId): faces=\(verdict.containsFaces) score=\(String(format: "%.2f", verdict.aestheticScore)) discoverable=\(verdict.discoverable)")
                #endif
                try? await postRefForVerdict.setData([
                    "discoverable": verdict.discoverable,
                    "aestheticScore": verdict.aestheticScore,
                    "containsFaces": verdict.containsFaces,
                ], merge: true)
            }
        }
    }

    /// Stable dedup key for a place selection (prefer DB id, then Google id,
    /// then name+coords) so the same place resolves once per post.
    private func placeKey(_ sel: PlaceSelection) -> String {
        if let id = sel.id, !sel.isNew { return "id:\(id)" }
        if let g = sel.googlePlaceId { return "g:\(g)" }
        return "n:\(sel.name.lowercased())|\(sel.lat),\(sel.lng)"
    }

    private func dedupPlaceSelections(_ sels: [PlaceSelection]) -> [PlaceSelection] {
        var seen = Set<String>()
        var out: [PlaceSelection] = []
        for s in sels where seen.insert(placeKey(s)).inserted { out.append(s) }
        return out
    }

    /// Calls the `findOrCreatePlace` Cloud Function — server-side dedup ensures
    /// the same place isn't created twice across users. Returns the resolved
    /// (placeId, placeName) for stamping on the post.
    private func resolvePlace(_ sel: PlaceSelection) async throws -> (id: String, name: String) {
        // Fast path: user picked an existing DB row from the picker — we
        // already have a stable placeId, so skip the cloud round-trip.
        if let existingId = sel.id, !sel.isNew {
            return (existingId, sel.name)
        }

        var lat = sel.lat
        var lng = sel.lng
        // User-added-by-name flow: no coords yet, fall back to current location.
        if lat == 0 && lng == 0 {
            if let coord = await LocationProvider.shared.currentCoordinate() {
                lat = coord.latitude
                lng = coord.longitude
            } else {
                throw SocialError.uploadFailed
            }
        }
        var payload: [String: Any] = [
            "name": sel.name,
            "type": sel.type.rawValue,
            "lat": lat,
            "lng": lng,
        ]
        if let gid = sel.googlePlaceId {
            payload["googlePlaceId"] = gid
        }
        // Pass the Google formatted address so the place doc can store it
        // (used later to derive a city label without reverse-geocoding).
        if let address = sel.address, !address.isEmpty {
            payload["address"] = address
        }
        let callable = Functions.functions().httpsCallable("findOrCreatePlace")
        let result = try await callable.call(payload)
        guard let dict = result.data as? [String: Any],
              let id = dict["placeId"] as? String,
              let name = dict["placeName"] as? String else {
            throw SocialError.uploadFailed
        }
        return (id, name)
    }

    private func generateVideoThumbnail(videoURL: URL, postId: String, authorUid: String) async throws -> String {
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let t = CMTime(seconds: 0.05, preferredTimescale: 600)
        let cg = try await gen.image(at: t).image
        let ui = UIImage(cgImage: cg)
        guard let data = ui.jpegData(compressionQuality: 0.75) else { throw SocialError.uploadFailed }
        let path = "social/\(authorUid)/\(postId)_thumb.jpg"
        let ref = Storage.storage().reference().child(path)
        _ = try await ref.putDataAsync(data)
        return try await ref.downloadURL().absoluteString
    }

    func react(to post: FriendPost, emoji: String) async throws {
        guard let reactor = uid else { throw SocialError.notSignedIn }
        guard reactor != post.authorId else { return }
        try await db.collection("posts").document(post.id).collection("reactions").document(reactor).setData([
            "emoji": emoji,
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    func removeReaction(from post: FriendPost) async throws {
        guard let reactor = uid else { throw SocialError.notSignedIn }
        try await db.collection("posts").document(post.id).collection("reactions").document(reactor).delete()
    }

    func deletePost(_ post: FriendPost) async throws {
        guard let u = uid, u == post.authorId else { throw SocialError.notAuthorized }
        try await db.collection("posts").document(post.id).delete()
        let ext = post.isVideo ? "mp4" : "jpg"
        try? await Storage.storage().reference().child("social/\(u)/\(post.id).\(ext)").delete()
        if post.isVideo {
            try? await Storage.storage().reference().child("social/\(u)/\(post.id)_thumb.jpg").delete()
        }
    }
}

enum SocialError: LocalizedError {
    case notSignedIn
    case invalidUsername
    case usernameTaken
    case userNotFound
    case cannotAddSelf
    case uploadFailed
    case needsUsername
    case notAuthorized
    case friendsCapReached
    case alreadyFriends(username: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .invalidUsername: return "Username must be 3–20 characters (letters, numbers, underscore)."
        case .usernameTaken: return "That username is taken."
        case .userNotFound: return "No user with that username."
        case .cannotAddSelf: return "You can’t add yourself."
        case .uploadFailed: return "Could not upload media."
        case .needsUsername: return "Choose a username first."
        case .notAuthorized: return "Not allowed."
        case .friendsCapReached: return "20-friend limit reached. Remove someone first."
        case .alreadyFriends(let username): return "You're already friends with @\(username)."
        }
    }
}
