import SwiftUI
import MapKit
import UIKit

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
            .glassEffect(
                .regular
                    .tint(AppTheme.accentAction.opacity(0.07))
                    .interactive(),
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
    case all, cafe, stall

    var label: String {
        switch self { case .all: "All"; case .cafe: "Cafés"; case .stall: "Stalls" }
    }
    var emoji: String {
        switch self { case .all: "📍"; case .cafe: "☕"; case .stall: "🍜" }
    }
}

// MARK: - Main map view

struct MainMapView: View {
    @ObservedObject var authService: AuthService
    @ObservedObject var firestoreService: FirestoreService

    @State private var activeCafeId: String?
    @State private var sheetView: SheetViewMode = .list
    @State private var filter: FilterType = .all
    @State private var sheetHeight: CGFloat = 210
    @State private var listScrollOffset: CGFloat = 0
    @State private var showListOverlay = false
    @State private var showAdmin = false
    @State private var editCafe: Cafe?
    @State private var centerOnUser = false
    @State private var targetCoordinate: CLLocationCoordinate2D?
    @State private var locationManager = LocationManager()

    // Cute "happy" breathing loop for the Show List pill.
    @State private var showListBreathing = false
    @State private var showListPressed   = false

    private let peekHeight: CGFloat = 210
    @State private var screenHeight: CGFloat = 700
    private var expandedHeight: CGFloat { screenHeight * 0.75 }
    private var isListAtTop: Bool { listScrollOffset >= -1 }

    private var filteredCafes: [Cafe] {
        switch filter {
        case .all:   return firestoreService.cafes
        case .cafe:  return firestoreService.cafes.filter { $0.type == .cafe }
        case .stall: return firestoreService.cafes.filter { $0.type == .stall }
        }
    }

    private var activeCafe: Cafe? {
        guard let id = activeCafeId else { return nil }
        return firestoreService.cafes.first { $0.id == id }
    }

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .bottom) {
            // Map
            CafeMapView(
                cafes: filteredCafes,
                activeCafeId: activeCafeId,
                onPinClick: { id in selectCafe(id) },
                centerOnUser: $centerOnUser,
                targetCoordinate: $targetCoordinate,
                locationManager: locationManager
            )

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
                    canDragDownFromContent: sheetView != .list || isListAtTop,
                    onHide: hideListSheet,
                    // Only surface the back-arrow in detail mode.
                    onBack: sheetView == .detail ? { goBackToList() } : nil
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
        .floatingPanel(isPresented: $showAdmin) {
            AdminAddView(
                firestoreService: firestoreService,
                editCafe: editCafe,
                onClose: {
                    showAdmin = false
                    editCafe  = nil
                }
            )
        }
    }

    // MARK: - Top buttons

    private var topButtons: some View {
        VStack(spacing: 10) {
            Button {
                editCafe = nil
                showAdmin = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .liquidGlassHUD()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add café or stall")

            Button {
                print("[Haptic] location button tapped")
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred()
                centerOnUser = true
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .liquidGlassHUD()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center on my location")
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
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) {
                showListPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    showListPressed = false
                }
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                if sheetHeight < peekHeight { sheetHeight = peekHeight }
                showListOverlay = true
            }
        } label: {
            HStack(spacing: 8) {
                // Accent dot — little heartbeat pulse so the pill feels alive.
                Circle()
                    .fill(AppTheme.accentAction)
                    .frame(width: 6, height: 6)
                    .shadow(
                        color: AppTheme.accentAction.opacity(showListBreathing ? 0.85 : 0.45),
                        radius: showListBreathing ? 5 : 2.5,
                        x: 0, y: 0
                    )
                    .scaleEffect(showListBreathing ? 1.15 : 0.92)

                Image(systemName: "list.bullet")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(showListBreathing ? -3 : 3))
                Text("Show list")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.3)
            }
            .foregroundColor(AppTheme.textPrimary)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            // Real Apple Liquid Glass capsule — refracts the map behind it.
            .glassEffect(
                .regular
                    .tint(AppTheme.accentAction.opacity(0.08))
                    .interactive(),
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
            // Gentle "breathing" loop + tiny bob + press squish.
            .scaleEffect(showListPressed ? 0.94 : (showListBreathing ? 1.035 : 1.0))
            .offset(y: showListBreathing ? -1.5 : 1.5)
        }
        .buttonStyle(.plain)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
        }
        .padding(.bottom, listShowButtonBottomInset(safeBottom: safeBottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
        .onAppear {
            // Kick off the infinite breathing/bob loop once the pill is on-screen.
            guard !showListBreathing else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                showListBreathing = true
            }
        }
    }

    private func hideListSheet() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            showListOverlay = false
            goBackToList()
            sheetHeight = peekHeight
        }
    }

    // MARK: - Sheet content

    @ViewBuilder
    private var sheetContent: some View {
        if sheetView == .list {
            FilterTabBar(active: $filter, counts: filterCounts) { f in
                filter = f
                activeCafeId = nil
                sheetView = .list
            }
            .padding(.top, 4)

            ScrollView {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SheetListOffsetPreferenceKey.self,
                                    value: proxy.frame(in: .named("CafeListScroll")).minY)
                }
                .frame(height: 0)

                LazyVStack(spacing: 10) {
                    ForEach(filteredCafes) { cafe in
                        CafeCardView(cafe: cafe, isActive: cafe.id == activeCafeId) {
                            selectCafe(cafe.id ?? "")
                        }
                    }
                    if filteredCafes.isEmpty {
                        Text("Nothing here yet.")
                            .font(.system(size: 14))
                            .foregroundColor(AppTheme.textSecondary)
                            .padding(.top, 32)
                    }
                    // Reserve room so the last card sits comfortably above
                    // the arc navbar at max scroll-down.
                    Color.clear.frame(height: 170)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .coordinateSpace(name: "CafeListScroll")
            .onPreferenceChange(SheetListOffsetPreferenceKey.self) { value in
                listScrollOffset = value
            }
        } else if let cafe = activeCafe {
            CafeDetailSheetContent(
                cafe: cafe,
                onEdit: {
                    editCafe = cafe
                    showAdmin = true
                },
                onDelete: {
                    Task {
                        if let id = cafe.id {
                            try? await firestoreService.deletePlace(id: id)
                        }
                        goBackToList()
                    }
                }
            )
        }
    }

    private var filterCounts: (all: Int, cafe: Int, stall: Int) {
        (
            all:   firestoreService.cafes.count,
            cafe:  firestoreService.cafes.filter { $0.type == .cafe }.count,
            stall: firestoreService.cafes.filter { $0.type == .stall }.count
        )
    }

    // MARK: - Navigation helpers

    private func selectCafe(_ id: String) {
        activeCafeId = id
        sheetView = .detail
        showListOverlay = true
        withAnimation(.spring(response: 0.4)) {
            sheetHeight = expandedHeight
        }
        if let cafe = firestoreService.cafes.first(where: { $0.id == id }) {
            targetCoordinate = CLLocationCoordinate2D(latitude: cafe.lat, longitude: cafe.lng)
        }
    }

    private func goBackToList() {
        activeCafeId = nil
        sheetView = .list
    }
}

enum SheetViewMode { case list, detail }

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
            // ── Header: back (left, detail-only) · drag handle (centered) · hide (right)
            ZStack {
                // Drag handle — always centered on the sheet width, independent
                // of whether the back button is visible, so it doesn't shift
                // between list and detail mode.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .highPriorityGesture(dragGesture)
                Capsule()
                    .fill(AppTheme.textPrimary.opacity(0.22))
                    .frame(width: 48, height: 5)

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
        .simultaneousGesture(dragGesture)
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
                        .tint(AppTheme.accentAction.opacity(0.07))
                        .interactive(),
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

private struct SheetListOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Filter tab bar

struct FilterTabBar: View {
    @Binding var active: FilterType
    let counts: (all: Int, cafe: Int, stall: Int)
    let onChange: (FilterType) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FilterType.allCases, id: \.self) { type in
                let count = type == .all ? counts.all : type == .cafe ? counts.cafe : counts.stall
                let isActive = active == type
                let chipAccent: Color? = type == .cafe ? AppTheme.cafeAccent
                    : type == .stall ? AppTheme.stallAccent : nil

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
