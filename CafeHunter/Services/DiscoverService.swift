import CoreLocation
import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// One row in the Discover feed — a place the current user hasn't visited
/// yet, surfaced because at least one *discoverable* post exists there.
/// The post's photo + aestheticScore are folded in so the map pin can
/// preview the place visually without leaking a friend-only post.
struct DiscoverPlace: Identifiable, Equatable {
    let id: String
    let name: String
    let type: PlaceType
    let lat: Double
    let lng: Double
    let distanceMeters: Double
    /// Photo URL from the chosen discoverable post at this place. This is
    /// the only image surface a stranger ever sees — no faces, classifier-
    /// approved, author-revocable via "Hide from Discover".
    let previewPhotoURL: String
    /// Aesthetic score of the chosen preview post (0…1).
    let aestheticScore: Double
    /// Global visit count on the place doc — coarse "is this hot?" signal.
    let visits: Int
    /// Internal ranking score; higher = surfaced earlier.
    let score: Double
}

/// Surfaces places the current user hasn't tagged yet, using user-uploaded
/// photos that have passed CafeHunter's classifier (no faces + aesthetic
/// floor — see PostClassifier.swift). Implicit-consent model: the act of
/// posting a passing photo authorizes its use as a place preview.
@MainActor
@Observable
final class DiscoverService {
    private(set) var results: [DiscoverPlace] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// How far around the user to surface places, in metres.
    static let defaultRadiusMeters: Double = 15_000
    /// Max rows surfaced in the map / list.
    static let displayLimit = 20

    func load(around coord: CLLocationCoordinate2D,
              radiusMeters: Double) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // Run the user's visits + the global discoverable-posts query
        // concurrently. Visits is per-user and small; the posts query is
        // the slower one but capped at 60 docs.
        async let visitedTask = fetchVisitedPlaceIds(uid: uid)
        async let postsTask = fetchDiscoverablePosts()

        let visited = await visitedTask
        let posts = await postsTask

        // Unique placeIds across the candidate posts. Discoverable posts
        // without a place can't render as map pins, so they're skipped.
        let placeIds = Array(Set(posts.compactMap(\.placeId)))
        let places = await fetchPlaces(ids: placeIds)
        let placeById = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })

        // Pick one preview post per place — highest aesthetic score wins.
        var bestPostByPlace: [String: FriendPost] = [:]
        for post in posts {
            guard let pid = post.placeId, !pid.isEmpty else { continue }
            if let existing = bestPostByPlace[pid] {
                let a = post.aestheticScore ?? 0
                let b = existing.aestheticScore ?? 0
                if a > b { bestPostByPlace[pid] = post }
            } else {
                bestPostByPlace[pid] = post
            }
        }

        let origin = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var candidates: [DiscoverPlace] = []
        for (pid, post) in bestPostByPlace {
            // Skip places the user already has a visit doc for.
            if visited.contains(pid) { continue }
            guard let p = placeById[pid] else { continue }
            let placeLoc = CLLocation(latitude: p.lat, longitude: p.lng)
            let distance = placeLoc.distance(from: origin)
            guard distance <= radiusMeters else { continue }
            // Combined score — aesthetic and engagement together so a
            // truly stunning shot at a quiet cafe can outrank a mediocre
            // shot at a busy chain. Distance penalty kept gentle so
            // walkable neighbours win at similar quality, but a great
            // spot 10 km away still cracks the list.
            let aesthetic = post.aestheticScore ?? 0
            let engagement = Double(p.globalVisitCount + p.globalEngagementCount)
            let score = aesthetic * 100
                      + log(1 + engagement) * 10
                      - distance / 500
            candidates.append(DiscoverPlace(
                id: pid,
                name: p.name,
                type: p.type,
                lat: p.lat,
                lng: p.lng,
                distanceMeters: distance,
                previewPhotoURL: post.mediaURL,
                aestheticScore: aesthetic,
                visits: p.globalVisitCount,
                score: score
            ))
        }
        results = Array(candidates.sorted { $0.score > $1.score }.prefix(Self.displayLimit))
        #if DEBUG
        print("[Discover] surfaced \(results.count) places from \(posts.count) discoverable posts (visited filter excluded \(visited.count))")
        #endif
    }

    // MARK: - Queries

    /// Per-user set of placeIds the user has a visit doc for. Used to
    /// keep Discover focused on places the user hasn't been to yet —
    /// the whole point of "worth exploring".
    private func fetchVisitedPlaceIds(uid: String) async -> Set<String> {
        do {
            let snap = try await Firestore.firestore()
                .collection("users").document(uid)
                .collection("visits")
                .getDocuments()
            return Set(snap.documents.map(\.documentID))
        } catch {
            #if DEBUG
            print("[Discover] visits fetch failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    /// All discoverable image posts globally, ranked by aesthetic score.
    /// Needs a composite Firestore index on
    ///   (discoverable=true, mediaType=image, aestheticScore desc)
    /// — created automatically the first time the query runs (Firestore
    /// console will surface a "create index" link in the error log).
    private func fetchDiscoverablePosts() async -> [FriendPost] {
        do {
            let snap = try await Firestore.firestore()
                .collection("posts")
                .whereField("discoverable", isEqualTo: true)
                .whereField("mediaType", isEqualTo: "image")
                .order(by: "aestheticScore", descending: true)
                .limit(to: 60)
                .getDocuments()
            return snap.documents.compactMap { FriendPost(document: $0) }
        } catch {
            lastError = error.localizedDescription
            #if DEBUG
            print("[Discover] discoverable posts query failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    /// Hydrates the place docs for a batch of placeIds in parallel. Returns
    /// a Sendable snapshot struct rather than the @MainActor-isolated
    /// `Place` model — see FriendPlacesService.swift for the same pattern.
    private func fetchPlaces(ids: [String]) async -> [DiscoverPlaceFields] {
        guard !ids.isEmpty else { return [] }
        let db = Firestore.firestore()
        return await withTaskGroup(of: DiscoverPlaceFields?.self) { group in
            for id in ids {
                group.addTask {
                    do {
                        let snap = try await db.collection("places").document(id).getDocument()
                        guard let data = snap.data(),
                              let name = data["name"] as? String,
                              let lat = data["lat"] as? Double,
                              let lng = data["lng"] as? Double else { return nil }
                        let typeStr = (data["type"] as? String) ?? "restaurant"
                        return DiscoverPlaceFields(
                            id: id,
                            name: name,
                            type: PlaceType(rawValue: typeStr) ?? .restaurant,
                            lat: lat,
                            lng: lng,
                            globalVisitCount: (data["globalVisitCount"] as? Int) ?? 0,
                            globalEngagementCount: (data["globalEngagementCount"] as? Int) ?? 0
                        )
                    } catch {
                        return nil
                    }
                }
            }
            var arr: [DiscoverPlaceFields] = []
            for await item in group { if let item { arr.append(item) } }
            return arr
        }
    }
}

/// Sendable snapshot of the `places/{id}` fields the Discover surface
/// needs. Used instead of the `Place` model because `Place.init()` is
/// MainActor-isolated (via `@DocumentID`) and we hydrate from inside a
/// nonisolated TaskGroup. Mirrors the FetchedPlaceFields pattern in
/// FriendPlacesService.swift.
private struct DiscoverPlaceFields: Sendable, Equatable {
    let id: String
    let name: String
    let type: PlaceType
    let lat: Double
    let lng: Double
    let globalVisitCount: Int
    let globalEngagementCount: Int
}
