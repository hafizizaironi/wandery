import SwiftUI

// MARK: - Marketing mockups (admin-only)
//
// Three full-bleed, swipeable pages recreating the headline features
// (Camera · Discover · My Hunt) with hardcoded data — no live services, no
// network — so the admin can screenshot them for App Store Connect. Imagery
// uses `MockImage`, which renders branded placeholders until real assets
// (mock_cafe1, mock_food2, …) are dropped into the catalog.

struct MarketingMockupsView: View {
    var onClose: () -> Void = {}

    @State private var page = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $page) {
                CameraMockPage().tag(0)
                DiscoverMockPage().tag(1)
                MyHuntMockPage().tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .ignoresSafeArea()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .accessibilityLabel("Close")
        }
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
                            placeName: "Sup Kambing Ayam",
                            caption: "2:44am, worth it",
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
