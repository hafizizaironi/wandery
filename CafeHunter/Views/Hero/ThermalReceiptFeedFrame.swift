import SwiftUI
import UIKit

/// A printed café receipt that wraps a real feed post: a monospace header,
/// dashed rules, the post's photo under a faint thermal-paper grain, LOCATION /
/// TIME / GUEST text rows, the caption, a drawn barcode, and a torn (zig-zag)
/// bottom edge.
///
/// Fully self-contained — renders the REAL media via `content()` and prints the
/// post's raw fields as receipt rows, with uniquely-named private primitives. No
/// entrance animation (a "prints out" scaleY would re-fire as the feed scrolls).
///
/// Selected by `FeedCardStyle.thermalReceipt`; gated to admins + allow-listed
/// testers (see `AuthService.canUseThermalFrame` and `ProfileHomeView`).
struct ThermalReceiptFeedFrame<Content: View>: View {
    let username: String?
    let date: Date?
    let placeName: String?
    let caption: String?
    /// The feed's square media slot side; the slip is sized relative to it so it
    /// tracks the device's viewfinder square.
    let photoSide: CGFloat
    /// Composer-only interactive pills overlaid on the photo (place top-left,
    /// music top-right, caption bottom-center), gated by `isComposer`. The feed
    /// prints place/caption/song as receipt rows instead, so these stay hidden there.
    var topLeading: () -> AnyView = { AnyView(EmptyView()) }
    var topTrailing: () -> AnyView = { AnyView(EmptyView()) }
    var bottomCenter: () -> AnyView = { AnyView(EmptyView()) }
    /// True in the post composer — show the interactive pills on the photo.
    var isComposer: Bool = false
    /// Feed post's attached song. When set, the slip prints a `♪ track — artist`
    /// row and the barcode reacts to `musicPlaying`; tapping the barcode calls
    /// `onMusicTap` (mute toggle).
    var music: PostMusic? = nil
    var musicPlaying: Bool = false
    var onMusicTap: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    // MARK: - Tunables
    // The slip is narrower than the square slot (receipts are narrow) and taller,
    // so it bleeds past the `photoSide` box. The page reserves ~90pt of slack on
    // each side, so keep the total height roughly within `photoSide + 180`. If the
    // bottom edge ever crowds the composer in-feed, lower `widthFactor`.
    private var widthFactor: CGFloat { 0.78 }
    private var slipWidth: CGFloat { photoSide * widthFactor }
    private var hInset: CGFloat { 15 }
    private var photoInner: CGFloat { slipWidth - hInset * 2 }

    private let paper = Color(red: 0.99, green: 0.99, blue: 0.975)
    private let ink   = Color(red: 0.07, green: 0.07, blue: 0.07)

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            photo
            rule
            infoBlock
            if let caption, !caption.isEmpty {
                rule
                Text("“\(caption)”")
                    .font(.system(size: 16, design: .serif)).italic()
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.vertical, 3)
            }
            rule
            barcode
        }
        .padding(.horizontal, hInset)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .frame(width: slipWidth)
        .background(paper)
        .clipShape(ReceiptTornEdge(teeth: 18, toothDepth: 7))
        .shadow(color: .black.opacity(0.32), radius: 16, x: 0, y: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 3) {
            Text("WANDERY")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .tracking(5)
                .foregroundStyle(ink)
            Text("GUEST RECEIPT")
                .font(.system(size: 9, design: .monospaced))
                .tracking(2)
                .foregroundStyle(ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }

    private var photo: some View {
        ZStack {
            content()
                .frame(width: photoInner, height: photoInner)
                .clipped()
            // The grain is a fixed pattern, identical on every card, so draw the
            // shared pre-rendered bitmap instead of ~7k `Canvas` path-fills per
            // card per frame. It's baked over white, and multiply-over-white is an
            // identity (white = 1), so `photo × bakedGrain == photo × grain` — the
            // look is unchanged.
            if let grain = ReceiptGrain.image {
                grain
                    .resizable()
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            } else {
                ReceiptThermalGrain()   // renderer-failed fallback (rare)
            }
        }
        .frame(width: photoInner, height: photoInner)
        .clipped()
        // In the composer the interactive place + music + caption pills ride on
        // the photo, same as the other frames (the feed prints them as receipt
        // rows instead).
        .overlay(alignment: .topLeading) {
            if isComposer { topLeading().padding(8) }
        }
        .overlay(alignment: .topTrailing) {
            if isComposer { topTrailing().padding(8) }
        }
        .overlay(alignment: .bottom) {
            if isComposer { bottomCenter().padding(.bottom, 10) }
        }
    }

    private var infoBlock: some View {
        VStack(spacing: 0) {
            infoRow("LOCATION", (placeName ?? "—").uppercased())
            infoRow("TIME", timeString)
            infoRow("GUEST", (username ?? "@wandery").uppercased())
            if let music { musicRow(music) }
        }
    }

    /// Receipt-native song row: a ♪/muted glyph + "Track — Artist".
    private func musicRow(_ m: PostMusic) -> some View {
        HStack(spacing: 8) {
            Image(systemName: musicPlaying ? "music.note" : "speaker.slash.fill")
                .font(.system(size: 10))
                .foregroundStyle(ink.opacity(0.5))
            Text("\(m.trackName) — \(m.artistName)")
                .fontWeight(.bold).foregroundStyle(ink).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .tracking(0.5)
        .padding(.vertical, 3)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key).foregroundStyle(ink.opacity(0.5))
            Spacer(minLength: 8)
            Text(value).fontWeight(.bold).foregroundStyle(ink).lineLimit(1)
        }
        .font(.system(size: 11, design: .monospaced))
        .tracking(0.5)
        .padding(.vertical, 3)
    }

    private var barcode: some View {
        VStack(spacing: 6) {
            ReceiptBarcode(ink: ink, playing: musicPlaying).frame(height: 38)
            Text("* \(serial) *")
                .font(.system(size: 10, design: .monospaced)).tracking(3)
                .foregroundStyle(ink)
                .lineLimit(1)
            Text("THANK YOU FOR WANDERING")
                .font(.system(size: 8.5, design: .monospaced)).tracking(1.5)
                .foregroundStyle(ink.opacity(0.55))
        }
        .padding(.top, 2)
        // In the feed the barcode doubles as the song's mute toggle.
        .contentShape(Rectangle())
        .onTapGesture { onMusicTap?() }
    }

    private var rule: some View {
        ReceiptDashRule()
            .stroke(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.4, dash: [4, 4]))
            .frame(height: 1.4)
            .padding(.vertical, 7)
    }

    // MARK: - Derived strings

    private var timeString: String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var serial: String {
        let base = (username ?? "wandery")
            .replacingOccurrences(of: "@", with: "")
            .uppercased()
        return base
    }

    private var accessibilitySummary: String {
        var parts = ["Receipt-style post"]
        if let placeName { parts.append("at \(placeName)") }
        if let username { parts.append("by \(username)") }
        if let caption, !caption.isEmpty { parts.append("“\(caption)”") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Self-contained receipt primitives
// Uniquely named so they never collide with the shelved `TornReceiptShape` /
// `Barcode2` / `ThermalGrain` in `FreshFrames/ThermalReceiptFrame.swift`.

/// Torn (zig-zag) bottom edge for the slip; straight on the other three sides.
private struct ReceiptTornEdge: Shape {
    var teeth: Int = 18
    var toothDepth: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - toothDepth))
        let step = rect.width / CGFloat(max(teeth, 1))
        var up = true
        var x = rect.maxX
        while x > rect.minX + 0.5 {
            x -= step
            let y = up ? rect.maxY : rect.maxY - toothDepth
            p.addLine(to: CGPoint(x: max(x, rect.minX), y: y))
            up.toggle()
        }
        p.closeSubpath()
        return p
    }
}

/// A single horizontal line, centered; dashed via the caller's stroke style.
private struct ReceiptDashRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Faint thermal-paper print grain + scan banding, multiplied over the photo.
private struct ReceiptThermalGrain: View {
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let dot: CGFloat = 3
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.9, height: 0.9)),
                                 with: .color(.black.opacity(0.18)))
                        x += dot
                    }
                    y += dot
                }
            }
            .blendMode(.multiply)
            .opacity(0.30)

            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(.black.opacity(0.045)))
                    y += 3
                }
            }
            .blendMode(.multiply)
        }
        .allowsHitTesting(false)
    }
}

/// Shared, render-once bitmap of `ReceiptThermalGrain`. The grain is a fixed,
/// deterministic pattern — identical on every receipt card — so we rasterize it
/// a single time and every card reuses the texture, replacing ~7k per-card
/// `Canvas` path-fills. Baked over white so a plain `.blendMode(.multiply)`
/// reproduces the original look exactly. `@MainActor` because `ImageRenderer` is;
/// the `static let` is built lazily on first access from a (main-thread) body.
@MainActor private enum ReceiptGrain {
    static let image: Image? = {
        let side: CGFloat = 240
        let renderer = ImageRenderer(
            content: ZStack { Color.white; ReceiptThermalGrain() }
                .frame(width: side, height: side)
        )
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }()
}

/// Drawn barcode that doubles as a song visualizer: a flat bar pattern at rest,
/// and a stylized equalizer that bounces while `playing`. The per-bar `weights`
/// act as amplitudes; a sine with a per-bar phase offset gives the bounce.
///
/// Start/stop is eased via an amplitude **envelope** (0 = flat, 1 = full bounce)
/// that smoothsteps over `ramp` seconds, so the bars grow into / settle out of
/// the beat instead of snapping. The timeline keeps ticking through the ease-out,
/// then pauses once flat to save power.
private struct ReceiptBarcode: View {
    let ink: Color
    var playing: Bool = false
    private let weights: [CGFloat] = [6, 2, 5, 2, 7, 3, 2, 6, 4, 2, 7, 2, 5, 3, 6, 2, 4, 7, 2, 5, 3, 2, 6]
    private let base: CGFloat = 22
    private let ramp: Double = 0.5

    @State private var envFrom: CGFloat = 0       // envelope value at the ramp's start
    @State private var envTo: CGFloat = 0         // envelope value being ramped toward
    @State private var rampStart: Date = .distantPast
    @State private var paused: Bool = true

    var body: some View {
        Group {
            if paused {
                // At rest every bar is `base` tall (env = 0) — render it statically
                // so idle (non-playing) cards don't each carry a `TimelineView`.
                bars(env: 0, t: 0)
            } else {
                // Animating (playing or easing out) — drive the bounce per frame.
                TimelineView(.animation) { ctx in
                    bars(env: envelope(at: ctx.date),
                         t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .onAppear { setEnvelope(to: playing ? 1 : 0, animated: false) }
        .onChange(of: playing) { _, now in setEnvelope(to: now ? 1 : 0, animated: true) }
    }

    private func bars(env: CGFloat, t: TimeInterval) -> some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(weights.enumerated()), id: \.offset) { i, w in
                Rectangle()
                    .fill(ink)
                    .frame(width: i % 4 == 0 ? 3 : 1.5,
                           height: base + w * 1.6 * oscillation(i, t) * env)
            }
        }
    }

    private func oscillation(_ i: Int, _ t: TimeInterval) -> CGFloat {
        0.5 + 0.5 * sin(t * 6 + Double(i) * 0.7)
    }

    /// Smoothstepped interpolation from `envFrom` → `envTo` over `ramp` seconds.
    private func envelope(at now: Date) -> CGFloat {
        let p = min(max(now.timeIntervalSince(rampStart) / ramp, 0), 1)
        let eased = p * p * (3 - 2 * p)
        return envFrom + (envTo - envFrom) * CGFloat(eased)
    }

    /// Retarget the envelope, ramping from wherever it currently is (so rapid
    /// play/pause toggles stay continuous). Pauses the timeline once it's flat.
    private func setEnvelope(to target: CGFloat, animated: Bool) {
        let now = Date()
        envFrom = animated ? envelope(at: now) : target
        envTo = target
        rampStart = now
        if target > 0 {
            paused = false                                   // run while bouncing
        } else if animated {
            Task {                                           // tick through the ease-out…
                try? await Task.sleep(for: .seconds(ramp))
                if envTo == 0 { paused = true }              // …then rest
            }
        } else {
            paused = true
        }
    }
}

#if DEBUG
#Preview("Thermal Receipt — feed frame") {
    ZStack {
        Color(red: 0.90, green: 0.88, blue: 0.83).ignoresSafeArea()
        ThermalReceiptFeedFrame(
            username: "@feez",
            date: Date(),
            placeName: "Mokky's · Bangsar",
            caption: "best teh tarik in town",
            photoSide: 360
        ) {
            LinearGradient(colors: [.orange, .pink, .purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
#endif
