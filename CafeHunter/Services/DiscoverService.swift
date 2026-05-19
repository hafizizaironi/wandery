import CoreLocation
import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// One row in the Discover feed — a place ranked by engagement + visits,
/// minus a distance penalty. Stamped with raw counters so the UI can show
/// secondary signals like "👥 5 visits · ❤️ 12 reactions".
struct DiscoverPlace: Identifiable, Equatable {
    let id: String
    let name: String
    let type: PlaceType
    let lat: Double
    let lng: Double
    let distanceMeters: Double
    let visits: Int
    let engagement: Int
    let score: Double
}

/// Suggests places the user hasn't been to yet, ranked by activity (visits +
/// engagement) and proximity. Engagement counters are written server-side
/// by `onReactionEngagement` / `onReplyEngagement`; the user-has-been
/// filter is driven by `users/{uid}/visits` (any doc, even closed).
@MainActor
@Observable
final class DiscoverService {
    private(set) var results: [DiscoverPlace] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Search radius in metres. Wide enough to cover the whole city for
    /// people on foot, narrow enough that a Kuala Lumpur-resident user
    /// doesn't see every cafe in Penang. Tunable.
    static let defaultRadiusMeters: Double = 15_000
    /// Max rows surfaced. Keeps the list scannable.
    static let displayLimit = 20

    func load(around coord: CLLocationCoordinate2D,
              radiusMeters: Double = DiscoverService.defaultRadiusMeters) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let degLat = radiusMeters / 111_000.0
        let degLng = radiusMeters / (111_000.0 * max(0.001, cos(coord.latitude * .pi / 180)))

        // Run the visits and places queries concurrently — the visits
        // query is tiny (one doc per place the user's visited), the places
        // query is the slower one.
        async let visitedTask = fetchVisitedPlaceIds(uid: uid)
        async let placesTask = fetchNearbyPlaceDocs(latRange: degLat, around: coord)

        let visited = await visitedTask
        let docs = await placesTask
        let origin = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

        var candidates: [DiscoverPlace] = []
        for doc in docs {
            // Already visited → not a discovery candidate.
            if visited.contains(doc.documentID) { continue }
            let d = doc.data()
            guard let name = d["name"] as? String,
                  let lat = d["lat"] as? Double,
                  let lng = d["lng"] as? Double else { continue }
            // Longitude bounding-box pre-filter (lat range was server-side).
            if abs(lng - coord.longitude) > degLng { continue }
            let placeLoc = CLLocation(latitude: lat, longitude: lng)
            let distance = placeLoc.distance(from: origin)
            guard distance <= radiusMeters else { continue }

            let visits = (d["globalVisitCount"] as? Int) ?? 0
            let engagement = (d["globalEngagementCount"] as? Int) ?? 0
            // Need at least one signal of activity — avoids surfacing
            // brand-new untouched places (which are noise for "discover").
            guard visits + engagement >= 1 else { continue }

            // Visits weighted 2× because they represent real attendance,
            // while reactions and replies are passive engagement. Distance
            // penalty is gentle (1 point per 200 m) so a great spot 5 km
            // away still beats a mediocre one across the road.
            let score = Double(engagement)
                      + Double(visits) * 2.0
                      - distance / 200.0

            let typeStr = (d["type"] as? String) ?? "restaurant"
            let resolvedType = PlaceType(rawValue: typeStr) ?? .restaurant
            candidates.append(DiscoverPlace(
                id: doc.documentID,
                name: name,
                type: resolvedType,
                lat: lat,
                lng: lng,
                distanceMeters: distance,
                visits: visits,
                engagement: engagement,
                score: score
            ))
        }

        results = Array(
            candidates.sorted { $0.score > $1.score }.prefix(Self.displayLimit)
        )
        #if DEBUG
        print("[Discover] \(results.count) suggestions from \(docs.count) candidates · visited filter excluded \(visited.count)")
        #endif
    }

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

    private func fetchNearbyPlaceDocs(latRange: Double,
                                      around coord: CLLocationCoordinate2D) async -> [QueryDocumentSnapshot] {
        do {
            let snap = try await Firestore.firestore()
                .collection("places")
                .whereField("lat", isGreaterThanOrEqualTo: coord.latitude - latRange)
                .whereField("lat", isLessThanOrEqualTo: coord.latitude + latRange)
                .limit(to: 200)
                .getDocuments()
            return snap.documents
        } catch {
            lastError = error.localizedDescription
            #if DEBUG
            print("[Discover] places fetch failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }
}
