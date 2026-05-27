import SwiftUI

extension Font {
    /// Editorial serif-italic used by the "My Hunt" surfaces (stat numbers,
    /// month labels, headline). The design calls for Instrument Serif Italic;
    /// until that font is bundled we substitute the system serif italic
    /// (New York). Swap this one implementation to switch to the real font.
    static func huntSerif(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif).italic()
    }
}
