import Foundation

/// Maps the user's audience selections to seeded iTunes search terms so that
/// the "Suggested for this place" list feels contextual — not generic.
///
/// These are intentionally short, high-signal queries. iTunes returns well-
/// known tracks for each, which matches the "what would play here" intent.
enum VibeSuggestionSeeds {

    private static let audienceToQuery: [Audience: String] = [
        .dateNight:    "romantic jazz",
        .familyDinner: "warm acoustic",
        .celebration:  "upbeat pop hits",
        .unwinding:    "lofi chill",
        .catchUp:      "indie acoustic",
        .workSession:  "lofi beats",
        .lateNight:    "downtempo r&b",
        .quickBite:    "upbeat indie",
    ]

    /// Returns up to 3 search queries derived from the chosen audiences.
    /// Falls back to two generic cafe-vibe queries when no audience is set.
    static func queries(for audiences: Set<Audience>) -> [String] {
        if audiences.isEmpty {
            return ["coffee shop", "chill vibes"]
        }
        let mapped = audiences.compactMap { audienceToQuery[$0] }
        let unique = Array(NSOrderedSet(array: mapped)) as? [String] ?? []
        return Array(unique.prefix(3))
    }

    /// Human-readable label for the suggestion section header.
    /// Example: "Suggested for date night, work session".
    static func headerLabel(for audiences: Set<Audience>) -> String {
        if audiences.isEmpty {
            return "Suggested for a cafe vibe"
        }
        // Preserve the enum's declaration order so the label is deterministic.
        let chosen = Audience.allCases.filter { audiences.contains($0) }
        let names = chosen.prefix(2).map { $0.label.lowercased() }
        let tail = chosen.count > 2 ? "…" : ""
        return "Suggested for \(names.joined(separator: ", "))\(tail)"
    }
}
