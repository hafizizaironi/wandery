import Foundation

/// Typed routing for the chat NavigationStack. Lives at the file level
/// (not nested) so both `ChatRootView` and the presenting surfaces
/// (HeroPageView, ProfileHomeView) can refer to it.
///
/// `thread` carries the other participant's `uid` + an optional preview
/// of their display name / photo URL so the thread header can render the
/// correct identity *before* the conv doc exists (i.e. on the very first
/// message between two people).
enum ChatRoute: Hashable, Identifiable {
    case inbox
    case thread(otherUid: String, displayName: String?, photoURL: String?)

    var id: String {
        switch self {
        case .inbox: return "inbox"
        case .thread(let uid, _, _): return "thread_\(uid)"
        }
    }
}
