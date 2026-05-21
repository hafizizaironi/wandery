import SwiftUI

/// Project-wide motion design tokens, translated from Emil Kowalski's
/// "design engineering" principles. The web-side advice (CSS cubic-beziers,
/// 100-300ms UI durations, scale-0.97 press feedback, never-from-scale-zero
/// entrances) maps cleanly onto SwiftUI's Animation / ButtonStyle APIs.
///
/// Use these instead of `.easeInOut(duration: 0.3)` ad-hoc so the whole app
/// feels cohesive. CafeHunter's personality is *warm and cozy* — slightly
/// playful springs over crisp linear curves — so the cozy preset has a
/// subtle bounce while UI-functional curves stay snappy.
enum Motion {
    // MARK: - Curves
    //
    // Apple's built-in easings are too weak for UI work — they lack the
    // "punch" that makes animations feel intentional. These cubic-beziers
    // are Emil's recommended stronger variants.

    /// Strong ease-out — for entrances, exits, and most UI interactions.
    /// Starts fast, settles smooth. Use as your default UI curve.
    static func strongEaseOut(duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    /// Strong ease-in-out — for elements moving across the screen
    /// (e.g. a card transitioning between two anchored positions).
    static func strongEaseInOut(duration: Double) -> Animation {
        .timingCurve(0.77, 0, 0.175, 1, duration: duration)
    }

    /// iOS drawer curve (Ionic) — for sheet/drawer slide-up and slide-down.
    /// Matches the feel of native iOS sheets without using `.sheet`.
    static func iosDrawer(duration: Double) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }

    // MARK: - Standard durations
    //
    // Per Emil: UI animations stay under 300ms. Faster perceived performance.

    enum Duration {
        /// Button press feedback. Snappy enough that users feel "heard"
        /// without the press visibly lagging the touch.
        static let press: Double = 0.16
        /// Tooltips, small popovers, instant menus.
        static let tooltip: Double = 0.16
        /// Dropdowns, selects, segmented controls.
        static let dropdown: Double = 0.2
        /// Sheets, modals, full-screen covers.
        static let modal: Double = 0.32
        /// Drawers, page transitions.
        static let drawer: Double = 0.4
    }

    // MARK: - Presets
    //
    // The animations you'll reach for 90% of the time. Pre-baked so calls
    // read like intent ("press feedback") rather than configuration.

    /// Tap feedback on buttons, pressable cards, etc.
    static let pressFeedback: Animation = strongEaseOut(duration: Duration.press)
    /// Tooltips and instant popovers.
    static let tooltip: Animation = strongEaseOut(duration: Duration.tooltip)
    /// Dropdowns, segmented control selection.
    static let dropdown: Animation = strongEaseOut(duration: Duration.dropdown)
    /// Sheet present/dismiss.
    static let modal: Animation = iosDrawer(duration: Duration.modal)
    /// Drawer / page slide.
    static let drawer: Animation = iosDrawer(duration: Duration.drawer)

    /// Cozy content reveal — used for first-impression moments where a
    /// little bounce reinforces the brand's warmth (welcome cards,
    /// achievement unlocks, post-publish confirmation). Keep bounce subtle.
    static let cozyReveal: Animation = .spring(duration: 0.5, bounce: 0.15)

    /// Tight content reveal for in-card stagger — no bounce, just a clean
    /// ease-out. Pair with a per-element delay (30–80ms between items).
    static let staggerReveal: Animation = strongEaseOut(duration: 0.3)

    // MARK: - Standard transitions
    //
    // Emil's first rule of entrances: never scale from zero. Start from
    // 0.95 with opacity 0 so the element has a perceptible "deflated"
    // shape that grows into place, not a poof-from-nothing.

    /// Default entrance/exit for cards, sheets, content blocks.
    /// Matches `transform: scale(0.95); opacity: 0` from CSS.
    static let coziedScaleFade: AnyTransition = .scale(scale: 0.95).combined(with: .opacity)
}

/// Standard pressable feedback for any tappable element in the app.
/// Applies a subtle `scale(0.97)` on press, matching Emil's recommended
/// "buttons must feel responsive" pattern. Honors `accessibilityReduceMotion`
/// — under reduced motion the scale is skipped but opacity dip survives so
/// the user still gets a visual ack.
struct ScalePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(Motion.pressFeedback, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ScalePressButtonStyle {
    /// `.buttonStyle(.scalePress)` — apply the project's standard press
    /// feedback. Cleaner at the call site than `ScalePressButtonStyle()`.
    static var scalePress: ScalePressButtonStyle { .init() }
}
