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

/// One media item within a post. A post carries 1…6 of these in display
/// order. Each can optionally carry its own place tag and caption.
struct PostMedia: Identifiable, Equatable {
    let type: String          // "image" | "video"
    let url: String
    let thumbnailURL: String?
    let placeId: String?
    let placeName: String?
    let caption: String?

    /// Stable identity for ForEach — `url` is unique within a post.
    var id: String { url }
    var isVideo: Bool { type == "video" }
    /// Thumbnail for videos, the image url otherwise.
    var displayURL: String { isVideo ? (thumbnailURL ?? url) : url }

    init(type: String, url: String, thumbnailURL: String? = nil,
         placeId: String? = nil, placeName: String? = nil, caption: String? = nil) {
        self.type = type
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.placeId = placeId
        self.placeName = placeName
        self.caption = caption
    }

    init?(dict: [String: Any]) {
        guard let type = dict["type"] as? String,
              let url = dict["url"] as? String, !url.isEmpty else { return nil }
        self.type = type
        self.url = url
        self.thumbnailURL = dict["thumbnailURL"] as? String
        self.placeId = dict["placeId"] as? String
        self.placeName = dict["placeName"] as? String
        self.caption = dict["caption"] as? String
    }
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
    /// Set by `PostClassifier` as a background task after upload, or by
    /// the author flipping the "Hide from Discover" toggle. When true,
    /// the post may surface to strangers in Discover; when false, the
    /// post stays inside the author's friend graph (default for any
    /// post that pre-dates the classifier). See firestore.rules for the
    /// matching read-gate.
    let discoverable: Bool
    /// Apple Vision aesthetic score 0…1. Used to rank Discover candidates
    /// when multiple discoverable posts exist for the same place.
    let aestheticScore: Double?
    /// Mirror of the classifier's face-gate verdict — kept on the doc
    /// for analytics + so a manual review surface can sort by it.
    let containsFaces: Bool?

    /// All media items in display order (always ≥1). Legacy single-media
    /// docs are synthesized into a one-item array from the top-level fields.
    let media: [PostMedia]

    var isVideo: Bool { media.first?.isVideo ?? (mediaType == "video") }
    var isMultiMedia: Bool { media.count > 1 }

    // Back-compat accessors — callers reading a single value get item 0;
    // the legacy stored fields remain the source for old docs.
    var primaryMediaURL: String { media.first?.url ?? mediaURL }
    var primaryThumbnailURL: String? { media.first?.thumbnailURL ?? thumbnailURL }
    var primaryPlaceName: String? {
        media.first(where: { $0.placeName?.isEmpty == false })?.placeName ?? placeName
    }
    var primaryCaption: String? {
        if let c = media.first(where: { $0.caption?.isEmpty == false })?.caption { return c }
        return caption.isEmpty ? nil : caption
    }

    /// Distinct tagged places across all media (first-seen order) — drives the
    /// map fan-out so a post surfaces under every place its photos tagged.
    var distinctPlaces: [(id: String, name: String)] {
        var seen = Set<String>()
        var out: [(id: String, name: String)] = []
        for m in media where m.placeId != nil {
            if seen.insert(m.placeId!).inserted {
                out.append((id: m.placeId!, name: m.placeName ?? ""))
            }
        }
        if out.isEmpty, let pid = placeId {
            out.append((id: pid, name: placeName ?? ""))
        }
        return out
    }
    var distinctPlaceIds: [String] { distinctPlaces.map(\.id) }

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
        placeName: String? = nil,
        discoverable: Bool = false,
        aestheticScore: Double? = nil,
        containsFaces: Bool? = nil,
        media: [PostMedia]? = nil
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
        self.discoverable = discoverable
        self.aestheticScore = aestheticScore
        self.containsFaces = containsFaces
        self.media = media ?? [PostMedia(
            type: mediaType, url: mediaURL, thumbnailURL: thumbnailURL,
            placeId: placeId, placeName: placeName,
            caption: caption.isEmpty ? nil : caption
        )]
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
        // Default to private — posts that pre-date the classifier never
        // had a `discoverable` field, and we never want a legacy post
        // surfacing publicly because of a default-true.
        discoverable = (d["discoverable"] as? Bool) ?? false
        aestheticScore = d["aestheticScore"] as? Double
        containsFaces = d["containsFaces"] as? Bool
        if let ts = d["createdAt"] as? Timestamp {
            createdAt = ts.dateValue()
        } else {
            createdAt = Date()
        }
        // New docs carry a `media` array; legacy single-media docs are
        // synthesized into a one-item array from the mirrored top-level fields.
        let synthesized = PostMedia(
            type: mediaType, url: mediaURL, thumbnailURL: thumbnailURL,
            placeId: placeId, placeName: placeName,
            caption: caption.isEmpty ? nil : caption
        )
        if let rawMedia = d["media"] as? [[String: Any]] {
            let parsed = rawMedia.compactMap { PostMedia(dict: $0) }
            media = parsed.isEmpty ? [synthesized] : parsed
        } else {
            media = [synthesized]
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
