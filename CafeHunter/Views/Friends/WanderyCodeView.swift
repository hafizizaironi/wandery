import SwiftUI

/// Renders a Wandery Code in the "Data rings" style (design skin 01): the real
/// 156-module bitmap, with consecutive on-modules merged into varying-length
/// arcs with rounded caps, sitting on faint guide grooves. This is purely a
/// cosmetic restyle of the *same* on/off data — every module center stays
/// dark/light exactly as the codec specifies, so it's still scannable.
///
/// Composed as layers so the data rings can rotate (and retract) independently:
///   • base — quiet zone + guide grooves + timing ring   (static)
///   • 4 data-ring layers — rotated via `ringAngles`      (animatable)
///   • top — finder pins + locket                          (static, registration)
///
/// `ringAngles` all-zero (the default) is the static, scan-stable render a
/// camera reads (and what `ImageRenderer` exports).
struct WanderyCodeCanvas: View {
    let encoded: WanderyCodec.Encoded
    /// Decorative rotation per data ring (degrees), inner→outer.
    var ringAngles: [Double] = [0, 0, 0, 0]
    /// Single-letter avatar for the locket; nil draws the teardrop glyph.
    var centerInitial: String? = nil

    private typealias G = WanderyCodeGeometry

    private static let ink     = Color(hex: "#1f1a17")
    private static let paper   = Color(hex: "#f0e9d8")
    private static let paperHi = Color(hex: "#f6efe4")
    private static let persim  = Color(hex: "#d96a3f")
    private static let olive   = Color(hex: "#5e7042")

    var body: some View {
        ZStack {
            baseLayer
            ForEach(0..<G.dataCounts.count, id: \.self) { i in
                ringLayer(i)
                    .rotationEffect(.degrees(i < ringAngles.count ? ringAngles[i] : 0))
            }
            topLayer
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Self.paper)
    }

    // MARK: - Layers

    private var baseLayer: some View {
        Canvas { ctx, sz in
            scaled(&ctx, sz)
            // Quiet zone (paper disc) so adaptive thresholding doesn't bleed.
            let q = G.quietR
            ctx.fill(Path(ellipseIn: CGRect(x: G.centerX - q, y: G.centerY - q, width: 2 * q, height: 2 * q)),
                     with: .color(Self.paper))
            // Faint guide grooves — the "ring track" under each data ring.
            for r in G.dataRadii {
                ctx.stroke(circlePath(r), with: .color(Self.ink.opacity(0.06)), style: StrokeStyle(lineWidth: 1))
            }
            // Timing ring (olive, coarse, non-data).
            drawRing(&ctx, modules: encoded.timing, r: G.timingR, w: G.timingW, color: Self.olive)
        }
    }

    private func ringLayer(_ i: Int) -> some View {
        Canvas { ctx, sz in
            scaled(&ctx, sz)
            guard i < encoded.rings.count else { return }
            drawRing(&ctx, modules: encoded.rings[i], r: G.dataRadii[i], w: Self.ringWidth(i), color: Self.ink)
        }
    }

    private var topLayer: some View {
        Canvas { ctx, sz in
            scaled(&ctx, sz)
            for (i, deg) in G.finderDegs.enumerated() { drawPin(&ctx, deg: deg, isNorth: i == 0) }
            drawLocket(&ctx)
        }
    }

    private static func ringWidth(_ i: Int) -> Double { [7, 6.5, 6, 5.5][min(i, 3)] }

    // MARK: - Drawing helpers

    private func scaled(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        ctx.scaleBy(x: min(sz.width, sz.height) / G.box, y: min(sz.width, sz.height) / G.box)
    }

    private func circlePath(_ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: G.centerX - r, y: G.centerY - r, width: 2 * r, height: 2 * r))
    }

    private func arcPath(r: Double, a0: Double, a1: Double) -> Path {
        var p = Path()
        let span = a1 - a0
        let segs = max(2, Int(span / 1.0))
        for k in 0...segs {
            let pt = G.pol(r, a0 + span * Double(k) / Double(segs))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    /// Draws a ring of modules, merging consecutive "on" modules into a single
    /// arc (varying-length dashes) with rounded caps. Off modules draw nothing.
    private func drawRing(_ ctx: inout GraphicsContext, modules: [Bool], r: Double, w: Double, color: Color) {
        let n = modules.count
        guard n > 0 else { return }
        let step = 360.0 / Double(n)
        let gap = step * G.gapFraction
        let stroke = StrokeStyle(lineWidth: w, lineCap: .round)
        var i = 0
        while i < n {
            guard modules[i] else { i += 1; continue }
            var j = i
            while j < n, modules[j] { j += 1 }           // run of on-modules [i, j)
            let a0 = Double(i) * step + gap
            let a1 = Double(j) * step - gap
            ctx.stroke(arcPath(r: r, a0: a0, a1: a1), with: .color(color), style: stroke)
            i = j
        }
    }

    private func drawPin(_ ctx: inout GraphicsContext, deg: Double, isNorth: Bool) {
        let c = G.pol(G.finderR, deg)
        let oR = G.pinOuterR
        let outer = Path(ellipseIn: CGRect(x: c.x - oR, y: c.y - oR, width: 2 * oR, height: 2 * oR))
        ctx.fill(outer, with: .color(Self.paperHi))
        ctx.stroke(outer, with: .color(Self.persim), style: StrokeStyle(lineWidth: 2.6))
        let dR = G.pinDotR
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - dR, y: c.y - dR, width: 2 * dR, height: 2 * dR)),
                 with: .color(Self.persim))
        if isNorth {
            let cR = G.collarR
            let collar = Path(ellipseIn: CGRect(x: c.x - cR, y: c.y - cR, width: 2 * cR, height: 2 * cR))
            ctx.stroke(collar, with: .color(Self.persim), style: StrokeStyle(lineWidth: 1.6, dash: [2, 2.5]))
        }
    }

    private func drawLocket(_ ctx: inout GraphicsContext) {
        let cx = G.centerX, cy = G.centerY
        let f = G.locketR + 4
        let frameRect = CGRect(x: cx - f, y: cy - f, width: 2 * f, height: 2 * f)
        ctx.stroke(Path(ellipseIn: frameRect),
                   with: .linearGradient(Gradient(colors: [Self.persim, Self.olive]),
                                         startPoint: CGPoint(x: frameRect.minX, y: frameRect.minY),
                                         endPoint: CGPoint(x: frameRect.maxX, y: frameRect.maxY)),
                   style: StrokeStyle(lineWidth: 4))
        let innerRect = CGRect(x: cx - G.locketR, y: cy - G.locketR, width: 2 * G.locketR, height: 2 * G.locketR)

        if let initial = centerInitial, !initial.isEmpty {
            ctx.fill(Path(ellipseIn: innerRect),
                     with: .linearGradient(Gradient(colors: [Color(hex: "#6f8350"), Color(hex: "#45542f")]),
                                           startPoint: CGPoint(x: innerRect.minX, y: innerRect.minY),
                                           endPoint: CGPoint(x: innerRect.maxX, y: innerRect.maxY)))
            ctx.stroke(Path(ellipseIn: innerRect), with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1))
            let letter = Text(initial.prefix(1).uppercased())
                .font(.system(size: G.locketR * 0.9, weight: .semibold))
                .foregroundStyle(.white)
            ctx.draw(letter, at: CGPoint(x: cx, y: cy))
            return
        }

        ctx.fill(Path(ellipseIn: innerRect), with: .color(Self.paperHi))
        ctx.stroke(Path(ellipseIn: innerRect), with: .color(Self.ink.opacity(0.12)), style: StrokeStyle(lineWidth: 1))
        var pin = Path()
        let s = 0.58
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: cx + x * s, y: cy + y * s) }
        pin.move(to: pt(0, -34))
        pin.addCurve(to: pt(-34, 0), control1: pt(-22, -34), control2: pt(-34, -18))
        pin.addCurve(to: pt(-3, 50), control1: pt(-34, 22), control2: pt(-8, 40))
        pin.addCurve(to: pt(3, 50), control1: pt(-1, 52), control2: pt(1, 52))
        pin.addCurve(to: pt(34, 0), control1: pt(8, 40), control2: pt(34, 22))
        pin.addCurve(to: pt(0, -34), control1: pt(34, -18), control2: pt(22, -34))
        pin.closeSubpath()
        ctx.fill(pin, with: .color(Self.persim))
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 10 * s, y: cy - 2 * s - 10 * s, width: 20 * s, height: 20 * s)),
                 with: .color(Self.paperHi))
    }
}

/// Live view: encodes `accountId` once, then draws the mark. `animated` runs a
/// slow per-ring parallax spin; flipping it off (e.g. "Hold still to scan")
/// eases the rings back to their original position rather than snapping. For
/// export use `WanderyCodeCanvas` directly (always static).
struct WanderyCodeView: View {
    let accountId: UInt64
    var version: Int = 0
    var animated: Bool = false
    var centerInitial: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var encoded: WanderyCodec.Encoded?
    @State private var ringAngles: [Double] = [0, 0, 0, 0]

    // Slow parallax: alternating directions, different periods (seconds/turn).
    private static let durations: [Double] = [54, 84, 116, 150]
    private static let directions: [Double] = [1, -1, 1, -1]

    var body: some View {
        Group {
            if let encoded {
                WanderyCodeCanvas(encoded: encoded, ringAngles: ringAngles, centerInitial: centerInitial)
            } else {
                Color(hex: "#f0e9d8").aspectRatio(1, contentMode: .fit).overlay(ProgressView())
            }
        }
        .task(id: accountId) {
            encoded = WanderyCodec()?.encode(accountId: accountId, version: version)
        }
        .onAppear { applySpin(animated) }
        .onChange(of: animated) { _, on in applySpin(on) }
    }

    private func applySpin(_ on: Bool) {
        guard !reduceMotion else { ringAngles = [0, 0, 0, 0]; return }
        if on {
            for i in 0..<4 {
                withAnimation(.linear(duration: Self.durations[i]).repeatForever(autoreverses: false)) {
                    ringAngles[i] = 360 * Self.directions[i]
                }
            }
        } else {
            // Retract: ease each ring back to its rest position.
            for i in 0..<4 {
                withAnimation(.easeOut(duration: 0.8)) { ringAngles[i] = 0 }
            }
        }
    }
}
