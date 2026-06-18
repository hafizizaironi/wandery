import SwiftUI

/// Live feed/composer adaptation of the shelved `HoloCardFrame` — a holographic
/// trading card: iridescent foil border, rarity pips, the real post photo as the
/// card art with a sheen sweep + rainbow film, and a serial footer. Uses the
/// same pill slots as `PlainFeedFrame` (place/caption/music float on the art).
///
/// The shelf demo's rise/"develop" entrance is dropped (it would re-fire on
/// scroll); the iridescent hue rotation + sheen sweep are continuous and
/// GPU-cheap so they stay. Self-contained sheen; reuses FrameKit's
/// `SparkleShape` / `FrameFont` / `Color(hex:)`.
struct HoloCardFeedFrame<Content: View, TopLeading: View, BottomCenter: View>: View {
    let username: String?
    let placeName: String?
    var photoSide: CGFloat
    var topTrailing: () -> AnyView = { AnyView(EmptyView()) }
    @ViewBuilder var content: () -> Content
    @ViewBuilder var topLeading: () -> TopLeading
    @ViewBuilder var bottomCenter: () -> BottomCenter

    private let pad: CGFloat = 13
    private let foil: CGFloat = 7
    @State private var hue = false

    private let foilColors = [
        Color(hex: 0xFF9ECD), Color(hex: 0xFFD76A), Color(hex: 0x9AF0C6),
        Color(hex: 0x8FC7FF), Color(hex: 0xC79BFF), Color(hex: 0xFF9ECD),
    ]

    private var shortPlace: String {
        placeName?.split(separator: " ").first.map { String($0).uppercased() } ?? ""
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AngularGradient(colors: foilColors, center: .center))
                .hueRotation(.degrees(hue ? 360 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                )
            cardBody.padding(foil)
        }
        .frame(width: photoSide + pad * 2 + foil * 2)
        .fixedSize()
        .shadow(color: Color(hex: 0x462878).opacity(0.55), radius: 22, x: 0, y: 18)
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { hue = true }
        }
    }

    private var cardBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(username ?? "@wandery")
                    .font(FrameFont.serif(25, italic: true))
                    .foregroundStyle(Color(hex: 0x3A2960))
                    .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    SparkleShape().fill(Color(hex: 0xC79BFF)).frame(width: 11, height: 11)
                    Text("HOLO RARE")
                        .font(FrameFont.mono(10, weight: .bold)).tracking(1)
                        .foregroundStyle(Color(hex: 0x8A5CC7))
                }
            }
            .padding(.bottom, 9)

            art

            HStack {
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        SparkleShape()
                            .fill(i < 3 ? Color(hex: 0xF0B53E) : Color(hex: 0xD9C9F0))
                            .frame(width: 12, height: 12)
                    }
                }
                Spacer()
                Text(shortPlace)
                    .font(FrameFont.mono(11)).tracking(1)
                    .foregroundStyle(Color(hex: 0x6A4BA0))
                    .lineLimit(1)
            }
            .padding(.top, 11)

            HStack {
                Text("No. 024 / 250")
                Spacer()
                Text("WANDERY · KL EDITION")
            }
            .font(FrameFont.mono(9)).tracking(1)
            .foregroundStyle(Color(hex: 0x5A3C96).opacity(0.6))
            .padding(.top, 7)
            .overlay(Rectangle().fill(Color(hex: 0x7850B4).opacity(0.18)).frame(height: 1),
                     alignment: .top)
            .padding(.top, 7)
        }
        .padding(pad)
        .background(
            LinearGradient(colors: [Color(hex: 0xFBF6FF), Color(hex: 0xF2EAFF)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var art: some View {
        ZStack(alignment: .topLeading) {
            content()
                .frame(width: photoSide, height: photoSide)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HoloFeedSheen().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            LinearGradient(colors: foilColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .hueRotation(.degrees(hue ? 360 : 0))
                .blendMode(.colorDodge)
                .opacity(0.22)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .allowsHitTesting(false)

            // Pills float on the art (place top-left, music top-right, caption bottom).
            topLeading().padding(8)
            VStack {
                Spacer(minLength: 0)
                HStack { Spacer(minLength: 0); bottomCenter(); Spacer(minLength: 0) }
                    .padding(.bottom, 8)
            }
            .frame(width: photoSide, height: photoSide)
            VStack {
                HStack { Spacer(minLength: 0); topTrailing() }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: photoSide, height: photoSide)
        }
        .frame(width: photoSide, height: photoSide)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.7), lineWidth: 2)
        )
        .shadow(color: Color(hex: 0x503282).opacity(0.3), radius: 6, y: 4)
    }
}

/// Holo sheen sweep — continuous, GPU-cheap (an offset + blur of a gradient).
private struct HoloFeedSheen: View {
    @State private var x: CGFloat = -1.2
    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, .white.opacity(0.5), Color(hex: 0xB4DCFF).opacity(0.35), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.6)
            .blur(radius: 3)
            .offset(x: x * geo.size.width)
            .onAppear {
                withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: false).delay(1)) {
                    x = 1.7
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("Holo — feed frame") {
    ZStack {
        Color(red: 0.10, green: 0.08, blue: 0.19).ignoresSafeArea()
        HoloCardFeedFrame(username: "@feez", placeName: "Mokky's · Bangsar", photoSide: 300) {
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
