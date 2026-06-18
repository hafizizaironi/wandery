import SwiftUI
import UIKit
import Photos
import CoreImage

// MARK: - Marketing mockups (admin-only)
//
// Three full-bleed, swipeable pages recreating the headline features
// (Camera · Discover · My Hunt) with hardcoded data — no live services, no
// network — so the admin can screenshot them for App Store Connect. Imagery
// uses `MockImage`, which renders branded placeholders until real photos are
// supplied — either by dropping assets (mock_cafe1, mock_food2, …) into the
// catalog, or by tapping "Edit" here and picking a photo for each slot (stored
// locally via `MockImageStore`).

/// Single source of truth for the mockup pages — drives both the TabView and
/// the save / save-all renderers, so adding a page is a one-line change.
private enum MockupPage: Int, CaseIterable, Identifiable {
    case camera, discover, myHunt, wanderyCode, placeCards, chat, widgets
    // Instagram invite story — a 3-frame sequence (ache → turn → call).
    // Exported at 9:16 instead of the App Store device ratio (see exportSize).
    case storyAche, storyTurn, storyCall

    var id: Int { rawValue }

    /// Short label for the save-all progress toast / accessibility.
    var title: String {
        switch self {
        case .camera:      return "Camera"
        case .discover:    return "Discover"
        case .myHunt:      return "My Hunt"
        case .wanderyCode: return "Wandery Code"
        case .placeCards:  return "Place cards"
        case .chat:        return "Chat"
        case .widgets:     return "Widgets"
        case .storyAche:   return "Story · Ache"
        case .storyTurn:   return "Story · Turn"
        case .storyCall:   return "Story · Call"
        }
    }

    @MainActor @ViewBuilder private var view: some View {
        switch self {
        case .camera:      CameraMockPage()
        case .discover:    DiscoverMockPage()
        case .myHunt:      MyHuntMockPage()
        case .wanderyCode: WanderyCodeMockPage()
        case .placeCards:  PlaceCardsMockPage()
        case .chat:        ChatThreadMockPage()
        case .widgets:     HomeWidgetsMockPage()
        case .storyAche:   StoryAchePage()
        case .storyTurn:   StoryTurnPage()
        case .storyCall:   StoryCallPage()
        }
    }

    /// Fixed export canvas for pages that aren't device-ratio App Store
    /// screenshots. Instagram stories must be 9:16 → 360×640 pt renders at
    /// `scale = 3` to exactly 1080×1920 px. `nil` = use the live cover size.
    var exportSize: CGSize? {
        switch self {
        case .storyAche, .storyTurn, .storyCall: return CGSize(width: 360, height: 640)
        default: return nil
        }
    }

    /// Type-erased so the TabView + the off-screen renderer hold a uniform
    /// element type. Rendered at most once per page (never a hot loop).
    @MainActor var anyView: AnyView { AnyView(view) }
}

struct MarketingMockupsView: View {
    var onClose: () -> Void = {}

    @State private var page: MockupPage = .camera
    @State private var editing = false
    @State private var showClearConfirm = false
    /// Full-bleed size of the cover, captured so the saved page matches the
    /// on-screen layout. Falls back to a sensible iPhone size if unset.
    @State private var renderSize: CGSize = .zero
    /// Transient "Saved to Photos ✓" toast text.
    @State private var saveStatus: String?
    /// True while a "Save all" batch is running (disables the button).
    @State private var savingAll = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $page) {
                ForEach(MockupPage.allCases) { mockPage in
                    mockPage.anyView.tag(mockPage)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .ignoresSafeArea()
            .environment(\.mockImageEditing, editing)

            topBar
        }
        // Capture the full-bleed size for the page renderer.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { renderSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in renderSize = newSize }
            }
            .ignoresSafeArea()
        )
        .overlay(alignment: .bottom) {
            if let saveStatus { saveToast(saveStatus) }
        }
        .confirmationDialog(
            "Remove every photo you've added?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all photos", role: .destructive) { MockImageStore.shared.clearAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Save current page (clean, no chrome)

    /// Renders the CURRENT page on its own — no edit overlays, no ✕, no Edit
    /// button, no page-indicator dots (those all live in the cover wrapper /
    /// TabView, not in the page) — and saves it to Photos for App Store use.
    private func saveCurrentPage() {
        let size = page.exportSize ?? (renderSize == .zero ? CGSize(width: 393, height: 852) : renderSize)
        let pageView = page.anyView
            .environment(\.mockImageEditing, false)   // never draw the edit affordance
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: pageView)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.uiImage else {
            Task { await flashSave("Couldn't render the page.") }
            return
        }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await flashSave("Allow Photos access in Settings to save.")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                await flashSave("Saved to Photos ✓")
            } catch {
                await flashSave("Couldn't save.")
            }
        }
    }

    /// Renders EVERY page (via the registry) and saves each to Photos in page
    /// order. One auth request up front; the per-page `await` keeps a single
    /// image alive at a time and guarantees each PHAsset write lands.
    private func saveAllPages() {
        let deviceSize = renderSize == .zero ? CGSize(width: 393, height: 852) : renderSize
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await flashSave("Allow Photos access in Settings to save."); return
            }
            savingAll = true
            defer { savingAll = false }
            let pages = MockupPage.allCases
            var saved = 0
            for mockPage in pages {
                let size = mockPage.exportSize ?? deviceSize
                let renderer = ImageRenderer(content:
                    mockPage.anyView
                        .environment(\.mockImageEditing, false)
                        .frame(width: size.width, height: size.height))
                renderer.scale = 3
                renderer.proposedSize = ProposedViewSize(size)
                guard let image = renderer.uiImage else { continue }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                    saved += 1
                    showProgress("Saved \(saved) of \(pages.count)…")
                } catch { /* keep going; report the total at the end */ }
            }
            await flashSave(saved == pages.count
                ? "Saved all \(pages.count) ✓"
                : "Saved \(saved) of \(pages.count)")
        }
    }

    /// Non-blocking toast setter (no auto-clear) for in-flight progress, so the
    /// per-page updates don't serialize behind `flashSave`'s 2.2s window.
    @MainActor private func showProgress(_ message: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { saveStatus = message }
    }

    @MainActor
    private func flashSave(_ message: String) async {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { saveStatus = message }
        try? await Task.sleep(for: .seconds(2.2))
        withAnimation(.easeInOut(duration: 0.3)) { saveStatus = nil }
    }

    private func saveToast(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
            .padding(.bottom, 44)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if editing {
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button(action: saveCurrentPage) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.4), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save this page to Photos")

            Button(action: saveAllPages) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.4), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(savingAll)
            .opacity(savingAll ? 0.5 : 1)
            .accessibilityLabel("Save all pages to Photos")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { editing.toggle() }
            } label: {
                Text(editing ? "Done" : "Edit")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(editing ? Color.black : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(editing ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.4)),
                                in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(editing ? "Finish editing photos" : "Edit photos")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.trailing, 16)
        .padding(.top, 12)
    }
}

// MARK: - Caption banner

private struct CaptionBanner: View {
    let title: String
    let subtitle: String
    var onDark: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.huntSerif(30))
                .multilineTextAlignment(.center)
                .foregroundStyle(onDark ? Color.white : AppTheme.textPrimary)
            Text(subtitle)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(onDark ? Color.white.opacity(0.7) : AppTheme.textSecondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Page 1 · Camera

private struct CameraMockPage: View {
    private let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                CaptionBanner(
                    title: "Snap it like a Polaroid",
                    subtitle: "CAPTURE · CAPTION · POST IN SECONDS",
                    onDark: true
                )
                Spacer(minLength: 0)
                GeometryReader { geo in
                    let side = min(geo.size.width - 96, 300)
                    VStack(spacing: 28) {
                        PolaroidFrame(
                            username: "@feez",
                            date: fixedDate,
                            placeName: "The Pokok",
                            caption: "2:44pm, worth it",
                            photoSide: side
                        ) {
                            MockImage(name: "mock_cafe1")
                        }
                        reviewButtons
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var reviewButtons: some View {
        HStack(spacing: 28) {
            circleButton(icon: "arrow.counterclockwise", size: 54, filled: false)
            circleButton(icon: "paperplane.fill", size: 68, filled: true)
            circleButton(icon: "square.and.arrow.down", size: 54, filled: false)
        }
    }

    private func circleButton(icon: String, size: CGFloat, filled: Bool) -> some View {
        Group {
            if filled {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(AppTheme.cafeAccent))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .liquidGlassChrome(in: Circle())
            }
        }
    }
}

// MARK: - Page 2 · Discover

private struct DiscoverMockPage: View {
    private struct Tile: Identifiable { let id = UUID(); let asset: String; let blurred: Bool }

    private let tiles: [Tile] = [
        .init(asset: "mock_cafe1", blurred: false),
        .init(asset: "mock_food1", blurred: false),
        .init(asset: "mock_stall1", blurred: false),
        .init(asset: "mock_food2", blurred: false),
        .init(asset: "mock_cafe2", blurred: true),
        .init(asset: "mock_stall2", blurred: false),
        .init(asset: "mock_food3", blurred: false),
        .init(asset: "mock_cafe3", blurred: false),
        .init(asset: "mock_food4", blurred: true),
        .init(asset: "mock_stall3", blurred: false),
        .init(asset: "mock_cafe4", blurred: false),
        .init(asset: "mock_food5", blurred: false),
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.08, blue: 0.06).ignoresSafeArea()
            VStack(spacing: 0) {
                CaptionBanner(
                    title: "See what's trending nearby",
                    subtitle: "REAL SPOTS · REAL PEOPLE · RIGHT NOW",
                    onDark: true
                )
                trendingHeader
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(tiles) { tile in
                        MockImage(name: tile.asset)
                            .frame(height: 116)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.white.opacity(0.10), lineWidth: 1)
                            )
                            .blur(radius: tile.blurred ? 12 : 0)
                    }
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
        }
    }

    private var trendingHeader: some View {
        HStack(spacing: 6) {
            Text("🔥").font(.title3)
            Text("Trending")
                .font(.title2).bold()
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

// MARK: - Page 3 · My Hunt

private struct MyHuntMockPage: View {
    private struct Row: Identifiable {
        let id = UUID()
        let name: String, emoji: String, city: String, asset: String, last: String
        let visits: Int, most: Bool
    }

    private let rows: [Row] = [
        .init(name: "Sup Kambing Ayam", emoji: "🍜", city: "Shah Alam", asset: "mock_stall1", last: "TODAY", visits: 6, most: true),
        .init(name: "Kopi Seni", emoji: "☕️", city: "Bangsar", asset: "mock_cafe1", last: "2 DAYS AGO", visits: 3, most: false),
        .init(name: "Honolu Ramen", emoji: "🍽️", city: "TRX", asset: "mock_food2", last: "MAY 24", visits: 2, most: false),
        .init(name: "Brew & Bite", emoji: "☕️", city: "Damansara", asset: "mock_cafe2", last: "MAY 21", visits: 1, most: false),
    ]

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            VStack(spacing: 0) {
                CaptionBanner(
                    title: "Your hunt, beautifully mapped",
                    subtitle: "EVERY CAFÉ, STALL & CITY YOU'VE TAGGED",
                    onDark: false
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        mapHero
                        milestone
                        monthSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private var mapHero: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cafeGradient(0))
                .frame(height: 280)
                .overlay { mapPins }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 10) {
                statCard(number: "12", label: "cafés")
                statCard(number: "08", label: "restaurants")
                statCard(number: "27", label: "stalls")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    private var mapPins: some View {
        GeometryReader { geo in
            let pts: [(CGFloat, CGFloat)] = [
                (0.22, 0.62), (0.40, 0.48), (0.55, 0.70),
                (0.68, 0.40), (0.34, 0.78), (0.78, 0.62), (0.50, 0.30)
            ]
            ZStack {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    PersimmonPinMock()
                        .position(x: geo.size.width * p.0, y: geo.size.height * p.1)
                }
            }
        }
    }

    private func statCard(number: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(number).font(.huntSerif(26)).foregroundStyle(AppTheme.textPrimary)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .liquidGlassChrome(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var milestone: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOU'VE BEEN BUSY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(AppTheme.cafeAccent)
            Text("47 places across 6 cities in 312 days.")
                .font(.huntSerif(22))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var monthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("May 2026 · 5 places")
                .font(.huntSerif(18))
                .foregroundStyle(AppTheme.textSecondary)
            ForEach(rows) { row in placeRow(row) }
        }
    }

    private func placeRow(_ row: Row) -> some View {
        HStack(spacing: 12) {
            MockImage(name: row.asset)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    if row.most {
                        Text("★ MOST")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .kerning(0.8)
                            .foregroundStyle(AppTheme.cafeAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(AppTheme.cafeAccent.opacity(0.12)))
                    }
                }
                HStack(spacing: 6) {
                    Text(row.emoji)
                    Text(row.city)
                    Text("·").foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                    Text("\(row.visits)× visited")
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Text(row.last)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .kerning(0.6)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 4)
    }
}

/// Local recreation of `HuntingMapSection`'s private `PersimmonPin`.
private struct PersimmonPinMock: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.cafeAccent)
                .frame(width: 16, height: 16)
                .overlay { Circle().stroke(Color.white, lineWidth: 2) }
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            Circle().fill(.white).frame(width: 5, height: 5)
        }
    }
}

// MARK: - Page 4 · Wandery Code

private struct WanderyCodeMockPage: View {
    // Encoded synchronously once (the README reference vector) so the real
    // circular code is non-nil at first body eval — both on-screen AND in the
    // off-screen Save-All renderer (a `.task`-based encode wouldn't have run).
    private static let referenceCode = WanderyCodec()?.encode(accountId: 12345)
    private static let paper = Color(hex: "#f0e9d8")

    var body: some View {
        ZStack {
            Self.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                CaptionBanner(
                    title: "Your code, your circle",
                    subtitle: "ONE SCAN TO ADD A HUNTING BUDDY",
                    onDark: false
                )
                Spacer(minLength: 4)
                codeArea
                identity
                Text("Point a friend's camera at this to add them on Wandery.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
                    .padding(.top, 12)
                Spacer(minLength: 8)
                buttons
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
            }
        }
    }

    private var codeArea: some View {
        let d: CGFloat = 300
        // Locket diameter mirrors WanderyCodeSpikeView.withAvatar — the quiet
        // zone at the code's centre, so overlaying it never affects a scan.
        let avatar = d * CGFloat(2 * WanderyCodeGeometry.locketR / WanderyCodeGeometry.box)
        return ZStack {
            if let code = Self.referenceCode {
                WanderyCodeCanvas(encoded: code)
                MockImage(name: "mock_wandery_avatar")
                    .scaledToFill()
                    .frame(width: avatar, height: avatar)
                    .clipShape(Circle())
            } else {
                fallbackCode   // decorative — codec init never fails in practice
            }
        }
        .frame(width: d, height: d)
    }

    private var identity: some View {
        VStack(spacing: 2) {
            Text("Feez")
                .font(.huntSerif(34))
                .foregroundStyle(AppTheme.textPrimary)
            Text("@feez")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.top, 18)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.cafeAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .overlay(Capsule().stroke(AppTheme.cafeAccent, lineWidth: 1.5))
            Label("Save Code", systemImage: "square.and.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color(hex: "#a07522"), in: Capsule())
        }
    }

    /// Decorative stand-in if `WanderyCodec()` ever fails to init (so a
    /// screenshot never shows an empty disc). Not a real, scannable code.
    private var fallbackCode: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(AppTheme.textPrimary,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, dash: [11, 7]))
                    .rotationEffect(.degrees(Double(i) * 41))
                    .padding(CGFloat(18 + i * 26))
            }
            ForEach(0..<3, id: \.self) { i in
                PersimmonPinMock()
                    .scaleEffect(1.6)
                    .offset(y: -132)
                    .rotationEffect(.degrees(Double(i) * 120))
            }
            Circle().fill(AppTheme.stallAccent).frame(width: 56, height: 56)
        }
    }
}

// MARK: - Page 5 · Place-detail cards

private struct PlaceCardsMockPage: View {
    private struct Card: Identifiable {
        let id = UUID()
        let asset: String, caption: String, time: String
    }
    private let cards: [Card] = [
        .init(asset: "mock_pd_card1", caption: "First flat white of the year ☕️", time: "2h ago"),
        .init(asset: "mock_pd_card2", caption: "corner seat, golden hour", time: "yesterday"),
        .init(asset: "mock_pd_card3", caption: "they remember my order now", time: "May 24"),
    ]

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            VStack(spacing: 0) {
                CaptionBanner(
                    title: "Every photo, from people you trust",
                    subtitle: "TAP A PIN · SEE WHO'S BEEN",
                    onDark: false
                )
                header
                Spacer(minLength: 0)
                GeometryReader { geo in
                    let side = min(geo.size.width - 64, 340)
                    ZStack {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { idx, card in
                            cardView(card, pos: idx, side: side)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("☕️").font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kopi Seni").font(.headline).foregroundStyle(AppTheme.textPrimary)
                Text("8 visits by 3 friends").font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func cardView(_ card: Card, pos: Int, side: CGFloat) -> some View {
        let scale = 1.0 - CGFloat(pos) * 0.04
        let yOff = CGFloat(pos) * 12
        return ZStack(alignment: .bottomLeading) {
            MockImage(name: card.asset)
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(card.caption)
                    .font(.subheadline).foregroundStyle(.white).lineLimit(2)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                Text(card.time).font(.caption2).foregroundStyle(.white.opacity(0.78))
            }
            .padding(14)
        }
        .frame(width: side, height: side)
        .overlay(alignment: .topTrailing) {
            if pos == 0 {
                MockImage(name: "mock_pd_avatar")
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    .padding(12)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(.white.opacity(0.18), lineWidth: 1))
        .scaleEffect(scale)
        .offset(y: yOff)
        .opacity(pos == 0 ? 1 : 0.9)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .zIndex(Double(3 - pos))
    }
}

// MARK: - Page 6 · Chat thread

private struct ChatThreadMockPage: View {
    private struct Msg: Identifiable { let id = UUID(); let text: String; let isMe: Bool }
    private let msgs: [Msg] = [
        .init(text: "where was that ramen??", isMe: false),
        .init(text: "TRX, level 2 — Honolu 🍜", isMe: true),
        .init(text: "adding it to my hunt 🔥", isMe: false),
    ]

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            VStack(spacing: 0) {
                CaptionBanner(
                    title: "Share a find without leaving the chat",
                    subtitle: "SEND A PLACE · KEEP HUNTING TOGETHER",
                    onDark: false
                )
                chatHeader
                Divider().opacity(0.15)
                VStack(spacing: 10) {
                    bubble(msgs[0])
                    bubble(msgs[1])
                    sharedPlaceBubble
                    bubble(msgs[2])
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                Spacer()
                composer
            }
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left").font(.headline).foregroundStyle(AppTheme.textPrimary)
            MockImage(name: "mock_chat_avatar")
                .scaledToFill().frame(width: 30, height: 30).clipShape(Circle())
            Text("Aisyah").font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func bubble(_ m: Msg) -> some View {
        HStack {
            if m.isMe { Spacer(minLength: 44) }
            Text(m.text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 18,
                        bottomLeadingRadius: m.isMe ? 18 : 4,
                        bottomTrailingRadius: m.isMe ? 4 : 18,
                        topTrailingRadius: 18,
                        style: .continuous
                    )
                    .fill(m.isMe ? AppTheme.surfacePrimary : AppTheme.cafeAccent.opacity(0.12))
                )
            if !m.isMe { Spacer(minLength: 44) }
        }
    }

    private var sharedPlaceBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                MockImage(name: "mock_chat_post")
                    .scaledToFill()
                    .frame(width: 200, height: 150)
                    .clipped()
                HStack(spacing: 6) {
                    Text("📍").font(.caption)
                    Text("Honolu Ramen · TRX")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .frame(width: 200)
            .background(AppTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 1))
            Spacer(minLength: 44)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 10) {
                Text("Message…")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(AppTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1))
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.cafeAccent))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

// MARK: - Page 7 · Home-screen widgets
//
// Recreates the widget VISUALS as plain SwiftUI (WidgetKit views need a
// TimelineEntry + widgetFamily, so they can't be embedded). Colors are local
// copies of the widget's WanderyTheme palette (that type lives in the widget
// target, not the app).

private struct HomeWidgetsMockPage: View {
    private let espresso  = Color(hex: "#160F09")
    private let cream     = Color(hex: "#EFE6D2")
    private let persimmon = Color(hex: "#D96A3F")
    private let olive     = Color(hex: "#7C8F56")
    private let honey     = Color(hex: "#C9913F")

    private let widgetW: CGFloat = 340
    private let widgetH: CGFloat = 158

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#C9B79C"), Color(hex: "#8A6E52")],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                CaptionBanner(
                    title: "Your circle, on your Home Screen",
                    subtitle: "PHOTO FEED · NEARBY MAP WIDGETS",
                    onDark: true
                )
                Spacer(minLength: 0)
                VStack(spacing: 22) {
                    photoFeedWidget
                    nearbyMapWidget
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var photoFeedWidget: some View {
        ZStack(alignment: .topLeading) {
            MockImage(name: "mock_widget_photo")
                .scaledToFill()
                .frame(width: widgetW, height: widgetH)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
            MockImage(name: "mock_widget_avatar")
                .scaledToFill().frame(width: 34, height: 34).clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .padding(14)
            VStack(alignment: .leading, spacing: 2) {
                Spacer()
                Text("Kopi Seni").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Text("first flat white of the year")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
            }
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .padding(14)
            .frame(width: widgetW, height: widgetH, alignment: .bottomLeading)
        }
        .frame(width: widgetW, height: widgetH)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    private var nearbyMapWidget: some View {
        ZStack {
            MockImage(name: "mock_widget_map")
                .scaledToFill().frame(width: widgetW, height: widgetH).clipped()
            GeometryReader { geo in
                ZStack {
                    pin(persimmon).position(x: geo.size.width * 0.30, y: geo.size.height * 0.40)
                    pin(olive).position(x: geo.size.width * 0.62, y: geo.size.height * 0.64)
                    pin(honey).position(x: geo.size.width * 0.76, y: geo.size.height * 0.34)
                    youDot.position(x: geo.size.width * 0.50, y: geo.size.height * 0.52)
                }
            }
            VStack {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 11, weight: .bold))
                        Text("Nearby · 5").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(espresso)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(cream, in: Capsule())
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(width: widgetW, height: widgetH)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    private func pin(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(45))
            .overlay(Circle().fill(.white).frame(width: 6, height: 6))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }

    private var youDot: some View {
        ZStack {
            Circle().fill(persimmon.opacity(0.25)).frame(width: 30, height: 30)
            Circle().fill(persimmon).frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
    }
}

// MARK: - Instagram invite story (9:16)
//
// A 3-frame sequence — ache → turn → call — that turns a relatable pain ("my
// friends post the food, never the place") into Wandery's promise (pin the spot,
// share it with only your circle) and lands on a scannable TestFlight QR.
//
// Each frame is authored on a fixed 360×640 design canvas (see `StoryFrame`) so
// the on-screen preview and the 1080×1920 export are pixel-for-pixel identical:
// the export renders the canvas at scale 1 (×3 = 1080×1920); the live preview
// just scales the same canvas up to fill the taller device screen.

/// 9:16 design canvas. Lays children out at a fixed 360×640 and scales that
/// whole canvas to fit the available space (letterboxing on a taller screen),
/// so authored point sizes map straight to the export with no proportion drift.
private struct StoryFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    private let design = CGSize(width: 360, height: 640)

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / design.width,
                            geo.size.height / design.height)
            ZStack {
                Color.black
                content()
                    .frame(width: design.width, height: design.height)
                    .scaleEffect(scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// The hero polaroid shared by frames 1 & 2 — same photo, same caption, but the
/// location pill flips from redacted to revealed (the "let's change that" beat).
/// The photo is a `MockImage` slot so Edit mode can drop in a real food pic; both
/// frames share the `"story_dish"` name so they update together.
private struct StoryPolaroid: View {
    var locationRevealed: Bool
    var photoSide: CGFloat

    private let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)

    var body: some View {
        PolaroidFrame(
            username: "@yourbff",
            date: fixedDate,
            placeName: locationRevealed ? "Kopi & Co · Bangsar" : "? ? ? ? ?",
            caption: "okay this looks unreal 🤤",
            photoSide: photoSide
        ) {
            MockImage(name: "story_dish")
        }
    }
}

// MARK: - Story · Ache (the problem)

private struct StoryAchePage: View {
    var body: some View {
        StoryFrame {
            ZStack {
                AppTheme.cafeGradient(0)
                VStack(spacing: 0) {
                    Spacer().frame(height: 64)
                    Text("WE'VE ALL BEEN HERE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(AppTheme.cafeAccent)
                    Spacer(minLength: 18)
                    StoryPolaroid(locationRevealed: false, photoSide: 218)
                    Spacer(minLength: 22)
                    Text("…but where is that?")
                        .font(.huntSerif(34))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                    Spacer().frame(height: 12)
                    Text("Your bff. Your cousin. That friend with great taste. They post the food — never the place.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 42)
                    Spacer().frame(height: 56)
                }
            }
        }
    }
}

// MARK: - Story · Turn (the solution)

private struct StoryTurnPage: View {
    var body: some View {
        StoryFrame {
            ZStack {
                AppTheme.cafeGradient(1)
                VStack(spacing: 0) {
                    Spacer().frame(height: 60)
                    StoryPolaroid(locationRevealed: true, photoSide: 210)
                    Spacer(minLength: 22)
                    Text("Let's change that.")
                        .font(.huntSerif(34))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                    Spacer().frame(height: 14)
                    Text("Wandery pins every food pic to the exact spot — and you share it with only your circle. The people you'd actually go eat with. No algorithm, no randoms.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 38)
                    Spacer(minLength: 20)
                    Text("SHARE YOUR SPOTS · SEE THEIRS · MAP IT")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.cafeAccent)
                    Spacer().frame(height: 52)
                }
            }
        }
    }
}

// MARK: - Story · Call (the CTA + QR)

private struct StoryCallPage: View {
    /// Generated once from the live TestFlight invite URL.
    private let qr = StoryQR.image(LegalURLs.testFlightInvite.absoluteString)
    private let cream = Color(hex: "#F7F5F2")

    var body: some View {
        StoryFrame {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: "#9A3E2A"), AppTheme.cafeAccent, Color(hex: "#C56A50")],
                    startPoint: .top, endPoint: .bottom
                )
                VStack(spacing: 0) {
                    Spacer().frame(height: 76)
                    Text("wandery")
                        .font(.wanderyWordmark(50))
                        .foregroundStyle(cream)
                    Spacer().frame(height: 10)
                    Text("Join the hunt. 🔥")
                        .font(.huntSerif(28))
                        .foregroundStyle(cream)
                    Spacer().frame(height: 8)
                    Text("FINAL BETA · 100 SEATS ONLY")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(cream.opacity(0.85))
                    Spacer(minLength: 26)
                    qrCard
                    Spacer(minLength: 22)
                    Text("Stay hunting. 🔥")
                        .font(.huntSerif(20))
                        .foregroundStyle(cream.opacity(0.9))
                    Spacer().frame(height: 84)
                }
            }
        }
    }

    private var qrCard: some View {
        VStack(spacing: 12) {
            Group {
                if let qr {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 162, height: 162)
                } else {
                    // Defensive: QR generation virtually never fails, but keep
                    // the card legible (and the link usable) if it ever does.
                    Text(LegalURLs.testFlightInvite.absoluteString)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 162, height: 162)
                }
            }
            Text("SCAN TO JOIN")
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppTheme.textPrimary)
            Text("testflight.apple.com/join/fhTBWC45")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }
}

// MARK: - QR generator

/// Minimal CoreImage QR builder for the invite story's CTA. Generated at most
/// once per page render (never a hot loop), so no caching is needed.
private enum StoryQR {
    static func image(_ string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard
            let output = filter.outputImage?
                .transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
