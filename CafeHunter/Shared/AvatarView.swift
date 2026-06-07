import SwiftUI

/// The app's single circular user avatar.
///
/// Loads `url` through ``CachedAsyncImage`` (the shared memory + disk cache) and
/// falls back to gradient initials when there's no photo or the load fails.
///
/// This replaces a row of hand-rolled avatar + initials copies that had drifted
/// apart in gradient, initials colour, and — the reason this is a refactor and
/// not just tidying — *whether they cached at all*: several used a raw
/// `AsyncImage`, which re-downloads and re-decodes the same face every time a
/// `LazyVStack`/`List` cell is recycled on scroll.
///
/// Look is standardised on the terracotta→sage gradient with white initials
/// (`AppTheme.textOnAccent`), matching the most recent call sites
/// (`ParticipantAvatar`, the friend chips). Font scales with `size` so one
/// component serves a 20pt map pin and a 100pt profile header alike.
struct AvatarView: View {
    let url: URL?
    /// Pre-resolved 1–2 letter initials shown when there's no image.
    let initials: String
    var size: CGFloat = 44
    var stroke: Stroke? = nil

    /// Optional ring drawn around the avatar.
    struct Stroke {
        var color: Color
        var width: CGFloat

        /// Hairline chrome border — matches the old `ParticipantAvatar`.
        static let subtle = Stroke(color: AppTheme.borderSubtle, width: 0.5)
    }

    // MARK: Name-based — computes initials from a display name.

    init(url: URL?, name: String?, size: CGFloat = 44, stroke: Stroke? = nil) {
        self.init(url: url, initials: Self.initials(from: name), size: size, stroke: stroke)
    }

    /// Convenience for the many call sites that hold the photo URL as a `String?`.
    init(urlString: String?, name: String?, size: CGFloat = 44, stroke: Stroke? = nil) {
        self.init(url: urlString.flatMap { URL(string: $0) }, name: name, size: size, stroke: stroke)
    }

    // MARK: Initials-based — for call sites that already resolved the initials
    // (e.g. a precomputed value with a uid or `"?"` fallback).

    init(url: URL?, initials: String, size: CGFloat = 44, stroke: Stroke? = nil) {
        self.url = url
        let trimmed = initials.trimmingCharacters(in: .whitespaces)
        self.initials = trimmed.isEmpty ? "?" : trimmed
        self.size = size
        self.stroke = stroke
    }

    init(urlString: String?, initials: String, size: CGFloat = 44, stroke: Stroke? = nil) {
        self.init(url: urlString.flatMap { URL(string: $0) }, initials: initials, size: size, stroke: stroke)
    }

    var body: some View {
        ZStack {
            // The gradient sits behind everything so it shows under the initials
            // and during loading; a successfully-loaded image fills the frame
            // and covers it completely.
            LinearGradient(
                colors: [AppTheme.accentAction, AppTheme.stallAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let url {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: initialsText
                    }
                }
            } else {
                initialsText
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if let stroke {
                Circle().stroke(stroke.color, lineWidth: stroke.width)
            }
        }
    }

    private var initialsText: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(AppTheme.textOnAccent)
            .minimumScaleFactor(0.5)
            .accessibilityHidden(true)
    }

    /// First letters of the first two words, uppercased. `"?"` when there's no
    /// usable name so empty avatars aren't blank gradient discs.
    static func initials(from name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "?" }
        let letters = trimmed.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return letters.isEmpty ? "?" : letters
    }
}
