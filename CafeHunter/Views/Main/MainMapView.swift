import SwiftUI
import MapKit
import UIKit

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

            listToggleButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // List overlay
            if showListOverlay {
                BottomSheetView(
                    height: $sheetHeight,
                    peekHeight: peekHeight,
                    expandedHeight: expandedHeight,
                    canDragDownFromContent: sheetView != .list || isListAtTop
                ) {
                    sheetContent
                }
            }
        }
        .onAppear { screenHeight = geo.size.height }
        .onChange(of: geo.size.height) { _, newValue in screenHeight = newValue }
        } // GeometryReader
        .ignoresSafeArea()
        .sheet(isPresented: $showAdmin, onDismiss: { editCafe = nil }) {
            AdminAddView(
                firestoreService: firestoreService,
                editCafe: editCafe,
                onClose: { showAdmin = false }
            )
        }
    }

    // MARK: - Top buttons

    private var topButtons: some View {
        VStack(spacing: 8) {
            if authService.isAdmin {
                Button {
                    editCafe = nil
                    showAdmin = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppTheme.cafeAccent)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.espresso)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AppTheme.cafeAccent.opacity(0.6), lineWidth: 2))
                        .shadow(radius: 4)
                }
            }
            Button {
                print("[Haptic] location button tapped")
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred()
                centerOnUser = true
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.cafeAccent)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.espresso)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AppTheme.cafeAccent.opacity(0.6), lineWidth: 2))
                    .shadow(radius: 4)
            }
        }
        .padding(.trailing, 16)
        .padding(.top, 60)
    }

    private var listToggleButton: some View {
        Button {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                showListOverlay.toggle()
                if showListOverlay && sheetHeight < peekHeight {
                    sheetHeight = peekHeight
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showListOverlay ? "map" : "list.bullet")
                    .font(.system(size: 13, weight: .bold))
                Text(showListOverlay ? "Hide list" : "Show list")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(AppTheme.cream)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AppTheme.glassStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4)
        }
        .padding(.trailing, 16)
        .padding(.bottom, ArcNavBar.frameContentHeight - 72)
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
                            .foregroundColor(AppTheme.cream.opacity(0.3))
                            .padding(.top, 32)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .coordinateSpace(name: "CafeListScroll")
            .onPreferenceChange(SheetListOffsetPreferenceKey.self) { value in
                listScrollOffset = value
            }
        } else if let cafe = activeCafe {
            // Back button bar
            HStack {
                Button(action: { goBackToList() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                        Text("Back to list")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(AppTheme.cafeAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppTheme.cafeAccent.opacity(0.12))
                    .cornerRadius(20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                    )
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 4)

            CafeDetailSheetContent(
                cafe: cafe,
                isAdmin: authService.isAdmin,
                onBack: { goBackToList() },
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
            // Drag handle
            Capsule()
                .fill(AppTheme.cream.opacity(0.45))
                .frame(width: 48, height: 6)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
                .highPriorityGesture(dragGesture)

            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: currentHeight)
        .background(AppTheme.espresso)
        .clipShape(
            .rect(topLeadingRadius: 20, bottomLeadingRadius: 0,
                  bottomTrailingRadius: 0, topTrailingRadius: 20)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: -4)
        .simultaneousGesture(dragGesture)
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
                let accent: Color = type == .stall ? AppTheme.stallAccent : AppTheme.cafeAccent

                Button { onChange(type) } label: {
                    HStack(spacing: 4) {
                        Text(type.emoji).font(.system(size: 12))
                        Text(type.label).font(.system(size: 11, weight: .semibold))
                        Text("\(count)")
                            .font(.system(size: 10))
                            .foregroundColor(isActive ? AppTheme.cream.opacity(0.7) : AppTheme.cream.opacity(0.3))
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(isActive ? Color.black.opacity(0.2) : AppTheme.cream.opacity(0.1)))
                    }
                    .foregroundColor(isActive ? AppTheme.cream : AppTheme.cream.opacity(0.45))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isActive
                                  ? (type == .stall ? AppTheme.stallAccent : type == .cafe ? accent : Color(red: 0.23, green: 0.15, blue: 0.09))
                                  : AppTheme.cream.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isActive ? Color.clear : AppTheme.cream.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}
