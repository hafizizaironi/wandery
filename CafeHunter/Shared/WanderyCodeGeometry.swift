import CoreGraphics
import Foundation

/// Single source of truth for the Wandery Code symbol geometry, shared by the
/// renderer (`WanderyCodeView`/`WanderyCodeCanvas`) and the detector
/// (`WanderyCodeDetector`). They MUST agree — the detector solves an affine
/// from the finder pins and then samples data modules at `dataRadii/finderR`
/// ratios, so any mismatch silently breaks decoding. Keeping the numbers here
/// (not duplicated in two files) makes drift impossible.
///
/// Module *counts* and read order (north, clockwise, inner→outer) must match
/// `WanderyCodec`. Radii/widths are presentation values and may be retuned, as
/// long as both sides read them from here.
///
/// Versus the original `render.js`: the four data rings are nudged inward
/// (outer 136→130) so the north pin's dashed collar clears the outer ring
/// instead of overlapping it.
enum WanderyCodeGeometry {
    // Box is larger than the symbol so the north pin + its dashed collar
    // (which sit at the outer radius) keep a clear margin and never clip the
    // canvas edge. finderR/dataRadii are unchanged, so decode is unaffected.
    static let box: Double = 360
    static let centerX: Double = 180
    static let centerY: Double = 180

    static let locketR: Double = 50
    static let timingR: Double = 72
    static let timingW: Double = 5

    /// Inner→outer. Counts must equal `WanderyCodec` DATA_RINGS.
    static let dataRadii: [Double] = [85, 100, 115, 130]
    static let dataWidths: [Double] = [8, 8, 7.5, 7.5]
    static let dataCounts: [Int] = [30, 36, 42, 48]

    static let finderR: Double = 152
    static let finderDegs: [Double] = [0, 120, 240]   // north first
    static let pinOuterR: Double = 8
    static let pinDotR: Double = 3.2
    /// North-only dashed collar, as a radius around the pin center.
    static let collarR: Double = 12

    static let quietR: Double = 176
    /// Angular fraction trimmed off each side of a module (visual gap).
    static let gapFraction: Double = 0.16

    /// Pairwise distance between finder pins (equilateral triangle side).
    /// Used by the detector to recover symbol→image scale from the pins.
    static var symbolSpacing: Double { finderR * (3.0).squareRoot() }

    /// Symbol-space point at radius `r`, `deg` from north (0°), clockwise.
    /// Identical mapping to `render.js`'s `pol()`.
    static func pol(_ r: Double, _ deg: Double) -> CGPoint {
        let a = (deg - 90) * .pi / 180
        return CGPoint(x: centerX + r * cos(a), y: centerY + r * sin(a))
    }
}
