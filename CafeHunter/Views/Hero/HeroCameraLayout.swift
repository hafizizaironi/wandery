import SwiftUI

/// Shared layout for the Hero camera viewfinder, post preview, and feed cards — one square template.
enum HeroCameraLayout {
    /// Clearance so content sits just above the arc's home-button peak.
    static func bottomChromeHeight(safeBottom: CGFloat) -> CGFloat {
        safeBottom + ArcNavBar.homeButtonFromBottom + 60
    }

    static let horizontalPadding: CGFloat = 8
    /// Height of the bottom control stack (mode swiper · library/shutter/flip
    /// row · feed hint). Flash + zoom dial overlay the viewfinder itself, so
    /// this stays compact and the square keeps its original size — together
    /// these reserve the same ~160pt below the card as the legacy shutter.
    static let controlStackHeight: CGFloat = 150
    static let viewfinderShutterSpacing: CGFloat = 10
    static let viewfinderCornerRadius: CGFloat = 24

    /// Total vertical space reserved BELOW the square card. Used by the camera
    /// page (for the control stack) AND the feed/empty pages (as a matching
    /// spacer) so the square never shifts position when paging between them.
    static var belowCardHeight: CGFloat { controlStackHeight + viewfinderShutterSpacing }

    /// One full-screen page for vertical paging (camera card + feed cards share the same viewport height).
    static func pageHeight(in geo: GeometryProxy) -> CGFloat {
        geo.size.height
    }

    /// Same square size as the live camera viewfinder (feed posts and post preview use this frame).
    static func viewfinderSide(in geo: GeometryProxy) -> CGFloat {
        let bottomChrome = bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
        let pad = horizontalPadding
        let usableW = max(0, geo.size.width - pad * 2)
        let availableH = geo.size.height - geo.safeAreaInsets.top - bottomChrome - belowCardHeight
        return max(120, min(usableW, availableH))
    }
}
