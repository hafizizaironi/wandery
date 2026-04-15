import SwiftUI

// Page order matches the arc's left-to-right tab positions:
//   Map (t=0.15, left) | Hero (t=0.50, center) | Profile (t=0.85, right)
enum ShellPage: Int, CaseIterable {
    case map     = 0
    case hero    = 1
    case profile = 2
}

struct MainShellView: View {
    @ObservedObject var authService: AuthService
    @ObservedObject var firestoreService: FirestoreService

    // Start on the Hero (feed) page — centre of the arc.
    @State private var selectedPage: ShellPage = .hero
    @State private var pageProgress: CGFloat   = 1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {

                // ── Pages ── absolutely positioned so they slide live
                // as pageProgress changes (driven by arc navbar taps / swipes).
                ZStack {
                    MainMapView(authService: authService, firestoreService: firestoreService)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (0 - pageProgress) * geo.size.width)

                    HeroPageView(isActive: selectedPage == .hero)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (1 - pageProgress) * geo.size.width)

                    ProfileHomeView(authService: authService)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (2 - pageProgress) * geo.size.width)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .zIndex(0)

                // ── Arc navbar ──
                // Height = arc region + bottom safe area (home indicator).
                ArcNavBar(
                    selectedPage: $selectedPage,
                    pageProgress: $pageProgress
                )
                .frame(height: ArcNavBar.frameContentHeight + geo.safeAreaInsets.bottom)
                .zIndex(10)
            }
        }
        .ignoresSafeArea()
        .onChange(of: pageProgress) { _, value in
            let snapped = ShellPage(rawValue: Int(value.rounded())) ?? .hero
            if snapped != selectedPage { selectedPage = snapped }
        }
    }
}
