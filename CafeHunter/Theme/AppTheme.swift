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

// MARK: - App theme

enum AppTheme {
    // Backgrounds
    static let espresso   = Color(red: 0.102, green: 0.059, blue: 0.027) // #1a0f07
    static let stallBg    = Color(red: 0.055, green: 0.118, blue: 0.063) // #0e1e10

    // Accents
    static let cafeAccent = Color(red: 0.769, green: 0.384, blue: 0.176) // #c4622d
    static let stallAccent = Color(red: 0.831, green: 0.584, blue: 0.165) // #d4952a

    // Text
    static let cream      = Color(red: 0.961, green: 0.937, blue: 0.902) // #f5efe6
    static let glassStroke = Color.white.opacity(0.24)

    // Status
    static let successGreen = Color(red: 0.416, green: 0.667, blue: 0.416) // #6aaa6a
    static let errorRed     = Color(red: 0.878, green: 0.361, blue: 0.361)

    // Helpers
    static func accent(for type: PlaceType) -> Color {
        type == .cafe ? cafeAccent : stallAccent
    }

    static func background(for type: PlaceType) -> Color {
        type == .cafe ? espresso : stallBg
    }

    static func cafeGradient(_ index: Int) -> LinearGradient {
        let configs: [(Color, Color)] = [
            (Color(red: 0.102, green: 0.059, blue: 0.027), Color(red: 0.478, green: 0.549, blue: 0.369)),
            (Color(red: 0.176, green: 0.102, blue: 0.055), Color(red: 0.769, green: 0.384, blue: 0.176)),
        ]
        let c = configs[index % configs.count]
        return LinearGradient(colors: [c.0, c.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func stallGradient(_ index: Int) -> LinearGradient {
        let configs: [(Color, Color)] = [
            (Color(red: 0.055, green: 0.118, blue: 0.063), Color(red: 0.416, green: 0.667, blue: 0.416)),
            (Color(red: 0.102, green: 0.208, blue: 0.125), Color(red: 0.831, green: 0.584, blue: 0.165)),
        ]
        let c = configs[index % configs.count]
        return LinearGradient(colors: [c.0, c.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func gradient(for type: PlaceType, index: Int) -> LinearGradient {
        type == .cafe ? cafeGradient(index) : stallGradient(index)
    }
}
