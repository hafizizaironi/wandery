import WidgetKit
import Foundation

/// A friend post reduced to exactly what the Photo Feed widget renders. Built
/// from either a live `FriendPost` (background-fresh path) or a cached
/// `SharedFeedStore.CachedPost` (instant/offline path).
struct WidgetPost: Equatable {
    let id: String
    let authorId: String
    let username: String
    let authorPhotoURL: String?
    let placeName: String?
    let caption: String
    let createdAt: Date
    /// Display-ready image URLs in carousel order (always ≥1).
    let photoURLs: [String]

    var photoCount: Int { photoURLs.count }
    var hue: Double { wanderyHue(for: authorId) }
    /// First letter of the handle for the avatar fallback (when no photo).
    var initials: String { username.first.map { String($0).uppercased() } ?? "?" }
}

/// One timeline frame: a post shown at a specific carousel index, with that
/// photo's bytes (and the author's avatar) pre-fetched — widgets can't load
/// remote images at render time.
struct PhotoEntry: TimelineEntry {
    let date: Date
    let post: WidgetPost?
    let index: Int
    let image: Data?
    let avatar: Data?
    /// Config: show the place/caption overlay (large family).
    let showCaption: Bool
    /// True when no signed-in user could be resolved — prompts "Open Wandery".
    let signedOut: Bool

    init(date: Date, post: WidgetPost?, index: Int, image: Data?, avatar: Data?,
         showCaption: Bool = true, signedOut: Bool) {
        self.date = date
        self.post = post
        self.index = index
        self.image = image
        self.avatar = avatar
        self.showCaption = showCaption
        self.signedOut = signedOut
    }

    static func empty(signedOut: Bool) -> PhotoEntry {
        PhotoEntry(date: Date(), post: nil, index: 0, image: nil, avatar: nil, signedOut: signedOut)
    }
}

/// Deterministic 0–360 hue from a string. `String.hashValue` is randomized per
/// process, which would flicker the avatar colour between widget reloads — so
/// roll a stable FNV-1a hash instead.
func wanderyHue(for s: String) -> Double {
    var h: UInt64 = 1_469_598_103_934_665_603        // FNV-1a offset basis
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
    return Double(h % 360)
}
