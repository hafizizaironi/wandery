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
    /// Real visit count from the place doc — bumped server-side once per
    /// "session" (multiple posts in one sitting count as one visit). Use
    /// this for any "X visits" UI label, NOT `posts.count`.
    var globalVisitCount: Int = 0
    /// Total engagement (reactions + replies) on tagged posts at this place.
    var globalEngagementCount: Int = 0

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
    /// Tracks the most recent post id we've seen per place — used to decide
    /// whether to refetch the place doc to pick up updated counters
    /// (`globalVisitCount`, `globalEngagementCount`) without re-fetching
    /// every place on every call.
    private var lastSeenPostByPlace: [String: String] = [:]

    private let db = Firestore.firestore()

    /// Recompute `places` from the latest feed snapshot. Fetches uncached
    /// place docs and re-fetches places that have a new "most-recent" post
    /// since last call (so counters refresh after activity). Cheap when
    /// nothing's changed.
    func refresh(from posts: [FriendPost]) async {
        let byPlace: [String: [FriendPost]] = Dictionary(
            grouping: posts.filter { $0.placeId != nil },
            by: { $0.placeId! }
        )

        // Refetch criteria:
        //   1. Place is uncached (first time we've seen it), OR
        //   2. The most-recent post at the place changed since last run
        //      (i.e. a new tag landed → visit/engagement counters might
        //       have moved on the server).
        let toFetch = byPlace.compactMap { placeId, postsAtPlace -> String? in
            if inflight.contains(placeId) { return nil }
            let mostRecentId = postsAtPlace
                .max(by: { $0.createdAt < $1.createdAt })?.id
            let needsFresh = placeCache[placeId] == nil ||
                lastSeenPostByPlace[placeId] != mostRecentId
            return needsFresh ? placeId : nil
        }
        #if DEBUG
        print("[FriendPlaces] refresh — feedPosts=\(posts.count) byPlace=\(byPlace.count) toFetch=\(toFetch.count) cached=\(placeCache.count)")
        #endif
        if !toFetch.isEmpty {
            for id in toFetch { inflight.insert(id) }
            await withTaskGroup(of: (String, Place?, Error?).self) { group in
                for id in toFetch {
                    group.addTask { [db] in
                        do {
                            let snap = try await db.collection("places")
                                .document(id)
                                .getDocument()
                            // Manual dict decode rather than Codable — the
                            // FirestoreDecoder fails opaquely when a field's
                            // type drifts (e.g. a new field was added but
                            // an older doc has it missing in some odd shape).
                            // Dict access reads what's there and falls
                            // through to defaults for anything missing.
                            guard let data = snap.data(),
                                  let name = data["name"] as? String,
                                  let lat = data["lat"] as? Double,
                                  let lng = data["lng"] as? Double else {
                                return (id, nil, NSError(
                                    domain: "FriendPlaces",
                                    code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "missing required fields"]
                                ))
                            }
                            let typeStr = (data["type"] as? String) ?? "restaurant"
                            var place = Place()
                            // `place.id = ...` is set in the main-actor consumer loop below;
                            // `@DocumentID`'s setter is MainActor-isolated and can't be touched
                            // from this nonisolated task.
                            place.name = name
                            place.type = PlaceType(rawValue: typeStr) ?? .restaurant
                            place.lat = lat
                            place.lng = lng
                            place.geohash = (data["geohash"] as? String) ?? ""
                            place.source = (data["source"] as? String) ?? "google"
                            place.googlePlaceId = data["googlePlaceId"] as? String
                            place.globalVisitCount = (data["globalVisitCount"] as? Int) ?? 0
                            place.globalEngagementCount = (data["globalEngagementCount"] as? Int) ?? 0
                            place.lastVisitedAt = (data["lastVisitedAt"] as? Timestamp)?.dateValue()
                            place.createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
                            return (id, place, nil)
                        } catch {
                            return (id, nil, error)
                        }
                    }
                }
                for await (id, place, err) in group {
                    inflight.remove(id)
                    if var place {
                        place.id = id
                        placeCache[id] = place
                    } else {
                        #if DEBUG
                        print("[FriendPlaces] FAILED to load place \(id): \(err?.localizedDescription ?? "nil")")
                        #endif
                    }
                }
            }
        }
        // Refresh the "last seen" pointer for each place so subsequent
        // calls only re-fetch when a new post lands.
        for (placeId, postsAtPlace) in byPlace {
            lastSeenPostByPlace[placeId] = postsAtPlace
                .max(by: { $0.createdAt < $1.createdAt })?.id
        }

        let assembled: [FriendPlace] = byPlace.compactMap { placeId, postsAtPlace in
            guard let p = placeCache[placeId] else {
                #if DEBUG
                print("[FriendPlaces] dropping \(placeId) — not in cache after fetch")
                #endif
                return nil
            }
            let sorted = postsAtPlace.sorted { $0.createdAt > $1.createdAt }
            return FriendPlace(
                id: placeId,
                name: p.name,
                type: p.type,
                lat: p.lat,
                lng: p.lng,
                posts: sorted,
                globalVisitCount: p.globalVisitCount,
                globalEngagementCount: p.globalEngagementCount
            )
        }
        #if DEBUG
        print("[FriendPlaces] assembled=\(assembled.count) of byPlace=\(byPlace.count)")
        #endif

        // Most-recently-active place first — useful when many pins overlap.
        places = assembled.sorted {
            ($0.mostRecent?.createdAt ?? .distantPast) > ($1.mostRecent?.createdAt ?? .distantPast)
        }
    }
}
