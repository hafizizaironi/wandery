import SwiftUI

/// Cold-launch entry sequence state. Drives `WanderyEntryView`. Both
/// transitions are a **circular close-in**:
///
///   loading (cropped polaroid on espresso)
///     → closing  (splash circular-closes onto the login page / map, or
///                 straight onto Hero for a returning user)
///     → [login, if signed-out]
///     → closing  (the map circular-closes onto the Hero tab once onboarded)
///     → done
///
/// See `~/.claude/plans/delightful-jumping-lemur.md`.
enum EntryPhase: Equatable {
    case loading    // dark espresso splash, cropped polaroid breathing
    case closing    // circular close-in onto the screen beneath
    case done
}

/// Canonical durations. The loading splash plays once per cold launch; the
/// first close-in reveals the login (or Hero for a returning user), and a
/// second close-in reveals Hero once the user is fully onboarded. The dwell
/// floor keeps the deliberate "intentional loading" beat even when auth
/// resolves instantly.
enum EntryTiming {
    static let loadingHold:    Double = 1.6   // splash dwell floor
    static let closeIn:        Double = 1.0   // circular close-in
    static let loginSheetRise: Double = 0.35  // delay before LoginView raises its sheet
    static let reducedHold:    Double = 0.8   // Reduce Motion: splash dwell, then a plain fade
}

extension Animation {
    /// Circular close-in — eases in, settles out.
    static let entryClose = Animation.timingCurve(0.5, 0, 0.3, 1, duration: EntryTiming.closeIn)
    /// Login sheet rise — eOutCubic-ish spring.
    static let entryPanel = Animation.spring(response: 0.55, dampingFraction: 0.86)
}

/// Splash-only dark espresso palette. The app's `AppTheme` is an all-light
/// "Clay & Ink" set (`espresso` is a legacy alias for the near-white
/// `surfaceCanvas`), so the dark launch backdrop lives here. Matches the
/// design doc's `#23170f → #0d0805`.
enum EntryPalette {
    static let espressoTop    = Color(hex: "#23170f")
    static let espressoBottom = Color(hex: "#0d0805")

    /// Radial wash — warmer at centre, deepening to the edges.
    static var splashBackground: RadialGradient {
        RadialGradient(
            colors: [espressoTop, espressoBottom],
            center: .center,
            startRadius: 0,
            endRadius: 520
        )
    }

    /// Warm wash laid over the map snapshot to tie tiles to the palette.
    static let mapWash = AppTheme.surfaceCanvas.opacity(0.10)
}
