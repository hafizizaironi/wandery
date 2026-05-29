import SwiftUI

/// In-app progress ring traced around the Dynamic Island cutout, shown while a
/// post uploads. This is the *foreground* upload indicator — a Live Activity
/// can't render in the DI while the app is frontmost, so we draw our own ring
/// hugging the island. Driven by the real `uploadProgress`.
///
/// When the flying capture card "dives" into the island (`splashTrigger`
/// increments), the ring reacts like water: a quick splash scale-pulse plus an
/// expanding ripple that fades.
///
/// The DI on current phones is ≈126×37 at ≈11pt from the top, centered; the
/// ring is sized a few points larger so it wraps the outside. Tunable.
struct DynamicIslandUploadRing: View {
    /// 0…1 upload progress.
    let progress: Double
    /// Bump to make the ring splash (the card just dove into the island).
    var splashTrigger: Int = 0

    private let ringSize = CGSize(width: 134, height: 44)
    private let topInset: CGFloat = 7.5

    var body: some View {
        ZStack {
            // Expanding ripple emitted on impact ("water splashed").
            Capsule(style: .continuous)
                .stroke(AppTheme.accentAction, lineWidth: 2)
                .keyframeAnimator(initialValue: Ripple(), trigger: splashTrigger) { view, r in
                    view.scaleEffect(r.scale).opacity(r.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.opacity) {
                        CubicKeyframe(0.55, duration: 0.02)
                        CubicKeyframe(0.0, duration: 0.55)
                    }
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1.0, duration: 0.02)
                        CubicKeyframe(1.7, duration: 0.55)
                    }
                }

            // Faint full track so the ring reads as a closed loop around the DI.
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 3)
            // Accent progress trace.
            Capsule(style: .continuous)
                .trim(from: 0, to: max(0.04, min(progress, 1)))
                .stroke(AppTheme.accentAction,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(width: ringSize.width, height: ringSize.height)
        // Splash scale-pulse: pop out, recoil, then a springy settle ("wave").
        .keyframeAnimator(initialValue: Splash(), trigger: splashTrigger) { view, s in
            view.scaleEffect(s.scale)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.22, duration: 0.14)
                CubicKeyframe(0.94, duration: 0.12)
                SpringKeyframe(1.0, duration: 0.34, spring: .bouncy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Splash { var scale: CGFloat = 1 }
    private struct Ripple {
        var scale: CGFloat = 1
        var opacity: CGFloat = 0
    }
}
