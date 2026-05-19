import Foundation

// MARK: - Achievement definition

struct Achievement: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String      // requirement shown when locked
    let flavourText: String   // tagline shown when unlocked
    let condition: (UserStats) -> Bool
}

// MARK: - All achievements

extension Achievement {
    static let definitions: [Achievement] = [
        Achievement(
            id: "first_brew",
            icon: "☕",
            title: "First Brew",
            subtitle: "Check in at your first café",
            flavourText: "The journey begins",
            condition: { $0.cafesVisited >= 1 }
        ),
        Achievement(
            id: "stall_stalker",
            icon: "🍜",
            title: "Stall Stalker",
            subtitle: "Visit 5 street stalls",
            flavourText: "Street food royalty",
            condition: { $0.stallsVisited >= 5 }
        ),
        Achievement(
            id: "aesthetic_eye",
            icon: "📸",
            title: "Aesthetic Eye",
            subtitle: "Share 10 photos",
            flavourText: "Feeding the feed",
            condition: { $0.photosShared >= 10 }
        ),
        Achievement(
            id: "better_together",
            icon: "👥",
            title: "Better Together",
            subtitle: "Go on a hunt with a friend",
            flavourText: "Best moments are shared",
            condition: { $0.friendsHunted >= 1 }
        ),
        Achievement(
            id: "cafe_hunter",
            icon: "🏅",
            title: "Café Hunter",
            subtitle: "Visit 10 cafés",
            flavourText: "Getting serious about the brew",
            condition: { $0.cafesVisited >= 10 }
        ),
        Achievement(
            id: "scout",
            icon: "🗺️",
            title: "Scout",
            subtitle: "Add a new place to the map",
            flavourText: "You found it first",
            condition: { $0.placesAdded >= 1 }
        ),
        Achievement(
            id: "regular",
            icon: "⭐",
            title: "Regular",
            subtitle: "Visit the same spot 3 times",
            flavourText: "They know your order",
            condition: { $0.favoritePlaceVisits >= 3 }
        ),
        Achievement(
            id: "night_owl",
            icon: "🌙",
            title: "Night Owl",
            subtitle: "Check in after 9 PM",
            flavourText: "The best spots stay open late",
            condition: { $0.nightCheckIns >= 1 }
        ),
        Achievement(
            id: "anniversary",
            icon: "🎂",
            title: "One Year",
            subtitle: "Use the app for a full year",
            flavourText: "A whole year of good food",
            condition: { _ in false } // evaluated separately using account creation date
        ),

        // Phase 5 — Discovery achievements. All driven by server-side
        // counters (see functions/index.js):
        //   findOrCreatePlace          → pioneerCount
        //   onPostCreatePlaceVisit     → uniquePlacesVisited / topAreaPlaceCount
        //   onReactionEngagement       → reactionsReceived
        //   onVisitClose               → topPlaceVisitCount
        Achievement(
            id: "pioneer",
            icon: "🧭",
            title: "Pioneer",
            subtitle: "Be the first to put a place on the map",
            flavourText: "You found it first",
            condition: { $0.pioneerCount >= 1 }
        ),
        Achievement(
            id: "wanderer",
            icon: "🌍",
            title: "Wanderer",
            subtitle: "Tag 10 different places",
            flavourText: "Always somewhere new",
            condition: { $0.uniquePlacesVisited >= 10 }
        ),
        Achievement(
            id: "local_guide",
            icon: "🗺️",
            title: "Local Guide",
            subtitle: "Tag 5 places in one neighbourhood",
            flavourText: "You know this corner of the map",
            condition: { $0.topAreaPlaceCount >= 5 }
        ),
        Achievement(
            id: "tastemaker",
            icon: "🌟",
            title: "Tastemaker",
            subtitle: "Earn 50 reactions on your posts",
            flavourText: "People follow your taste",
            condition: { $0.reactionsReceived >= 50 }
        ),
        Achievement(
            id: "loyal",
            icon: "💛",
            title: "Loyal",
            subtitle: "Visit the same spot 3 separate times",
            flavourText: "It's not a phase, it's a regular",
            condition: { $0.topPlaceVisitCount >= 3 }
        ),
    ]
}
