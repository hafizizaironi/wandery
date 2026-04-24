import SwiftUI

// Page order matches the arc's left-to-right tab positions:
//   Map (t=0.15, left) | Hero (t=0.50, center) | Profile (t=0.85, right)
enum ShellPage: Int, CaseIterable {
    case map     = 0
    case hero    = 1
    case profile = 2
}

struct MainShellView: View {
    @ObservedObject var authService:      AuthService
    @ObservedObject var firestoreService: FirestoreService
    @ObservedObject var statsService:     UserStatsService
    @ObservedObject var socialService:    SocialService

    // Start on the Hero (feed) page — centre of the arc.
    @State private var selectedPage: ShellPage = .hero
    @State private var pageProgress: CGFloat   = 1
    @State private var showAddCafe = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {

                // ── Pages ── absolutely positioned so they slide live
                // as pageProgress changes (driven by arc navbar taps / swipes).
                ZStack {
                    MainMapView(authService: authService, firestoreService: firestoreService)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (0 - pageProgress) * geo.size.width)
                        // Off-screen siblings keep full layout frames; without this they steal taps on Map.
                        .allowsHitTesting(abs(pageProgress - 0) < 0.5)

                    HeroPageView(isActive: selectedPage == .hero, socialService: socialService)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (1 - pageProgress) * geo.size.width)
                        .allowsHitTesting(abs(pageProgress - 1) < 0.5)

                    ProfileHomeView(
                        authService:   authService,
                        statsService:  statsService,
                        socialService: socialService,
                        isTabActive:   abs(pageProgress - 2) < 0.5
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
                ArcNavBar(
                    selectedPage: $selectedPage,
                    pageProgress: $pageProgress,
                    onAddTap: {
                        withAnimation(.spring(response: 0.65, dampingFraction: 0.88)) {
                            showAddCafe = true
                        }
                    }
                )
                .frame(height: ArcNavBar.frameContentHeight + geo.safeAreaInsets.bottom)
                .zIndex(10)

                // ── Portal flow — overlaid above everything, transitions from "+" center.
                if showAddCafe {
                    AddCafeFlowView(onDismiss: {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) {
                            showAddCafe = false
                        }
                    })
                    .transition(.portal(origin: CGPoint(
                        x: geo.size.width / 2,
                        y: geo.size.height - geo.safeAreaInsets.bottom - ArcNavBar.addButtonAboveSafeArea
                    )))
                    .ignoresSafeArea()
                    .zIndex(20)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: pageProgress) { _, value in
            let snapped = ShellPage(rawValue: Int(value.rounded())) ?? .hero
            if snapped != selectedPage { selectedPage = snapped }
        }
    }
}
