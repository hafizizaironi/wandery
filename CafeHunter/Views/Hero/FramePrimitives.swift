import SwiftUI

// Shared primitives for the feed-card "skin" frames (Film Strip, Holo, Star
// Pass, Par Avion). Trimmed from the retired `FreshFrames/FrameKit.swift` — the
// demo model (`FramePost`/`FrameImage`/`FramePhoto`) and the shelf gallery were
// deleted once each design was ported to a self-contained `…FeedFrame` over real
// post media. Only the colour/font/shape helpers the live frames reuse remain.
//
// Custom fonts: the mock uses Instrument Serif (display) + Caveat (handwriting);
// `FrameFont` falls back to system serif if they aren't bundled, so nothing breaks.

// MARK: - Color tokens

extension Color {
    /// 0xRRGGBB literal initialiser (distinct overload from the app's
    /// `Color(hex: String)`), used by the frame palettes below.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Palette shared across the skin frames (mirrors the design mock's hex values).
enum FramePalette {
    // Star Pass ticket
    static let gold       = Color(hex: 0xF0CD84)
    static let nightTop   = Color(hex: 0x34245F)
    static let nightMid   = Color(hex: 0x1D1442)
    static let nightDeep  = Color(hex: 0x100B2A)
    static let cardInk    = Color(hex: 0xF8F1E2)

    // 35mm film
    static let celluloid  = Color(hex: 0x181511)
    static let sprocket   = Color(hex: 0xD9CCB0)
    static let edgePrint  = Color(hex: 0xFFB733)

    // Par-Avion postcard
    static let airRed     = Color(hex: 0xC8443E)
    static let airBlue    = Color(hex: 0x2F5B86)
    static let paper      = Color(hex: 0xFCF5E8)
    static let inkBrown   = Color(hex: 0x3A2C22)
    static let noteRed    = Color(hex: 0xB23F44)
}

// MARK: - Fonts

enum FrameFont {
    /// Instrument Serif (display). Falls back to system serif if unbundled.
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let base = Font.custom("InstrumentSerif-Regular", size: size)
        return italic ? base.italic() : base
    }
    /// Caveat (handwriting). Falls back to system serif if unbundled.
    static func script(_ size: CGFloat) -> Font {
        Font.custom("Caveat-Regular", size: size)
    }
    /// System monospaced — serials, edge print, locations.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Shapes

/// Four-point sparkle / star (Holo rarity pips, Star Pass stars).
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * w, y: rect.minY + y / 24 * h)
        }
        var path = Path()
        path.move(to: p(12, 0))
        path.addCurve(to: p(24, 12), control1: p(12.8, 7), control2: p(17, 11.2))
        path.addCurve(to: p(12, 24), control1: p(17, 12.8), control2: p(12.8, 17))
        path.addCurve(to: p(0, 12),  control1: p(11.2, 17), control2: p(7, 12.8))
        path.addCurve(to: p(12, 0),  control1: p(7, 11.2),  control2: p(11.2, 7))
        path.closeSubpath()
        return path
    }
}

/// Heart (Par Avion stamp + note).
struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 32 * w, y: rect.minY + y / 29 * h)
        }
        var path = Path()
        path.move(to: p(16, 29))
        path.addCurve(to: p(1, 9.5),  control1: p(16, 29),   control2: p(1, 19))
        path.addCurve(to: p(9.5, 1),  control1: p(1, 4.8),    control2: p(4.8, 1))
        path.addCurve(to: p(16, 4.8), control1: p(12.3, 1),   control2: p(14.8, 2.5))
        path.addCurve(to: p(22.5, 1), control1: p(17.2, 2.5), control2: p(19.7, 1))
        path.addCurve(to: p(31, 9.5), control1: p(27.2, 1),   control2: p(31, 4.8))
        path.addCurve(to: p(16, 29),  control1: p(31, 19),    control2: p(16, 29))
        path.closeSubpath()
        return path
    }
}

/// Ticket outline: a rounded rect with two semicircular notches bitten out of
/// the left/right edges at `notchY`, so the perforation reads as a real cut on
/// any background (Star Pass).
struct TicketShape: Shape {
    var cornerRadius: CGFloat = 22
    var notchY: CGFloat
    var notchRadius: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius)
        path.addEllipse(in: CGRect(x: rect.minX - notchRadius,
                                   y: notchY - notchRadius,
                                   width: notchRadius * 2, height: notchRadius * 2))
        path.addEllipse(in: CGRect(x: rect.maxX - notchRadius,
                                   y: notchY - notchRadius,
                                   width: notchRadius * 2, height: notchRadius * 2))
        return path
    }
}

/// A single horizontal rule (Star Pass perforation dash line).
struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Reusable views

/// A twinkling sparkle that pulses opacity + scale forever (Star Pass).
struct TwinkleSparkle: View {
    var size: CGFloat
    var delay: Double
    var period: Double
    @State private var on = false

    var body: some View {
        SparkleShape()
            .fill(FramePalette.gold)
            .frame(width: size, height: size)
            .opacity(on ? 1 : 0.25)
            .scaleEffect(on ? 1.1 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true).delay(delay)) {
                    on = true
                }
            }
    }
}
