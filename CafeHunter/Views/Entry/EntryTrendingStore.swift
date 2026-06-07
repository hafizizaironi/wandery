import Foundation
import CoreLocation

/// Tiny on-disk snapshot of the most recent "trending" places so the
/// *signed-out* login fly-over can show real spots + photos.
///
/// The login screen has no authenticated user, and every trending source
/// (`/places`, `/posts`, the `discoverFeed` function) is gated behind auth +
/// App Check — so a signed-out client can't fetch trending directly. Instead,
/// whenever a signed-in user loads Discover we persist a handful of places
/// here; the entry screen replays them on next launch / after sign-out. The
/// photo URLs are tokenized Firebase Storage download URLs, which fetch fine
/// without auth (and `CachedAsyncImage` usually already has the bytes on disk).
///
/// Carries no user identity — `discoverFeed` already strips uids/usernames, so
/// the cache (and the pins built from it) reveal nothing about who posted.
enum EntryTrendingStore {
    struct Item: Codable, Sendable {
        let id: String
        let name: String
        let type: String      // PlaceType.rawValue
        let lat: Double
        let lng: Double
        let photoURL: String  // tokenized Storage download URL
    }

    /// Top N kept — enough for a varied fly-over without bloating the file.
    private static let cap = 12

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("entry-trending.json")
    }

    /// Persist the current trending list (only places that have a photo).
    /// Encoding + the write run off the main actor; a failure is silent — the
    /// fly-over just falls back to demo pins.
    static func save(_ trending: [TrendingPlace]) {
        let items: [Item] = trending.compactMap { place in
            guard let url = place.photos.first?.url, !url.isEmpty else { return nil }
            return Item(id: place.id,
                        name: place.name,
                        type: place.type.rawValue,
                        lat: place.lat,
                        lng: place.lng,
                        photoURL: url)
        }
        guard !items.isEmpty else { return }
        let top = Array(items.prefix(cap))
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(top) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Read the cached trending places. Empty on a true first launch (no
    /// signed-in Discover load has happened yet) → the caller uses demo pins.
    static func load() -> [Item] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return []
        }
        return items
    }
}
