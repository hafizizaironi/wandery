import Foundation
import FirebaseFirestore

enum PlaceType: String, Codable, CaseIterable {
    case cafe
    case stall

    var emoji: String { self == .cafe ? "☕" : "🍜" }
    var label: String { self == .cafe ? "Café" : "Street Stall" }
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
