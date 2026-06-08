import Foundation
import JavaScriptCore

/// Swift bridge to the validated Wandery Code codec (`wandery-code-codec.js`,
/// embedded verbatim in `WanderyCodecJS.swift`). The JS is the byte/bit
/// source of truth; running it through JavaScriptCore guarantees the
/// encoded/decoded layout is identical to the design spec with zero porting
/// risk.
///
/// A 44-bit opaque account id ⇄ a 156-module bitmap (4 data rings of
/// 30/36/42/48), with RS(19,7) error correction + a CRC-8 integrity gate.
///
/// NOT thread-safe: a `JSContext` must be used from a single thread/queue at
/// a time. Create one instance per consumer — the detector owns one on its
/// serial analysis queue; UI/rendering uses a separate main-thread instance.
final class WanderyCodec {

    /// Module layout, in canonical order (north, clockwise, inner→outer).
    struct Encoded {
        /// All 156 data-module bits, concatenated inner→outer.
        let bits: [Bool]
        /// Data rings split out: [30, 36, 42, 48] modules, inner→outer.
        let rings: [[Bool]]
        /// The 24-module timing ring (alternating, non-data).
        let timing: [Bool]
    }

    struct Decoded {
        let version: Int
        let accountId: UInt64
        /// Number of bytes the Reed–Solomon stage had to correct (0 = clean).
        let byteErrors: Int
    }

    private let context: JSContext
    private let encodeFn: JSValue
    private let decodeFn: JSValue

    init?() {
        guard let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, err in
            dlog("[WanderyCodec] JS exception: \(err?.toString() ?? "unknown")")
        }
        ctx.evaluateScript(wanderyCodecJS)

        // Thin shims over the codec:
        //  • wcDecodeJSON returns a JSON string so the BigInt `userID` crosses
        //    the bridge as a decimal string (JSC BigInt marshaling is unreliable).
        //  • wcEncodeBits flattens the ring objects to plain bit arrays.
        ctx.evaluateScript(#"""
        function wcDecodeJSON(bits) {
          var r = WanderyCodec.decodeModules(bits);
          if (!r || !r.ok) return JSON.stringify({ ok: false });
          return JSON.stringify({
            ok: true, version: r.version,
            userID: r.userID.toString(), byteErrors: r.byteErrors
          });
        }
        function wcEncodeBits(userID, version) {
          var m = WanderyCodec.encodeModules(userID, version);
          return {
            bits: m.bits,
            timing: m.timing,
            rings: m.rings.map(function (x) { return x.modules; })
          };
        }
        """#)

        guard let enc = ctx.objectForKeyedSubscript("wcEncodeBits"), !enc.isUndefined,
              let dec = ctx.objectForKeyedSubscript("wcDecodeJSON"), !dec.isUndefined else {
            return nil
        }
        self.context = ctx
        self.encodeFn = enc
        self.decodeFn = dec
    }

    // MARK: - Encode

    /// account id (< 2⁴⁴, so it round-trips exactly through a JS Number) +
    /// version → the module bitmap. Returns nil only on a bridge failure.
    func encode(accountId: UInt64, version: Int = 0) -> Encoded? {
        guard let result = encodeFn.call(withArguments: [NSNumber(value: accountId),
                                                         NSNumber(value: version)]),
              let dict = result.toDictionary(),
              let bitsArr = dict["bits"] as? [Any],
              let timingArr = dict["timing"] as? [Any],
              let ringsArr = dict["rings"] as? [Any] else { return nil }

        let bits = bitsArr.map { ($0 as? NSNumber)?.intValue == 1 }
        let timing = timingArr.map { ($0 as? NSNumber)?.intValue == 1 }
        let rings: [[Bool]] = ringsArr.map { ring in
            (ring as? [Any])?.map { ($0 as? NSNumber)?.intValue == 1 } ?? []
        }
        return Encoded(bits: bits, rings: rings, timing: timing)
    }

    // MARK: - Decode

    /// 156 sampled module bits (north, clockwise, inner→outer) → the account
    /// id, or nil when the symbol can't be read (RS uncorrectable / CRC fail).
    /// A nil result means "not confident" — never surface it as an error.
    func decode(bits: [Bool]) -> Decoded? {
        let jsBits = bits.map { NSNumber(value: $0 ? 1 : 0) }
        guard let json = decodeFn.call(withArguments: [jsBits])?.toString(),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ok"] as? Bool) == true,
              let idStr = obj["userID"] as? String,
              let id = UInt64(idStr) else { return nil }

        let version = (obj["version"] as? NSNumber)?.intValue ?? 0
        let byteErrors = (obj["byteErrors"] as? NSNumber)?.intValue ?? 0
        return Decoded(version: version, accountId: id, byteErrors: byteErrors)
    }

    // MARK: - Self-check

    /// Round-trips the README reference vector (id 12345). Confirms the JS
    /// bridge is correct independently of any computer vision. Logs + returns
    /// the result so the spike can show it on launch.
    @discardableResult
    func selfCheck() -> Bool {
        guard let enc = encode(accountId: 12345),
              enc.bits.count == 156,
              let dec = decode(bits: enc.bits),
              dec.accountId == 12345, dec.version == 0, dec.byteErrors == 0 else {
            dlog("[WanderyCodec] SELF-CHECK FAILED — JS bridge is not producing the reference vector")
            return false
        }
        dlog("[WanderyCodec] self-check OK — encode/decode(12345) round-trips across \(enc.bits.count) modules")
        return true
    }
}
