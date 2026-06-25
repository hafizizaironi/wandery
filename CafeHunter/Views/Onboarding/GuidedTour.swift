import SwiftUI

// MARK: - Guided first-run tour (spotlight coach-marks)
//
// A tiny, dependency-free coach-mark system. Real UI elements tag themselves
// with `.tourAnchor(_:)`; MainShellView reads their on-screen frames through a
// preference and dims the whole screen except a spring-pulsing spotlight around
// the current step's target, with a tooltip. The tour drives the tabs itself
// (each step's `onEnter`), so it "walks" the user through the app — they just
// tap Next. Matches the app's spring vocabulary (Shared/Motion.swift) and
// honours Reduce Motion.

/// Elements the tour can spotlight. Tagged at the source with `.tourAnchor`.
enum TourTarget: Hashable {
    case mapTab, heroTab, profileTab, feed, trending
}

/// Collects every tagged element's bounds anchor, keyed by target. The last
/// writer wins, so a target tagged once resolves to a single frame.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>],
                       nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this view's frame so the guided tour can spotlight it.
    func tourAnchor(_ target: TourTarget) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

/// One step: which element to spotlight, the copy, and a side effect run on
/// entering the step (switch the tab so `target` is on-screen before the
/// spotlight lands).
struct TourStep {
    let target: TourTarget
    let title: String
    let body: String
    var onEnter: () -> Void = {}
}

/// Full-screen dim + spotlight cutout + tooltip for the current step.
///
/// `frame` is the resolved on-screen rect of the step's target, already in this
/// overlay's coordinate space. It's nil for the frame or two after a tab switch
/// while the new screen lays out — we just show the dim + centred tooltip until
/// it resolves, so the spotlight never flashes at the wrong spot.
struct GuidedTourOverlay: View {
    let step: TourStep
    let index: Int
    let count: Int
    let frame: CGRect?
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private let pad: CGFloat = 10          // breathing room around the target
    private let radius: CGFloat = 18

    /// The padded, rounded spotlight rect (nil until the target frame resolves).
    private var hole: CGRect? {
        frame.map { $0.insetBy(dx: -pad, dy: -pad) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dim everything, then mask out the spotlight so the real
                // element shows through. The Color fills the whole frame and
                // swallows taps (the app underneath stays inert; the user
                // advances with the buttons below).
                Color.black.opacity(0.72)
                    .mask(dimMask(screen: geo.size).fill(style: FillStyle(eoFill: true)))
                    .contentShape(Rectangle())
                    .onTapGesture { /* swallow taps on the dim */ }

                if let hole {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(AppTheme.accentAction, lineWidth: 2.5)
                        .frame(width: hole.width, height: hole.height)
                        .scaleEffect(reduceMotion ? 1 : (pulse ? 1.06 : 1.0))
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)
                }

                tooltip(screen: geo.size)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)
                    .repeatForever(autoreverses: true)) { pulse = true }
            }
        }
        // Glide the spotlight + tooltip between steps.
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: frame)
    }

    /// Screen rect ∪ rounded spotlight rect — filled even-odd as a mask, the
    /// hole is excluded so that region stays clear.
    private func dimMask(screen: CGSize) -> Path {
        var p = Path(CGRect(origin: .zero, size: screen))
        if let hole {
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius))
        }
        return p
    }

    // MARK: tooltip card

    @ViewBuilder
    private func tooltip(screen: CGSize) -> some View {
        let card = VStack(alignment: .leading, spacing: 10) {
            // Progress dots.
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i == index ? AppTheme.accentAction : AppTheme.textPrimary.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
            Text(step.title)
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text(step.body)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip", action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Button(action: onNext) {
                    Text(index == count - 1 ? "Done" : "Next")
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.textOnAccent)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(AppTheme.accentAction, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: 340)
        .background(AppTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .padding(.horizontal, 20)

        // Place the card opposite the spotlight: targets in the bottom half
        // (navbar) push the card up; everything else sits below the target.
        // No resolved frame yet → centre it.
        card.frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: tooltipAlignment(screen: screen))
            .padding(.top, screen.height * 0.12)
            .padding(.bottom, screen.height * 0.16)
    }

    private func tooltipAlignment(screen: CGSize) -> Alignment {
        guard let frame else { return .center }
        return frame.midY > screen.height / 2 ? .top : .bottom
    }
}
