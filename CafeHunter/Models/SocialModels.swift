import Foundation
import FirebaseFirestore

struct UserProfile: Equatable {
    var username: String?
    var usernameLower: String?
    var displayName: String?
    var photoURL: String?
    /// When true, this user's visits do NOT contribute to other users'
    /// friend-of-friend Discover. Default false (treat absent as opted in).
    var optedOutOfDiscovery: Bool = false
    /// Base64 X25519 public key for E2EE messaging. Published by
    /// `SocialService.ensureIdentityKey()`. Nil for users who haven't
    /// run the E2EE-capable build yet (their messages fall back to plaintext).
    var publicKey: String?
}

// NOTE: `PostMedia` and `FriendPost` were moved to `PostModels.swift` so the
// `FriendsFeedWidget` extension can share them without pulling in the messaging
// types below.

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
    /// Per-uid "last seen the thread" stamps. Promoted from the v1
    /// local-only `@AppStorage` approach in Phase 3.6. Missing entries
    /// mean "never marked read on this server" — readers fall back to
    /// the local stamp for backwards compatibility on legacy convs.
    let lastReadAt: [String: Date]
    /// True when `lastMessage` holds E2EE ciphertext (sealed with the
    /// conversation key). The inbox decrypts it before display. False for
    /// legacy/plaintext previews, reaction-mirror templates, and "Message
    /// deleted".
    let lastMessageEnc: Bool

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
        if let raw = d["lastReadAt"] as? [String: Timestamp] {
            lastReadAt = raw.mapValues { $0.dateValue() }
        } else {
            lastReadAt = [:]
        }
        lastMessageEnc = d["lastMessageEnc"] as? Bool ?? false
    }

    private init(id: String, participantIds: [String], lastMessage: String,
                 lastMessageSenderId: String, lastMessageAt: Date?, createdAt: Date?,
                 lastReadAt: [String: Date], lastMessageEnc: Bool) {
        self.id = id
        self.participantIds = participantIds
        self.lastMessage = lastMessage
        self.lastMessageSenderId = lastMessageSenderId
        self.lastMessageAt = lastMessageAt
        self.createdAt = createdAt
        self.lastReadAt = lastReadAt
        self.lastMessageEnc = lastMessageEnc
    }

    /// Returns a copy with `lastMessage` replaced (used after decrypting the
    /// inbox preview); clears `lastMessageEnc` since the held value is now plain.
    func withLastMessage(_ newValue: String) -> Conversation {
        Conversation(id: id, participantIds: participantIds, lastMessage: newValue,
                     lastMessageSenderId: lastMessageSenderId, lastMessageAt: lastMessageAt,
                     createdAt: createdAt, lastReadAt: lastReadAt, lastMessageEnc: false)
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
    /// Per-uid reactions on this message. Keys are participant uids,
    /// values are emoji strings. iMessage-style: each participant may
    /// add at most one reaction, and senders can react to their own
    /// messages too. Updated in place via `reactToMessage` /
    /// `unreactToMessage` on `ConversationService`. Empty by default
    /// for any message older than 2026-05; new messages also start
    /// empty and only materialise the field after a first reaction.
    let reactions: [String: String]
    /// In-thread reply ("swipe/long-press → Reply"). `replyToId` is the
    /// replied-to message's doc id; `replyToText` is a snippet snapshot
    /// stamped at write time so the quoted header renders without a fetch.
    /// Both nil for non-reply messages.
    let replyToId: String?
    let replyToText: String?
    /// Soft-delete tombstone (unsend). The sender flips this true; the
    /// bubble then renders a "message deleted" placeholder. Hard deletes
    /// stay disabled in the rules, so this is the only unsend path.
    let deleted: Bool
    /// True once the referenced post has been deleted by its author — the
    /// `onPostDelete` function sets this (and strips `postMediaURL`) on every
    /// reply/reaction mirror, so the chat stops showing the dead image. The
    /// reply text stays; only the post preview becomes "no longer available".
    let postDeleted: Bool
    /// E2EE version flag. `0` (or absent) = legacy plaintext; `>= 1` = `text`
    /// (and `replyToText`/`postPreview` when present) hold AES-GCM ciphertext
    /// that `ConversationService` decrypts before publishing. Set to `0` for
    /// optimistic/pending bubbles (they hold plaintext locally).
    let encv: Int

    var isPostReaction: Bool { kind == "reaction" }
    var isPostReply: Bool { kind == "reply" }
    var referencesPost: Bool { postId != nil && (isPostReaction || isPostReply) }
    /// True for an in-thread message reply (distinct from a post mirror).
    var isMessageReply: Bool { replyToId != nil }

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
        reactions = d["reactions"] as? [String: String] ?? [:]
        replyToId = d["replyToId"] as? String
        replyToText = d["replyToText"] as? String
        deleted = d["deleted"] as? Bool ?? false
        postDeleted = d["postDeleted"] as? Bool ?? false
        encv = d["encv"] as? Int ?? 0
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
    /// Recipient's username — only present on requests created after the
    /// cancel feature shipped; older docs leave it nil.
    let toUsername: String?
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
        toUsername = d["toUsername"] as? String
        if let ts = d["createdAt"] as? Timestamp {
            createdAt = ts.dateValue()
        } else {
            createdAt = Date()
        }
    }
}
