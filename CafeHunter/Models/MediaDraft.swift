import SwiftUI

/// A single in-progress media item in the compose flow, before upload.
/// Holds either a captured/imported image or a local video file URL, plus
/// an optional place tag and caption. Converted to `PostMedia` on upload.
///
/// Not `Sendable` (carries `UIImage`/`URL`) — lives in `HeroPageView`'s
/// MainActor-isolated state only.
struct MediaDraft: Identifiable, Equatable {
    enum Source: Equatable {
        case image(UIImage)
        case video(URL)
    }

    let id = UUID()
    var source: Source
    var place: PlaceSelection?
    var caption: String?

    var isVideo: Bool {
        if case .video = source { return true }
        return false
    }
}
