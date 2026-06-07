import SwiftUI

// MARK: - Animated wave text

/// Renders each character of `text` with a left-to-right sine-wave vertical jitter,
/// driven by a TimelineView so the animation is smooth and clock-independent.
struct AnimatedWaveText: View {
    let text: String
    let font: Font

    private let amplitude: CGFloat = 3.2   // max vertical travel in points
    private let period: Double     = 0.9   // seconds per full cycle
    private let phasePerChar: Double = 0.18  // wave phase offset between adjacent chars

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { idx, char in
                    Text(String(char))
                        .font(font)
                        .foregroundStyle(.white)
                        .offset(y: yOffset(t: t, index: idx))
                }
            }
        }
    }

    /// Wave travels left → right: earlier characters lead; later ones follow.
    private func yOffset(t: Double, index: Int) -> CGFloat {
        amplitude * CGFloat(sin((t / period - Double(index) * phasePerChar) * .pi * 2))
    }
}
