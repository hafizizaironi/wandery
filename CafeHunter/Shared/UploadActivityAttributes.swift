import ActivityKit
import Foundation

/// Attributes for the post-upload Live Activity (Dynamic Island ring).
///
/// Shared between the app (which starts/updates/ends the activity via
/// `UploadLiveActivityController`) and the Widget Extension (which renders the
/// Dynamic Island + lock-screen presentations). When the Widget Extension
/// target is added, give THIS file membership in that target too.
struct UploadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 0…1 upload progress, byte-accurate across all media items.
        var progress: Double
        /// True once the upload finished (drives a brief "done" state before
        /// the activity dismisses).
        var done: Bool
        /// True if the upload failed (lets the pill show a failure glyph).
        var failed: Bool
    }

    /// Static attributes fixed for the life of the activity. Empty for now —
    /// the dynamic photo would live here (or a shared App Group file) in a
    /// future pass; v1 shows the app glyph + progress.
    init() {}
}
