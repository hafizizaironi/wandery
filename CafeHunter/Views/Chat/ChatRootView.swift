import SwiftUI

/// NavigationStack container for the whole chat surface. Hosted from
/// `MainShellView` via `.fullScreenCover(item: $chatPresentation)`.
///
/// `initialRoute` decides whether the cover opens on the inbox (Hero's
/// Messages button) or jumps straight to a thread (FriendListView's
/// per-row chat icon). Either way, the user can navigate freely after
/// landing — popping to the inbox is always available.
///
/// Reason we push the thread via `NavigationStack` instead of presenting
/// it as a sheet/overlay: SwiftUI's automatic keyboard safe-area inset
/// only propagates through real `NavigationStack` pushes, so the composer
/// tracks the keyboard 1:1 for free. (Documented in the chat handoff
/// gotcha #5.)
struct ChatRootView: View {
    var conversationService: ConversationService
    var socialService:       SocialService
    var initialRoute:        ChatRoute
    var onDismiss:           () -> Void
    /// Optional: when set, post-reference bubbles in chat threads
    /// become tappable. Tapping dismisses the chat surface and stages
    /// the post id on MainShellView's `pendingHeroPostJumpId`.
    var onJumpToPost:        ((String) -> Void)?

    @State private var hydrator = ParticipantHydrator()
    @State private var path:     [ChatRoute]

    init(
        conversationService: ConversationService,
        socialService:       SocialService,
        initialRoute:        ChatRoute,
        onDismiss:           @escaping () -> Void,
        onJumpToPost:        ((String) -> Void)? = nil
    ) {
        self.conversationService = conversationService
        self.socialService       = socialService
        self.initialRoute        = initialRoute
        self.onDismiss           = onDismiss
        self.onJumpToPost        = onJumpToPost
        // Seed the path so opening straight into a thread doesn't flash
        // the inbox for a frame before pushing.
        switch initialRoute {
        case .inbox:  _path = State(initialValue: [])
        case .thread: _path = State(initialValue: [initialRoute])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            InboxView(
                conversationService: conversationService,
                socialService:       socialService,
                hydrator:            hydrator,
                onClose:             onDismiss,
                onOpenThread:        { route in path.append(route) }
            )
            .navigationDestination(for: ChatRoute.self) { route in
                destination(for: route)
            }
        }
        .tint(AppTheme.accentAction)
        // Force light color scheme — AppTheme's palette is fixed-light
        // (cream / ink), so leaving system color scheme to .dark gives
        // us inverted system text colors + dark materials on top of
        // light AppTheme backgrounds. The whole chat surface lives in
        // the light palette deliberately.
        .preferredColorScheme(.light)
        .onDisappear {
            // Detach the thread listener when the cover closes so we
            // aren't paying for a snapshot stream behind the scenes.
            conversationService.openThread(nil)
            hydrator.reset()
        }
    }

    @ViewBuilder
    private func destination(for route: ChatRoute) -> some View {
        switch route {
        case .inbox:
            // Defensive — inbox is the navigation root, but we declare
            // it here so a programmatic `.inbox` push doesn't 404.
            InboxView(
                conversationService: conversationService,
                socialService:       socialService,
                hydrator:            hydrator,
                onClose:             onDismiss,
                onOpenThread:        { r in path.append(r) }
            )
        case .thread(let uid, let displayName, let photoURL):
            ChatThreadView(
                conversationService: conversationService,
                socialService:       socialService,
                hydrator:            hydrator,
                otherUid:            uid,
                seedDisplayName:     displayName,
                seedPhotoURL:        photoURL,
                onJumpToPost:        onJumpToPost
            )
        }
    }
}
