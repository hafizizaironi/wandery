import SwiftUI

// Page order matches the arc's left-to-right tab positions:
//   Map (t=0.15, left) | Hero (t=0.50, center) | Profile (t=0.85, right)
enum ShellPage: Int, CaseIterable {
    case map     = 0
    case hero    = 1
    case profile = 2
}

struct MainShellView: View {
    var authService:         AuthService
    var firestoreService:    FirestoreService
    var statsService:        UserStatsService
    var socialService:       SocialService
    var conversationService: ConversationService
    var userPrivateService:  UserPrivateService

    // Start on the Hero (feed) page — centre of the arc.
    @State private var selectedPage: ShellPage = .hero
    @State private var pageProgress: CGFloat   = 1
    /// Snapshot of `pageProgress` at the moment an edge-drag started.
    /// The drag handler updates `pageProgress = start - dx / width` so
    /// the user can swipe back and forth without each frame compounding.
    @State private var edgeDragStartProgress: CGFloat? = nil
    /// Snapshot of `selectedPage` at the moment an edge-drag started.
    /// Used to clamp the drag's reachable range to ±1 page from the
    /// starting page — a single drag can never skip past an adjacent
    /// page (e.g., Map → Profile in one gesture is impossible).
    @State private var edgeDragStartPage: ShellPage = .hero
    /// True while an edge drag is in flight. We commit to "this is a
    /// page-switch gesture" on the first `.onChanged` (where we know
    /// the start location) and ignore drags that started away from the
    /// edges, so vertical scrolling inside Hero / Profile stays
    /// untouched.
    @State private var edgeDragActive: Bool = false
    /// Set when the user taps a place pill in the feed; consumed by MainMapView
    /// which centers the map and opens the place-detail sheet.
    @State private var pendingMapJumpPlaceId: String?
    /// Set when the user taps a post-reference bubble inside chat;
    /// consumed by HeroPageView, which scrolls to that post.
    @State private var pendingHeroPostJumpId: String?
    /// Drives the chat surface presented as a `.fullScreenCover`. Set
    /// from Hero's Messages button (`.inbox`) or from the FriendListView
    /// per-row chat icon (`.thread`). Nil = no chat visible.
    @State private var chatPresentation: ChatRoute?

    /// Soft phone-prompt state. The panel is the friendly explainer that
    /// pops once per cold launch; the sheet is the full phone-onboarding
    /// flow it hands off to. `didPromptThisLaunch` blocks re-presenting
    /// after the user dismisses — they'll see it again on the next cold
    /// launch.
    @State private var showPhonePromptPanel = false
    @State private var showPhoneOnboardingSheet = false
    @State private var didPromptThisLaunch = false

    /// Contacts suggestion state. The panel pops once per user (gated
    /// by `userPrivateService.profile.contactsPromptShown`); tapping
    /// "Find friends" hands off to the full FriendFindView sheet.
    @State private var showContactsSuggestionPanel = false
    @State private var showFriendFindSheet = false
    @State private var didEvaluateContactsThisLaunch = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {

                // ── Pages ── absolutely positioned so they slide live
                // as pageProgress changes (driven by arc navbar taps / swipes).
                ZStack {
                    MainMapView(
                        authService: authService,
                        firestoreService: firestoreService,
                        socialService: socialService,
                        pendingPlaceJumpId: $pendingMapJumpPlaceId
                    )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (0 - pageProgress) * geo.size.width)
                        // Off-screen siblings keep full layout frames; without this they steal taps on Map.
                        .allowsHitTesting(abs(pageProgress - 0) < 0.5)

                    HeroPageView(
                        isActive: selectedPage == .hero,
                        socialService: socialService,
                        conversationService: conversationService,
                        pendingPostJumpId: $pendingHeroPostJumpId,
                        edgeDragActive: edgeDragActive,
                        onJumpToPlace: { placeId in jumpToMap(placeId: placeId) },
                        onOpenMessages: { chatPresentation = .inbox }
                    )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (1 - pageProgress) * geo.size.width)
                        .allowsHitTesting(abs(pageProgress - 1) < 0.5)

                    ProfileHomeView(
                        authService:         authService,
                        statsService:        statsService,
                        socialService:       socialService,
                        userPrivateService:  userPrivateService,
                        isTabActive:         abs(pageProgress - 2) < 0.5,
                        onMessageFriend:     { row in
                            chatPresentation = .thread(
                                otherUid: row.id,
                                displayName: row.titleText,
                                photoURL: row.photoURL
                            )
                        }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(x: (2 - pageProgress) * geo.size.width)
                    .allowsHitTesting(abs(pageProgress - 2) < 0.5)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .zIndex(0)
                // Edge-drag page switch — only triggers when the drag
                // STARTS within `edgeDragGutter` pt of either screen
                // edge AND is dominantly horizontal. Anything else is
                // a no-op so the existing scroll/tap gestures inside
                // each page keep working. Uses `simultaneousGesture`
                // so it runs alongside (not instead of) child gestures.
                .simultaneousGesture(edgeDragGesture(in: geo.size))

                // ── Arc navbar ──
                // Height = arc region + bottom safe area (home indicator).
                let navbarHeight = ArcNavBar.frameContentHeight + geo.safeAreaInsets.bottom
                ArcNavBar(
                    selectedPage: $selectedPage,
                    pageProgress: $pageProgress
                )
                .frame(height: navbarHeight)
                .zIndex(10)
            }
        }
        .ignoresSafeArea()
        .onChange(of: pageProgress) { _, value in
            let snapped = ShellPage(rawValue: Int(value.rounded())) ?? .hero
            if snapped != selectedPage { selectedPage = snapped }
        }
        .fullScreenCover(item: $chatPresentation) { route in
            ChatRootView(
                conversationService: conversationService,
                socialService:       socialService,
                initialRoute:        route,
                onDismiss:           { chatPresentation = nil },
                onJumpToPost:        { postId in jumpToPost(postId: postId) }
            )
        }
        .sheet(isPresented: $showPhonePromptPanel) {
            PhonePromptPanel(
                onAddPhone: {
                    showPhonePromptPanel = false
                    // Schedule the next sheet on the run loop so the
                    // first one has time to dismiss before the second
                    // tries to present — back-to-back sheet swaps on
                    // iOS can otherwise drop the second.
                    DispatchQueue.main.async {
                        showPhoneOnboardingSheet = true
                    }
                },
                onDismiss: { showPhonePromptPanel = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showPhoneOnboardingSheet) {
            PhoneOnboardingView(
                userPrivateService: userPrivateService,
                authService:        authService,
                onCancel:           { showPhoneOnboardingSheet = false },
                onSuccess:          { showPhoneOnboardingSheet = false }
            )
        }
        .sheet(isPresented: $showContactsSuggestionPanel) {
            ContactsSuggestionPanel(
                onAllow: {
                    showContactsSuggestionPanel = false
                    Task { await userPrivateService.markContactsPromptShown() }
                    DispatchQueue.main.async {
                        showFriendFindSheet = true
                    }
                },
                onSkip: {
                    showContactsSuggestionPanel = false
                    Task { await userPrivateService.markContactsPromptShown() }
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showFriendFindSheet) {
            FriendFindView(
                socialService:      socialService,
                userPrivateService: userPrivateService,
                onClose:            { showFriendFindSheet = false }
            )
        }
        .onAppear {
            // Once per cold launch: surface the soft prompt to legacy
            // users (the hard gate in ContentView already handles new
            // users via `needsPhone`, so this only fires when the user
            // is in MainShell with no verified number).
            if !didPromptThisLaunch, userPrivateService.shouldPromptPhone {
                didPromptThisLaunch = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if userPrivateService.shouldPromptPhone {
                        showPhonePromptPanel = true
                    }
                }
            }
            // Contacts suggestion: once per *user* (persisted via
            // `contactsPromptShown`), only after phone is verified.
            // Delayed slightly more than the phone panel so they
            // don't pile on top of each other.
            if !didEvaluateContactsThisLaunch, userPrivateService.shouldSuggestContacts {
                didEvaluateContactsThisLaunch = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if userPrivateService.shouldSuggestContacts && !showPhonePromptPanel {
                        showContactsSuggestionPanel = true
                    }
                }
            }
        }
    }

    /// Triggered from a post-reference bubble in chat: dismiss the
    /// fullScreenCover, switch to Hero, and stage the post id so
    /// HeroPageView scrolls there when it becomes visible again.
    private func jumpToPost(postId: String) {
        chatPresentation = nil
        pendingHeroPostJumpId = postId
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            selectedPage = .hero
            pageProgress = 1
        }
    }

    private func jumpToMap(placeId: String) {
        // Set the pending placeId first so MainMapView can react to it the
        // moment its hit-testing engages. Then animate the page transition.
        pendingMapJumpPlaceId = placeId
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            selectedPage = .map
            pageProgress = 0
        }
    }

    // MARK: - Edge-drag page switching

    /// Distance from either screen edge within which a drag start is
    /// considered an edge-swipe. 24pt matches the system's own back-
    /// gesture region — small enough to not collide with normal taps
    /// near the edge of the post card / map controls.
    private static let edgeDragGutter: CGFloat = 24

    /// Captures left/right edge drags and translates them into
    /// `pageProgress` changes. Vertical scrolls inside Hero / Profile
    /// are unaffected because:
    ///   1. We only activate on drags that *start* within `edgeDragGutter`
    ///      of either edge.
    ///   2. We require the drag to be dominantly horizontal
    ///      (|dx| > |dy|) before moving the pager.
    private func edgeDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if edgeDragStartProgress == nil {
                    // First .onChanged — decide whether this drag qualifies.
                    let startX = value.startLocation.x
                    let fromLeft  = startX < Self.edgeDragGutter
                    let fromRight = startX > size.width - Self.edgeDragGutter
                    let horizontalEnough = abs(value.translation.width)
                                            > abs(value.translation.height)
                    guard (fromLeft || fromRight) && horizontalEnough else {
                        // Not an edge drag — set a sentinel that's
                        // out-of-range so we don't keep re-checking.
                        edgeDragActive = false
                        edgeDragStartProgress = -.infinity
                        return
                    }
                    edgeDragActive = true
                    edgeDragStartProgress = pageProgress
                    edgeDragStartPage = selectedPage
                }
                guard edgeDragActive,
                      let start = edgeDragStartProgress,
                      start.isFinite
                else { return }

                // Swipe RIGHT (dx > 0) → move toward earlier page (Map).
                // Clamp to ±1 page from where the drag began so a
                // single gesture can never skip past an adjacent page.
                let raw = start - value.translation.width / size.width
                let (lo, hi) = Self.adjacentPageBounds(from: edgeDragStartPage)
                pageProgress = max(lo, min(hi, raw))
            }
            .onEnded { value in
                defer {
                    edgeDragActive = false
                    edgeDragStartProgress = nil
                }
                guard edgeDragActive,
                      let start = edgeDragStartProgress,
                      start.isFinite
                else { return }

                // Use the predicted end (incorporates flick velocity)
                // to decide which page to snap to. A slow drag that
                // doesn't cross the midpoint snaps back; a fast flick
                // commits to the next page even if released early.
                // Apply the same ±1 cap as during the drag.
                let predictedRaw = start - value.predictedEndTranslation.width / size.width
                let (lo, hi) = Self.adjacentPageBounds(from: edgeDragStartPage)
                let limited = Int(max(lo, min(hi, predictedRaw)).rounded())
                let snapped = ShellPage(rawValue: limited) ?? edgeDragStartPage
                withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
                    selectedPage = snapped
                    pageProgress = CGFloat(snapped.rawValue)
                }
            }
    }

    /// Range of pageProgress reachable by a single drag that started
    /// on `page`. Always exactly ±1 from the start page, clamped to
    /// the valid page range so drags from the first or last page can
    /// only move in one direction.
    private static func adjacentPageBounds(from page: ShellPage) -> (CGFloat, CGFloat) {
        let lastIndex = ShellPage.allCases.count - 1
        let lo = max(0, page.rawValue - 1)
        let hi = min(lastIndex, page.rawValue + 1)
        return (CGFloat(lo), CGFloat(hi))
    }
}
