import SwiftUI

extension View {
    /// Applies `foregroundStyle(color.opacity(...))` with an opacity that
    /// automatically increases when Increase Contrast is enabled.
    ///
    /// CafeHunter uses dark ink (`AppTheme.cream` = `#282520`) on a light
    /// warm-white canvas. At opacities below ~0.7 the resulting blended
    /// text falls under WCAG 4.5:1 contrast for normal-size text. Use this
    /// helper whenever you'd otherwise write `.foregroundStyle(color.opacity(value))`
    /// for body or smaller text so the app stays legible for users with
    /// Increase Contrast on.
    ///
    /// The `+ 0.3` bump is deliberately conservative — pushes a 0.4 base
    /// to 0.7 (≈ 4.7:1) and a 0.55 base to 0.85 (≈ 8:1).
    func contrastAware(_ color: Color, opacity baseOpacity: Double) -> some View {
        modifier(ContrastAwareForeground(color: color, baseOpacity: baseOpacity))
    }
}

private struct ContrastAwareForeground: ViewModifier {
    let color: Color
    let baseOpacity: Double
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(
            color.opacity(
                contrast == .increased
                    ? min(1.0, baseOpacity + 0.3)
                    : baseOpacity
            )
        )
    }
}
