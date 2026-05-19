import Foundation
import FirebaseFirestore

enum PlaceType: String, Codable, CaseIterable {
    case cafe
    case stall
    case restaurant

    var emoji: String {
        switch self {
        case .cafe: return "☕"
        case .stall: return "🍜"
        case .restaurant: return "🍽️"
        }
    }

    var label: String {
        switch self {
        case .cafe: return "Café"
        case .stall: return "Street Stall"
        case .restaurant: return "Restaurant"
        }
    }
}

struct Cafe: Identifiable, Codable {
    @DocumentID var id: String?
    var slug: String = ""
    var name: String = ""
    var neighborhood: String = ""
    var type: PlaceType = .cafe
    var lat: Double = 0
    var lng: Double = 0
    var tagline: String = ""
    var hours: String = ""
    var vibeTags: [String] = []
    var description: String = ""
    var photos: [String] = []
}

/// Slim place record created on-demand from a tagged post.
/// Distinct from `Cafe` (the legacy admin-curated record) — `Place` is what
/// the close-friends map is built on. Deduped server-side via geohash + name.
struct Place: Identifiable, Codable {
    @DocumentID var id: String?
    var name: String = ""
    var type: PlaceType = .restaurant
    var lat: Double = 0
    var lng: Double = 0
    var geohash: String = ""
    /// "google" when imported from Google Places, "user" when added manually.
    var source: String = "google"
    /// Google Places place_id, when available — used for dedup.
    var googlePlaceId: String?
    var globalVisitCount: Int = 0
    /// Total reactions + replies on tagged posts at this place. Aggregated
    /// server-side by `onReactionEngagement` / `onReplyEngagement`.
    var globalEngagementCount: Int = 0
    var lastVisitedAt: Date?
    var createdAt: Date?
}

struct CafeFormData {
    var type: PlaceType = .cafe
    var name: String = ""
    var slug: String = ""
    var tagline: String = ""
    var neighborhood: String = ""
    var hours: String = ""
    var description: String = ""
    var vibeTags: [String] = []
    var lat: Double = 0
    var lng: Double = 0

    mutating func generateSlug() {
        slug = name
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
