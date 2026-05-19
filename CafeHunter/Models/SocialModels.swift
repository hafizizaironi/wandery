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
    let placeId: String?
    let placeName: String?

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
        createdAt: Date,
        placeId: String? = nil,
        placeName: String? = nil
    ) {
        self.id = id
        self.authorId = authorId
        self.authorUsername = authorUsername
        self.caption = caption
        self.mediaType = mediaType
        self.mediaURL = mediaURL
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
        self.placeId = placeId
        self.placeName = placeName
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
        placeId = d["placeId"] as? String
        placeName = d["placeName"] as? String
        if let ts = d["createdAt"] as? Timestamp {
            createdAt = ts.dateValue()
        } else {
            createdAt = Date()
        }
    }
}

/// 1:1 conversation between two users. Doc id is deterministic
/// (`Conversation.id(for: a, b)`) so we can `findOrCreate` without a query.
/// `participantIds` is always sorted asc — same convention as the doc id.
struct Conversation: Identifiable, Equatable {
    let id: String
    let participantIds: [String]
    let lastMessage: String
    let lastMessageSenderId: String
    let lastMessageAt: Date?
    let createdAt: Date?

    static func id(for a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    /// The participant that is *not* `me`. Returns nil for malformed docs.
    func otherParticipant(of me: String) -> String? {
        participantIds.first(where: { $0 != me })
    }

    init?(document: DocumentSnapshot) {
        guard let d = document.data() else { return nil }
        guard let ids = d["participantIds"] as? [String], ids.count == 2 else { return nil }
        id = document.documentID
        participantIds = ids
        lastMessage = d["lastMessage"] as? String ?? ""
        lastMessageSenderId = d["lastMessageSenderId"] as? String ?? ""
        lastMessageAt = (d["lastMessageAt"] as? Timestamp)?.dateValue()
        createdAt = (d["createdAt"] as? Timestamp)?.dateValue()
    }
}

/// Single message inside a conversation. Server-stamped `createdAt` so
/// reordering is deterministic across clients.
///
/// `kind` distinguishes plain chat messages from messages that are mirrors
/// of feed-post interactions:
///   - `text`     — direct chat text (default).
///   - `reaction` — reactor emoji-tapped a post; `emoji` + `postId` set.
///   - `reply`    — reactor wrote a comment on a post; `text` + `postId` set.
/// `postPreview` is a short caption snapshot we stamp at write time so the
/// chat bubble can show the post context without a second fetch.
struct ChatMessage: Identifiable, Equatable {
    let id: String
    let senderId: String
    let text: String
    let kind: String
    let postId: String?
    let postPreview: String?
    let emoji: String?
    /// Snapshot of the referenced post's media URL at write time (the
    /// thumbnail URL for videos, the full image URL for photos). Stamped
    /// here so the chat thumbnail can render without an extra fetch.
    let postMediaURL: String?
    let postIsVideo: Bool
    let createdAt: Date

    var isPostReaction: Bool { kind == "reaction" }
    var isPostReply: Bool { kind == "reply" }
    var referencesPost: Bool { postId != nil && (isPostReaction || isPostReply) }

    init?(document: QueryDocumentSnapshot) {
        let d = document.data()
        guard let senderId = d["senderId"] as? String,
              let text = d["text"] as? String else { return nil }
        id = document.documentID
        self.senderId = senderId
        self.text = text
        kind = d["kind"] as? String ?? "text"
        postId = d["postId"] as? String
        postPreview = d["postPreview"] as? String
        emoji = d["emoji"] as? String
        postMediaURL = d["postMediaURL"] as? String
        postIsVideo = d["postIsVideo"] as? Bool ?? false
        if let ts = d["createdAt"] as? Timestamp {
            createdAt = ts.dateValue()
        } else {
            // Doc just written, server stamp not yet acked — sort to bottom.
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
