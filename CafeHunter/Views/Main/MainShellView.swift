import SwiftUI

// Page order matches the arc's left-to-right tab positions:
//   Map (t=0.15, left) | Hero (t=0.50, center) | Profile (t=0.85, right)
enum ShellPage: Int, CaseIterable {
    case map     = 0
    case hero    = 1
    case profile = 2
}

struct MainShellView: View {
    @ObservedObject var authService:         AuthService
    @ObservedObject var firestoreService:    FirestoreService
    @ObservedObject var statsService:        UserStatsService
    @ObservedObject var socialService:       SocialService
    @ObservedObject var conversationService: ConversationService

    // Start on the Hero (feed) page — centre of the arc.
    @State private var selectedPage: ShellPage = .hero
    @State private var pageProgress: CGFloat   = 1
    /// Set when the user taps a place pill in the feed; consumed by MainMapView
    /// which centers the map and opens the place-detail sheet.
    @State private var pendingMapJumpPlaceId: String?
    /// Flipped on by HeroPageView whenever the inbox or a chat thread is
    /// presented. We use it to spring the arc navbar away (so the chat
    /// surface gets the full screen) and spring it back on dismiss.
    @State private var isChatActive: Bool = false
    /// Set when a chat thumbnail tapped on the Profile page wants to land
    /// the user on a specific Hero feed post. HeroPageView consumes it.
    @State private var pendingHeroJumpPostId: String?

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
                        isChatActive: $isChatActive,
                        pendingHeroJumpPostId: $pendingHeroJumpPostId,
                        onJumpToPlace: { placeId in jumpToMap(placeId: placeId) }
                    )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (1 - pageProgress) * geo.size.width)
                        .allowsHitTesting(abs(pageProgress - 1) < 0.5)

                    ProfileHomeView(
                        authService:         authService,
                        statsService:        statsService,
                        socialService:       socialService,
                        conversationService: conversationService,
                        isTabActive:         abs(pageProgress - 2) < 0.5,
                        isChatActive:        $isChatActive,
                        onJumpToHeroPost:    { postId in jumpToHero(postId: postId) }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(x: (2 - pageProgress) * geo.size.width)
                    .allowsHitTesting(abs(pageProgress - 2) < 0.5)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .zIndex(0)

                // ── Arc navbar ──
                // Height = arc region + bottom safe area (home indicator).
                // Springs off-screen (and fades) whenever a chat surface is
                // active so the conversation gets the full view. The same
                // spring drives the rise on dismiss → the navbar reads as
                // a single liquid surface re-emerging from the bottom.
                let navbarHidden = isChatActive
                let navbarHeight = ArcNavBar.frameContentHeight + geo.safeAreaInsets.bottom
                ArcNavBar(
                    selectedPage: $selectedPage,
                    pageProgress: $pageProgress
                )
                .frame(height: navbarHeight)
                .offset(y: navbarHidden ? navbarHeight + 24 : 0)
                .opacity(navbarHidden ? 0 : 1)
                .scaleEffect(navbarHidden ? 0.92 : 1.0, anchor: .bottom)
                .blur(radius: navbarHidden ? 6 : 0)
                .allowsHitTesting(!navbarHidden)
                .animation(.spring(response: 0.5, dampingFraction: 0.78), value: navbarHidden)
                .zIndex(10)
            }
        }
        .ignoresSafeArea()
        .onChange(of: pageProgress) { _, value in
            let snapped = ShellPage(rawValue: Int(value.rounded())) ?? .hero
            if snapped != selectedPage { selectedPage = snapped }
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

    /// Mirror of jumpToMap, but for a chat-thumbnail tap on the Profile page
    /// that wants to land on a specific post in the Hero feed.
    private func jumpToHero(postId: String) {
        pendingHeroJumpPostId = postId
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            selectedPage = .hero
            pageProgress = 1
        }
    }
}
