import Foundation
import FirebaseAuth
import FirebaseFunctions

/// A generated mascot tied to a submitted cafe.
/// - `imageURL`   : rendered avatar (currently DiceBear; swap for real AI later)
/// - `name`       : procedural, memorable character name
/// - `tagline`    : short poetic description
/// - `aiPrompt`   : the prompt we'd send to a real image model. Kept around so
///                  swapping to a real backend later needs no call-site change.
struct GeneratedCharacter: Equatable, Hashable {
    let imageURL: String
    let name: String
    let tagline: String
    let aiPrompt: String
}

enum CharacterGenerationService {

    /// Generate a character for the given draft. `attempt` bumps the seed so
    /// rerolls produce a different character from the same cafe.
    ///
    /// Pipeline:
    ///   1. Name + tagline — deterministic, derived from the draft hash.
    ///   2. Image — call the `generateCharacter` Cloud Function (Replicate
    ///      Flux Schnell → Firebase Storage). On any failure fall back to a
    ///      seeded DiceBear avatar so dev always works.
    static func generate(for draft: CafeDraft, attempt: Int = 0) async -> GeneratedCharacter {
        let start = Date()

        let seed = "\(draft.name)|\(draft.neighborhood)|\(attempt)"
        let name = buildName(draft: draft, seed: seed)
        let tagline = buildTagline(draft: draft, seed: seed)
        let prompt = buildAIPrompt(draft: draft)

        let imageURL = await resolveImageURL(prompt: prompt, seed: seed)

        // Minimum animation time so the "brewing" beat has room to breathe,
        // even if the network call returned fast or fell through to DiceBear.
        let elapsed = Date().timeIntervalSince(start)
        let minimum: TimeInterval = 2.0
        if elapsed < minimum {
            let remainingNS = UInt64((minimum - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: remainingNS)
        }

        return GeneratedCharacter(
            imageURL: imageURL,
            name: name,
            tagline: tagline,
            aiPrompt: prompt
        )
    }

    // MARK: - Image source

    /// Calls the deployed Cloud Function; falls back to DiceBear on any error
    /// so development still works without a live backend.
    private static func resolveImageURL(prompt: String, seed: String) async -> String {
        guard Auth.auth().currentUser != nil else {
            return diceBearURL(for: seed)
        }

        do {
            let callable = Functions.functions().httpsCallable("generateCharacter")
            let result = try await callable.call([
                "prompt": prompt,
                "seed": seed,
            ])
            if let data = result.data as? [String: Any],
               let url = data["imageURL"] as? String,
               !url.isEmpty {
                return url
            }
        } catch {
            // Any error (network, auth, quota, Replicate down) → DiceBear.
            print("[CharacterGen] Cloud Function failed: \(error.localizedDescription)")
        }

        return diceBearURL(for: seed)
    }

    private static func diceBearURL(for seed: String) -> String {
        let encoded = seed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "seed"
        return "https://api.dicebear.com/7.x/fun-emoji/png"
            + "?seed=\(encoded)&size=400"
            + "&backgroundColor=fce7d8,ffd6b0,f9c6a4,ffe3d3"
    }

    // MARK: - Procedural name

    private static let adjectives = [
        "Warm", "Quiet", "Dreamy", "Steady", "Gentle", "Bright",
        "Cosy", "Tender", "Wild", "Sparkling", "Golden", "Hushed",
        "Curious", "Wistful", "Bold"
    ]

    private static let nouns = [
        "Keeper", "Wanderer", "Muse", "Brewer", "Soul", "Spark",
        "Flame", "Whisper", "Echo", "Friend", "Daydream", "Lantern",
        "Hearth", "Current", "Spell"
    ]

    private static func buildName(draft: CafeDraft, seed: String) -> String {
        let h = hash(seed)
        let adj = adjectives[h % adjectives.count]
        let noun = nouns[(h / adjectives.count) % nouns.count]

        let base = draft.name
            .split(separator: " ")
            .first
            .map(String.init)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Someone"

        return "\(base), the \(adj) \(noun)"
    }

    // MARK: - Procedural tagline

    private static let taglines = [
        "Keeps the secret spots alive.",
        "Lives in the quiet between sips.",
        "Knows every regular by heart.",
        "Builds memories, one visit at a time.",
        "Here to make you feel at home.",
        "Brews warmth on rainy afternoons.",
        "Guards the good corners of the city.",
        "Stays up late so the magic doesn't fade.",
        "Whispers recommendations to the right people.",
        "Tastes like an afternoon that lingers."
    ]

    private static func buildTagline(draft: CafeDraft, seed: String) -> String {
        taglines[hash(seed + "#tagline") % taglines.count]
    }

    // MARK: - AI prompt (for future real image gen)

    private static func buildAIPrompt(draft: CafeDraft) -> String {
        let kind = draft.placeType == .cafe ? "café" : "street stall"

        let audience = Audience.allCases
            .filter { draft.audiences.contains($0) }
            .map    { $0.label.lowercased() }
            .joined(separator: ", ")

        let topDims = draft.ratings
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key.label.lowercased() }
            .joined(separator: ", ")

        var pieces: [String] = [
            "A whimsical, friendly mascot character for a \(kind) called \"\(draft.name)\"",
            "in the \(draft.neighborhood) neighbourhood"
        ]
        if !audience.isEmpty { pieces.append("a place for \(audience)") }
        if !topDims.isEmpty  { pieces.append("known for its \(topDims)") }
        pieces.append("warm terracotta + amber colour palette, soft glow, isolated on a gradient background, storybook illustration style")

        return pieces.joined(separator: ", ")
    }

    // MARK: - Stable hash

    /// Swift's `Hasher` is randomised per-launch, so two different app runs
    /// produce different values for the same input. We need stability so a
    /// cafe always generates the same character across runs — use FNV-1a.
    private static func hash(_ input: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return Int(truncatingIfNeeded: h & 0x7fffffff)
    }
}
