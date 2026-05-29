import UIKit

/// Small device-geometry helpers read from the key window (reliable even when a
/// parent applies `.ignoresSafeArea()`, which zeroes a child GeometryReader's
/// insets).
enum DeviceMetrics {
    static var topSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    /// Dynamic Island phones report a ≈59pt top inset, vs ≈47–50 (notch) or
    /// 20 (classic). 55 is a safe threshold.
    static var hasDynamicIsland: Bool { topSafeInset >= 55 }
}
