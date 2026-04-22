import Foundation
import FirebaseFirestore

struct UserProfile: Equatable {
    var username: String?
    var usernameLower: String?
    var displayName: String?
    var photoURL: String?
}

struct FriendPost: Identifiable, Equatable {
    let id: String
    let authorId: String
    let authorUsername: String
    let caption: String
    let mediaType: String
    let mediaURL: String
    let thumbnailURL: String?
    let createdAt: Date

    var isVideo: Bool { mediaType == "video" }

    /// Local / optimistic row (e.g. right after posting) — mirrors Firestore fields.
    init(
        id: String,
        authorId: String,
        authorUsername: String,
        caption: String,
        mediaType: String,
        mediaURL: String,
        thumbnailURL: String?,
        createdAt: Date
    ) {
        self.id = id
        self.authorId = authorId
        self.authorUsername = authorUsername
        self.caption = caption
        self.mediaType = mediaType
        self.mediaURL = mediaURL
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
    }

    init?(document: QueryDocumentSnapshot) {
        let d = document.data()
        guard let authorId = d["authorId"] as? String,
              let authorUsername = d["authorUsername"] as? String,
              let caption = d["caption"] as? String,
              let mediaType = d["mediaType"] as? String,
              let mediaURL = d["mediaURL"] as? String else { return nil }
        id = document.documentID
        self.authorId = authorId
        self.authorUsername = authorUsername
        self.caption = caption
        self.mediaType = mediaType
        self.mediaURL = mediaURL
        thumbnailURL = d["thumbnailURL"] as? String
        if let ts = d["createdAt"] as? Timestamp {
            createdAt = ts.dateValue()
        } else {
            createdAt = Date()
        }
    }
}

struct FriendRequestModel: Identifiable, Equatable {
    let id: String
    let fromUid: String
    let toUid: String
    let fromUsername: String
    let status: String
    let createdAt: Date

    init?(document: QueryDocumentSnapshot) {
        let d = document.data()
        guard let fromUid = d["fromUid"] as? String,
              let toUid = d["toUid"] as? String,
              let status = d["status"] as? String else { return nil }
        id = document.documentID
        self.fromUid = fromUid
        self.toUid = toUid
        self.status = status
        fromUsername = d["fromUsername"] as? String ?? "user"
        if let ts = d["createdAt"] as? Timestamp {
            createdAt = ts.dateValue()
        } else {
            createdAt = Date()
        }
    }
}
