import SwiftUI

/// A vertical, one-page-per-swipe pager whose **live drag is isolated** from the
/// (very large) `HeroPageView` body.
///
/// `dragOffset` lives here as local state, so finger-tracking re-renders only
/// this thin wrapper — not the camera preview + every feed card. When the offset
/// was state on `HeroPageView`, each drag frame re-executed that whole body
/// (rebuilding `cameraContent` and all feed pages), which made the drag stutter.
/// The page content is built once by the parent and passed in; here we only
/// re-apply a transform to the already-built view.
struct HeroCardPager<Content: View>: View {
    let pageCount: Int
    let pageHeight: CGFloat
    let width: CGFloat
    /// The settled page. Written (animated) on release; the parent reads it back
    /// to keep card identity in sync. Not mutated during the live drag.
    @Binding var index: Int
    var disabled: Bool
    var settle: Animation
    /// Fired when a vertical paging drag is first recognized (e.g. dismiss keyboard).
    var onDragStart: () -> Void
    /// Fired with the chosen index on release, so the parent can commit identity
    /// (heroCardID / activeCardID) + prefetch — off the live-drag path.
    var onSettle: (Int) -> Void
    @ViewBuilder var content: Content

    @State private var dragOffset: CGFloat = 0
    @State private var isPaging = false

    var body: some View {
        content
            .frame(width: width, alignment: .top)
            .offset(y: -CGFloat(index) * pageHeight + dragOffset)
            .frame(width: width, height: pageHeight, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .gesture(gesture)
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !disabled else { return }
                // Axis-lock: claim the drag only when it's dominantly vertical,
                // then latch for the rest of THIS drag so a curved finger path
                // can't leak into (or out of) the horizontal card gestures.
                if !isPaging {
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    isPaging = true
                    onDragStart()
                }
                dragOffset = rubberBanded(value.translation.height)
            }
            .onEnded { value in
                defer { isPaging = false }
                guard isPaging, !disabled else {
                    withAnimation(settle) { dragOffset = 0 }
                    return
                }
                // Commit on either a deliberate drag (>90pt) or a flick
                // (predicted >220pt) — the forgiving thresholds the card swipers
                // use. The dominant of the two decides direction; advance ≤1 page.
                let dy = value.translation.height
                let predicted = value.predictedEndTranslation.height
                var target = index
                if abs(dy) > 90 || abs(predicted) > 220 {
                    let dir = abs(predicted) > abs(dy) ? predicted : dy
                    target += dir < 0 ? 1 : -1     // drag up → next, down → prev
                }
                target = max(0, min(pageCount - 1, target))
                withAnimation(settle) {
                    index = target
                    dragOffset = 0
                }
                onSettle(target)
            }
    }

    /// Pass-through, except an asymptotic resistance past the first/last page
    /// (iOS-style overscroll so the ends feel bounded, not dead).
    private func rubberBanded(_ raw: CGFloat) -> CGFloat {
        if index == 0 && raw > 0 { return resist(raw) }
        if index == pageCount - 1 && raw < 0 { return -resist(-raw) }
        return raw
    }

    private func resist(_ x: CGFloat) -> CGFloat {
        let limit: CGFloat = 200
        return (1 - 1 / (x / limit * 0.55 + 1)) * limit
    }
}
