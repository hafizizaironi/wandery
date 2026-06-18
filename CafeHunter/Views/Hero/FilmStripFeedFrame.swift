import SwiftUI

/// Live feed/composer adaptation of the shelved `FilmStripFrame` — a single
/// 35mm celluloid cell (the real post photo) flanked by sprocket rails, a film
/// edge print, sepia wash, and a gentle top light-leak. Uses the same
/// `content`/`topLeading`/`topTrailing`/`bottomCenter` pill slots as
/// `PlainFeedFrame` (so place/caption/music pills float on the photo in both
/// feed + composer). The shelf demo's 3-frame "advance" entrance is dropped —
/// it would re-fire on every scroll.
///
/// Self-contained primitives (`FilmSprocketRail` / `FilmStripLightLeak`) so the
/// shelf's private versions can't break it. Reuses FrameKit's `FramePalette` /
/// `Color(hex:)` / `FrameFont`.
struct FilmStripFeedFrame<Content: View, TopLeading: View, BottomCenter: View>: View {
    let username: String?
    let placeName: String?
    var photoSide: CGFloat
    var topTrailing: () -> AnyView = { AnyView(EmptyView()) }
    @ViewBuilder var content: () -> Content
    @ViewBuilder var topLeading: () -> TopLeading
    @ViewBuilder var bottomCenter: () -> BottomCenter

    private let rail: CGFloat = 22
    private let innerPad: CGFloat = 6
    private let pill: CGFloat = 8

    var body: some View {
        ZStack {
            Rectangle().fill(FramePalette.celluloid)

            HStack(spacing: 0) {
                FilmSprocketRail().frame(width: rail)
                VStack(spacing: 6) {
                    photoCell
                    edgePrint.padding(.horizontal, 2)
                }
                .padding(.horizontal, innerPad)
                .padding(.vertical, 6)
                FilmSprocketRail().frame(width: rail)
            }
            .padding(.vertical, 12)

            FilmStripLightLeak()
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
        .frame(width: photoSide + (rail + innerPad) * 2)
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 14)
    }

    // MARK: the single film cell (real photo + floating pills)

    private var photoCell: some View {
        ZStack(alignment: .topLeading) {
            content()
                .frame(width: photoSide, height: photoSide)
                .saturation(0.9)
                .overlay(sepiaWash)
                .clipped()
                .overlay(Rectangle().stroke(Color.white.opacity(0.06), lineWidth: 1))

            // Location pill — top-leading.
            topLeading().padding(pill)

            // Caption pill — bottom-center.
            VStack {
                Spacer(minLength: 0)
                HStack { Spacer(minLength: 0); bottomCenter(); Spacer(minLength: 0) }
                    .padding(.bottom, pill)
            }
            .frame(width: photoSide, height: photoSide)

            // Music control — top-trailing.
            VStack {
                HStack { Spacer(minLength: 0); topTrailing() }
                Spacer(minLength: 0)
            }
            .padding(pill)
            .frame(width: photoSide, height: photoSide)
        }
        .frame(width: photoSide, height: photoSide)
    }

    private var sepiaWash: some View {
        LinearGradient(colors: [Color(hex: 0x7A5A2A).opacity(0.18), .clear],
                       startPoint: .top, endPoint: .bottom)
            .blendMode(.multiply)
    }

    private var edgePrint: some View {
        HStack {
            Text("KODAK GOLD 200")
            Spacer(minLength: 6)
            Text("\((username ?? "@wandery").uppercased()) · \(placeName?.split(separator: " ").first.map(String.init)?.uppercased() ?? "")")
                .lineLimit(1)
        }
        .font(FrameFont.mono(10, weight: .bold))
        .tracking(1.5)
        .foregroundStyle(FramePalette.edgePrint.opacity(0.85))
    }
}

// MARK: - Self-contained primitives

private struct FilmSprocketRail: View {
    var body: some View {
        GeometryReader { geo in
            let count = 13
            VStack(spacing: max(4, (geo.size.height - 20 - CGFloat(count) * 18) / CGFloat(count - 1))) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FramePalette.sprocket)
                        .frame(width: 13, height: 18)
                        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }
}

/// Warm top light-leak. Continuous, GPU-cheap (no layout, just an animating
/// opacity) so it's safe to leave running in a scrolling feed.
private struct FilmStripLightLeak: View {
    @State private var bright = false
    var body: some View {
        LinearGradient(
            colors: [Color(hex: 0xFF8C3C).opacity(0.55),
                     Color(hex: 0xFF5A28).opacity(0.18), .clear],
            startPoint: .top, endPoint: .bottom
        )
        .blendMode(.screen)
        .opacity(bright ? 0.7 : 0.35)
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { bright = true }
        }
    }
}

#if DEBUG
#Preview("Film Strip — feed frame") {
    ZStack {
        Color(red: 0.09, green: 0.08, blue: 0.06).ignoresSafeArea()
        FilmStripFeedFrame(username: "@feez", placeName: "Mokky's · Bangsar", photoSide: 300) {
            LinearGradient(colors: [.orange, .pink, .purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } topLeading: {
            EmptyView()
        } bottomCenter: {
            EmptyView()
        }
    }
}
#endif
