import Foundation
import FirebaseFirestore

/// Aggregated representation of one tagged place + all the friend posts at it.
/// Drives both the map annotation layer and the place-detail card stack.
struct FriendPlace: Identifiable, Equatable {
    let id: String   // = places/{id}
    var name: String
    var type: PlaceType
    var lat: Double
    var lng: Double
    /// Posts at this place, most recent first.
    var posts: [FriendPost]

    var mostRecent: FriendPost? { posts.first }
}

/// Derives `[FriendPlace]` from a stream of feed posts.
/// Caches place docs so we don't re-fetch on every feed snapshot. Hydration
/// errors silently skip the place (the post still exists in the feed).
@MainActor
@Observable
final class FriendPlacesService {
    private(set) var places: [FriendPlace] = []
    private var placeCache: [String: Place] = [:]
    private var inflight: Set<String> = []

    private let db = Firestore.firestore()

    /// Recompute `places` from the latest feed snapshot. Cheap when no new
    /// placeIds appear (cache hit); otherwise fetches missing place docs in
    /// parallel before producing the new list.
    func refresh(from posts: [FriendPost]) async {
        let byPlace: [String: [FriendPost]] = Dictionary(
            grouping: posts.filter { $0.placeId != nil },
            by: { $0.placeId! }
        )

        // Hydrate any uncached placeIds in parallel.
        let toFetch = byPlace.keys.filter { placeCache[$0] == nil && !inflight.contains($0) }
        if !toFetch.isEmpty {
            for id in toFetch { inflight.insert(id) }
            await withTaskGroup(of: (String, Place?).self) { group in
                for id in toFetch {
                    group.addTask { [db] in
                        let doc = try? await db.collection("places")
                            .document(id)
                            .getDocument(as: Place.self)
                        return (id, doc)
                    }
                }
                for await (id, place) in group {
                    inflight.remove(id)
                    if let place { placeCache[id] = place }
                }
            }
        }

        let assembled: [FriendPlace] = byPlace.compactMap { placeId, postsAtPlace in
            guard let p = placeCache[placeId] else { return nil }
            let sorted = postsAtPlace.sorted { $0.createdAt > $1.createdAt }
            return FriendPlace(
                id: placeId,
                name: p.name,
                type: p.type,
                lat: p.lat,
                lng: p.lng,
                posts: sorted
            )
        }

        // Most-recently-active place first — useful when many pins overlap.
        places = assembled.sorted {
            ($0.mostRecent?.createdAt ?? .distantPast) > ($1.mostRecent?.createdAt ?? .distantPast)
        }
    }
}
