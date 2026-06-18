import SwiftUI

/// Live feed/composer adaptation of the shelved `StarPassTicketFrame` — a
/// celestial admit-one ticket: perforated tear line, gold serial + barcode, a
/// holographic sheen, twinkling stars, and the real post photo. Like the
/// receipt, place/caption print into the ticket stub (feed); in the composer
/// (`isComposer`) the interactive place/music/caption pills overlay the photo.
///
/// The shelf demo's rise/"develop" entrance is dropped (re-fires on scroll); the
/// sheen + star twinkles are continuous and GPU-cheap so they stay. Reuses
/// FrameKit's `TicketShape` / `SparkleShape` / `TwinkleSparkle` / `Line` /
/// `FramePalette` / `FrameFont`; self-contained sheen + barcode.
struct StarPassTicketFeedFrame<Content: View>: View {
    let username: String?
    let placeName: String?
    let caption: String?
    var photoSide: CGFloat
    var topLeading: () -> AnyView = { AnyView(EmptyView()) }
    var topTrailing: () -> AnyView = { AnyView(EmptyView()) }
    var bottomCenter: () -> AnyView = { AnyView(EmptyView()) }
    var isComposer: Bool = false
    @ViewBuilder var content: () -> Content

    private let pad: CGFloat = 16
    private let headerH: CGFloat = 24
    private let gapHeaderPhoto: CGFloat = 12
    private let perfH: CGFloat = 26

    private var W: CGFloat { photoSide + pad * 2 }
    private var notchY: CGFloat { pad + headerH + gapHeaderPhoto + photoSide + perfH / 2 }

    var body: some View {
        ZStack {
            TicketShape(notchY: notchY)
                .fill(
                    RadialGradient(
                        colors: [FramePalette.nightTop, FramePalette.nightMid, FramePalette.nightDeep],
                        center: .init(x: 0.5, y: -0.1),
                        startRadius: 8, endRadius: W * 1.2
                    ),
                    style: FillStyle(eoFill: true)
                )
                .overlay(
                    TicketShape(notchY: notchY)
                        .stroke(FramePalette.gold.opacity(0.35), lineWidth: 1)
                )

            content2
                .padding(pad)
                .frame(width: W)
        }
        .frame(width: W)
        .compositingGroup()
        .clipShape(TicketShape(notchY: notchY))
        .overlay(sheen.clipShape(TicketShape(notchY: notchY)).allowsHitTesting(false))
        .shadow(color: FramePalette.nightDeep.opacity(0.7), radius: 22, x: 0, y: 18)
    }

    // MARK: content

    private var content2: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    SparkleShape().fill(FramePalette.gold).frame(width: 13, height: 13)
                    label("Hero Pass")
                }
                Spacer()
                label("Admit One")
            }
            .frame(height: headerH)

            Spacer().frame(height: gapHeaderPhoto)

            photoView

            ZStack {
                Line()
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                    .foregroundStyle(FramePalette.gold.opacity(0.55))
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
            .frame(height: perfH)

            // stub
            VStack(alignment: .leading, spacing: 0) {
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(FrameFont.serif(26, italic: true))
                        .foregroundStyle(FramePalette.cardInk)
                        .lineLimit(2)
                }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(username ?? "@wandery")
                            .font(FrameFont.mono(12))
                            .foregroundStyle(FramePalette.gold)
                        Text((placeName ?? "—").uppercased())
                            .font(FrameFont.mono(10))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                    TicketBarcode()
                }
                .padding(.top, caption?.isEmpty == false ? 12 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var photoView: some View {
        content()
            .frame(width: photoSide, height: photoSide)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(FramePalette.gold.opacity(0.4), lineWidth: 1)
            )
            .overlay(
                LinearGradient(colors: [.purple.opacity(0.12), .clear, FramePalette.nightDeep.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
            )
            // Composer pills ride on the photo (feed prints place/caption in the stub).
            .overlay(alignment: .topLeading)  { if isComposer { topLeading().padding(8) } }
            .overlay(alignment: .topTrailing) { if isComposer { topTrailing().padding(8) } }
            .overlay(alignment: .bottom)      { if isComposer { bottomCenter().padding(.bottom, 8) } }
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased())
            .font(FrameFont.mono(11, weight: .bold))
            .tracking(2)
            .foregroundStyle(FramePalette.gold)
    }

    // MARK: sheen + twinkling stars

    private var sheen: some View {
        ZStack {
            ForEach(Array(starPassStars.enumerated()), id: \.offset) { _, s in
                TwinkleSparkle(size: s.size, delay: s.delay, period: 2.6 + s.delay)
                    .position(x: s.x / 440 * W, y: s.y / 440 * W)
            }
            StarPassSheen()
        }
    }
}

// File-scope (a generic type can't hold static stored properties).
private struct StarPassStar { let x, y, size: CGFloat; let delay: Double }
private let starPassStars: [StarPassStar] = [
    .init(x: 38, y: 60, size: 13, delay: 0),    .init(x: 392, y: 48, size: 10, delay: 0.8),
    .init(x: 360, y: 120, size: 8, delay: 1.4), .init(x: 60, y: 150, size: 7, delay: 2.1),
    .init(x: 410, y: 250, size: 9, delay: 0.5), .init(x: 24, y: 300, size: 8, delay: 1.7),
]

// MARK: - Self-contained sheen + barcode

private struct StarPassSheen: View {
    @State private var x: CGFloat = -1.3
    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, Color(hex: 0xBEAAFF).opacity(0.16),
                         Color(hex: 0xFFF0C8).opacity(0.22),
                         Color(hex: 0x96C8FF).opacity(0.16), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.55)
            .blur(radius: 6)
            .rotationEffect(.degrees(8))
            .offset(x: x * geo.size.width)
            .onAppear {
                withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: false).delay(1)) {
                    x = 1.6
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TicketBarcode: View {
    private let heights: [CGFloat] = [7,3,5,2,6,3,8,2,4,6,3,7,2,5]
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { i, h in
                RoundedRectangle(cornerRadius: 1)
                    .fill(FramePalette.gold.opacity(0.8))
                    .frame(width: i % 3 == 0 ? 3 : 2, height: 12 + h * 2)
            }
        }
        .frame(height: 30)
    }
}

#if DEBUG
#Preview("Star Pass — feed frame") {
    ZStack {
        Color(red: 0.05, green: 0.04, blue: 0.13).ignoresSafeArea()
        StarPassTicketFeedFrame(
            username: "@feez", placeName: "Mokky's · Bangsar",
            caption: "best teh tarik in town", photoSide: 300
        ) {
            LinearGradient(colors: [.orange, .pink, .purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
#endif
