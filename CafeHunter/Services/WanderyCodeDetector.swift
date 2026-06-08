import Foundation
import CoreVideo
import simd

/// Camera-side detector: turns a grayscale frame into the 156 module bits and
/// decodes them via `WanderyCodec`. Implements the pipeline in the design's
/// `detector-outline.md` — adaptive binarize → find the 3 finder pins →
/// affine solve → sample modules → decode — in pure Swift (no 3rd-party CV).
///
/// This is the spike's crux. It targets a reliable decode in GOOD conditions
/// (head-on, decent light, code filling much of the frame). Robustness under
/// dim light / steep tilt / occlusion is a deliberate follow-up. Every stage
/// logs counts behind `debugLogging` so we can tune from real device runs.
///
/// NOT thread-safe — drive it from a single serial queue (the scanner's
/// video-data queue). Its `WanderyCodec` (a JSContext) lives on that queue.
final class WanderyCodeDetector {

    struct Result: Equatable { let accountId: UInt64; let version: Int; let byteErrors: Int }

    /// Lightweight per-frame telemetry for the on-screen debug HUD.
    struct Frame {
        var components = 0
        var candidates = 0
        var pins = 0
        var solved = false
        var decoded: Result?
    }

    // MARK: - Tunables (device-tunable; surfaced for iteration)

    /// Bradley adaptive-threshold window as a fraction of image width.
    var windowFraction = 0.125
    /// Bradley threshold: a pixel is "dark" if it's `t` below its local mean.
    var bradleyT = 0.15
    /// Candidate finder-pin bounding-box side, as a fraction of image min-dim.
    var pinSideRange: ClosedRange<Double> = 0.008...0.10
    /// Require the same id over this many consecutive frames before firing.
    var requiredAgreement = 2
    var debugLogging = true

    // MARK: - State

    private let codec: WanderyCodec?
    private var lastId: UInt64?
    private var agreement = 0
    private(set) var lastFrame = Frame()

    // Symbol-space geometry — shared with the renderer via WanderyCodeGeometry
    // so the two can never drift (a mismatch silently breaks decoding).
    private typealias G = WanderyCodeGeometry
    private static let center = SIMD2<Double>(G.centerX, G.centerY)

    init() { codec = WanderyCodec() }

    // MARK: - Entry

    /// Analyze one luma (grayscale) plane. Returns a confident decode (after
    /// multi-frame agreement) or nil. `base` points at row-major 8-bit luma.
    func analyze(base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Result? {
        var frame = Frame()
        defer { lastFrame = frame }

        // 1. Pack into a contiguous grayscale buffer (strip row padding).
        var gray = [UInt8](repeating: 0, count: width * height)
        gray.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let src = base + y * bytesPerRow
                dst.baseAddress!.advanced(by: y * width).update(from: src, count: width)
            }
        }

        // 2. Adaptive (Bradley) threshold → binary (1 = dark/ink).
        let binary = bradleyThreshold(gray, width: width, height: height)

        // 3. Connected components on dark pixels.
        let comps = connectedComponents(binary, width: width, height: height)
        frame.components = comps.count

        // 4. Candidate pins → bullseye-verified pins → equilateral triple.
        let minDim = Double(min(width, height))
        let candidates = comps.filter { c in
            let side = Double(max(c.w, c.h))
            let f = side / minDim
            guard f >= pinSideRange.lowerBound && f <= pinSideRange.upperBound else { return false }
            let aspect = Double(max(c.w, c.h)) / Double(max(1, min(c.w, c.h)))
            return aspect <= 1.7
        }
        frame.candidates = candidates.count

        let verified = candidates.filter { isBullseye(binary, width: width, height: height,
                                                       cx: $0.cx, cy: $0.cy,
                                                       approxRadius: Double(max($0.w, $0.h)) / 2) }
        frame.pins = verified.count

        guard let pins = pickPinTriangle(verified) else {
            log("comps=\(comps.count) cand=\(candidates.count) pins=\(verified.count) → no triangle")
            agreement = 0; lastId = nil
            return nil
        }

        // 5. Order pins (north + clockwise) and solve the affine symbol→image.
        guard let ordered = orderPins(pins, binary: binary, width: width, height: height),
              let affine = solveAffine(ordered) else {
            log("triangle found but ordering/affine failed")
            return nil
        }
        frame.solved = true

        // 6. Sample the 156 data modules through the transform.
        let bits = sampleModules(binary, width: width, height: height, affine: affine)

        // 7. Decode + multi-frame agreement.
        guard let dec = codec?.decode(bits: bits) else {
            log("pins=4? solved; decode failed (uncorrectable/crc)")
            agreement = 0; lastId = nil
            return nil
        }
        let result = Result(accountId: dec.accountId, version: dec.version, byteErrors: dec.byteErrors)
        frame.decoded = result

        if dec.accountId == lastId {
            agreement += 1
        } else {
            lastId = dec.accountId
            agreement = 1
        }
        log("DECODE id=\(dec.accountId) errs=\(dec.byteErrors) agree=\(agreement)/\(requiredAgreement)")
        return agreement >= requiredAgreement ? result : nil
    }

    func reset() { lastId = nil; agreement = 0 }

    // MARK: - 2. Bradley adaptive threshold (integral image)

    private func bradleyThreshold(_ gray: [UInt8], width: Int, height: Int) -> [UInt8] {
        let w = width, h = height
        // Integral image (row-major, (w+1)×(h+1)).
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        gray.withUnsafeBufferPointer { g in
            integral.withUnsafeMutableBufferPointer { I in
                for y in 0..<h {
                    var rowSum = 0
                    let gRow = y * w
                    let iRow = (y + 1) * (w + 1)
                    let iPrev = y * (w + 1)
                    for x in 0..<w {
                        rowSum += Int(g[gRow + x])
                        I[iRow + (x + 1)] = I[iPrev + (x + 1)] + rowSum
                    }
                }
            }
        }
        let s = max(2, Int(Double(w) * windowFraction))
        let half = s / 2
        var binary = [UInt8](repeating: 0, count: w * h)
        gray.withUnsafeBufferPointer { g in
            integral.withUnsafeBufferPointer { I in
                binary.withUnsafeMutableBufferPointer { b in
                    for y in 0..<h {
                        let y0 = max(0, y - half), y1 = min(h - 1, y + half)
                        for x in 0..<w {
                            let x0 = max(0, x - half), x1 = min(w - 1, x + half)
                            let count = (x1 - x0 + 1) * (y1 - y0 + 1)
                            // sum over [x0..x1]×[y0..y1] via the integral image
                            let sum = I[(y1 + 1) * (w + 1) + (x1 + 1)]
                                - I[y0 * (w + 1) + (x1 + 1)]
                                - I[(y1 + 1) * (w + 1) + x0]
                                + I[y0 * (w + 1) + x0]
                            let pixel = Int(g[y * w + x])
                            // dark if pixel is meaningfully below the local mean
                            if Double(pixel * count) < Double(sum) * (1.0 - bradleyT) {
                                b[y * w + x] = 1
                            }
                        }
                    }
                }
            }
        }
        return binary
    }

    // MARK: - 3. Connected components (4-connectivity flood fill)

    private struct Component { let cx: Double; let cy: Double; let w: Int; let h: Int; let area: Int }

    private func connectedComponents(_ binary: [UInt8], width: Int, height: Int) -> [Component] {
        let w = width, h = height
        var labels = [Int32](repeating: 0, count: w * h) // 0 = unlabeled
        var comps: [Component] = []
        var stack: [Int] = []
        let maxArea = (w * h) / 6     // skip implausibly large merged blobs
        let minArea = 4

        binary.withUnsafeBufferPointer { bin in
            labels.withUnsafeMutableBufferPointer { lab in
                var nextLabel: Int32 = 1
                for start in 0..<(w * h) where bin[start] == 1 && lab[start] == 0 {
                    stack.removeAll(keepingCapacity: true)
                    stack.append(start)
                    lab[start] = nextLabel
                    var minX = w, maxX = 0, minY = h, maxY = 0, area = 0
                    var sumX = 0, sumY = 0
                    while let p = stack.popLast() {
                        let px = p % w, py = p / w
                        area += 1; sumX += px; sumY += py
                        if px < minX { minX = px }; if px > maxX { maxX = px }
                        if py < minY { minY = py }; if py > maxY { maxY = py }
                        if area > maxArea { break }
                        // 4-neighbors
                        if px > 0, bin[p - 1] == 1, lab[p - 1] == 0 { lab[p - 1] = nextLabel; stack.append(p - 1) }
                        if px < w - 1, bin[p + 1] == 1, lab[p + 1] == 0 { lab[p + 1] = nextLabel; stack.append(p + 1) }
                        if py > 0, bin[p - w] == 1, lab[p - w] == 0 { lab[p - w] = nextLabel; stack.append(p - w) }
                        if py < h - 1, bin[p + w] == 1, lab[p + w] == 0 { lab[p + w] = nextLabel; stack.append(p + w) }
                    }
                    nextLabel += 1
                    if area >= minArea && area <= maxArea {
                        comps.append(Component(cx: Double(sumX) / Double(area),
                                               cy: Double(sumY) / Double(area),
                                               w: maxX - minX + 1, h: maxY - minY + 1, area: area))
                    }
                }
            }
        }
        return comps
    }

    // MARK: - 4. Bullseye verification + triangle selection

    private func sample(_ binary: [UInt8], width: Int, height: Int, x: Double, y: Double) -> Bool {
        let xi = Int(x.rounded()), yi = Int(y.rounded())
        guard xi >= 0, xi < width, yi >= 0, yi < height else { return false }
        return binary[yi * width + xi] == 1
    }

    /// A pin is a bullseye: dark center → light gap → dark ring → light
    /// outside, radially symmetric. Verify across several rays; data-module
    /// arcs (elongated, not radially symmetric) fail this.
    private func isBullseye(_ binary: [UInt8], width: Int, height: Int,
                            cx: Double, cy: Double, approxRadius: Double) -> Bool {
        guard sample(binary, width: width, height: height, x: cx, y: cy) else { return false }
        let rays = 12
        let maxR = approxRadius * 2.6
        var good = 0
        for k in 0..<rays {
            let ang = Double(k) / Double(rays) * 2 * .pi
            let dx = cos(ang), dy = sin(ang)
            // record on/off transitions along the ray
            var transitions: [(dark: Bool, r: Double)] = []
            var prev = true // center is dark
            transitions.append((true, 0))
            var r = 1.0
            while r <= maxR {
                let dark = sample(binary, width: width, height: height, x: cx + dx * r, y: cy + dy * r)
                if dark != prev { transitions.append((dark, r)); prev = dark }
                r += 1
            }
            // Expect pattern starting dark, then ≥1 light, then dark, then light:
            // [dark, light, dark, light...]. Accept if the first four alternate
            // as dark,light,dark,light within maxR.
            if transitions.count >= 4,
               transitions[0].dark, !transitions[1].dark,
               transitions[2].dark, !transitions[3].dark {
                good += 1
            }
        }
        return Double(good) / Double(rays) >= 0.6
    }

    private struct Pin { let x: Double; let y: Double; let r: Double }

    /// Among verified bullseyes, pick the 3 that best form an equilateral
    /// triangle (the finder pins sit at 0/120/240°, so pairwise distances
    /// are equal). Brute force over a small candidate set.
    private func pickPinTriangle(_ comps: [Component]) -> [Pin]? {
        let pins = comps.map { Pin(x: $0.cx, y: $0.cy, r: Double(max($0.w, $0.h)) / 2) }
        guard pins.count >= 3 else { return nil }
        // Cap the search to the largest ~10 to bound O(n³).
        let pool = Array(pins.sorted { $0.r > $1.r }.prefix(10))
        var best: [Pin]?
        var bestScore = Double.greatestFiniteMagnitude
        for i in 0..<pool.count {
            for j in (i + 1)..<pool.count {
                for k in (j + 1)..<pool.count {
                    let a = pool[i], b = pool[j], c = pool[k]
                    let d1 = dist(a, b), d2 = dist(b, c), d3 = dist(c, a)
                    let mean = (d1 + d2 + d3) / 3
                    guard mean > 1 else { continue }
                    // equilateral-ness: normalized spread of the three sides
                    let spread = (abs(d1 - mean) + abs(d2 - mean) + abs(d3 - mean)) / mean
                    // similar pin radii too
                    let rMean = (a.r + b.r + c.r) / 3
                    let rSpread = (abs(a.r - rMean) + abs(b.r - rMean) + abs(c.r - rMean)) / max(1, rMean)
                    let score = spread + 0.5 * rSpread
                    if spread < 0.18 && score < bestScore { bestScore = score; best = [a, b, c] }
                }
            }
        }
        return best
    }

    private func dist(_ a: Pin, _ b: Pin) -> Double { hypot(a.x - b.x, a.y - b.y) }

    // MARK: - 5. Order pins (north + clockwise) and affine solve

    /// Returns pins in symbol order: [north(0°), 120°, 240°]. North is the pin
    /// with the most transitions in the annulus just outside it (dashed collar).
    private func orderPins(_ pins: [Pin], binary: [UInt8], width: Int, height: Int) -> [Pin]? {
        guard pins.count == 3 else { return nil }
        // Estimate symbol→image scale from mean pin spacing (equilateral side).
        let spacing = (dist(pins[0], pins[1]) + dist(pins[1], pins[2]) + dist(pins[2], pins[0])) / 3
        let scale = spacing / G.symbolSpacing
        let collarR = G.collarR * scale   // north's dashed collar radius, in image px

        func collarTransitions(_ p: Pin) -> Int {
            let steps = 48
            var prev = sample(binary, width: width, height: height,
                              x: p.x + collarR, y: p.y)
            var t = 0
            for s in 1...steps {
                let ang = Double(s) / Double(steps) * 2 * .pi
                let dark = sample(binary, width: width, height: height,
                                  x: p.x + cos(ang) * collarR, y: p.y + sin(ang) * collarR)
                if dark != prev { t += 1; prev = dark }
            }
            return t
        }

        let north = pins.max { collarTransitions($0) < collarTransitions($1) }!
        let others = pins.filter { $0.x != north.x || $0.y != north.y }
        guard others.count == 2 else { return nil }

        // Order the other two clockwise from north around the centroid.
        let cx = (pins[0].x + pins[1].x + pins[2].x) / 3
        let cy = (pins[0].y + pins[1].y + pins[2].y) / 3
        func ang(_ p: Pin) -> Double {
            var a = atan2(p.y - cy, p.x - cx) // y-down: increasing = clockwise
            if a < 0 { a += 2 * .pi }
            return a
        }
        let nA = ang(north)
        let sorted = others.sorted { rel($0, nA) < rel($1, nA) }
        return [north, sorted[0], sorted[1]]

        func rel(_ p: Pin, _ base: Double) -> Double {
            var d = ang(p) - base
            if d < 0 { d += 2 * .pi }
            return d
        }
    }

    /// Affine A (2×2) + t mapping symbol space → image, from 3 correspondences.
    private struct Affine { let a: simd_double2x2; let t: SIMD2<Double> }

    private func symbolPin(_ index: Int) -> SIMD2<Double> {
        // north 0°, then 120°, 240° — matches orderPins output.
        let deg = G.finderDegs[index]
        return pol(G.finderR, deg)
    }

    private func pol(_ r: Double, _ deg: Double) -> SIMD2<Double> {
        let a = (deg - 90) * .pi / 180
        return SIMD2<Double>(Self.center.x + r * cos(a), Self.center.y + r * sin(a))
    }

    private func solveAffine(_ ordered: [Pin]) -> Affine? {
        // Solve for A,t such that  dst_i = A·src_i + t,  i=0,1,2.
        // Subtract pin0 to eliminate t: (dst_i - dst_0) = A·(src_i - src_0).
        let s0 = symbolPin(0), s1 = symbolPin(1), s2 = symbolPin(2)
        let d0 = SIMD2<Double>(ordered[0].x, ordered[0].y)
        let d1 = SIMD2<Double>(ordered[1].x, ordered[1].y)
        let d2 = SIMD2<Double>(ordered[2].x, ordered[2].y)
        // S = [s1-s0, s2-s0] (columns), D = [d1-d0, d2-d0]; A = D · S⁻¹.
        let S = simd_double2x2(columns: (s1 - s0, s2 - s0))
        let D = simd_double2x2(columns: (d1 - d0, d2 - d0))
        let det = S.columns.0.x * S.columns.1.y - S.columns.1.x * S.columns.0.y
        guard abs(det) > 1e-6 else { return nil }
        let A = D * S.inverse
        let t = d0 - A * s0
        return Affine(a: A, t: t)
    }

    // MARK: - 6. Sample modules

    private func sampleModules(_ binary: [UInt8], width: Int, height: Int, affine: Affine) -> [Bool] {
        var bits: [Bool] = []
        bits.reserveCapacity(156)
        for ring in 0..<G.dataCounts.count {
            let n = G.dataCounts[ring]
            let radius = G.dataRadii[ring]
            let step = 360.0 / Double(n)
            for i in 0..<n {
                let deg = (Double(i) + 0.5) * step
                let sp = pol(radius, deg)                 // symbol-space module center
                let ip = affine.a * sp + affine.t         // → image
                // Average a small disc (~¼ module) for noise immunity.
                bits.append(sampleDisc(binary, width: width, height: height,
                                       x: ip.x, y: ip.y, radius: 1.5))
            }
        }
        return bits
    }

    private func sampleDisc(_ binary: [UInt8], width: Int, height: Int,
                            x: Double, y: Double, radius: Double) -> Bool {
        var dark = 0, total = 0
        let r = Int(radius.rounded())
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r * r {
                let xi = Int(x.rounded()) + dx, yi = Int(y.rounded()) + dy
                if xi >= 0, xi < width, yi >= 0, yi < height {
                    total += 1
                    if binary[yi * width + xi] == 1 { dark += 1 }
                }
            }
        }
        return total > 0 && Double(dark) / Double(total) >= 0.5
    }

    private func log(_ msg: @autoclosure () -> String) {
        guard debugLogging else { return }
        dlog("[WanderyDetector] \(msg())")
    }
}
