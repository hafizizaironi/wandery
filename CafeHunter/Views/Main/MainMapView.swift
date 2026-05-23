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
        content
            // No `.interactive()` — it defers tap recognition while resolving touch vs. glass tracking.
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
            .shadow(color: AppTheme.accentAction.opacity(0.14),
                    radius: 8, x: 0, y: 3)
            .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
    }
}

extension View {
    /// Applies the shared circular Liquid Glass HUD styling.
    fileprivate func liquidGlassHUD() -> some View {
        modifier(LiquidGlassHUDModifier())
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
    /// Set externally (e.g. from a feed pill tap) to fly to a place + open
    /// the detail sheet. Cleared once consumed.
    @Binding var pendingPlaceJumpId: String?

    @State private var friendPlacesService = FriendPlacesService()
    @State private var activeFriendPlace: FriendPlace?
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

    // Show List pill idle animation — periodic "happy jump".
    @State private var showListJumpOffset: CGFloat = 0
    @State private var showListJumpScale:  CGFloat = 1.0
    @State private var showListDotPulse    = false
    @State private var showListPressed     = false
    @State private var showListIdleTask:   Task<Void, Never>? = nil

    private let peekHeight: CGFloat = 210
    @State private var screenHeight: CGFloat = 700
    private var expandedHeight: CGFloat { screenHeight * 0.75 }
    private var isListAtTop: Bool { listScrollOffset >= -1 }

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
                activeCafeId: nil,
                onPinClick: { id in centerOnLegacyCafe(id: id) },
                onFriendPinClick: { place in activeFriendPlace = place },
                onClusterTap: { places in clusterSelection = ClusterSelection(places: places) },
                centerOnUser: $centerOnUser,
                targetCoordinate: $targetCoordinate,
                locationManager: locationManager
            )
            .task(id: socialService.feedPosts.map(\.id)) {
                await friendPlacesService.refresh(from: socialService.feedPosts)
            }
            .sheet(item: $activeFriendPlace) { place in
                PlaceDetailSheet(place: place) {
                    activeFriendPlace = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showDiscover) {
                DiscoverView(
                    locationManager: locationManager,
                    onSelect: { place in
                        showDiscover = false
                        // Centre the map on the picked place using the
                        // same upper-quarter bias we use elsewhere so the
                        // pin sits where the eye lands, not buried under
                        // a UI panel.
                        targetCoordinate = CLLocationCoordinate2D(
                            latitude: place.lat - 0.00375,
                            longitude: place.lng
                        )
                    },
                    onClose: { showDiscover = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
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
            }
            .onChange(of: pendingPlaceJumpId) { _, newId in
                guard let placeId = newId else { return }
                Task { await consumePlaceJump(placeId: placeId) }
            }

            // Top-right HUD buttons
            topButtons
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // "Show list" — floats just above the arc's top peak; hidden while sheet is open
            if !showListOverlay {
                showListFloatingButton(safeBottom: geo.safeAreaInsets.bottom)
            }

            // List overlay
            if showListOverlay {
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
                // Horizontal inset so the sheet floats like a card
                .padding(.horizontal, FloatingPanelStyle.horizontalInset)
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
            .accessibilityLabel("Discover creator's pick places")
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
            .glassEffect(
                .regular
                    .tint(AppTheme.accentAction.opacity(0.08)),
                in: Capsule()
            )
            .liquidGlassShine(in: Capsule(), strength: 1.0)
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.70),
                                Color.white.opacity(0.20),
                                AppTheme.accentAction.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: AppTheme.accentAction.opacity(0.18),
                    radius: 10, x: 0, y: 3)
            .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
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

        ScrollView {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SheetListOffsetPreferenceKey.self,
                                value: proxy.frame(in: .named("CafeListScroll")).minY)
            }
            .frame(height: 0)

            LazyVStack(spacing: 8) {
                ForEach(filteredPlaces) { place in
                    placeRow(place)
                }
                if filteredPlaces.isEmpty {
                    Text(filter == .all
                         ? "No places shared yet — tag a place when you post."
                         : "No \(filter.label.lowercased()) shared yet.")
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(.top, 32)
                        .padding(.horizontal, 24)
                }
                // Reserve room so the last row sits comfortably above the
                // arc navbar at max scroll-down.
                Color.clear.frame(height: 170)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .coordinateSpace(name: "CafeListScroll")
        .onPreferenceChange(SheetListOffsetPreferenceKey.self) { value in
            listScrollOffset = value
        }
    }

    /// Plain row — emoji, name, visit count. Tap centers the map on the
    /// place and opens the friend-posts card stack.
    private func placeRow(_ place: FriendPlace) -> some View {
        Button {
            selectFriendPlace(place)
        } label: {
            HStack(spacing: 12) {
                Text(place.type.emoji).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(visitsLabel(place))
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.surfacePrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func visitsLabel(_ place: FriendPlace) -> String {
        // `globalVisitCount` is the real visit metric (one visit per
        // session, not one per post). Falls back to post count for places
        // whose counter hasn't been hydrated yet — better than showing 0.
        let visits = max(place.globalVisitCount, 0)
        let displayed = visits > 0 ? visits : place.posts.count
        let friendCount = Set(place.posts.map(\.authorId)).count
        if displayed == 1 { return "1 visit" }
        if friendCount <= 1 { return "\(displayed) visits" }
        return "\(displayed) visits · \(friendCount) friends"
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
            let postsAtPlace = socialService.feedPosts.filter { $0.placeId == placeId }
            let synthesized = FriendPlace(
                id: placeId,
                name: doc.name,
                type: doc.type,
                lat: doc.lat,
                lng: doc.lng,
                posts: postsAtPlace.sorted { $0.createdAt > $1.createdAt }
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
        .background(AppTheme.espresso)
        .clipShape(RoundedRectangle(
            cornerRadius: FloatingPanelStyle.cornerRadius,
            style: .continuous
        ))
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: -6)
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
                .foregroundColor(AppTheme.textPrimary)
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
                AppTheme.surfaceCanvas.ignoresSafeArea()
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
                                            .foregroundColor(AppTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(visitsLabel(place))
                                            .font(.system(size: 11))
                                            .foregroundColor(AppTheme.textSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(AppTheme.textSecondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12).fill(AppTheme.surfacePrimary))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.borderSubtle, lineWidth: 1))
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
        let friendCount = Set(place.posts.map(\.authorId)).count
        if displayed == 1 { return "1 visit" }
        if friendCount <= 1 { return "\(displayed) visits" }
        return "\(displayed) visits · \(friendCount) friends"
    }
}

private struct SheetListOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FilterType.allCases, id: \.self) { type in
                let count = count(for: type)
                let isActive = active == type
                let chipAccent = chipAccent(for: type)

                Button { onChange(type) } label: {
                    HStack(spacing: 4) {
                        Text(type.emoji).font(.system(size: 12))
                        Text(type.label).font(.system(size: 11, weight: .semibold))
                        Text("\(count)")
                            .font(.system(size: 10))
                            .foregroundColor(isActive ? AppTheme.textPrimary.opacity(0.7) : AppTheme.textSecondary)
                            .padding(.horizontal, 4)
                            .background(
                                Capsule()
                                    .fill(
                                        isActive
                                            ? AppTheme.textPrimary.opacity(type == .all ? 0.1 : 0.06)
                                            : AppTheme.textPrimary.opacity(0.05)
                                    )
                            )
                    }
                    .foregroundColor(
                        isActive
                            ? (chipAccent ?? AppTheme.textPrimary)
                            : AppTheme.textSecondary
                    )
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isActive ? AppTheme.surfacePrimary : AppTheme.textPrimary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isActive
                                    ? (chipAccent?.opacity(0.4) ?? AppTheme.borderSubtle)
                                    : AppTheme.borderSubtle,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}
