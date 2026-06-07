import Foundation
import FirebaseFunctions
import CoreLocation
import Observation

// MARK: - Wire models

/// A 2nd-degree ("friend-of-friend") place suggestion. Surfaced as a small,
/// dashed-ring pin on the map with the photo blurred — the photo is only ever
/// drawn from `discoverable == true` posts (the existing consent gate), and
/// the response carries NO uids/usernames so the bridge identities stay
/// opaque to the caller.
struct CirclePlace: Identifiable, Equatable, Sendable {
    let id: String              // placeId
    let name: String
    let type: PlaceType
    let lat: Double
    let lng: Double
    /// Best discoverable photo from a 2nd-degree visitor, or nil → placeholder pin.
    let photoURL: String?
    /// How many distinct 2nd-degree visitors contributed this place ("Visited by N in your circle").
    let viaCount: Int
    let globalVisitCount: Int
}

/// One preview photo for a Trending row. The server only surfaces
/// `discoverable == true` photos from authors who haven't opted out, so every
/// Trending photo is shown full-resolution — there's no blur/tease state on
/// this surface.
struct TrendingPhoto: Equatable, Sendable {
    let url: String
}

struct TrendingPlace: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: PlaceType
    let lat: Double
    let lng: Double
    let photos: [TrendingPhoto]   // 0…3
    let globalVisitCount: Int
}

// MARK: - Service

/// Calls the `discoverFeed` Cloud Function, caches the result in memory, and
/// exposes `circle` + `trending` for the Map FoF pin layer and the Trending
/// sheet. The function maintains its own 6h Firestore cache; this in-memory
/// 5-minute throttle is just to keep `.task` re-runs from re-hitting the
/// network on every view appear.
@MainActor
@Observable
final class CircleDiscoverService {
    private(set) var circle: [CirclePlace] = []
    private(set) var trending: [TrendingPlace] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?
    private(set) var partial = false

    private var inflight: Task<Void, Never>?
    private let throttle: TimeInterval = 5 * 60

    /// Trigger a load. No-op if a load is already in flight; throttled to one
    /// network round-trip per 5 minutes unless `force == true` (pull-to-refresh).
    func load(force: Bool = false) async {
        if let last = lastLoadedAt, !force,
           Date().timeIntervalSince(last) < throttle, !circle.isEmpty || !trending.isEmpty {
            return
        }
        if let inflight, !force {
            await inflight.value
            return
        }
        inflight?.cancel()
        let task = Task { await self.runLoad(force: force) }
        inflight = task
        await task.value
        inflight = nil
    }

    func refresh() async { await load(force: true) }

    private func runLoad(force: Bool) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let callable = Functions.functions().httpsCallable("discoverFeed")
        do {
            let result = try await callable.call(["force": force])
            guard let data = result.data as? [String: Any] else {
                lastError = "Unexpected discoverFeed response."
                return
            }
            let circleRaw = data["circle"] as? [[String: Any]] ?? []
            let trendingRaw = data["trending"] as? [[String: Any]] ?? []
            circle = circleRaw.compactMap(Self.parseCircle)
            trending = trendingRaw.compactMap(Self.parseTrending)
            partial = (data["partial"] as? Bool) ?? false
            lastLoadedAt = Date()
            // Persist a slim snapshot for the signed-out login fly-over, which
            // can't fetch trending itself (auth + App Check gated).
            EntryTrendingStore.save(trending)
        } catch {
            // Don't blow away an existing cached payload on transient errors —
            // just record the message; the pins keep showing what we have.
            lastError = (error as NSError).localizedDescription
        }
    }

    // MARK: Parsing

    private static func parseCircle(_ d: [String: Any]) -> CirclePlace? {
        guard let id = d["placeId"] as? String, !id.isEmpty,
              let name = d["name"] as? String,
              let lat = d["lat"] as? Double,
              let lng = d["lng"] as? Double else { return nil }
        return CirclePlace(
            id: id,
            name: name,
            type: parsePlaceType(d["type"]),
            lat: lat,
            lng: lng,
            photoURL: (d["photoURL"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            viaCount: (d["viaCount"] as? Int) ?? 0,
            globalVisitCount: (d["globalVisitCount"] as? Int) ?? 0
        )
    }

    private static func parseTrending(_ d: [String: Any]) -> TrendingPlace? {
        guard let id = d["placeId"] as? String, !id.isEmpty,
              let name = d["name"] as? String,
              let lat = d["lat"] as? Double,
              let lng = d["lng"] as? Double else { return nil }
        // Wire format: `photos: [{url}]`. Any `blur` flag the server still
        // sends is ignored — Trending only surfaces clear photos now. Fall
        // back to the legacy `photoURLs: [String]` shape so a client running
        // against an older function deploy doesn't drop photos entirely.
        let photosRaw = d["photos"] as? [[String: Any]] ?? []
        var photos = photosRaw.compactMap { entry -> TrendingPhoto? in
            guard let url = entry["url"] as? String, !url.isEmpty else { return nil }
            return TrendingPhoto(url: url)
        }
        if photos.isEmpty, let legacy = d["photoURLs"] as? [String] {
            photos = legacy.filter { !$0.isEmpty }.map { TrendingPhoto(url: $0) }
        }
        return TrendingPlace(
            id: id,
            name: name,
            type: parsePlaceType(d["type"]),
            lat: lat,
            lng: lng,
            photos: Array(photos.prefix(3)),
            globalVisitCount: (d["globalVisitCount"] as? Int) ?? 0
        )
    }

    private static func parsePlaceType(_ raw: Any?) -> PlaceType {
        guard let s = raw as? String else { return .cafe }
        return PlaceType(rawValue: s) ?? .cafe
    }
}
