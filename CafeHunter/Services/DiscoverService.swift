import CoreLocation
import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// One row in the Creator's Pick feed — an admin-curated place rendered as
/// a map pin or list row. Preview photo is taken from the place's own
/// `photos[0]`, not from any user post.
struct DiscoverPlace: Identifiable, Equatable {
    let id: String
    let name: String
    let type: PlaceType
    let lat: Double
    let lng: Double
    let distanceMeters: Double
    let previewPhotoURL: String
    /// Global visit count on the place doc — coarse "is this hot?" signal.
    let visits: Int
    /// Manual sort order set by the admin in `CreatorPicksAdminView`.
    let order: Int
}

/// Surfaces admin-curated "Creator's Pick" places near the user. Picks are
/// expressed as a `creatorPickOrder: Int` field on `places/{id}` docs —
/// nil/absent means the place is not a pick. Renders ordered by that field.
@MainActor
@Observable
final class DiscoverService {
    private(set) var results: [DiscoverPlace] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// How far around the user to surface picks, in metres.
    static let defaultRadiusMeters: Double = 15_000
    /// Max rows surfaced in the map / list.
    static let displayLimit = 20

    func load(around coord: CLLocationCoordinate2D,
              radiusMeters: Double) async {
        guard Auth.auth().currentUser != nil else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let picks = await fetchCreatorPicks()
        let origin = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

        var nearby: [DiscoverPlace] = []
        for p in picks {
            let placeLoc = CLLocation(latitude: p.lat, longitude: p.lng)
            let distance = placeLoc.distance(from: origin)
            guard distance <= radiusMeters else { continue }
            nearby.append(DiscoverPlace(
                id: p.id,
                name: p.name,
                type: p.type,
                lat: p.lat,
                lng: p.lng,
                distanceMeters: distance,
                previewPhotoURL: p.previewPhotoURL,
                visits: p.globalVisitCount,
                order: p.creatorPickOrder
            ))
        }

        // Already sorted by `creatorPickOrder asc` from Firestore — the
        // distance filter preserves that order.
        results = Array(nearby.prefix(Self.displayLimit))
        #if DEBUG
        print("[CreatorPicks] surfaced \(results.count)/\(picks.count) picks within \(Int(radiusMeters))m")
        #endif
    }

    // MARK: - Query

    /// Fetches all places marked as a creator's pick, ordered by the
    /// admin's manual sort. Picks are sparse (curated, ~tens of docs) so
    /// no `limit` is applied at the query level — the radius filter and
    /// `displayLimit` happen client-side.
    ///
    /// Needs a single-field index on `creatorPickOrder` — Firestore
    /// auto-creates these the first time the query runs.
    private func fetchCreatorPicks() async -> [CreatorPickPlace] {
        do {
            let snap = try await Firestore.firestore()
                .collection("places")
                .whereField("creatorPickOrder", isGreaterThan: 0)
                .order(by: "creatorPickOrder")
                .getDocuments()
            return snap.documents.compactMap(CreatorPickPlace.init(document:))
        } catch {
            lastError = error.localizedDescription
            #if DEBUG
            print("[CreatorPicks] query failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }
}

/// Sendable snapshot of the `places/{id}` fields the Creator's Pick surface
/// needs. Mirrors the FetchedPlaceFields / DiscoverPlaceFields pattern
/// elsewhere — used instead of the `Place` model because `Place.init()` is
/// MainActor-isolated via `@DocumentID`.
private struct CreatorPickPlace: Sendable, Equatable {
    let id: String
    let name: String
    let type: PlaceType
    let lat: Double
    let lng: Double
    let previewPhotoURL: String
    let globalVisitCount: Int
    let creatorPickOrder: Int

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard let name = data["name"] as? String,
              let lat = data["lat"] as? Double,
              let lng = data["lng"] as? Double,
              let order = data["creatorPickOrder"] as? Int else { return nil }
        let typeStr = (data["type"] as? String) ?? "restaurant"
        let photos = (data["photos"] as? [String]) ?? []
        // A pick without a preview photo would render as a blank card —
        // skip those rather than surface them. The admin picker enforces
        // the same rule on the way in.
        guard let firstPhoto = photos.first, !firstPhoto.isEmpty else { return nil }

        self.id = document.documentID
        self.name = name
        self.type = PlaceType(rawValue: typeStr) ?? .restaurant
        self.lat = lat
        self.lng = lng
        self.previewPhotoURL = firstPhoto
        self.globalVisitCount = (data["globalVisitCount"] as? Int) ?? 0
        self.creatorPickOrder = order
    }
}
