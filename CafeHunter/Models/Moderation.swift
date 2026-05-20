import Foundation

/// What the user is reporting. Used by the `reportContent` Cloud Function;
/// server validates the raw value against an allow-list.
enum ReportTargetType: String, Sendable {
    case user
    case post
    case message
}

/// Identifiable wrapper used as a `.sheet(item:)` driver for the
/// ReportSheet. The view sets this when the user taps Report; SwiftUI
/// presents the modal and clears it on dismiss.
struct ReportTarget: Identifiable, Equatable, Hashable {
    let type: ReportTargetType
    let targetId: String
    var id: String { "\(type.rawValue):\(targetId)" }
}

/// Why the user is reporting. Server-side enum matches; if we add a case
/// here, update functions/index.js too.
enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case spam
    case harassment
    case inappropriate
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam:          "Spam"
        case .harassment:    "Harassment or bullying"
        case .inappropriate: "Inappropriate content"
        case .other:         "Other"
        }
    }
}
