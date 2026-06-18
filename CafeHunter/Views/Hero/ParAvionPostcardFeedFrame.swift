import SwiftUI

/// Live feed/composer adaptation of the shelved `ParAvionPostcardFrame` — an
/// airmail love postcard: the real post photo + washi tape on the left, a
/// handwritten note, heart stamp + circular postmark, and ruled address lines
/// on the right. Being a LANDSCAPE card it renders at its natural 3:2 aspect
/// scaled to the slot width (so the photo is smaller than the square frames),
/// centred in the feed's square slot. Caption prints as the note; in the
/// composer (`isComposer`) the interactive pills overlay the photo.
///
/// Dropped vs the shelf demo: the drop-in entrance, the photo "develop", and the
/// re-firing floating heart (all `onAppear`-driven → jank on scroll). The
/// airmail border Canvas is light (~a few dozen stripe fills) so it stays.
struct ParAvionPostcardFeedFrame<Content: View>: View {
    let username: String?
    let placeName: String?
    let caption: String?
    let date: Date?
    var photoSide: CGFloat
    var topLeading: () -> AnyView = { AnyView(EmptyView()) }
    var topTrailing: () -> AnyView = { AnyView(EmptyView()) }
    var bottomCenter: () -> AnyView = { AnyView(EmptyView()) }
    var isComposer: Bool = false
    @ViewBuilder var content: () -> Content

    private let border: CGFloat = 7
    /// Card width budget = the slot's photo side; height keeps the 3:2 postcard aspect.
    private var cardW: CGFloat { photoSide }
    private var cardH: CGFloat { photoSide * (320.0 / 480.0) }
    private var photoCell: CGFloat { (cardW - border * 2) * 0.46 }

    var body: some View {
        ZStack {
            // peeking card behind (static — no entrance)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(hex: 0xF0E2CF))
                .frame(width: cardW, height: cardH)
                .rotationEffect(.degrees(4.5))
                .offset(x: 12, y: 10)
                .shadow(color: Color(hex: 0x502820).opacity(0.35), radius: 12, x: 0, y: 8)

            card.rotationEffect(.degrees(-1.5))
        }
        .frame(width: cardW + 30, height: cardH + 34)
    }

    private var card: some View {
        ZStack {
            PostcardAirmailBorder(cornerRadius: 5)
                .frame(width: cardW, height: cardH)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(FramePalette.paper)
                .frame(width: cardW - border * 2, height: cardH - border * 2)
                .overlay(inner.frame(width: cardW - border * 2, height: cardH - border * 2))
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .frame(width: cardW, height: cardH)
        .shadow(color: Color(hex: 0x502820).opacity(0.55), radius: 20, x: 0, y: 16)
    }

    private var inner: some View {
        HStack(spacing: 0) {
            // left: photo + washi tape (+ composer pills)
            ZStack {
                content()
                    .frame(width: photoCell, height: photoCell)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(
                        LinearGradient(colors: [Color(hex: 0xD86C74).opacity(0.06), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    )
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 4)
                    .overlay(alignment: .topLeading)  { if isComposer { topLeading().padding(6) } }
                    .overlay(alignment: .topTrailing) { if isComposer { topTrailing().padding(6) } }
                    .overlay(alignment: .bottom)      { if isComposer { bottomCenter().padding(.bottom, 6) } }

                PostcardWashiTape()
                    .frame(width: photoCell * 0.42, height: 18)
                    .rotationEffect(.degrees(-9))
                    .offset(x: -photoCell / 2 + 18, y: -photoCell / 2 + 4)
            }
            .frame(width: (cardW - border * 2) * 0.48)

            Rectangle()
                .fill(Color(hex: 0x785038).opacity(0.28))
                .frame(width: 1)
                .padding(.vertical, 14)

            rightPanel
                .frame(maxWidth: .infinity)
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
        }
    }

    private var rightPanel: some View {
        ZStack(alignment: .topTrailing) {
            stamp
            VStack(alignment: .leading, spacing: 3) {
                Text(noteText)
                    .font(FrameFont.script(22))
                    .foregroundStyle(FramePalette.noteRed)
                    .lineLimit(3)
                HeartShape().fill(FramePalette.noteRed).frame(width: 13, height: 11)
            }
            .frame(maxWidth: 150, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 4)

            ruledLines
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private var noteText: String {
        (caption?.isEmpty == false) ? caption! : "wish you\nwere here"
    }

    private var stamp: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .foregroundStyle(Color(hex: 0x785038).opacity(0.5))
                .background(
                    RadialGradient(colors: [Color(hex: 0xFFE3E0), Color(hex: 0xF6C9C4)],
                                   center: .init(x: 0.5, y: 0.38), startRadius: 2, endRadius: 32)
                )
                .frame(width: 50, height: 60)
                .overlay(HeartShape().fill(FramePalette.airRed).frame(width: 24, height: 22))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            PostcardPostmark(location: placeName?.split(separator: " ").first.map(String.init) ?? "MAMAK",
                             time: timeString)
                .frame(width: 60, height: 60)
                .rotationEffect(.degrees(-12))
                .offset(x: -26, y: 22)
                .opacity(0.72)
        }
        .frame(width: 64, height: 78)
        .padding(.trailing, 2)
    }

    private var ruledLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(username ?? "@wandery")
                .font(FrameFont.script(18))
                .foregroundStyle(FramePalette.inkBrown)
                .lineLimit(1)
            Rectangle().fill(Color(hex: 0x785038).opacity(0.28)).frame(height: 1).padding(.top, 5)
            Text("WANDERY · HERO FEED")
                .font(FrameFont.mono(8)).tracking(1.5)
                .foregroundStyle(Color(hex: 0x785038).opacity(0.6))
                .padding(.top, 6)
            Rectangle().fill(Color(hex: 0x785038).opacity(0.28)).frame(height: 1).padding(.top, 5)
        }
    }

    private var timeString: String {
        guard let date else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Self-contained primitives

private struct PostcardAirmailBorder: View {
    var cornerRadius: CGFloat
    var body: some View {
        Canvas { ctx, size in
            let stripe: CGFloat = 11
            let colors = [FramePalette.airRed, FramePalette.paper, FramePalette.airBlue, FramePalette.paper]
            var i = 0
            var offset: CGFloat = -size.height
            while offset < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                path.addLine(to: CGPoint(x: offset + size.height + stripe, y: size.height))
                path.addLine(to: CGPoint(x: offset + stripe, y: 0))
                path.closeSubpath()
                ctx.fill(path, with: .color(colors[i % colors.count]))
                offset += stripe
                i += 1
            }
        }
        .background(FramePalette.paper)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct PostcardWashiTape: View {
    var body: some View {
        Rectangle()
            .fill(Color(hex: 0xD86C74).opacity(0.5))
            .overlay(
                GeometryReader { geo in
                    Path { p in
                        var x: CGFloat = 0
                        while x < geo.size.width {
                            p.addRect(CGRect(x: x, y: 0, width: 6, height: geo.size.height))
                            x += 12
                        }
                    }
                    .fill(Color.white.opacity(0.45))
                }
            )
            .shadow(color: .black.opacity(0.12), radius: 2, y: 2)
    }
}

private struct PostcardPostmark: View {
    let location: String
    let time: String
    var body: some View {
        ZStack {
            Circle().stroke(style: StrokeStyle(lineWidth: 1.4, dash: [2, 3]))
                .foregroundStyle(FramePalette.airBlue)
                .padding(6)
            Circle().stroke(FramePalette.airBlue, lineWidth: 1.2)
                .padding(12)
            VStack(spacing: 2) {
                Text(location.uppercased())
                    .font(FrameFont.mono(7, weight: .bold)).tracking(1)
                Text(time)
                    .font(FrameFont.mono(8, weight: .bold))
            }
            .foregroundStyle(FramePalette.airBlue)
        }
    }
}

#if DEBUG
#Preview("Par Avion — feed frame") {
    ZStack {
        Color(red: 0.96, green: 0.89, blue: 0.87).ignoresSafeArea()
        ParAvionPostcardFeedFrame(
            username: "@feez", placeName: "Mokky's · Bangsar",
            caption: "wish you\nwere here", date: Date(), photoSide: 320
        ) {
            LinearGradient(colors: [.orange, .pink, .purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
#endif
