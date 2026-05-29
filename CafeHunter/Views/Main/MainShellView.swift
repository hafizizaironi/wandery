import SwiftUI
import FirebaseAuth

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

    /// "My Hunt" pop-out. Owned here (above the arc navbar) so the overlay
    /// covers the whole screen — it scale-pops in from the profile via the
    /// transition below. `friendPlacesService` also lives here so both the
    /// profile card and the overlay read the same data.
    @State private var showMyHunt = false
    @State private var friendPlacesService = FriendPlacesService()

    /// "What's new" carousel — shown once per release. The release identity
    /// is `whatsNewReleaseKey` in `WhatsNewSheet.swift`; bump that constant
    /// for the next round of changes and the sheet shows again automatically
    /// for everyone (existing users + brand-new accounts).
    @AppStorage("whatsNew.lastSeenKey") private var whatsNewLastSeen: String = ""
    @State private var showWhatsNew = false
    /// One-time warm intro for testers (TestFlight/dev builds only — see
    /// `AppEnvironment.isTester`). Auto-shows once per device, re-openable
    /// from the "Welcome message" row in Profile.
    @AppStorage("tester.welcome.seen") private var testerWelcomeSeen = false
    @State private var showTesterWelcome = false
    /// Admin-only: full-screen marketing-mockup pages for App Store screenshots.
    @State private var showMarketingMockups = false
    /// Pulse-binding for the WhatsNew "Show me the map →" jump:
    /// MainShellView sets this true, MainMapView watches and opens the
    /// Trending sheet, then resets the flag.
    @State private var pendingShowTrending = false
    /// Set when arriving at a post via a notification tap; HeroPageView gives
    /// that post a brief highlight, then clears this.
    @State private var highlightedPostId: String?
    /// Bumped to ask ProfileHomeView to scroll to its Friend Requests section
    /// (e.g. after tapping a friend-request notification).
    @State private var scrollToRequestsToken: Int = 0

    // Soft "update available" nudge — reads config/app once, compares build
    // numbers, shows a dismissible banner. Dismissal remembered per-build.
    @State private var updateChecker = AppUpdateChecker()
    @AppStorage("update.dismissedBuild") private var dismissedUpdateBuild = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True when a full-screen surface fully hides the Hero page (chat,
    /// friend-find, phone onboarding, marketing mockups). HeroPageView uses
    /// this to sleep the camera while the user is in messages and deeper.
    private var heroIsCovered: Bool {
        chatPresentation != nil
            || showFriendFindSheet
            || showPhoneOnboardingSheet
            || showMarketingMockups
    }

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
                        isActive: selectedPage == .map,
                        pendingPlaceJumpId: $pendingMapJumpPlaceId,
                        pendingShowTrending: $pendingShowTrending
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
                        highlightedPostId: $highlightedPostId,
                        edgeDragActive: edgeDragActive,
                        onJumpToPlace: { placeId in jumpToMap(placeId: placeId) },
                        onOpenMessages: { chatPresentation = .inbox },
                        onFindFriends: { showFriendFindSheet = true },
                        isObscured: heroIsCovered
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
                        friendPlacesService: friendPlacesService,
                        showMyHunt:          $showMyHunt,
                        onMessageFriend:     { row in
                            chatPresentation = .thread(
                                otherUid: row.id,
                                displayName: row.titleText,
                                photoURL: row.photoURL
                            )
                        },
                        onPreviewWhatsNew:   { showWhatsNew = true },
                        onShowTesterWelcome: { showTesterWelcome = true },
                        onShowMarketingMockups: { showMarketingMockups = true },
                        scrollToRequestsToken: scrollToRequestsToken
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(x: (2 - pageProgress) * geo.size.width)
                    .allowsHitTesting(abs(pageProgress - 2) < 0.5)
                    // Push the profile back while My Hunt is open (iOS depth).
                    // No `.animation(value:)` here — that breaks the profile's
                    // ScrollView gestures. The toggles run inside `withAnimation`
                    // (onTap / onClose), so these still animate.
                    .scaleEffect(showMyHunt ? 0.96 : 1)
                    .brightness(showMyHunt ? -0.08 : 0)
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

                // ── My Hunt overlay ── zIndex above the navbar so it covers
                // everything; scale-pops in via the transition below.
                if showMyHunt {
                    MyHuntView(
                        myUid: authService.user?.uid ?? "",
                        friendPlacesService: friendPlacesService,
                        username: socialService.profile?.username,
                        joinedAt: authService.user?.metadata.creationDate,
                        topInset: geo.safeAreaInsets.top,
                        onClose: {
                            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                                showMyHunt = false
                            }
                        }
                    )
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .zIndex(20)
                }

                // ── Arc navbar ──
                // Height = arc region + bottom safe area (home indicator).
                let navbarHeight = ArcNavBar.frameContentHeight + geo.safeAreaInsets.bottom
                ArcNavBar(
                    selectedPage: $selectedPage,
                    pageProgress: $pageProgress
                )
                .frame(height: navbarHeight)
                .zIndex(10)

                // ── Soft update banner ── top-pinned, dismissible. Hidden
                // while My Hunt is open; zIndex above the navbar, below My Hunt.
                if updateChecker.updateAvailable(dismissedBuild: dismissedUpdateBuild), !showMyHunt {
                    AppUpdateBanner(updateURL: updateChecker.updateURL) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            dismissedUpdateBuild = updateChecker.latestBuild ?? dismissedUpdateBuild
                        }
                    }
                    .padding(.top, geo.safeAreaInsets.top + 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(15)
                }

                // ── Background-upload failure banner ── top-pinned, above the
                // update banner. Retry replays the saved drafts.
                if let uploadError = socialService.pendingUploadError, !showMyHunt {
                    UploadErrorBanner(
                        message: uploadError,
                        onRetry: { socialService.retryUpload() },
                        onDismiss: { socialService.dismissUploadError() }
                    )
                    .padding(.top, geo.safeAreaInsets.top + 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(16)
                }

                // ── In-app Dynamic Island upload ring ── the foreground upload
                // indicator (a Live Activity can't render in the DI while the
                // app is frontmost), traced around the island. DI phones only.
                if socialService.isUploadingPost, DeviceMetrics.hasDynamicIsland {
                    DynamicIslandUploadRing(
                        progress: socialService.uploadProgress,
                        splashTrigger: socialService.cardImpactTick
                    )
                    .transition(.opacity)
                    .zIndex(30)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: socialService.pendingUploadError)
            .animation(.easeInOut(duration: 0.25), value: socialService.isUploadingPost)
        }
        .ignoresSafeArea()
        // Soft check for a newer published build (config/app) — best-effort.
        .task { await updateChecker.check() }
        // Route a tapped notification. `.task` drains a cold-start tap that
        // was buffered before this view mounted; `.onChange` handles taps
        // while the app is already running. Both only fire once the shell is
        // mounted, which ContentView gates behind auth + onboarding.
        .task {
            if let link = NotificationRouter.shared.pending { consume(link) }
        }
        .onChange(of: NotificationRouter.shared.pending) { _, link in
            if let link { consume(link) }
        }
        // Hydrate the My Hunt map from the same feed posts the Map tab uses.
        .task(id: socialService.feedPosts.map(\.id)) {
            await friendPlacesService.refresh(from: socialService.feedPosts)
        }
        // Subscribe to my visit sessions so `FriendPlace.myVisitCount` matches
        // the server-side dedupe used by `globalVisitCount`. Re-subscribes
        // when the signed-in uid changes; clears on sign-out.
        .task(id: authService.user?.uid) {
            if let uid = authService.user?.uid, !uid.isEmpty {
                friendPlacesService.subscribeToMyVisits(uid: uid)
            } else {
                friendPlacesService.unsubscribeMyVisits()
            }
        }
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
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewSheet(
                onDismiss: {
                    whatsNewLastSeen = whatsNewReleaseKey
                    showWhatsNew = false
                },
                onJumpToFeature: { feature in
                    // Mark the tour as seen + close, then route. The deeper
                    // navs (Discover sheet / My Hunt overlay) fire after a
                    // short delay so the page-switch animation lands first.
                    whatsNewLastSeen = whatsNewReleaseKey
                    showWhatsNew = false
                    switch feature {
                    case .camera:
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                            selectedPage = .hero
                        }
                    case .discover:
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                            selectedPage = .map
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            pendingShowTrending = true
                        }
                    case .myHunt:
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                            selectedPage = .profile
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                                showMyHunt = true
                            }
                        }
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTesterWelcome) {
            TesterWelcomeSheet(onDismiss: {
                testerWelcomeSeen = true
                showTesterWelcome = false
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showMarketingMockups) {
            MarketingMockupsView(onClose: { showMarketingMockups = false })
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

            // Tester welcome — once per device, testers only. Fires just
            // before What's New so a fresh tester install sees the welcome
            // first; What's New then defers to the next cold launch.
            if AppEnvironment.isTester, !testerWelcomeSeen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    guard !testerWelcomeSeen else { return }
                    guard !showPhonePromptPanel,
                          !showContactsSuggestionPanel,
                          !showPhoneOnboardingSheet,
                          !showFriendFindSheet,
                          chatPresentation == nil else { return }
                    showTesterWelcome = true
                }
            }

            // What's New — once per release. Delayed longer than the phone/
            // contacts prompts so it never piles on; if either is up when
            // the timer fires, defer to next cold launch (the key won't
            // update until the user dismisses *this* sheet).
            if whatsNewLastSeen != whatsNewReleaseKey {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    guard whatsNewLastSeen != whatsNewReleaseKey else { return }
                    guard !showPhonePromptPanel,
                          !showContactsSuggestionPanel,
                          !showPhoneOnboardingSheet,
                          !showFriendFindSheet,
                          !showTesterWelcome,
                          chatPresentation == nil else { return }
                    showWhatsNew = true
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

    /// Apply a tapped-notification deep link, then clear it.
    private func consume(_ link: NotificationDeepLink) {
        switch link {
        case .thread(let otherUid):
            chatPresentation = .thread(otherUid: otherUid, displayName: nil, photoURL: nil)
        case .post(let postId):
            jumpToPost(postId: postId)
            highlightedPostId = postId
        case .friendRequests:
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                selectedPage = .profile
                pageProgress = 2
            }
            // Defer the scroll until the page transition settles (same delay
            // the What's New jumps use).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                scrollToRequestsToken += 1
            }
        }
        NotificationRouter.shared.pending = nil
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
    /// considered an edge-swipe. 12pt is a tighter hot zone than the
    /// system back-gesture region — small enough to not collide with
    /// normal taps near the edge of the post card / map controls.
    private static let edgeDragGutter: CGFloat = 12

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
