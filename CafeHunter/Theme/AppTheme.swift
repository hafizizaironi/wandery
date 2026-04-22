import SwiftUI

// MARK: - Hex colour convenience

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red:     Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

// MARK: - App theme (Clay & Ink)

enum AppTheme {

    // MARK: Semantic tokens

    /// Main screen canvas — near-white warm
    static let surfaceCanvas = Color(hex: "#F7F5F2")
    /// Chrome — nav, cards, selected fill (same as accentSecondary)
    static let surfacePrimary = Color(hex: "#EDEBE6")

    /// “Ink” — main text
    static let textPrimary = Color(hex: "#282520")
    static let textSecondary = Color(hex: "#282520").opacity(0.55)

    /// Terracotta — use sparingly: primary CTAs, key chips, nav knob, map pins
    static let accentAction = Color(hex: "#B5523A")
    /// Chrome tone — borders / selected; matches `surfacePrimary`
    static let accentSecondary = Color(hex: "#EDEBE6")

    static let borderSubtle = Color(hex: "#CCCAC3").opacity(0.6)

    /// Stalls — muted sage
    static let stallAccent = Color(hex: "#7A8B6F")

    /// Text on terracotta / `accentAction` buttons
    static let textOnAccent = Color.white

    /// Dark scrim over unpredictable camera preview
    static let cameraScrim = Color.black.opacity(0.5)

    // MARK: Status (unchanged)

    static let successGreen = Color(red: 0.416, green: 0.667, blue: 0.416)
    static let errorRed     = Color(red: 0.878, green: 0.361, blue: 0.361)

    // MARK: Legacy aliases

    static var espresso: Color { surfaceCanvas }
    static var stallBg: Color { stallAccent.opacity(0.08) }
    static var cafeAccent: Color { accentAction }
    static var cream: Color { textPrimary }
    static var glassStroke: Color { borderSubtle }

    // MARK: Place-type helpers

    static func accent(for type: PlaceType) -> Color {
        type == .cafe ? cafeAccent : stallAccent
    }

    /// Fills for type chips — chrome; pair with `accent` stroke, not a saturated fill
    static func background(for type: PlaceType) -> Color {
        surfacePrimary
    }

    static func cafeGradient(_ index: Int) -> LinearGradient {
        let configs: [(Color, Color)] = [
            (Color(hex: "#E3DDD8"), surfaceCanvas),
            (Color(hex: "#D1B4A7"), Color(hex: "#F7F5F2")),
        ]
        let c = configs[index % configs.count]
        return LinearGradient(colors: [c.0, c.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func stallGradient(_ index: Int) -> LinearGradient {
        let configs: [(Color, Color)] = [
            (Color(hex: "#D2D6CD"), surfaceCanvas),
            (Color(hex: "#8F9A85"), Color(hex: "#EEF0EA")),
        ]
        let c = configs[index % configs.count]
        return LinearGradient(colors: [c.0, c.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func gradient(for type: PlaceType, index: Int) -> LinearGradient {
        type == .cafe ? cafeGradient(index) : stallGradient(index)
    }
}
