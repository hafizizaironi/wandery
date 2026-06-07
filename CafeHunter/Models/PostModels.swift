import Foundation
import FirebaseFirestore

// Post models live in their own file (split out of `SocialModels.swift`) so the
// `FriendsFeedWidget` extension can compile `FriendPost`/`PostMedia` without
// dragging in the messaging types (`Conversation`, `ChatMessage`) and their
// app-only dependencies. Add this file to BOTH the `CafeHunter` and
// `FriendsFeedWidgetExtension` targets (membership exception in the synchronized
// group — same mechanism `Keychain.swift`/`MessageCrypto.swift` use for the NSE).
// Only dependency here is FirebaseFirestore (Timestamp / QueryDocumentSnapshot).

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

    /// Audience gate. `false` (or absent on legacy docs → decoded false) =
    /// an "everyone" post, visible to all the author's friends (and Discover
    /// if `discoverable`). `true` = audience-limited: visible ONLY to the
    /// uids in `recipientUids`. A restricted post is never discoverable. See
    /// firestore.rules for the matching read-gate.
    let restricted: Bool
    /// When `restricted`, the exact set of uids that may see the post —
    /// the selected friends PLUS the author. Empty for "everyone" posts.
    let recipientUids: [String]

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
        restricted: Bool = false,
        recipientUids: [String] = [],
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
        self.restricted = restricted
        self.recipientUids = recipientUids
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
        // Legacy docs predate the audience gate; absent → "everyone".
        restricted = (d["restricted"] as? Bool) ?? false
        recipientUids = d["recipientUids"] as? [String] ?? []
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
