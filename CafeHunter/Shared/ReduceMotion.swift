import SwiftUI

extension Animation {
    /// Returns the given animation when Reduce Motion is off, or a near-zero
    /// cross-fade when it's on. Use in place of any spring/slide on screens
    /// that can be presented while the user is reading.
    ///
    /// Springs trigger vestibular discomfort for users who enable Reduce
    /// Motion. Replacing them with a 0.1s linear fade keeps the UI
    /// responsive without the motion that's the problem.
    static func motionRespecting(
        _ animation: Animation,
        reduceMotion: Bool
    ) -> Animation {
        reduceMotion ? .linear(duration: 0.1) : animation
    }
}
