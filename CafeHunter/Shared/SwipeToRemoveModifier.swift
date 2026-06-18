import SwiftUI
import UIKit

/// A small chip/badge that's both **tappable** and **swipe-to-dismiss** in one
/// coordinated gesture, so the two never fight. Mirrors the feel of
/// `SwipeToReplyModifier` (chat): a rubber-banded one-direction drag that arms
/// past a threshold (with a `.light` haptic), fades the content as it nears the
/// threshold, and fires `onRemove` if released while armed — otherwise springs
/// back.
///
/// The modifier owns the tap too: a real swipe sets `dragHappened`, so the
/// Button's tap (still delivered under `.simultaneousGesture`) no-ops instead of
/// also firing `onTap` — the same guard `FeedPolaroidCard` uses for its place
/// pill. `.simultaneousGesture` (not `.highPriorityGesture`) keeps any parent
/// scroll/paging working. When `enabled` is false the swipe is absent but the
/// tap still works.
struct SwipeToRemoveModifier: ViewModifier {
    enum Direction { case left, right }          // left = negative x, right = positive x

    let direction: Direction
    var enabled: Bool = true
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var offset: CGFloat = 0
    @State private var armed = false
    @State private var dragHappened = false

    private let activate: CGFloat = 50
    private let maxDrag:  CGFloat = 76

    func body(content: Content) -> some View {
        Button { if !dragHappened { onTap() } } label: {
            content
                .offset(x: offset)
                .opacity(1 - Double(min(abs(offset) / (activate * 2), 0.5)))
        }
        .buttonStyle(.scalePress)
        .simultaneousGesture(enabled ? swipe : nil)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                dragHappened = true
                let dir = direction == .right ? max(0, v.translation.width)
                                              : min(0, v.translation.width)
                offset = rubberBanded(dir)
                let now = abs(offset) >= activate
                if now != armed {
                    armed = now
                    if now { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            }
            .onEnded { _ in
                let fire = armed
                armed = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { offset = 0 }
                if fire { onRemove() }
                // Reset AFTER the Button's tap (delivered on the same touch-up)
                // has read it, so the swipe doesn't also trigger `onTap`.
                DispatchQueue.main.async { dragHappened = false }
            }
    }

    /// Resist past `activate`, cap at `maxDrag` — a soft wall so the chip can't
    /// be dragged arbitrarily far.
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        let m = x.magnitude
        guard m > activate else { return x }
        return (x < 0 ? -1 : 1) * min(activate + (m - activate) * 0.35, maxDrag)
    }
}

extension View {
    func swipeToRemove(_ direction: SwipeToRemoveModifier.Direction,
                       enabled: Bool = true,
                       onTap: @escaping () -> Void,
                       onRemove: @escaping () -> Void) -> some View {
        modifier(SwipeToRemoveModifier(direction: direction, enabled: enabled,
                                       onTap: onTap, onRemove: onRemove))
    }
}
