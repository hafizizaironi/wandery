import SwiftUI
import UIKit

extension Font {
    /// Editorial serif-italic used by the "My Hunt" surfaces (stat numbers,
    /// month labels, headline). The design calls for Instrument Serif Italic;
    /// until that font is bundled we substitute the system serif italic
    /// (New York). Swap this one implementation to switch to the real font.
    static func huntSerif(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif).italic()
    }

    /// PostScript name of the bundled Instrument Serif Italic, if present.
    /// (Confirm against the actual TTF once it's dropped in — Google's build
    /// registers as "InstrumentSerif-Italic".)
    private static let instrumentSerifItalic = "InstrumentSerif-Italic"

    /// The `wandery` wordmark face. Prefers the bundled Instrument Serif
    /// Italic; until the TTF + `UIAppFonts` entry land, falls back to the
    /// `huntSerif` system substitute so the lockup still renders. No
    /// call-site changes are needed when the real font is added.
    static func wanderyWordmark(_ size: CGFloat) -> Font {
        if UIFont(name: instrumentSerifItalic, size: size) != nil {
            return .custom(instrumentSerifItalic, size: size)
        }
        return huntSerif(size)
    }
}
