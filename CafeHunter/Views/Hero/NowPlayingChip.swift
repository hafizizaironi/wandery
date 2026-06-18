import SwiftUI

/// A minimalist, background-free "now playing" indicator shown centered below a
/// music post's card. A small play/pause button; while the song plays the title
/// scrolls beside it in a seamless infinite loop that dissolves at both ends.
/// When paused the title smoothly collapses, leaving just the play button.
struct NowPlayingChip: View {
    var title: String
    var isPlaying: Bool
    var onTap: () -> Void

    /// Visible width of the scrolling-title window.
    private let marqueeW: CGFloat = 180
    /// Gap between the button and the title — folded INTO the collapsing block
    /// (not the HStack spacing) so it animates as one piece instead of a step.
    private let gap: CGFloat = 8
    private let buttonD: CGFloat = 28

    /// Fixed bounding width (the expanded size). The button + title HStack is
    /// centered inside it, so the button's x is a smooth function of the HStack's
    /// animating width — it GLIDES from dead-centre (collapsed) to left-of-centre
    /// (expanded) instead of the parent snapping it to a new centre.
    private var containerW: CGFloat { buttonD + gap + marqueeW }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                playButton
                HStack(spacing: 0) {
                    Color.clear.frame(width: gap)
                    MarqueeText(text: title, active: isPlaying, width: marqueeW)
                }
                .frame(width: isPlaying ? gap + marqueeW : 0, alignment: .leading)
                .opacity(isPlaying ? 1 : 0)
                .clipped()
            }
            // The HStack width animates (button-only ↔ full); the fixed,
            // center-aligned container keeps it centred — so the button and the
            // title expand/collapse uniformly about the centre, button included.
            .frame(width: containerW, alignment: .center)
            .animation(.spring(response: 0.55, dampingFraction: 0.9), value: isPlaying)
        }
        .buttonStyle(.scalePress)
        .accessibilityLabel("Song: \(title)")
        .accessibilityHint(isPlaying ? "Tap to pause" : "Tap to play")
    }

    private var playButton: some View {
        ZStack {
            Circle().fill(AppTheme.accentAction)
            // The glyph must move as ONE rigid unit with the circle during the
            // glide. So: no per-state `.offset` (would drift it) and no
            // `.contentTransition` (its scale-in/out plays over the glide spring
            // and reads as the icon lagging the circle). A plain instant swap
            // keeps the glyph dead-centre, locked to the circle the whole time.
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white)
                .animation(nil, value: isPlaying)
        }
        .frame(width: buttonD, height: buttonD)
        .shadow(color: AppTheme.accentAction.opacity(0.45), radius: 5, y: 2)
    }
}

/// A single line of text that scrolls horizontally in a seamless, time-based
/// infinite loop and dissolves (fades) at both edges. Two identical copies plus
/// a `TimelineView` sawtooth offset make the wrap invisible — no `repeatForever`
/// restart hitch. Only animates while `active`.
private struct MarqueeText: View {
    let text: String
    var active: Bool
    var width: CGFloat

    @State private var textWidth: CGFloat = 0
    private let gap: CGFloat = 38
    private let speed: Double = 36   // points per second

    var body: some View {
        let unit = textWidth + gap
        Group {
            if active && unit > 0 {
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let x = -CGFloat((elapsed * speed).truncatingRemainder(dividingBy: Double(unit)))
                    HStack(spacing: gap) {
                        label
                        label
                    }
                    .offset(x: x)
                    .frame(width: width, alignment: .leading)
                }
            } else {
                label.frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width, height: 15)
        .clipped()
        .mask(edgeFade)
        // Measure one copy's intrinsic width for the loop distance.
        .background(
            label.fixedSize()
                .hidden()
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { textWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in textWidth = w }
                })
                .allowsHitTesting(false)
        )
    }

    private var label: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
    }

    /// Opaque in the middle, transparent at the two ends — fades the title in
    /// and out of the window so the loop reads as a smooth dissolve.
    private var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
}
