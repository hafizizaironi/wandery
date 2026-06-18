import Foundation

// MARK: - Achievement definition

struct Achievement: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String      // requirement shown when locked
    let flavourText: String   // tagline shown when unlocked
    /// Hidden achievement — rendered as a mystery "???" badge until unlocked.
    var isSecret: Bool = false
    let condition: (UserStats) -> Bool
}

// MARK: - All achievements
//
// IDs are stable — they key the per-user `unlockedAchievements` map in
// Firestore, so renaming an id loses unlock history. Copy/threshold can change
// freely. Conditions read `UserStats` counters (bumped server-side; see
// `functions/index.js`). `anniversary` is special-cased in `achievementIsUnlocked`
// against the account creation date, so its condition is always false here.

extension Achievement {
    static let definitions: [Achievement] = [
        // ── Café ladder ☕ ──
        Achievement(id: "first_brew", icon: "☕", title: "First Sip",
                    subtitle: "Hunt your first café",
                    flavourText: "The hunt begins. One café down, the whole city to chew through. 🔥",
                    condition: { $0.cafesVisited >= 1 }),
        Achievement(id: "cafe_hunter", icon: "☕", title: "Caffeine Scout",
                    subtitle: "Visit 10 cafés",
                    flavourText: "Ten cafés deep and the barista nods when you walk in. Scout status: earned.",
                    condition: { $0.cafesVisited >= 10 }),
        Achievement(id: "cafe_hunter_25", icon: "🫘", title: "Café Connoisseur",
                    subtitle: "Visit 25 cafés",
                    flavourText: "You don't drink coffee — you audit it. 25 cafés of refined obsession.",
                    condition: { $0.cafesVisited >= 25 }),
        Achievement(id: "cafe_hunter_50", icon: "🎩", title: "Espresso Apex",
                    subtitle: "Visit 50 cafés",
                    flavourText: "Fifty cafés conquered. Somewhere, a flat white is afraid of you. 🔥",
                    condition: { $0.cafesVisited >= 50 }),

        // ── Street-stall ladder 🍜 ──
        Achievement(id: "stall_first", icon: "🛵", title: "Stool Pigeon",
                    subtitle: "Visit your first street stall",
                    flavourText: "Plastic stool, big flavour. The best food has no front door. The streets claimed you.",
                    condition: { $0.stallsVisited >= 1 }),
        Achievement(id: "stall_stalker", icon: "🍢", title: "Street Sweeper",
                    subtitle: "Visit 5 street stalls",
                    flavourText: "Five stalls in and you trust the cart with no sign the most. As you should.",
                    condition: { $0.stallsVisited >= 5 }),
        Achievement(id: "stall_stalker_15", icon: "🍜", title: "Hawker Devotee",
                    subtitle: "Visit 15 street stalls",
                    flavourText: "Roaring woks, zero pretension. 15 stalls — this is real devotion. 🔥",
                    condition: { $0.stallsVisited >= 15 }),
        Achievement(id: "stall_stalker_30", icon: "🔥", title: "Alley Oracle",
                    subtitle: "Visit 30 street stalls",
                    flavourText: "30 stalls. You smell the good smoke two blocks away. Oracle confirmed.",
                    condition: { $0.stallsVisited >= 30 }),

        // ── Restaurant ladder 🍽️ ──
        Achievement(id: "restaurant_raider_5", icon: "🍽️", title: "Reservation, Please",
                    subtitle: "Visit 5 restaurants",
                    flavourText: "From curb to candlelight. Five tables claimed by pure curiosity.",
                    condition: { $0.restaurantsVisited >= 5 }),
        Achievement(id: "restaurant_raider_15", icon: "🍴", title: "Reservation Renegade",
                    subtitle: "Visit 15 restaurants",
                    flavourText: "15 restaurants raided. You order the weird thing on purpose now.",
                    condition: { $0.restaurantsVisited >= 15 }),
        Achievement(id: "restaurant_raider_30", icon: "👨‍🍳", title: "Tasting Menu Tyrant",
                    subtitle: "Visit 30 restaurants",
                    flavourText: "Thirty rooms, thirty menus, zero regrets. The chefs talk about you. 🔥",
                    condition: { $0.restaurantsVisited >= 30 }),

        // ── Exploration ladder 🗺️ ──
        Achievement(id: "wanderer", icon: "🗺️", title: "Spot Collector",
                    subtitle: "Visit 10 unique places",
                    flavourText: "Ten down. The map's starting to fill up — and it looks like your diary. 🗺️",
                    condition: { $0.uniquePlacesVisited >= 10 }),
        Achievement(id: "wanderer_50", icon: "🌆", title: "Appetite for the City",
                    subtitle: "Visit 50 unique places",
                    flavourText: "Fifty spots wide. You're not eating in the city — you're eating the city. 🔥",
                    condition: { $0.uniquePlacesVisited >= 50 }),
        Achievement(id: "wanderer_100", icon: "🏆", title: "Apex Hunter",
                    subtitle: "Visit 100 unique places",
                    flavourText: "100 spots. You don't find places anymore — places find you. 🏆",
                    condition: { $0.uniquePlacesVisited >= 100 }),

        // ── Pioneer ladder 🧭 ──
        Achievement(id: "pioneer", icon: "📍", title: "First Footprint",
                    subtitle: "Be first to put a place on the map",
                    flavourText: "You planted the flag. This one's officially yours. The map remembers who got there first. 🔥",
                    condition: { $0.pioneerCount >= 1 }),
        Achievement(id: "pioneer_5", icon: "🚩", title: "Trailblazer",
                    subtitle: "Be first to map 5 places",
                    flavourText: "Five flags planted. You don't follow the hunt — you start it.",
                    condition: { $0.pioneerCount >= 5 }),
        Achievement(id: "pioneer_25", icon: "🧭", title: "The Cartographer",
                    subtitle: "Be first to map 25 places",
                    flavourText: "25 firsts. They should rename a street after you. Built different. 🔥",
                    condition: { $0.pioneerCount >= 25 }),

        // ── Local-turf ladder 🏘️ ──
        Achievement(id: "local_guide", icon: "🏘️", title: "Neighbourhood Hero",
                    subtitle: "Tag 5 places in one neighbourhood",
                    flavourText: "Five spots in one patch. You're learning your turf bite by bite.",
                    condition: { $0.topAreaPlaceCount >= 5 }),
        Achievement(id: "local_guide_20", icon: "👑", title: "Mayor of the Block",
                    subtitle: "Tag 20 places in one neighbourhood",
                    flavourText: "Twenty spots in one zone. This isn't your neighbourhood anymore — it's your kingdom. 👑",
                    condition: { $0.topAreaPlaceCount >= 20 }),
        Achievement(id: "local_guide_40", icon: "🏰", title: "Turf Tyrant",
                    subtitle: "Tag 40 places in one neighbourhood",
                    flavourText: "Forty spots, one patch. Locals should be tipping YOU. 🔥",
                    condition: { $0.topAreaPlaceCount >= 40 }),

        // ── Loyalty ladder 💛 ──
        Achievement(id: "loyal", icon: "☕", title: "The Regular",
                    subtitle: "Return to one spot 3 times",
                    flavourText: "They're starting to know your order. You've got a 'usual' now. ❤️",
                    condition: { $0.topPlaceVisitCount >= 3 }),
        Achievement(id: "loyal_8", icon: "🪑", title: "Your Seat",
                    subtitle: "Return to one spot 8 times",
                    flavourText: "Eight trips back. That corner table is legally yours now. 🪑",
                    condition: { $0.topPlaceVisitCount >= 8 }),
        Achievement(id: "loyal_15", icon: "💍", title: "Ride or Die",
                    subtitle: "Return to one spot 15 times",
                    flavourText: "Fifteen visits to one beloved haunt. That's not a habit, that's a marriage. 🔥",
                    condition: { $0.topPlaceVisitCount >= 15 }),

        // ── Photo ladder 📸 ──
        Achievement(id: "aesthetic_eye", icon: "📸", title: "Snap Happy",
                    subtitle: "Share 10 photos",
                    flavourText: "Ten shots fired into the feed. Your feed eats first, always.",
                    condition: { $0.photosShared >= 10 }),
        Achievement(id: "aesthetic_eye_50", icon: "🖼️", title: "Feed Photographer",
                    subtitle: "Share 50 photos",
                    flavourText: "50 photos in the bag. Certified documenter of delicious. 🔥",
                    condition: { $0.photosShared >= 50 }),

        // ── Video 🎬 ──
        Achievement(id: "the_director", icon: "🎬", title: "Lights, Camera, Hunt",
                    subtitle: "Post 5 videos",
                    flavourText: "Stills are cute. You're out here making cinema. 🎬",
                    condition: { $0.videoPostsCount >= 5 }),
        Achievement(id: "feed_royalty", icon: "🍿", title: "Feed Royalty",
                    subtitle: "Post 20 videos",
                    flavourText: "Twenty videos deep. Photos are for amateurs — you bring the whole experience. 🔥",
                    condition: { $0.videoPostsCount >= 20 }),

        // ── Soundtrack 🎧 ──
        Achievement(id: "now_playing", icon: "🎧", title: "Now Playing",
                    subtitle: "Attach a song to a post",
                    flavourText: "Every great bite has a beat. Press play, hunter — this place just got a soundtrack. 🎶",
                    condition: { $0.musicPostsCount >= 1 }),
        Achievement(id: "the_dj", icon: "🎵", title: "Soundtrack to the Hunt",
                    subtitle: "Attach a song to 20 posts",
                    flavourText: "Twenty spots, twenty tracks. Your feed isn't a map, it's a mixtape. 🔥",
                    condition: { $0.musicPostsCount >= 20 }),

        // ── Odd hours 🌅🌙 ──
        Achievement(id: "dawn_patrol", icon: "🌅", title: "Dawn Patrol",
                    subtitle: "Post 5 times before 8 AM",
                    flavourText: "First light, first brew, first to the table. The early hunter gets the croissant. 🥐",
                    condition: { $0.earlyBirdCount >= 5 }),
        Achievement(id: "night_owl", icon: "🌙", title: "Night Forager",
                    subtitle: "Post after 9 PM",
                    flavourText: "Supper o'clock. While they sleep, you hunt the midnight menu. 🌃",
                    condition: { $0.nightCheckIns >= 1 }),
        Achievement(id: "night_owl_20", icon: "🦉", title: "Last Call Legend",
                    subtitle: "Post 20 times after 9 PM",
                    flavourText: "Twenty midnight feasts deep. The city's nocturnal, and so are you. 🔥",
                    condition: { $0.nightCheckIns >= 20 }),

        // ── Pack / social 🤝 ──
        Achievement(id: "better_together", icon: "🤝", title: "The Plug",
                    subtitle: "Add your first friend",
                    flavourText: "The hunt's better with a partner in crime. Good spots are made for sharing. 🤝",
                    condition: { $0.friendsCount >= 1 }),
        Achievement(id: "squad_10", icon: "👯", title: "Squad Up",
                    subtitle: "Add 10 friends",
                    flavourText: "Ten deep. That's not a friend list, that's a tasting panel.",
                    condition: { $0.friendsCount >= 10 }),
        Achievement(id: "ringleader_30", icon: "🎪", title: "Ringleader",
                    subtitle: "Add 30 friends",
                    flavourText: "You're basically running a supper club now. Every feed runs through you. 👑",
                    condition: { $0.friendsCount >= 30 }),

        // ── Streaks 🔥 ──
        Achievement(id: "streak_3", icon: "🔥", title: "Caught the Fever",
                    subtitle: "Post 3 days in a row",
                    flavourText: "Three days straight. The hunt's got a hold of you. 🔥",
                    condition: { $0.currentStreak >= 3 }),
        Achievement(id: "streak_7", icon: "🔥", title: "Week on Fire",
                    subtitle: "Hit a 7-day streak",
                    flavourText: "Seven straight days. The streak is lit and so are you. Don't break it now. 🔥🔥",
                    condition: { $0.longestStreak >= 7 }),
        Achievement(id: "streak_30", icon: "🌋", title: "Unstoppable",
                    subtitle: "Hit a 30-day streak",
                    flavourText: "Thirty days, zero misses. You're not hunting anymore — you're a force of nature. 🌋",
                    condition: { $0.longestStreak >= 30 }),

        // ── Tastemaker (reactions) 💛 ──
        Achievement(id: "tastemaker", icon: "💛", title: "Crowd Pleaser",
                    subtitle: "Collect 50 reactions",
                    flavourText: "Fifty taps of pure envy. Your feed makes people hungry — the highest honour. 💛",
                    condition: { $0.reactionsReceived >= 50 }),
        Achievement(id: "tastemaker_250", icon: "💅", title: "Certified Iconic",
                    subtitle: "Collect 250 reactions",
                    flavourText: "250 reactions. People don't follow places anymore — they follow YOU. 🌟",
                    condition: { $0.reactionsReceived >= 250 }),

        // ── Combos 🍴 ──
        Achievement(id: "holy_trinity", icon: "🍴", title: "The Holy Trinity",
                    subtitle: "Hunt a café, a stall, AND a restaurant",
                    flavourText: "Espresso, satay, fine dining — all in one appetite. No snob, no skipper. A true eater. 🔥",
                    condition: { s in s.cafesVisited >= 1 && s.stallsVisited >= 1 && s.restaurantsVisited >= 1 }),
        Achievement(id: "trendsetter", icon: "✨", title: "Trendsetter",
                    subtitle: "Map 3 firsts AND collect 25 reactions",
                    flavourText: "You don't follow the hype. You PLANT it, then watch everyone show up. 🌱🔥",
                    condition: { s in s.pioneerCount >= 3 && s.reactionsReceived >= 25 }),

        // ── Secret 🤫 (masked as "???" until unlocked) ──
        Achievement(id: "needle_drop", icon: "💿", title: "Needle Drop",
                    subtitle: "A photo, a place, and the perfect song…",
                    flavourText: "Pic in frame, tune in the air. That's not a post, that's a whole aesthetic. Chef's kiss. 🤌",
                    isSecret: true,
                    condition: { s in s.photosShared >= 1 && s.musicPostsCount >= 1 }),
        Achievement(id: "dawn_and_dusk", icon: "🌗", title: "Dawn & Dusk",
                    subtitle: "Burn the candle at both ends.",
                    flavourText: "Sunrise kopi, midnight char kway teow. You don't keep hours — you keep appetite. 🔥",
                    isSecret: true,
                    condition: { s in s.earlyBirdCount >= 1 && s.nightCheckIns >= 1 }),
        Achievement(id: "main_character", icon: "🌟", title: "Main Character",
                    subtitle: "Fame, range, and a crew all at once…",
                    flavourText: "100 reactions, 10 friends, and 25 places hunted. The protagonist energy is UNREAL. 🎬🔥",
                    isSecret: true,
                    condition: { s in s.reactionsReceived >= 100 && s.friendsCount >= 10 && s.uniquePlacesVisited >= 25 }),
        Achievement(id: "viral_moment", icon: "🚀", title: "Going Viral",
                    subtitle: "Keep posting and watch the love roll in…",
                    flavourText: "One thousand reactions. You didn't go viral, you ARE the algorithm now. 🤯🔥",
                    isSecret: true,
                    condition: { $0.reactionsReceived >= 1000 }),

        // ── Anniversary 🎂 (special date logic in achievementIsUnlocked) ──
        Achievement(id: "anniversary", icon: "🎂", title: "One Year",
                    subtitle: "Good things take time.",
                    flavourText: "365 days on the hunt with us. Same appetite, new chapter. Stay hunting. 🔥",
                    isSecret: true,
                    condition: { _ in false }),
    ]
}
