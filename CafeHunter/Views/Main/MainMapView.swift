import SwiftUI
import MapKit
import UIKit
import FirebaseFirestore

// MARK: - Liquid-glass shine (specular highlight)

/// Reusable specular-highlight overlay that gives any liquid-glass surface
/// the "light reflected through a 3D glass dome" look Apple uses on iOS 26:
///   • a broad top-down sheen that lifts the upper half of the shape
///   • a diagonal top-left streak for the crisp wet-glass catchlight
///   • a faint bottom inner-shadow suggesting the curved underside
/// All layers are clipped to the same host shape so edges stay clean.
struct LiquidGlassShine<S: Shape>: View {
    let shape: S
    /// 0 = no shine, 1 = default Apple-ish, >1 = more pronounced.
    var strength: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Broad top sheen — the overall "lit from above" gradient.
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.55 * strength), location: 0.00),
                            .init(color: .white.opacity(0.22 * strength), location: 0.22),
                            .init(color: .white.opacity(0.06 * strength), location: 0.48),
                            .init(color: .clear,                         location: 0.70)
                        ],
                        startPoint: .top,
                        endPoint:   .bottom
                    )
                )

            // Diagonal catchlight streak from top-left — the sharper reflection.
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.35 * strength), location: 0.00),
                            .init(color: .white.opacity(0.10 * strength), location: 0.25),
                            .init(color: .clear,                         location: 0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    )
                )

            // Soft bottom darkening — makes the glass feel domed, not flat.
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear,                         location: 0.55),
                            .init(color: .black.opacity(0.06 * strength), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint:   .bottom
                    )
                )
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Overlays a liquid-glass specular highlight clipped to `shape`.
    func liquidGlassShine<S: Shape>(in shape: S, strength: CGFloat = 1.0) -> some View {
        overlay(LiquidGlassShine(shape: shape, strength: strength))
    }
}

// MARK: - Liquid-glass HUD pill

/// Shared glass treatment for circular HUD buttons (Add, Recenter, etc.).
/// Matches the Show List / Hide List pills: real iOS 26 Liquid Glass with a
/// faint terracotta tint, a white→accent rim highlight, a reflected
/// catchlight, and a soft lift shadow.
private struct LiquidGlassHUDModifier: ViewModifier {
    func body(content: Content) -> some View {
        // Same recipe as the project-wide `liquidGlassChrome` — kept as a
        // separate modifier purely for the legacy `liquidGlassHUD()` call
        // sites and so we can tweak HUD-specific shadow weight if needed.
        content.liquidGlassChrome(in: Circle())
    }
}

extension View {
    /// Applies the shared circular Liquid Glass HUD styling.
    fileprivate func liquidGlassHUD() -> some View {
        modifier(LiquidGlassHUDModifier())
    }
}

// MARK: - Shared Liquid Glass chrome

/// One-size-fits-most Liquid Glass treatment for any chrome shape — nav
/// pills, button capsules, composer input fields, etc. Uses the same
/// `.glassEffect(.clear, in: shape)` recipe as the sheet panels with a
/// dark-tinted gradient stroke for the rim, so every floating element in
/// the app reads as the same material.
private struct LiquidGlassChromeModifier<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .glassEffect(.clear, in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.28),
                            Color.black.opacity(0.08),
                            Color.black.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
    }
}

extension View {
    /// Applies the project-wide Liquid Glass chrome treatment to any shape.
    /// Use for pills, capsules, composer inputs, navbar surfaces — anything
    /// that should read as the same material as the sheet panels.
    func liquidGlassChrome<S: Shape>(in shape: S) -> some View {
        modifier(LiquidGlassChromeModifier(shape: shape))
    }
}

/// Liquid Glass backdrop for system sheets — same `.glassEffect(.clear)`
/// as the floating panel + chrome modifiers. The system clips to the
/// sheet's rounded top corners for us. Used via
/// `.presentationBackground { LiquidGlassSheetBackground() }`.
struct LiquidGlassSheetBackground: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(.clear, in: Rectangle())
    }
}

// MARK: - Liquid-glass panel surface

/// High-fidelity Liquid Glass panel — translated from the CSS recipe at
/// https://codepen.io ("color-mix inset box-shadow stack"). The CSS uses
/// 8+ layered inset shadows to fake the asymmetric lighting that makes
/// real glass look like a domed lens: bright top-left, faint dark line
/// just inside the top edge, soft bottom darkening, gradient rim. SwiftUI
/// can't do inset shadows directly, so each "layer" becomes either an
/// overlay gradient (for area shading) or a strokes-with-offset trick
/// (for thin specular lines).
private struct LiquidGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            // iOS 26 Liquid Glass — `.clear` is the see-through variant
            // (more transparent than `.regular` while preserving Apple's
            // refractive lens at the edges). Apple's docs warn against
            // stacking glass with materials, masks, or custom Metal —
            // the system is designed to be applied directly to a shape
            // and left alone. One subtle gradient stroke is the only
            // decoration on top; it gives the panel a defined edge over
            // any backdrop the map provides.
            .glassEffect(.clear, in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.32),
                            Color.black.opacity(0.10),
                            Color.black.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 6)
    }
}

extension View {
    /// Applies the shared rounded-rectangle Liquid Glass panel styling.
    fileprivate func liquidGlassPanel(cornerRadius: CGFloat) -> some View {
        modifier(LiquidGlassPanelModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Filter type

enum FilterType: String, CaseIterable {
    case all, cafe, restaurant, stall

    var label: String {
        switch self {
        case .all: "All"
        case .cafe: "Cafés"
        case .restaurant: "Restaurants"
        case .stall: "Stalls"
        }
    }
    var emoji: String {
        switch self {
        case .all: "📍"
        case .cafe: "☕"
        case .restaurant: "🍽️"
        case .stall: "🍜"
        }
    }
}

// MARK: - Main map view

struct MainMapView: View {
    var authService: AuthService
    var firestoreService: FirestoreService
    var socialService: SocialService
    /// True while the Map is the visible page (`selectedPage == .map`).
    /// Driven by MainShellView; on the rising edge we recenter on the user
    /// (unless they're searching or arriving via a place-jump).
    var isActive: Bool
    /// Set externally (e.g. from a feed pill tap) to fly to a place + open
    /// the detail sheet. Cleared once consumed.
    @Binding var pendingPlaceJumpId: String?
    /// Pulse-binding from the WhatsNew "Show me the map →" jump. When set
    /// true by the host, the view opens the Trending sheet and resets the
    /// flag. No-op when already showing or when there's no friend pin to land on.
    @Binding var pendingShowTrending: Bool

    @State private var friendPlacesService = FriendPlacesService()
    @State private var activeFriendPlace: FriendPlace?
    /// Shuffled order of `filteredPlaces` used by the Tinder card stack.
    /// Recomputed whenever the filter or the underlying places list
    /// changes. The first element is guaranteed to differ from the first
    /// element of the *list view* so the carousel + list don't show the
    /// same top item.
    @State private var carouselOrder: [FriendPlace] = []
    /// Set when the user taps a multi-place cluster pin (e.g. a mall). Drives
    /// a small picker sheet that lets them pick which of the bundled places
    /// to actually open.
    @State private var clusterSelection: ClusterSelection?
    @State private var filter: FilterType = .all
    @State private var sheetHeight: CGFloat = 210
    @State private var listScrollOffset: CGFloat = 0
    @State private var showListOverlay = false
    @State private var centerOnUser = false
    @State private var targetCoordinate: CLLocationCoordinate2D?
    @State private var locationManager = LocationManager()
    /// Drives the Discover overlay sheet.
    @State private var showDiscover = false

    // MARK: - Circle (friend-of-friend) discovery
    /// Network-aware Discover state. Loads `circle` + `trending` from the
    /// `discoverFeed` Cloud Function and caches in-memory for 5 min.
    @State private var circleService = CircleDiscoverService()
    /// The tapped circle pin (drives the floating `CirclePlaceCard`). Floating
    /// card, not a sheet — the user keeps map context.
    @State private var activeCirclePlace: CirclePlace?
    /// Map toggle for the FoF pin layer. Persists per-user via @AppStorage so
    /// turning it off survives relaunches. Force-OFF when the user has opted
    /// out of contributing — "if you don't share, you don't consume."
    @AppStorage("discover.showCircle") private var showCirclePref: Bool = true
    private var circleLayerEnabled: Bool {
        showCirclePref && !(socialService.profile?.optedOutOfDiscovery ?? false)
    }

    // Show List pill idle animation — periodic "happy jump".
    @State private var showListJumpOffset: CGFloat = 0
    @State private var showListJumpScale:  CGFloat = 1.0
    @State private var showListDotPulse    = false
    @State private var showListPressed     = false
    @State private var showListIdleTask:   Task<Void, Never>? = nil

    // Sized for the Tinder-style card carousel — the old 210pt peek was for
    // a vertical row list where chips + 2 rows were a useful tease. A hero
    // card needs ~520pt to render at a natural portrait proportion.
    private let peekHeight: CGFloat = 520
    @State private var screenHeight: CGFloat = 700
    private var expandedHeight: CGFloat { screenHeight * 0.75 }
    private var isListAtTop: Bool { listScrollOffset >= -1 }

    /// 0 when the sheet is at `peekHeight`, 1 when fully expanded.
    /// Drives the dynamic carousel shrink + fade below.
    private var expansionProgress: CGFloat {
        let range = expandedHeight - peekHeight
        guard range > 0 else { return 0 }
        return max(0, min(1, (sheetHeight - peekHeight) / range))
    }

    /// Carousel height shrinks linearly with sheet expansion. Capped at
    /// 0 so the cards fully collapse before the sheet reaches its top.
    private var dynamicCarouselHeight: CGFloat {
        max(0, 340 - 340 * expansionProgress * 1.25)
    }

    private var carouselOpacity: Double {
        max(0, 1 - Double(expansionProgress) * 1.5)
    }

    /// Map pins still draw the legacy curated cafes for now (Phase 2 decision),
    /// but the sheet list no longer reflects them — it lists places shared via
    /// post tagging only.
    private var mapCafes: [Cafe] { firestoreService.cafes }

    /// The sheet list is now driven by FriendPlace (places that the user or
    /// their friends have tagged in a post). No more curated-cafe details.
    private var filteredPlaces: [FriendPlace] {
        switch filter {
        case .all:        return friendPlacesService.places
        case .cafe:       return friendPlacesService.places.filter { $0.type == .cafe }
        case .restaurant: return friendPlacesService.places.filter { $0.type == .restaurant }
        case .stall:      return friendPlacesService.places.filter { $0.type == .stall }
        }
    }

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .bottom) {
            // Map
            CafeMapView(
                cafes: mapCafes,
                friendPlaces: friendPlacesService.places,
                circlePlaces: circleLayerEnabled ? circleService.circle : [],
                onCirclePinClick: { place in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        activeCirclePlace = place
                    }
                },
                activeCafeId: nil,
                onPinClick: { id in centerOnLegacyCafe(id: id) },
                onFriendPinClick: { place in activeFriendPlace = place },
                onClusterTap: { places in clusterSelection = ClusterSelection(places: places) },
                centerOnUser: $centerOnUser,
                targetCoordinate: $targetCoordinate,
                locationManager: locationManager,
                userPhotoURL: socialService.profile?.photoURL
            )
            .task(id: socialService.feedPosts.map(\.id)) {
                await friendPlacesService.refresh(from: socialService.feedPosts)
            }
            // Load the discoverFeed on appear. The server caches for 6h and
            // the service throttles to once per 5 min on the client, so this
            // is cheap to re-run on every map appear.
            .task { await circleService.load() }
            // After the user posts (`feedPosts.count` changes), give the
            // `onPostCreatePlaceVisit` trigger a moment to commit, then nudge
            // the cache so a fresh visit by a friend can start contributing.
            .task(id: socialService.feedPosts.count) {
                try? await Task.sleep(for: .seconds(30))
                await circleService.load(force: true)
            }
            // Reshuffle the carousel order whenever the filter or the
            // visible places change. Runs on first appearance + every
            // time the place-id set or the active filter changes.
            .task(id: "\(filter.rawValue):\(filteredPlaces.map(\.id).joined())") {
                refreshCarouselOrder()
            }
            .sheet(item: $activeFriendPlace) { place in
                PlaceDetailSheet(place: place) {
                    activeFriendPlace = nil
                }
                // `.fraction(0.7)` sits well above `.medium` so the place
                // name and primary actions (Google Maps / Waze) are clear
                // of the sheet edge, without going fullscreen.
                .presentationDetents([.fraction(0.7)])
                .presentationDragIndicator(.hidden)
                // Custom Liquid Glass to match the visited-places panel.
                // Sheet content uses white text (set inside the views)
                // for contrast against the clear-glass backdrop.
                .presentationBackground {
                    LiquidGlassSheetBackground()
                }
            }
            .sheet(isPresented: $showDiscover) {
                TrendingDiscoverView(
                    service: circleService,
                    onSelect: { placeId in
                        // Driving the existing place-jump binding centres the
                        // map AND opens PlaceDetailSheet via the synthesized-
                        // FriendPlace fallback for places the user has no
                        // friend posts at.
                        pendingPlaceJumpId = placeId
                    },
                    onClose: { showDiscover = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground {
                    LiquidGlassSheetBackground()
                }
            }
            .sheet(item: $clusterSelection) { selection in
                ClusterPickerSheet(
                    places: selection.places,
                    onPick: { picked in
                        clusterSelection = nil
                        // Slight delay so the picker sheet finishes dismissing
                        // before the detail sheet starts presenting — avoids
                        // SwiftUI's "two sheets at once" warning.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            selectFriendPlace(picked)
                        }
                    },
                    onCancel: { clusterSelection = nil }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground {
                    LiquidGlassSheetBackground()
                }
            }
            .onChange(of: pendingPlaceJumpId) { _, newId in
                guard let placeId = newId else { return }
                Task { await consumePlaceJump(placeId: placeId) }
            }
            // External "open Trending" trigger from the WhatsNew sheet.
            .onChange(of: pendingShowTrending) { _, new in
                guard new else { return }
                pendingShowTrending = false
                showDiscover = true
            }
            // Recenter on the user whenever the Map becomes the active page,
            // *unless* they're searching (Discover open) or arriving via a
            // place-jump — those flows own the camera and should win. The
            // place-jump check works because pendingPlaceJumpId is set before
            // the page swap, so it's still non-nil on this rising edge and
            // gets consumed by the handler above.
            .onChange(of: isActive) { _, active in
                guard active, !showDiscover, pendingPlaceJumpId == nil else { return }
                centerOnUser = true
            }

            // Top-right HUD buttons
            topButtons
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Floating "Circle" detail card (tapped a FoF pin). Sits above
            // the navbar; tapping outside dismisses, matching the existing
            // overlay pattern from DiscoverView's place card.
            if let place = activeCirclePlace {
                Color.black.opacity(0.001)   // catch-all dismiss tap
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { activeCirclePlace = nil }
                    }
                VStack {
                    Spacer()
                    CirclePlaceCard(
                        place: place,
                        userLocation: locationManager.userLocation,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.18)) { activeCirclePlace = nil }
                        }
                    )
                    .padding(.bottom, 110)   // clearance above the arc navbar
                }
                .transition(.opacity)
                .zIndex(5)
            }

            // "Show list" — floats just above the arc's top peak; hidden while sheet is open
            if !showListOverlay {
                showListFloatingButton(safeBottom: geo.safeAreaInsets.bottom)
            }

            // List overlay
            if showListOverlay {
                // Backdrop dim — mirrors the system `.sheet` dim that
                // sits behind the detail-location panel. Without this,
                // the visited-places panel's glass refracts a bright
                // map and reads visibly lighter than the detail-
                // location panel. Tap to dismiss.
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .onTapGesture { hideListSheet() }
                    .transition(.opacity)

                BottomSheetView(
                    height: $sheetHeight,
                    peekHeight: peekHeight,
                    expandedHeight: expandedHeight,
                    canDragDownFromContent: isListAtTop,
                    onHide: hideListSheet,
                    onBack: nil
                ) {
                    sheetContent
                }
                // Horizontal inset so the sheet floats like a card; bottom
                // inset lifts it above the arc nav bar (Map/Hero/Profile)
                // so the card isn't clipped by the bar.
                .padding(.horizontal, FloatingPanelStyle.horizontalInset)
                .padding(.bottom, ArcNavBar.frameContentHeight + geo.safeAreaInsets.bottom + 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { screenHeight = geo.size.height }
        .onChange(of: geo.size.height) { _, newValue in screenHeight = newValue }
        } // GeometryReader
        .ignoresSafeArea()
    }

    // MARK: - Top buttons

    /// The legacy admin "+" form (manually adding cafés/stalls/restaurants)
    /// is gone — all places are now created server-side via the post-tagging
    /// flow (`findOrCreatePlace`). HUD now hosts:
    ///   - "center on me" — recenters the map.
    ///   - Discover (✨)   — opens the trending-spots feed for places
    ///                       you haven't visited yet.
    private var topButtons: some View {
        VStack(spacing: 10) {
            Button {
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred()
                centerOnUser = true
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .liquidGlassHUD()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center on my location")

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showDiscover = true
            } label: {
                Text("✨")
                    .font(.system(size: 19))
                    .frame(width: 44, height: 44)
                    .liquidGlassHUD()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discover trending places")

            // Toggle the friend-of-friend ("Circle") pin layer on the map.
            // Hidden entirely for users who've opted out of contributing —
            // if you don't share, you don't consume.
            if !(socialService.profile?.optedOutOfDiscovery ?? false) {
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    showCirclePref.toggle()
                } label: {
                    Image(systemName: showCirclePref ? "person.2.fill" : "person.2")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(showCirclePref ? AppTheme.cafeAccent : AppTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .liquidGlassHUD()
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showCirclePref
                                    ? "Hide circle pins on the map"
                                    : "Show circle pins on the map")
            }
        }
        .padding(.trailing, 16)
        .padding(.top, 60)
    }

    /// Distance from screen bottom to the Show List pill's bottom edge.
    /// We sit just above the active hero knob (~36pt radius, ×1.24 when
    /// enlarged during a drag) with a small breathing gap on top.
    private func listShowButtonBottomInset(safeBottom: CGFloat) -> CGFloat {
        // ArcNavBar.homeButtonFromBottom is measured from the arc-nav frame
        // bottom; adding safeBottom gives a true screen-bottom offset.
        // + 46  → clear the enlarged hero knob (36 × 1.24 ≈ 45)
        // + 16  → breathing gap between pill and knob
        ArcNavBar.homeButtonFromBottom + safeBottom + 62
    }

    private func showListFloatingButton(safeBottom: CGFloat) -> some View {
        let pill = Button {
            // Open the sheet immediately; the tap squash is purely decorative.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                if sheetHeight < peekHeight { sheetHeight = peekHeight }
                showListOverlay = true
            }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) {
                showListPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    showListPressed = false
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(AppTheme.accentAction)
                    .frame(width: 6, height: 6)
                    .shadow(
                        color: AppTheme.accentAction.opacity(showListDotPulse ? 0.85 : 0.40),
                        radius: showListDotPulse ? 5 : 2,
                        x: 0, y: 0
                    )
                    .scaleEffect(showListDotPulse ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.18), value: showListDotPulse)

                Image(systemName: "list.bullet")
                    .font(.system(size: 12, weight: .bold))
                Text("Show list")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.3)
            }
            .foregroundColor(AppTheme.textPrimary)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .liquidGlassChrome(in: Capsule())
            // Jump offset + scale drive the periodic hop; press squash stays.
            .scaleEffect(showListPressed ? 0.94 : showListJumpScale)
            .offset(y: showListJumpOffset)
        }
        .buttonStyle(.plain)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
        }
        .padding(.bottom, listShowButtonBottomInset(safeBottom: safeBottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
        .onAppear { startShowListIdleAnimation() }
        .onDisappear { stopShowListIdleAnimation() }
    }

    /// Launches a looping Task that fires a springy "happy jump" on the pill
    /// every 3 seconds. Restarted fresh each time the pill enters the view tree.
    private func startShowListIdleAnimation() {
        stopShowListIdleAnimation()
        showListJumpOffset = 0
        showListJumpScale  = 1.0
        showListDotPulse   = false

        showListIdleTask = Task {
            // Short initial pause so it doesn't jump the instant it appears.
            try? await Task.sleep(for: .seconds(1.2))
            while !Task.isCancelled {
                await performHappyJump()
                try? await Task.sleep(for: .seconds(3.0))
            }
        }
    }

    private func stopShowListIdleAnimation() {
        showListIdleTask?.cancel()
        showListIdleTask = nil
    }

    @MainActor
    private func performHappyJump() async {
        // Phase 1 – squish down slightly before launching.
        withAnimation(.spring(response: 0.12, dampingFraction: 0.82)) {
            showListJumpScale  = 0.92
            showListJumpOffset = 2
        }
        try? await Task.sleep(for: .milliseconds(110))

        // Phase 2 – spring upward with overshoot.
        withAnimation(.spring(response: 0.30, dampingFraction: 0.45)) {
            showListJumpScale  = 1.08
            showListJumpOffset = -12
            showListDotPulse   = true
        }
        try? await Task.sleep(for: .milliseconds(300))

        // Phase 3 – settle back to rest.
        withAnimation(.spring(response: 0.40, dampingFraction: 0.65)) {
            showListJumpScale  = 1.0
            showListJumpOffset = 0
            showListDotPulse   = false
        }
    }

    private func hideListSheet() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            showListOverlay = false
            sheetHeight = peekHeight
        }
    }

    // MARK: - Sheet content

    @ViewBuilder
    private var sheetContent: some View {
        FilterTabBar(active: $filter, counts: filterCounts) { f in
            filter = f
        }
        .padding(.top, 4)

        if filteredPlaces.isEmpty {
            VStack {
                Spacer(minLength: 32)
                Text(filter == .all
                     ? "No places shared yet — tag a place when you post."
                     : "No \(filter.label.lowercased()) shared yet.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
                Spacer(minLength: 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Card carousel up top — shrinks + fades out as the user
            // scrolls the list below. Uses `carouselOrder` (shuffled)
            // so the top card never matches the top of the list.
            FriendPlaceCarousel(places: carouselOrder) { place in
                selectFriendPlace(place)
            }
            .frame(height: dynamicCarouselHeight)
            .opacity(carouselOpacity)
            .clipped()
            .padding(.bottom, 6)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: expansionProgress)

            Divider()
                .background(Color.primary.opacity(0.10))
                .padding(.horizontal, 14)
                .opacity(carouselOpacity)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredPlaces) { place in
                        compactPlaceRow(place)
                    }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
            // Trigger auto-expand / auto-collapse ONLY on threshold-
            // crossings (oldValue → newValue transitions). Without this
            // guard the `withAnimation { sheetHeight = … }` would fire
            // on every scroll frame, interrupting the spring and
            // producing the stutter the user reported.
            .onScrollGeometryChange(for: CGFloat.self) { proxy in
                proxy.contentOffset.y
            } action: { oldOffset, newOffset in
                // Snap-update `listScrollOffset` only on top/non-top
                // transitions (keeps the existing `isListAtTop` gate
                // working without firing a state-write every frame).
                let wasAtTop = oldOffset <= 1
                let nowAtTop = newOffset <= 1
                if wasAtTop != nowAtTop {
                    listScrollOffset = nowAtTop ? 0 : -100
                }
                // Crossing 4pt down → auto-expand.
                if oldOffset <= 4, newOffset > 4,
                   sheetHeight < expandedHeight - 4 {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        sheetHeight = expandedHeight
                    }
                }
                // Crossing -60pt up (overscroll pull-down at top) → auto-collapse.
                else if oldOffset >= -60, newOffset < -60,
                        sheetHeight > peekHeight + 4 {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        sheetHeight = peekHeight
                    }
                }
            }
        }
    }

    /// Re-shuffles the carousel order so the top card is randomised AND
    /// distinct from the top of the list. Called via `.task(id:)` on the
    /// view body whenever the filter or place list changes.
    private func refreshCarouselOrder() {
        let source = filteredPlaces
        guard source.count > 1 else {
            carouselOrder = source
            return
        }
        var shuffled = source.shuffled()
        // If shuffle happened to put the list-top first, swap with index 1.
        if shuffled.first?.id == source.first?.id {
            shuffled.swapAt(0, 1)
        }
        carouselOrder = shuffled
    }

    /// Compact list row used under the Tinder carousel — same places, but
    /// scannable. Tap routes through `selectFriendPlace` just like the card.
    private func compactPlaceRow(_ place: FriendPlace) -> some View {
        Button {
            selectFriendPlace(place)
        } label: {
            HStack(spacing: 12) {
                rowThumbnail(place)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(visitsLabel(place))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// Square thumbnail of the most-recent friend post at the place.
    /// Falls back to a translucent panel + type emoji when the URL is
    /// missing or fails to load.
    private func rowThumbnail(_ place: FriendPlace) -> some View {
        let url: URL? = {
            guard let post = place.mostRecent else { return nil }
            let raw = post.isVideo
                ? (post.thumbnailURL ?? post.mediaURL)
                : post.mediaURL
            return URL(string: raw)
        }()
        return CachedAsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure, .empty:
                thumbnailPlaceholder(for: place.type)
            @unknown default:
                thumbnailPlaceholder(for: place.type)
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func thumbnailPlaceholder(for type: PlaceType) -> some View {
        ZStack {
            Color.primary.opacity(0.08)
            Text(type.emoji)
                .font(.system(size: 22))
                .opacity(0.6)
        }
    }

    private func visitsLabel(_ place: FriendPlace) -> String {
        let visits = max(place.globalVisitCount, 0)
        let displayed = visits > 0 ? visits : place.posts.count
        // `displayed` is the GLOBAL visit count — anyone, friend or not. The
        // posts here come from your feed (friends + you), so that subset is
        // the people you actually know who've been.
        let circleCount = Set(place.posts.map(\.authorId)).count
        let peopleWord = displayed == 1 ? "person" : "people"
        var label = "\(displayed) \(peopleWord) visited"
        if circleCount > 1 {
            label += " · \(circleCount) from your circle"
        }
        return label
    }

    private var filterCounts: (all: Int, cafe: Int, restaurant: Int, stall: Int) {
        let p = friendPlacesService.places
        return (
            all:        p.count,
            cafe:       p.filter { $0.type == .cafe }.count,
            restaurant: p.filter { $0.type == .restaurant }.count,
            stall:      p.filter { $0.type == .stall }.count
        )
    }

    // MARK: - Navigation helpers

    /// Reaction to `pendingPlaceJumpId` being set externally. Looks up the
    /// place in the local cache; falls back to a Firestore fetch if it isn't
    /// yet hydrated (e.g. user tapped a pill before the feed listener fired).
    private func consumePlaceJump(placeId: String) async {
        defer { pendingPlaceJumpId = nil }

        // 1. Local cache hit — fast path.
        if let place = friendPlacesService.places.first(where: { $0.id == placeId }) {
            targetCoordinate = CLLocationCoordinate2D(
                latitude: place.lat - 0.00375,
                longitude: place.lng
            )
            activeFriendPlace = place
            return
        }

        // 2. Cache miss — fetch the place doc directly + synthesize a
        //    one-post FriendPlace so the sheet still opens.
        let db = Firestore.firestore()
        do {
            let doc = try await db.collection("places")
                .document(placeId)
                .getDocument(as: Place.self)
            let friendPosts = socialService.feedPosts.filter { $0.distinctPlaceIds.contains(placeId) }
            // Trending-place / new-user path: the friend graph has no posts
            // at this place, so the card stack would render empty. Fall back
            // to public posts (clear AND blurred) so the sheet has content.
            // PostStackCard renders non-discoverable ones with a blur based
            // on `postsAreFallback` below.
            let postsAtPlace: [FriendPost]
            let postsAreFallback: Bool
            if friendPosts.isEmpty {
                postsAtPlace = await fetchDiscoverablePostsAtPlace(placeId, db: db)
                postsAreFallback = true
            } else {
                postsAtPlace = friendPosts.sorted { $0.createdAt > $1.createdAt }
                postsAreFallback = false
            }
            let synthesized = FriendPlace(
                id: placeId,
                name: doc.name,
                type: doc.type,
                lat: doc.lat,
                lng: doc.lng,
                posts: postsAtPlace,
                // Pass through the global counters so the detail sheet shows
                // "N visits" instead of "0 visits by 0 friends" when the user
                // landed here from a non-friend surface (e.g. Trending).
                globalVisitCount: doc.globalVisitCount,
                globalEngagementCount: doc.globalEngagementCount,
                address: doc.address,
                postsAreFallback: postsAreFallback
            )
            targetCoordinate = CLLocationCoordinate2D(
                latitude: doc.lat - 0.00375,
                longitude: doc.lng
            )
            activeFriendPlace = synthesized
        } catch {
            // Place was deleted or unreadable — silently no-op so the user
            // isn't stranded with a confusing error after a UI tap.
        }
    }

    /// Pulls public posts at a place when the friend feed has none. Used by
    /// the trending → place-detail flow so the sheet never renders an empty
    /// card stack. Includes BOTH discoverable=true (rendered clear) AND
    /// discoverable=false (rendered blurred via PostStackCard's blur
    /// modifier). Posts authored by users who toggled "Help your circle
    /// discover" OFF are dropped entirely — we respect that opt-out by
    /// hiding the card, not blurring it. The `containsFaces == false`
    /// filter is required to match the Firestore rule.
    private func fetchDiscoverablePostsAtPlace(_ placeId: String,
                                               db: Firestore) async -> [FriendPost] {
        do {
            let snap = try await db.collection("posts")
                .whereField("placeId", isEqualTo: placeId)
                .whereField("containsFaces", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 20)
                .getDocuments()
            let posts = snap.documents.compactMap(FriendPost.init(document:))
            let optedOut = await fetchOptedOutAuthorSet(
                authorIds: Array(Set(posts.map(\.authorId))),
                db: db
            )
            return posts.filter { !optedOut.contains($0.authorId) }
        } catch {
            #if DEBUG
            print("[MainMapView] place-posts fallback fetch failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    /// Bulk-fetches `users/{uid}.optedOutOfDiscovery` for the given authors
    /// and returns the set of UIDs that have the toggle OFF (= opted out).
    /// Used to hide opted-out authors' cards in the place-detail panel —
    /// mirrors how the trending Cloud Function drops them. Splits into
    /// chunks of 30 because that's Firestore's `in:` query cap.
    private func fetchOptedOutAuthorSet(authorIds: [String],
                                        db: Firestore) async -> Set<String> {
        guard !authorIds.isEmpty else { return [] }
        var result: Set<String> = []
        let chunks = stride(from: 0, to: authorIds.count, by: 30).map {
            Array(authorIds[$0..<min($0 + 30, authorIds.count)])
        }
        for chunk in chunks {
            do {
                let snap = try await db.collection("users")
                    .whereField(FieldPath.documentID(), in: chunk)
                    .getDocuments()
                for doc in snap.documents {
                    if (doc.data()["optedOutOfDiscovery"] as? Bool) == true {
                        result.insert(doc.documentID)
                    }
                }
            } catch {
                #if DEBUG
                print("[MainMapView] opt-out batch read failed: \(error.localizedDescription)")
                #endif
            }
        }
        return result
    }

    private func selectFriendPlace(_ place: FriendPlace) {
        // Drop the list sheet so the map is fully visible behind the rising
        // place-detail sheet.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            showListOverlay = false
            sheetHeight = peekHeight
        }
        // Bias the center southward by ~25 % of the zoom span so the pin
        // lands in the upper quarter of the screen — i.e. roughly centered
        // in the visible top half once the .medium detail sheet is up.
        targetCoordinate = CLLocationCoordinate2D(
            latitude: place.lat - 0.00375,
            longitude: place.lng
        )
        activeFriendPlace = place
    }

    /// Legacy curated cafes still draw on the map but no longer have a
    /// detail page. Tapping one just centers the map.
    private func centerOnLegacyCafe(id: String) {
        guard let cafe = firestoreService.cafes.first(where: { $0.id == id }) else { return }
        targetCoordinate = CLLocationCoordinate2D(latitude: cafe.lat, longitude: cafe.lng)
    }
}

// MARK: - Bottom sheet container

struct BottomSheetView<Content: View>: View {
    @Binding var height: CGFloat
    let peekHeight: CGFloat
    let expandedHeight: CGFloat
    let canDragDownFromContent: Bool
    var onHide: () -> Void
    /// Optional leading-action callback; when non-nil, a back arrow appears
    /// in the sheet header (used while viewing a café detail).
    var onBack: (() -> Void)? = nil
    @ViewBuilder let content: Content

    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingSheet = false

    private var currentHeight: CGFloat {
        clampedHeight(height - dragTranslation)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let movingDown = value.translation.height > 0
                let movingUp = value.translation.height < 0
                let canExpand = height < expandedHeight - 1
                let canCollapse = canDragDownFromContent || height < expandedHeight - 1

                if !isDraggingSheet {
                    if (movingDown && canCollapse) || (movingUp && canExpand) {
                        isDraggingSheet = true
                    } else {
                        return
                    }
                }

                dragTranslation = value.translation.height
            }
            .onEnded { value in
                guard isDraggingSheet else { return }
                let projectedHeight = clampedHeight(height - value.predictedEndTranslation.height)
                let targetHeight = nearestSnapHeight(to: projectedHeight)

                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                    height = targetHeight
                }
                dragTranslation = 0
                isDraggingSheet = false
            }
    }

    private func clampedHeight(_ proposed: CGFloat) -> CGFloat {
        min(expandedHeight, max(peekHeight, proposed))
    }

    private func nearestSnapHeight(to projectedHeight: CGFloat) -> CGFloat {
        let toPeek = abs(projectedHeight - peekHeight)
        let toExpanded = abs(projectedHeight - expandedHeight)
        return toExpanded < toPeek ? expandedHeight : peekHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header: back (left, detail-only) · drag handle (center) · hide (right)
            // Drag only on the handle strip; handle is below the HStack so side buttons stay tappable
            // (Spacer does not absorb hits — center falls through to the drag gesture).
            ZStack {
                Capsule()
                    .fill(AppTheme.textPrimary.opacity(0.22))
                    .frame(width: 48, height: 5)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 18)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)

                HStack(spacing: 10) {
                    if let onBack {
                        sheetIconButton(systemImage: "chevron.left",
                                        accessibility: "Back to list",
                                        action: onBack)
                    }
                    Spacer(minLength: 0)
                    sheetIconButton(systemImage: "xmark",
                                    accessibility: "Hide list",
                                    action: onHide)
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 50)

            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: currentHeight)
        // Liquid Glass with a black tint for higher opacity — the panel
        // reads as a more material-y surface than plain `.clear`, while
        // still preserving the refractive edges.
        .clipShape(RoundedRectangle(
            cornerRadius: FloatingPanelStyle.cornerRadius,
            style: .continuous
        ))
        // `Color(.systemBackground)` adapts: near-white tint in light mode,
        // near-black in dark mode. Keeps the panel readable in both.
        .glassEffect(
            .clear.tint(Color(.systemBackground).opacity(0.90)),
            in: RoundedRectangle(
                cornerRadius: FloatingPanelStyle.cornerRadius,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.20), radius: 14, x: 0, y: 6)
    }

    /// Compact liquid-glass icon button used in the sheet header.
    private func sheetIconButton(
        systemImage: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 34, height: 34)
                .glassEffect(
                    .regular
                        .tint(AppTheme.accentAction.opacity(0.07)),
                    in: Circle()
                )
                .liquidGlassShine(in: Circle(), strength: 1.0)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.70),
                                    Color.white.opacity(0.18),
                                    AppTheme.accentAction.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: AppTheme.accentAction.opacity(0.12),
                        radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - Cluster picker

/// Wrapper so an array can drive `.sheet(item:)`. Identity is per-tap, not
/// per-cluster — every fresh tap presents a new sheet even if the same
/// cluster is tapped twice in a row.
struct ClusterSelection: Identifiable {
    let id = UUID()
    let places: [FriendPlace]
}

/// Small picker shown when the user taps a multi-place cluster pin. Lists
/// the places stacked at that location; tapping one opens the regular
/// detail sheet for it.
struct ClusterPickerSheet: View {
    let places: [FriendPlace]
    let onPick: (FriendPlace) -> Void
    let onCancel: () -> Void

    /// Sort by friend-engagement first (most-tagged on top) so the busiest
    /// spots in a mall surface immediately, then by recency.
    private var sortedPlaces: [FriendPlace] {
        places.sorted { a, b in
            if a.posts.count != b.posts.count { return a.posts.count > b.posts.count }
            let aDate = a.mostRecent?.createdAt ?? .distantPast
            let bDate = b.mostRecent?.createdAt ?? .distantPast
            return aDate > bDate
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Sheet background is glass via .presentationBackground;
                // ZStack root must stay transparent so the glass shows.
                Color.clear
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedPlaces) { place in
                            Button {
                                onPick(place)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(place.type.emoji).font(.system(size: 18))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                        Text(visitsLabel(place))
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.78))
                                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.78))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Glass row chrome — matches every other
                                // pill / panel surface in the app.
                                .liquidGlassChrome(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("\(places.count) places here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onCancel)
                }
            }
        }
    }

    private func visitsLabel(_ place: FriendPlace) -> String {
        // `globalVisitCount` is the real visit metric (one visit per
        // session, not one per post). Falls back to post count for places
        // whose counter hasn't been hydrated yet — better than showing 0.
        let visits = max(place.globalVisitCount, 0)
        let displayed = visits > 0 ? visits : place.posts.count
        // `displayed` is the GLOBAL visit count — anyone, friend or not. The
        // posts here come from your feed (friends + you), so that subset is
        // the people you actually know who've been.
        let circleCount = Set(place.posts.map(\.authorId)).count
        let peopleWord = displayed == 1 ? "person" : "people"
        var label = "\(displayed) \(peopleWord) visited"
        if circleCount > 1 {
            label += " · \(circleCount) from your circle"
        }
        return label
    }
}

// MARK: - Filter tab bar

struct FilterTabBar: View {
    @Binding var active: FilterType
    let counts: (all: Int, cafe: Int, restaurant: Int, stall: Int)
    let onChange: (FilterType) -> Void

    private func count(for type: FilterType) -> Int {
        switch type {
        case .all:        return counts.all
        case .cafe:       return counts.cafe
        case .restaurant: return counts.restaurant
        case .stall:      return counts.stall
        }
    }

    private func chipAccent(for type: FilterType) -> Color? {
        switch type {
        case .cafe:       return AppTheme.cafeAccent
        case .stall:      return AppTheme.stallAccent
        case .restaurant: return AppTheme.accentAction
        case .all:        return nil
        }
    }

    /// `.all` always shows; a type chip only appears when it has ≥ 1 place.
    private var visibleTypes: [FilterType] {
        FilterType.allCases.filter { $0 == .all || count(for: $0) > 0 }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(visibleTypes, id: \.self) { type in
                let count = count(for: type)
                let isActive = active == type
                let chipAccent = chipAccent(for: type)

                Button { onChange(type) } label: {
                    HStack(spacing: 6) {
                        Text(type.emoji).font(.system(size: 15))
                        Text("\(count)")
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(
                                isActive
                                    ? (chipAccent ?? .primary)
                                    : .secondary
                            )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(
                            isActive
                                ? (chipAccent?.opacity(0.14) ?? AppTheme.surfacePrimary)
                                : AppTheme.textPrimary.opacity(0.04)
                        )
                    )
                    .overlay(
                        Capsule().stroke(
                            isActive
                                ? (chipAccent?.opacity(0.55) ?? AppTheme.borderSubtle)
                                : AppTheme.borderSubtle.opacity(0.6),
                            lineWidth: isActive ? 1.2 : 0.8
                        )
                    )
                    .scaleEffect(isActive ? 1.0 : 0.96)
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(type.label), \(count) places")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}
