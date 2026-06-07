// Auto-generated — byte-exact embed of the validated Wandery Code codec.
// Source of truth: design_handoff_wandery_code/reference/wandery-code-codec.js
// DO NOT EDIT BY HAND. Regenerate from the source if the codec spec changes.
//
// Run verbatim via JavaScriptCore (see WanderyCodec.swift) so the bit/byte
// layout, RS params, CRC, mask and module order stay identical to the spec.

let wanderyCodecJS = #"""
/* ============================================================
 * wandery-code-codec.js  —  THE SOURCE OF TRUTH
 * ------------------------------------------------------------
 * Framework-agnostic. No dependencies. Works in browser, Node,
 * or a sandbox. UMD-style global attach + CommonJS export.
 *
 * Turns a Wandery account id into the exact 156-module bitmap a
 * Wandery Code carries, and decodes a sampled bitmap back into an
 * id — with Reed–Solomon error correction (RS(19,7), up to 6
 * corrupted bytes ≈ 31% of the symbol) and a CRC-8 integrity gate.
 *
 * Pipeline (encode):
 *   version(4b) | userID(44b)            -> 6 header bytes
 *   + CRC-8 over the header              -> 7 data bytes
 *   RS(19,7) over GF(2^8), prim 0x11D    -> 19 codeword bytes
 *   XOR fixed balancing mask             -> 19 masked bytes
 *   152 bits MSB-first + 4 pad(0)        -> 156 module bits
 *   laid clockwise from north, ring2->5  -> module bitmap
 *
 * Decode reverses it and returns {ok, version, userID, byteErrors}.
 * ============================================================ */
(function (root, factory) {
  const mod = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = mod;
  root.WanderyCodec = mod;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  // ---- GF(2^8) with primitive polynomial 0x11D, generator α=2 ----
  const PRIM = 0x11d;
  const EXP = new Uint8Array(512);
  const LOG = new Uint8Array(256);
  (function initTables() {
    let x = 1;
    for (let i = 0; i < 255; i++) {
      EXP[i] = x; LOG[x] = i;
      x <<= 1; if (x & 0x100) x ^= PRIM;
    }
    for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
  })();
  const gmul = (a, b) => (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]];
  const gdiv = (a, b) => (a === 0) ? 0 : EXP[(LOG[a] + 255 - LOG[b]) % 255];
  const ginv = (a) => EXP[255 - LOG[a]];
  const gpow = (a, n) => { let e = (LOG[a] * n) % 255; if (e < 0) e += 255; return EXP[e]; };

  // ---- polynomial helpers (big-endian coefficient arrays) ----
  const polyScale = (p, x) => p.map((c) => gmul(c, x));
  function polyAdd(p, q) {
    const r = new Array(Math.max(p.length, q.length)).fill(0);
    for (let i = 0; i < p.length; i++) r[i + r.length - p.length] = p[i];
    for (let i = 0; i < q.length; i++) r[i + r.length - q.length] ^= q[i];
    return r;
  }
  function polyMul(p, q) {
    const r = new Array(p.length + q.length - 1).fill(0);
    for (let j = 0; j < q.length; j++)
      for (let i = 0; i < p.length; i++)
        r[i + j] ^= gmul(p[i], q[j]);
    return r;
  }
  function polyEval(p, x) {
    let y = p[0];
    for (let i = 1; i < p.length; i++) y = gmul(y, x) ^ p[i];
    return y;
  }

  // ---- Reed–Solomon ----
  function rsGeneratorPoly(nsym) {
    let g = [1];
    for (let i = 0; i < nsym; i++) g = polyMul(g, [1, gpow(2, i)]);
    return g;
  }
  function rsEncode(msg, nsym) {
    const gen = rsGeneratorPoly(nsym);
    const out = new Uint8Array(msg.length + nsym);
    out.set(msg, 0);
    for (let i = 0; i < msg.length; i++) {
      const coef = out[i];
      if (coef !== 0) for (let j = 1; j < gen.length; j++) out[i + j] ^= gmul(gen[j], coef);
    }
    out.set(msg, 0); // restore message; parity already sits in the tail
    return out;
  }
  function rsSyndromes(msg, nsym) {
    const s = [0];
    for (let i = 0; i < nsym; i++) s.push(polyEval(msg, gpow(2, i)));
    return s;
  }
  function rsErrorLocator(synd, nsym) {
    let errLoc = [1], oldLoc = [1];
    for (let i = 0; i < nsym; i++) {
      const K = i + 1;
      let delta = synd[K];
      for (let j = 1; j < errLoc.length; j++)
        delta ^= gmul(errLoc[errLoc.length - 1 - j], synd[K - j]);
      oldLoc = oldLoc.concat([0]);
      if (delta !== 0) {
        if (oldLoc.length > errLoc.length) {
          const newLoc = polyScale(oldLoc, delta);
          oldLoc = polyScale(errLoc, ginv(delta));
          errLoc = newLoc;
        }
        errLoc = polyAdd(errLoc, polyScale(oldLoc, delta));
      }
    }
    while (errLoc.length && errLoc[0] === 0) errLoc.shift();
    return errLoc;
  }
  function rsErrorPositions(errLoc, nmess) {
    const errs = errLoc.length - 1;
    const pos = [];
    // Chien search: roots sit at α^{-power}. Evaluate Λ at α^{-i};
    // a zero means an error in the coefficient of x^i, i.e. message
    // index nmess-1-i (the codeword is most-significant-first).
    for (let i = 0; i < nmess; i++)
      if (polyEval(errLoc, gpow(2, -i)) === 0) pos.push(nmess - 1 - i);
    return pos.length === errs ? pos : null;
  }
  function rsErrataLocator(coefPos) {
    let e = [1];
    for (const p of coefPos) e = polyMul(e, polyAdd([1], [gpow(2, p), 0]));
    return e;
  }
  function rsErrorEvaluator(synd, errLoc, nsym) {
    let r = polyMul(synd, errLoc);
    r = r.slice(r.length - (nsym + 1));
    return r;
  }
  function rsCorrect(msg, synd, errPos) {
    const coefPos = errPos.map((p) => msg.length - 1 - p);
    const errLoc = rsErrataLocator(coefPos);
    const syndRev = synd.slice().reverse();
    let errEval = rsErrorEvaluator(syndRev, errLoc, errLoc.length - 1);
    errEval = errEval.slice().reverse();

    const X = coefPos.map((cp) => gpow(2, cp - 255 + 255)); // = α^{cp}
    // Forney
    const E = new Uint8Array(msg.length);
    for (let i = 0; i < X.length; i++) {
      const Xi = gpow(2, coefPos[i]);
      const XiInv = ginv(Xi);
      let prime = 1;
      for (let j = 0; j < X.length; j++) {
        if (j !== i) {
          const Xj = gpow(2, coefPos[j]);
          prime = gmul(prime, 1 ^ gmul(XiInv, Xj));
        }
      }
      let y = polyEval(errEval.slice().reverse(), XiInv);
      y = gmul(Xi, y);
      if (prime === 0) return null;
      E[errPos[i]] = gdiv(y, prime);
    }
    const out = new Uint8Array(msg.length);
    for (let i = 0; i < msg.length; i++) out[i] = msg[i] ^ E[i];
    return out;
  }
  function rsDecode(codeword, nsym) {
    const msg = Uint8Array.from(codeword);
    const synd = rsSyndromes(msg, nsym);
    if (synd.slice(1).every((s) => s === 0)) return { data: msg, byteErrors: 0 };
    const errLoc = rsErrorLocator(synd, nsym);
    if (errLoc.length - 1 > nsym / 2) return null; // beyond capacity
    const pos = rsErrorPositions(errLoc, msg.length);
    if (!pos) return null;
    const fixed = rsCorrect(msg, synd, pos);
    if (!fixed) return null;
    // verify the fix actually clears the syndromes
    const check = rsSyndromes(fixed, nsym);
    if (!check.slice(1).every((s) => s === 0)) return null;
    return { data: fixed, byteErrors: pos.length };
  }

  // ---- CRC-8 (poly 0x07, init 0x00) ----
  function crc8(bytes) {
    let c = 0;
    for (const b of bytes) {
      c ^= b;
      for (let i = 0; i < 8; i++) c = (c & 0x80) ? ((c << 1) ^ 0x07) & 0xff : (c << 1) & 0xff;
    }
    return c & 0xff;
  }

  // ---- fixed balancing mask (v0). XOR is its own inverse. ----
  // Version-dependent masking is deferred until a future symbol
  // version signals itself in an unmasked format marker.
  function maskStream(n) {
    const out = new Uint8Array(n);
    let s = 0x57;
    for (let i = 0; i < n; i++) { s = (s * 109 + 59) & 0xff; out[i] = s ^ ((i * 27) & 0xff); }
    return out;
  }
  function applyMask(bytes) {
    const m = maskStream(bytes.length);
    return bytes.map((b, i) => b ^ m[i]);
  }

  // ---- geometry constants (must match the renderer & spec) ----
  const NSYM = 12;                 // RS parity bytes  -> RS(19,7)
  const DATA_BYTES = 7;            // version+userID(6) + crc8(1)
  const CODEWORD_BYTES = DATA_BYTES + NSYM; // 19
  const DATA_RINGS = [             // read order: inner -> outer
    { id: "d2", modules: 30 },
    { id: "d3", modules: 36 },
    { id: "d4", modules: 42 },
    { id: "d5", modules: 48 },
  ];
  const TIMING_MODULES = 24;
  const TOTAL_DATA_MODULES = DATA_RINGS.reduce((a, r) => a + r.modules, 0); // 156
  const PAYLOAD_BITS = CODEWORD_BYTES * 8; // 152
  const PAD_MODULES = TOTAL_DATA_MODULES - PAYLOAD_BITS; // 4

  const MASK44 = (1n << 44n) - 1n;

  // ---- bit helpers ----
  function bytesToBits(bytes) {
    const bits = [];
    for (const b of bytes) for (let i = 7; i >= 0; i--) bits.push((b >> i) & 1);
    return bits;
  }
  function bitsToBytes(bits) {
    const out = new Uint8Array(bits.length >> 3);
    for (let i = 0; i < out.length; i++) {
      let b = 0;
      for (let j = 0; j < 8; j++) b = (b << 1) | (bits[i * 8 + j] & 1);
      out[i] = b;
    }
    return out;
  }

  // ====================================================
  //  ENCODE
  // ====================================================
  function packHeader(version, userID) {
    const v = ((BigInt(version) & 0xfn) << 44n) | (BigInt(userID) & MASK44);
    const bytes = new Uint8Array(6);
    let n = v;
    for (let i = 5; i >= 0; i--) { bytes[i] = Number(n & 0xffn); n >>= 8n; }
    return bytes;
  }
  function unpackHeader(bytes) {
    let v = 0n;
    for (let i = 0; i < 6; i++) v = (v << 8n) | BigInt(bytes[i]);
    return { version: Number((v >> 44n) & 0xfn), userID: (v & MASK44) };
  }

  /** account id (Number|BigInt, < 2^44) + version -> 19 masked codeword bytes */
  function encodeBytes(userID, version = 0) {
    const header = packHeader(version, userID);
    const data = new Uint8Array(DATA_BYTES);
    data.set(header, 0);
    data[6] = crc8(header);
    const codeword = rsEncode(data, NSYM); // 19 bytes
    return applyMask(codeword);
  }

  /** -> { bits:[156], rings:[{id,modules:[...]}], timing:[24], meta } */
  function encodeModules(userID, version = 0) {
    const masked = encodeBytes(userID, version);
    let bits = bytesToBits(masked);                 // 152
    bits = bits.concat(new Array(PAD_MODULES).fill(0)); // -> 156
    const rings = [];
    let c = 0;
    for (const r of DATA_RINGS) {
      rings.push({ id: r.id, modules: bits.slice(c, c + r.modules) });
      c += r.modules;
    }
    const timing = Array.from({ length: TIMING_MODULES }, (_, i) => i % 2 === 0 ? 1 : 0);
    return {
      bits, rings, timing,
      meta: { version, userID: BigInt(userID).toString(), totalModules: TOTAL_DATA_MODULES },
    };
  }

  // ====================================================
  //  DECODE
  // ====================================================
  /** 156 sampled module bits (north, CW, ring2->5) -> {ok,...} */
  function decodeModules(moduleBits) {
    if (!moduleBits || moduleBits.length < PAYLOAD_BITS)
      return { ok: false, reason: "too few modules" };
    const payload = moduleBits.slice(0, PAYLOAD_BITS); // drop 4 pad
    const masked = bitsToBytes(payload);               // 19 bytes
    const codeword = applyMask(Array.from(masked));     // unmask (XOR)
    const dec = rsDecode(codeword, NSYM);
    if (!dec) return { ok: false, reason: "uncorrectable (RS)" };
    const data = dec.data;
    const header = data.slice(0, 6);
    if (crc8(header) !== data[6]) return { ok: false, reason: "crc mismatch" };
    const { version, userID } = unpackHeader(header);
    return { ok: true, version, userID, byteErrors: dec.byteErrors };
  }

  return {
    // high level
    encodeModules, decodeModules, encodeBytes,
    // mid level (handy for tests / detectors)
    packHeader, unpackHeader, crc8, applyMask,
    rsEncode, rsDecode, bytesToBits, bitsToBytes,
    // internals (exposed for detector implementations & tests)
    rsSyndromes, rsErrorLocator, rsErrorPositions, rsCorrect, polyEval, rsGeneratorPoly,
    // constants
    NSYM, DATA_BYTES, CODEWORD_BYTES, DATA_RINGS, TIMING_MODULES,
    TOTAL_DATA_MODULES, PAYLOAD_BITS, PAD_MODULES, MASK44,
    gf: { gmul, gdiv, ginv, gpow, EXP, LOG },
  };
});
"""#
