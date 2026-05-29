import ActivityKit
import Foundation

/// Attributes for the post-upload Live Activity.
///
/// ⚠️ This is a deliberate copy of `CafeHunter/Shared/UploadActivityAttributes.swift`.
/// The app target and this Widget Extension are separate modules; ActivityKit
/// bridges them by the (unqualified) type name, so both must declare a type
/// named `UploadActivityAttributes` with an identical `ContentState`. Keep the
/// two files in sync — if you change one, change the other.
struct UploadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double
        var done: Bool
        var failed: Bool
    }

    init() {}
}
