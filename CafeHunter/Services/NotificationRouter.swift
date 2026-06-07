import Foundation

/// A screen a tapped notification wants to open.
enum NotificationDeepLink: Equatable {
    case thread(otherUid: String)
    case post(postId: String)
    case friendRequests
    /// Open the friends feed (the Hero page). Set by a widget tap
    /// (`wandery://feed`) — see `CafeHunterApp.onOpenURL`.
    case feed
    /// Open a specific place's detail. Set by a Nearby Map widget tap
    /// (`wandery://place/<id>`) → jumps the map + opens `PlaceDetailSheet`.
    case place(placeId: String)
    /// Open the live map centered on the user (`wandery://nearby` widget tap).
    case nearby
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
