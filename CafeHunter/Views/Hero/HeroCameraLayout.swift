import SwiftUI

/// Shared layout for the Hero camera viewfinder, post preview, and feed cards — one square template.
enum HeroCameraLayout {
    /// Clearance so content sits just above the arc's home-button peak.
    static func bottomChromeHeight(safeBottom: CGFloat) -> CGFloat {
        safeBottom + ArcNavBar.homeButtonFromBottom + 60
    }

    static let horizontalPadding: CGFloat = 8
    static let shutterAreaHeight: CGFloat = 100
    static let viewfinderShutterSpacing: CGFloat = 60
    static let viewfinderCornerRadius: CGFloat = 24

    /// One full-screen page for vertical paging (camera card + feed cards share the same viewport height).
    static func pageHeight(in geo: GeometryProxy) -> CGFloat {
        geo.size.height
    }

    /// Same square size as the live camera viewfinder (feed posts and post preview use this frame).
    static func viewfinderSide(in geo: GeometryProxy) -> CGFloat {
        let bottomChrome = bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
        let pad = horizontalPadding
        let usableW = max(0, geo.size.width - pad * 2)
        let availableH = geo.size.height - geo.safeAreaInsets.top - bottomChrome - shutterAreaHeight - viewfinderShutterSpacing
        return max(120, min(usableW, availableH))
    }
}
