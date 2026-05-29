import Foundation

/// A screen a tapped notification wants to open.
enum NotificationDeepLink: Equatable {
    case thread(otherUid: String)
    case post(postId: String)
    case friendRequests
}

/// Bridges notification taps (handled in the non-SwiftUI `NotificationService`
/// delegate) to SwiftUI navigation. `NotificationService.didReceive` parses the
/// push payload and sets `pending`; `MainShellView` observes it and routes,
/// then clears it. A single slot is enough — last tap wins. Buffered values
/// survive a cold-start tap until `MainShellView` mounts and drains them.
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()
    private init() {}

    var pending: NotificationDeepLink?
}
