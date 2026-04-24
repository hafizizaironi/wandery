import SwiftUI

/// Portal transition — bursts a circular aperture from a given screen point,
/// flooding the destination in through the expanding hole.
///
/// progress: 0 = closed (at origin, no destination visible)
/// progress: 1 = open (aperture fills screen, destination at full opacity)
///
/// Timing: aperture reaches full screen at progress=0.7 (fast "whoomp"),
/// destination fades in from progress=0.5 → 1.0 (lags so it feels like
/// arrival instead of a hard cut).
struct PortalModifier: ViewModifier {
    let origin: CGPoint
    let progress: Double

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let diag = hypot(geo.size.width, geo.size.height)
            let maxRadius = diag * 1.15

            let apertureT = min(1.0, progress / 0.7)
            let radius = maxRadius * apertureT

            let contentT = max(0, min(1.0, (progress - 0.5) / 0.5))

            ZStack {
                // Deep void — sells "you left the map and stepped through somewhere".
                // Masked to the aperture so it only appears where the portal has opened.
                Color.black
                    .opacity(apertureT * 0.95)
                    .mask(
                        Circle()
                            .frame(width: radius * 2, height: radius * 2)
                            .position(origin)
                    )
                    .allowsHitTesting(false)

                // Destination content, revealed through the aperture.
                content
                    .scaleEffect(0.88 + 0.12 * contentT)
                    .opacity(contentT)
                    .mask(
                        Circle()
                            .frame(width: radius * 2, height: radius * 2)
                            .position(origin)
                    )

                // Streaks radiating outward — reads as warp / speed lines.
                // They spill past the aperture edge on purpose: the portal's
                // energy is bigger than the hole.
                if progress > 0.02 && progress < 0.65 {
                    PortalStreaks(
                        origin: origin,
                        strength: 1.0 - min(1.0, progress / 0.65)
                    )
                    .allowsHitTesting(false)
                }

                // Bright energy ring at the aperture's leading edge — the
                // "rim" of the portal as it widens.
                if apertureT > 0.02 && apertureT < 0.98 {
                    Circle()
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.98, green: 0.60, blue: 0.18),
                                    Color(red: 0.84, green: 0.22, blue: 0.36),
                                    Color(red: 0.96, green: 0.44, blue: 0.20),
                                    Color(red: 0.98, green: 0.60, blue: 0.18)
                                ]),
                                center: .center
                            ),
                            lineWidth: 14 + 34 * (1 - apertureT)
                        )
                        .frame(width: radius * 2, height: radius * 2)
                        .position(origin)
                        .blur(radius: 8)
                        .opacity(0.85 * (1 - apertureT))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Radial speed-streaks. Drawn with Canvas for cheap per-frame redraw so
/// the lines stay crisp through the blur on top of the rim.
private struct PortalStreaks: View {
    let origin: CGPoint
    let strength: Double

    @State private var phase: Double = 0

    var body: some View {
        Canvas { ctx, size in
            _ = size
            let count = 32
            for i in 0..<count {
                let jitter = sin(Double(i) * 1.7 + phase * 2) * 0.08
                let angle = (Double(i) / Double(count)) * 2 * .pi + jitter
                let startR = 18.0 + 12 * sin(Double(i) * 2 + phase * 3)
                let endR = 520.0 + 80 * sin(Double(i) + phase)

                let x1 = origin.x + CGFloat(cos(angle) * startR)
                let y1 = origin.y + CGFloat(sin(angle) * startR)
                let x2 = origin.x + CGFloat(cos(angle) * endR)
                let y2 = origin.y + CGFloat(sin(angle) * endR)

                var path = Path()
                path.move(to: CGPoint(x: x1, y: y1))
                path.addLine(to: CGPoint(x: x2, y: y2))

                let hue = 0.04 + 0.08 * Double(i % 5) / 5.0
                ctx.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hue: hue, saturation: 0.82, brightness: 1.0)
                                .opacity(strength * 0.9),
                            Color(hue: hue, saturation: 0.82, brightness: 1.0)
                                .opacity(0.0)
                        ]),
                        startPoint: CGPoint(x: x1, y: y1),
                        endPoint: CGPoint(x: x2, y: y2)
                    ),
                    lineWidth: 1.6
                )
            }
        }
        .blendMode(.screen)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

extension AnyTransition {
    /// Transition that opens from `origin` like a portal aperture, with the
    /// destination arriving through the hole.
    static func portal(origin: CGPoint) -> AnyTransition {
        .modifier(
            active: PortalModifier(origin: origin, progress: 0.0),
            identity: PortalModifier(origin: origin, progress: 1.0)
        )
    }
}
