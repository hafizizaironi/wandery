import SwiftUI

/// Circular "close-in": masks a layer with a circle that shrinks from beyond
/// the screen down to nothing, collapsing it into a point to reveal whatever
/// sits beneath (the Hero tab). `progress == 1` = fully open (layer visible),
/// `progress == 0` = fully closed (layer gone).
struct CircularClose: ViewModifier {
    var progress: CGFloat
    var center: UnitPoint = .init(x: 0.5, y: 0.5)

    func body(content: Content) -> some View {
        content.mask(
            GeometryReader { geo in
                // Reach past the far corner so a fully-open circle clears the
                // whole screen regardless of centre.
                let maxR = hypot(geo.size.width, geo.size.height) * 1.1
                let diameter = maxR * 2 * progress
                Circle()
                    .frame(width: diameter, height: diameter)
                    .position(x: geo.size.width * center.x,
                              y: geo.size.height * center.y)
            }
        )
    }
}

extension View {
    /// Collapses the view into a shrinking circle. Animate `progress` 1 → 0
    /// over `EntryTiming.closeIn` to close in on the Hero tab.
    func circularClose(progress: CGFloat,
                       center: UnitPoint = .init(x: 0.5, y: 0.5)) -> some View {
        modifier(CircularClose(progress: progress, center: center))
    }
}
