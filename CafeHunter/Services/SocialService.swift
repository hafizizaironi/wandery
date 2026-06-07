import AVFoundation
import Combine
import CoreLocation
@preconcurrency import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import UIKit
import WidgetKit

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

    // MARK: - Background post upload
    /// True while a post is uploading in the background (the user has already
    /// returned to the camera). Drives the non-DI "Posting…" pill and the
    /// Live Activity lifecycle.
    private(set) var isUploadingPost = false
    /// Real upload progress 0…1 across all media items (byte-accurate via
    /// `StorageUploadTask`). Drives the Live Activity ring + non-DI pill.
    // `private(set)` dropped to internal-set so the upload pipeline in
    // `SocialService+Upload.swift` can advance it; views still only read it.
    var uploadProgress: Double = 0
    /// Set when a background upload fails — surfaces the retry banner. Cleared
    /// on retry / dismiss.
    var pendingUploadError: String?
    /// Incremented when the flying capture card "dives" into the Dynamic Island,
    /// so the in-app DI ring can splash/ripple in reaction. Bumped by the view.
    private(set) var cardImpactTick = 0
    func signalCardImpact() { cardImpactTick += 1 }
    /// Drafts + audience kept so a failed upload can be retried verbatim.
    private var savedUpload: (drafts: [MediaDraft], recipients: [String]?)?

    /// Raw posts from Firestore before blocked-user filtering. Kept private
    /// so callers always see the filtered `feedPosts`. Re-applied through
    /// `applyBlockedFilter()` whenever either input changes.
    private var rawFeedPosts: [FriendPost] = []
    /// Sources merged into `rawFeedPosts`: "everyone" posts by me + friends
    /// (Q1) and restricted posts directed at me (Q2). Kept separate so each
    /// listener updates independently before `mergeFeeds()` recombines them.
    private var rawOpenPosts: [FriendPost] = []
    private var rawRestrictedPosts: [FriendPost] = []
    /// Last time we asked WidgetKit to reload, so feed churn doesn't blow the
    /// daily refresh budget. See `mirrorFeedToWidget()`.
    private var lastWidgetReload: Date?

    var needsUsername: Bool {
        guard let p = profile else { return true }
        return p.username == nil || p.username?.isEmpty == true
    }

    // Internal (not private) so the `SocialService+Upload.swift` extension can reach it.
    let db = Firestore.firestore()
    private var feedListener: ListenerRegistration?
    /// Q2 listener for restricted posts directed at me (recipientUids contains me).
    private var restrictedFeedListener: ListenerRegistration?
    private var friendsListener: ListenerRegistration?
    private var requestsListener: ListenerRegistration?
    private var outgoingRequestsListener: ListenerRegistration?
    private var profileListener: ListenerRegistration?
    private var blockedListener: ListenerRegistration?

    var uid: String? { Auth.auth().currentUser?.uid }

    func start(for user: FirebaseAuth.User?) {
        reset()
        guard let user else {
            isLoadingProfile = false
            // Signed out: wipe the widget's shared cache and blank it out.
            SharedFeedStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        isLoadingProfile = true
        // Mirror the uid so the widget can resolve which feed to query even
        // before its shared Auth state is warm.
        SharedFeedStore.writeUID(user.uid)
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
                    // Hand the friend list to the widget so its timeline
                    // provider can build the feed query without a separate read.
                    SharedFeedStore.writeFriendIds(self.friendIds)
                    // Mirror friend names for the widget's "Show photos from"
                    // picker (the friends subcollection has only ids).
                    self.mirrorFriendsToWidget()
                    self.attachFeedListener()
                }
            }
    }

    /// Last friend-id set we mirrored names for — skip re-fetching profiles
    /// when the friends listener fires without an actual membership change.
    private var lastMirroredFriendIds: Set<String> = []

    /// Resolve friend display names from `users/{id}` and cache them in the App
    /// Group for the widget's "Show photos from" picker. Only runs when the
    /// friend set changed (rare), batching the id lookups 30 at a time.
    private func mirrorFriendsToWidget() {
        let ids = friendIds
        let idSet = Set(ids)
        guard idSet != lastMirroredFriendIds else { return }
        lastMirroredFriendIds = idSet
        guard !ids.isEmpty else { SharedFeedStore.writeFriends([]); return }
        Task {
            var summaries: [SharedFeedStore.FriendSummary] = []
            for start in stride(from: 0, to: ids.count, by: 30) {
                let chunk = Array(ids[start..<min(start + 30, ids.count)])
                guard let snap = try? await db.collection("users")
                    .whereField(FieldPath.documentID(), in: chunk).getDocuments() else { continue }
                for doc in snap.documents {
                    let d = doc.data()
                    let display = (d["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let name = display ?? (d["username"] as? String) ?? "Friend"
                    summaries.append(.init(id: doc.documentID, name: name))
                }
            }
            SharedFeedStore.writeFriends(summaries.sorted { $0.name.lowercased() < $1.name.lowercased() })
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
        mirrorFeedToWidget()
    }

    /// Mirror the top of the feed into the App Group and nudge the widget.
    /// The snapshot write is a cheap local file so it runs every time (keeps the
    /// widget's instant/offline render fresh); the WidgetKit reload is debounced
    /// to ~once per 30s so listener churn doesn't exhaust the daily refresh
    /// budget (~40–70/day). The real-time nudge comes from the Notification
    /// Service Extension on a `newPost` push.
    private func mirrorFeedToWidget() {
        // Friends only — the widget never shows the signed-in user's own posts.
        let me = uid
        let cached = feedPosts.filter { $0.authorId != me }.prefix(6).map { post in
            SharedFeedStore.CachedPost(
                id: post.id,
                authorId: post.authorId,
                username: post.authorUsername,
                caption: post.primaryCaption ?? "",
                mediaURL: post.primaryMediaURL,
                thumbnailURL: post.primaryThumbnailURL,
                createdAt: post.createdAt,
                placeName: post.primaryPlaceName,
                // All photos in carousel order; `displayURL` resolves video
                // posters so the widget always downloads an image.
                photos: post.media.map {
                    SharedFeedStore.CachedPost.Photo(url: $0.displayURL, thumbnailURL: nil)
                }
            )
        }
        SharedFeedStore.writeSnapshot(Array(cached))

        let now = Date()
        if let last = lastWidgetReload, now.timeIntervalSince(last) < 30 { return }
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
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
    // MARK: - Background upload entry points

    /// Fire-and-forget a post upload. Returns immediately so the caller can run
    /// its launch transition and let the user keep interacting; the upload runs
    /// on a service-owned Task that outlives the capture view. On success the
    /// post lands in the feed via the existing optimistic prepend; on failure
    /// `pendingUploadError` is set (and the drafts are kept for `retryUpload`).
    func enqueuePost(drafts: [MediaDraft], recipientUids: [String]?) {
        savedUpload = (drafts, recipientUids)
        pendingUploadError = nil
        isUploadingPost = true
        uploadProgress = 0
        UploadLiveActivityController.shared.start()
        Task { await runUpload() }
    }

    /// Re-run the last failed upload with the saved drafts/audience.
    func retryUpload() {
        guard let s = savedUpload else { return }
        enqueuePost(drafts: s.drafts, recipientUids: s.recipients)
    }

    func dismissUploadError() { pendingUploadError = nil }

    private func runUpload() async {
        guard let s = savedUpload else { return }
        do {
            try await uploadAndCreatePost(drafts: s.drafts, recipientUids: s.recipients)
            uploadProgress = 1
            isUploadingPost = false
            savedUpload = nil
            UploadLiveActivityController.shared.finish(failed: false)
        } catch {
            isUploadingPost = false
            pendingUploadError = Self.friendlyUploadError(error)
            UploadLiveActivityController.shared.finish(failed: true)
            // savedUpload retained so the banner's Retry can replay it.
        }
    }

    private static func friendlyUploadError(_ error: Error) -> String {
        let ns = error as NSError
        let lower = ns.localizedDescription.lowercased()
        if lower.contains("network") || lower.contains("offline") || lower.contains("internet") {
            return "No internet — your moment didn't make it out 📶"
        }
        return "That moment didn't post — give it another go?"
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
        case .notSignedIn: return "Looks like you're not signed in."
        case .invalidUsername: return "Keep it to 3–20 characters — letters, numbers, and underscores only ✏️"
        case .usernameTaken: return "Aw, someone snagged that one already. Try another?"
        case .userNotFound: return "Couldn't find anyone with that username 🤔"
        case .cannotAddSelf: return "You can't add yourself, you legend 😄"
        case .uploadFailed: return "That upload didn't go through — give it another go?"
        case .needsUsername: return "Pick a username first ✏️"
        case .notAuthorized: return "Hmm, you're not allowed to do that."
        case .friendsCapReached: return "Whoa, your circle's full at 20! Make room for a new one first 🔥"
        case .alreadyFriends(let username): return "You two are already friends! @\(username) 🤝"
        }
    }
}
