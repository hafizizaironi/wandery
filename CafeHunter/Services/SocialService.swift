import AVFoundation
import Combine
import CoreLocation
@preconcurrency import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import UIKit

@MainActor
final class SocialService: ObservableObject {

    @Published private(set) var profile: UserProfile?
    @Published private(set) var friendIds: [String] = []
    @Published private(set) var incomingRequests: [FriendRequestModel] = []
    @Published private(set) var feedPosts: [FriendPost] = []
    @Published private(set) var isLoadingProfile = true
    @Published var errorMessage: String?

    var needsUsername: Bool {
        guard let p = profile else { return true }
        return p.username == nil || p.username?.isEmpty == true
    }

    private let db = Firestore.firestore()
    private var feedListener: ListenerRegistration?
    private var friendsListener: ListenerRegistration?
    private var requestsListener: ListenerRegistration?
    private var profileListener: ListenerRegistration?

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
                    photoURL: data["photoURL"] as? String
                )
            }
        }
        attachFriendsListener(uid: user.uid)
        attachIncomingRequestsListener(uid: user.uid)
    }

    func reset() {
        feedListener?.remove()
        friendsListener?.remove()
        requestsListener?.remove()
        profileListener?.remove()
        feedListener = nil
        friendsListener = nil
        requestsListener = nil
        profileListener = nil
        profile = nil
        friendIds = []
        incomingRequests = []
        feedPosts = []
    }

    private func ensureUserDocument(user: FirebaseAuth.User) {
        let uid = user.uid
        let displayName = user.displayName ?? ""
        let ref = db.collection("users").document(uid)
        ref.getDocument { snap, _ in
            guard let snap, !snap.exists else { return }
            ref.setData([
                "displayName": displayName,
                "createdAt": FieldValue.serverTimestamp(),
            ], merge: true)
        }
    }

    private func attachFriendsListener(uid: String) {
        friendsListener?.remove()
        friendsListener = db.collection("users").document(uid).collection("friends")
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.friendIds = snap?.documents.map(\.documentID) ?? []
                    self.attachFeedListener()
                }
            }
    }

    private func attachIncomingRequestsListener(uid: String) {
        requestsListener?.remove()
        requestsListener = db.collection("friendRequests")
            .whereField("toUid", isEqualTo: uid)
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.incomingRequests = snap?.documents.compactMap { FriendRequestModel(document: $0) } ?? []
                }
            }
    }

    private func attachFeedListener() {
        feedListener?.remove()
        guard let myUid = uid else { return }
        var chunk: [String] = Array(friendIds.prefix(29))
        if !chunk.contains(myUid) {
            chunk.append(myUid)
        }
        if chunk.count > 30 {
            chunk = Array(chunk.prefix(30))
        }
        guard !chunk.isEmpty else {
            feedPosts = []
            return
        }
        feedListener = db.collection("posts")
            .whereField("authorId", in: chunk)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .addSnapshotListener { [weak self] snap, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let err {
                        self.errorMessage = err.localizedDescription
                        self.feedPosts = []
                        return
                    }
                    guard let docs = snap?.documents else {
                        self.feedPosts = []
                        return
                    }
                    self.feedPosts = docs.compactMap { FriendPost(document: $0) }
                        .filter { !$0.mediaURL.isEmpty }
                }
            }
    }

    /// Inserts a row immediately after posting so the feed updates before the next snapshot (and covers listener edge cases).
    func prependOptimisticFeedPost(_ post: FriendPost) {
        guard !feedPosts.contains(where: { $0.id == post.id }) else { return }
        feedPosts = [post] + feedPosts
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
        let fromName = profile?.username ?? (Auth.auth().currentUser?.email ?? "user")
        try await db.collection("friendRequests").addDocument(data: [
            "fromUid": fromUid,
            "toUid": toUid,
            "fromUsername": fromName,
            "status": "pending",
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    func acceptRequest(_ request: FriendRequestModel) async throws {
        guard let myUid = uid else { throw SocialError.notSignedIn }
        guard request.toUid == myUid else { return }
        let reqRef = db.collection("friendRequests").document(request.id)
        let other = request.fromUid
        let batch = db.batch()
        batch.updateData(["status": "accepted"], forDocument: reqRef)
        batch.setData([
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: db.collection("users").document(myUid).collection("friends").document(other))
        batch.setData([
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: db.collection("users").document(other).collection("friends").document(myUid))
        try await batch.commit()
    }

    func rejectRequest(_ request: FriendRequestModel) async throws {
        guard let myUid = uid else { throw SocialError.notSignedIn }
        guard request.toUid == myUid else { return }
        try await db.collection("friendRequests").document(request.id).updateData([
            "status": "rejected",
        ])
    }

    func uploadAndCreatePost(image: UIImage?,
                             videoURL: URL?,
                             caption: String,
                             place: PlaceSelection? = nil) async throws {
        guard let authorUid = uid else { throw SocialError.notSignedIn }
        guard profile?.username != nil else { throw SocialError.needsUsername }
        let cap = String(caption.prefix(25))
        let postRef = db.collection("posts").document()
        let postId = postRef.documentID
        // Client `Timestamp` so `orderBy(createdAt)` queries include the doc immediately. `serverTimestamp()`
        // can leave the field null until the server ack, which excludes the row from ordered queries.
        let createdAt = Timestamp(date: Date())

        // Resolve / dedup the place via Cloud Function before stamping the post.
        // Bypassed for placeless posts.
        let resolvedPlace: (id: String, name: String)? = try await {
            guard let place else { return nil }
            return try await resolvePlace(place)
        }()

        if let image {
            let processed = CameraCaptureProcessing.preparePhotoForUpload(image) ?? image
            guard let data = processed.jpegData(compressionQuality: 0.82) else { throw SocialError.uploadFailed }
            let path = "social/\(authorUid)/\(postId).jpg"
            let ref = Storage.storage().reference().child(path)
            _ = try await ref.putDataAsync(data)
            let url = try await ref.downloadURL()
            var payload: [String: Any] = [
                "authorId": authorUid,
                "authorUsername": profile?.username ?? "user",
                "caption": cap,
                "mediaType": "image",
                "mediaURL": url.absoluteString,
                "createdAt": createdAt,
            ]
            if let resolvedPlace {
                payload["placeId"] = resolvedPlace.id
                payload["placeName"] = resolvedPlace.name
            }
            try await postRef.setData(payload)
            prependOptimisticFeedPost(FriendPost(
                id: postId,
                authorId: authorUid,
                authorUsername: profile?.username ?? "user",
                caption: cap,
                mediaType: "image",
                mediaURL: url.absoluteString,
                thumbnailURL: nil,
                createdAt: createdAt.dateValue(),
                placeId: resolvedPlace?.id,
                placeName: resolvedPlace?.name
            ))
            return
        }

        if let videoURL {
            let squareURL: URL
            if videoURL.lastPathComponent.contains("_sq") {
                squareURL = videoURL
            } else {
                squareURL = (try? await CameraCaptureProcessing.exportSquareVideo(from: videoURL)) ?? videoURL
            }
            let data = try Data(contentsOf: squareURL)
            let path = "social/\(authorUid)/\(postId).mp4"
            let ref = Storage.storage().reference().child(path)
            _ = try await ref.putDataAsync(data)
            let url = try await ref.downloadURL()
            var thumbURL: String?
            if let t = try? await generateVideoThumbnail(videoURL: squareURL, postId: postId, authorUid: authorUid) {
                thumbURL = t
            }
            var payload: [String: Any] = [
                "authorId": authorUid,
                "authorUsername": profile?.username ?? "user",
                "caption": cap,
                "mediaType": "video",
                "mediaURL": url.absoluteString,
                "createdAt": createdAt,
            ]
            if let thumbURL {
                payload["thumbnailURL"] = thumbURL
            }
            if let resolvedPlace {
                payload["placeId"] = resolvedPlace.id
                payload["placeName"] = resolvedPlace.name
            }
            try await postRef.setData(payload)
            prependOptimisticFeedPost(FriendPost(
                id: postId,
                authorId: authorUid,
                authorUsername: profile?.username ?? "user",
                caption: cap,
                mediaType: "video",
                mediaURL: url.absoluteString,
                thumbnailURL: thumbURL,
                createdAt: createdAt.dateValue(),
                placeId: resolvedPlace?.id,
                placeName: resolvedPlace?.name
            ))
            return
        }
        throw SocialError.uploadFailed
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
        }
    }
}
