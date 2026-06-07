import Foundation
import CoreLocation
import GooglePlacesSwift
import FirebaseFirestore

/// Disambiguation: our app's `PlaceType` (Cafe.swift) vs Google's `PlaceType`.
/// `GMSType` is Google's category enum (cafe/bakery/bar/...); `PlaceType` is ours.
private typealias GMSType = GooglePlacesSwift.PlaceType
private typealias GMSPlace = GooglePlacesSwift.Place

/// Wraps Google Places SDK calls used by the place-tag picker.
/// Filters to food/drink categories so the user only sees on-domain places.
@MainActor
final class PlacePickerService {
    static let shared = PlacePickerService()
    private init() {}

    /// Default search radius. Wide enough to cover typical mall footprints
    /// and dense urban blocks where GPS can drift 100–300 m indoors. Earlier
    /// Radius for the nearby DB + Google search around the user's current
    /// location. History: 200m → 600m (malls had storefront coords > user fix)
    /// → 3000m. The 600m default still hid DB places the user had tagged in
    /// the same neighborhood — typical GPS drift indoors + the fact that a
    /// "nearby" cafe can easily be a few blocks away pushed real venues out
    /// of range. Bounded by `.limit(to: 200)` so the read cost stays flat
    /// regardless of radius.
    /// `nonisolated` so it can be referenced as a default-argument value
    /// for `nearby(_:radius:)` — default-arg expressions evaluate outside
    /// the type's `@MainActor` context.
    nonisolated static let defaultRadiusMeters: Double = 3_000

    /// Google categories we surface for the picker. Stalls have no Google
    /// equivalent — user adds those manually.
    /// NOTE: `.food` is intentionally excluded. Although the SDK enum
    /// exposes it, the Places API (New) `searchNearby` endpoint only
    /// accepts "Table A" primary types and rejects the whole request with
    /// `400 INVALID_ARGUMENT: Unsupported types: food.` if it's present —
    /// which silently broke nearby search everywhere. Same applies to any
    /// other Table-B-only enum case (e.g. point_of_interest).
    private let foodPlaceTypes: Set<GMSType> = [
        .restaurant, .cafe, .bakery, .bar, .mealTakeaway, .mealDelivery, .nightClub,
    ]

    func nearby(_ coord: CLLocationCoordinate2D,
                radius: Double = defaultRadiusMeters) async throws -> [PlaceCandidate] {
        #if DEBUG
        print("[PlacePicker] nearby query: center=(\(coord.latitude),\(coord.longitude)) radius=\(Int(radius))m")
        #endif
        // Run both sources in parallel — each may fail/return empty
        // independently. Google failure must NOT erase DB results (and vice
        // versa), so we collect Result values rather than throwing eagerly.
        async let dbResult: Result<[PlaceCandidate], Error> = {
            do { return .success(try await self.fetchNearbyDbPlaces(coord: coord, radius: radius)) }
            catch { return .failure(error) }
        }()
        async let googleResult: Result<[PlaceCandidate], Error> = {
            do { return .success(try await self.fetchGoogleNearby(coord: coord, radius: radius)) }
            catch { return .failure(error) }
        }()

        let (dbR, googleR) = await (dbResult, googleResult)

        let db: [PlaceCandidate]
        switch dbR {
        case .success(let arr): db = arr
        case .failure(let e):
            #if DEBUG
            print("[PlacePicker] DB nearby failed: \(e.localizedDescription)")
            #endif
            db = []
        }
        let google: [PlaceCandidate]
        switch googleR {
        case .success(let arr): google = arr
        case .failure(let e):
            #if DEBUG
            print("[PlacePicker] Google nearby failed: \(e.localizedDescription)")
            #endif
            google = []
        }

        // Dedup: a DB row with googlePlaceId X overrides the Google result with same X.
        let dbGoogleIds = Set(db.compactMap(\.googlePlaceId))
        let filteredGoogle = google.filter { c in
            guard let gid = c.googlePlaceId else { return true }
            return !dbGoogleIds.contains(gid)
        }
        // Sort by an "effective distance" that lets trending DB places nudge
        // ahead of cold ones at similar real distance. Each visit shaves a
        // few meters off the perceived distance, capped so a wildly popular
        // place across town doesn't outrank what you're standing next to.
        let merged = (db + filteredGoogle).sorted { a, b in
            Self.effectiveDistance(a) < Self.effectiveDistance(b)
        }
        #if DEBUG
        print("[PlacePicker] merged candidates: \(merged.count) (db=\(db.count), google=\(google.count) → kept \(filteredGoogle.count))")
        #endif
        return merged
    }

    private func fetchGoogleNearby(coord: CLLocationCoordinate2D,
                                   radius: Double) async throws -> [PlaceCandidate] {
        let restriction = CircularCoordinateRegion(center: coord, radius: radius)
        let request = SearchNearbyRequest(
            locationRestriction: restriction,
            placeProperties: [.placeID, .displayName, .formattedAddress, .coordinate, .types],
            includedTypes: foodPlaceTypes,
            maxResultCount: 20,
            rankPreference: .distance
        )
        let result = await PlacesClient.shared.searchNearby(with: request)
        switch result {
        case .success(let places):
            return places.compactMap { Self.candidate(from: $0, origin: coord) }
        case .failure(let err):
            throw err
        }
    }

    /// Fetches places near `coord` from the global `places` collection (any
    /// author — not just the current user). Phase 3 swap: previously this
    /// was filtered by `createdBy == uid`, which meant other users' tagged
    /// stalls never surfaced in the picker. Now we use a lat range filter
    /// (Firestore auto-indexes single-field ranges, no composite needed)
    /// and finish the precision client-side with longitude + great-circle
    /// distance. Sorted by distance for the picker's tagging use-case.
    private func fetchNearbyDbPlaces(coord: CLLocationCoordinate2D,
                                     radius: Double) async throws -> [PlaceCandidate] {
        // Lat range expressed as a fraction of the planet's circumference —
        // 1° latitude ≈ 111 km everywhere on Earth.
        let degLat = radius / 111_000.0
        // Per-cosine fudge for longitude: 1° longitude shrinks toward the
        // poles. Clamped to avoid /0 at the pole.
        let degLng = radius / (111_000.0 * max(0.001, cos(coord.latitude * .pi / 180)))

        let snap = try await Firestore.firestore()
            .collection("places")
            .whereField("lat", isGreaterThanOrEqualTo: coord.latitude - degLat)
            .whereField("lat", isLessThanOrEqualTo: coord.latitude + degLat)
            .limit(to: 200)
            .getDocuments()

        let origin = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var matched: [PlaceCandidate] = []
        for doc in snap.documents {
            let d = doc.data()
            guard let name = d["name"] as? String,
                  let lat = d["lat"] as? Double,
                  let lng = d["lng"] as? Double else {
                continue
            }
            // Bounding-box pre-filter: cheap longitude check before the
            // more expensive great-circle calculation.
            if abs(lng - coord.longitude) > degLng { continue }
            let placeLoc = CLLocation(latitude: lat, longitude: lng)
            let distance = placeLoc.distance(from: origin)
            guard distance <= radius else { continue }
            let typeStr = (d["type"] as? String) ?? "restaurant"
            let resolvedType = PlaceType(rawValue: typeStr) ?? .restaurant
            matched.append(PlaceCandidate(
                id: doc.documentID,
                googlePlaceId: d["googlePlaceId"] as? String,
                name: name,
                address: nil,
                suggestedType: resolvedType,
                lat: lat,
                lng: lng,
                distanceMeters: distance,
                source: .db,
                globalVisitCount: d["globalVisitCount"] as? Int
            ))
        }
        #if DEBUG
        print("[PlacePicker] DB nearby: \(matched.count) of \(snap.documents.count) within \(Int(radius))m of (\(coord.latitude), \(coord.longitude))")
        #endif
        return matched
    }

    /// Firestore name-prefix search across the *entire* `places` collection,
    /// independent of the user's current location. Lets a typed search surface
    /// DB places that are outside the nearby radius — i.e. "I tagged X last
    /// week in a different neighborhood, let me find it again". Uses the
    /// canonical Firestore prefix-range pattern (`name >= q && name < q + \u{f8ff}`)
    /// which is auto-indexed on a single field.
    ///
    /// Case-sensitive — the user's typed text has to match how the place was
    /// stored. Most CafeHunter places come from Google place names so they
    /// follow conventional title case ("Starbucks Pavilion KL"). If this
    /// proves brittle we can mirror a `nameLower` field in the Cloud Function.
    func searchDbByName(_ text: String,
                       around coord: CLLocationCoordinate2D?) async throws -> [PlaceCandidate] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let upperBound = trimmed + "\u{f8ff}"
        let snap = try await Firestore.firestore()
            .collection("places")
            .whereField("name", isGreaterThanOrEqualTo: trimmed)
            .whereField("name", isLessThan: upperBound)
            .limit(to: 30)
            .getDocuments()
        let origin = coord.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        var out: [PlaceCandidate] = []
        for doc in snap.documents {
            let d = doc.data()
            guard let name = d["name"] as? String,
                  let lat = d["lat"] as? Double,
                  let lng = d["lng"] as? Double else { continue }
            let typeStr = (d["type"] as? String) ?? "restaurant"
            let resolvedType = PlaceType(rawValue: typeStr) ?? .restaurant
            let placeLoc = CLLocation(latitude: lat, longitude: lng)
            let distance = origin.map { placeLoc.distance(from: $0) }
            out.append(PlaceCandidate(
                id: doc.documentID,
                googlePlaceId: d["googlePlaceId"] as? String,
                name: name,
                address: nil,
                suggestedType: resolvedType,
                lat: lat,
                lng: lng,
                distanceMeters: distance,
                source: .db,
                globalVisitCount: d["globalVisitCount"] as? Int
            ))
        }
        #if DEBUG
        print("[PlacePicker] DB name-prefix '\(trimmed)' returned \(out.count) results")
        #endif
        return out
    }

    func autocomplete(_ query: String,
                      around coord: CLLocationCoordinate2D?) async throws -> [PlaceCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // While typing, *don't* restrict to `foodPlaceTypes` — Google's primary
        // type for many F&B venues isn't in our Table-A subset (e.g. Coffee
        // Bean is often `cafe`/`coffee_shop` and a number of mall tenants
        // come back as `establishment` only). Filtering them out at this
        // stage made search feel broken even when the name was typed
        // exactly. The user has typed a name → noise risk is low; rely on
        // our own relevance ranking to keep the list tight.
        // Bias radius widened from 5 km → 25 km so out-of-immediate-area
        // names (the place they're walking to, the spot in the next mall)
        // still surface near the top.
        let bias: (any CoordinateRegionBias)? = coord.map {
            CircularCoordinateRegion(center: $0, radius: 25_000)
        }
        let filter = AutocompleteFilter(
            types: [],
            coordinateRegionBias: bias
        )
        let request = AutocompleteRequest(query: trimmed, filter: filter)

        let result = await PlacesClient.shared.fetchAutocompleteSuggestions(with: request)
        switch result {
        case .success(let suggestions):
            return suggestions.compactMap { Self.candidate(from: $0) }
        case .failure(let err):
            throw err
        }
    }

    /// Best-effort resolve of a Google `place_id` for an app-created place (one
    /// with no stored id), so navigation can route to the real POI instead of a
    /// bare coordinate. Searches the name biased to the place's coordinate, then
    /// keeps a match only when the name is similar AND the resolved point is
    /// close. Returns `nil` when there's no confident match → caller falls back
    /// to the coordinate. (Autocomplete predictions carry no coords, so the top
    /// name matches are distance-verified via `fetchCoordinate`; capped at 2
    /// lookups to bound Places API cost.)
    func resolveGooglePlaceId(name: String,
                              near coord: CLLocationCoordinate2D,
                              maxDistanceMeters: Double = 250) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let candidates = (try? await autocomplete(trimmed, around: coord)) ?? []
        guard !candidates.isEmpty else { return nil }

        let target = MapsNavigation.normalizedName(trimmed)
        let ranked = candidates
            .map { (cand: $0, score: MapsNavigation.nameSimilarity(target, MapsNavigation.normalizedName($0.name))) }
            .filter { $0.score >= 0.5 }
            .sorted { $0.score > $1.score }

        let origin = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        for entry in ranked.prefix(2) {
            guard let pid = entry.cand.googlePlaceId, !pid.isEmpty,
                  let resolved = try? await fetchCoordinate(googlePlaceId: pid) else { continue }
            let meters = CLLocation(latitude: resolved.latitude, longitude: resolved.longitude).distance(from: origin)
            if meters <= maxDistanceMeters { return pid }
        }
        return nil
    }

    /// Resolve coords + name for an autocomplete result that didn't include them.
    func fetchCoordinate(googlePlaceId: String) async throws -> CLLocationCoordinate2D {
        let request = FetchPlaceRequest(
            placeID: googlePlaceId,
            placeProperties: [.coordinate]
        )
        let result = await PlacesClient.shared.fetchPlace(with: request)
        switch result {
        case .success(let place):
            return place.location
        case .failure(let err):
            throw err
        }
    }

    /// Distance with a popularity discount for trending places.
    /// Each visit subtracts ~3 m of perceived distance, capped at 90 m so
    /// the popularity bias never overrides true proximity. Tunable.
    private static func effectiveDistance(_ c: PlaceCandidate) -> Double {
        let base = c.distanceMeters ?? .infinity
        guard let visits = c.globalVisitCount, visits > 0 else { return base }
        let discount = min(Double(visits) * 3.0, 90.0)
        return base - discount
    }

    private static func candidate(from place: GMSPlace,
                                  origin: CLLocationCoordinate2D) -> PlaceCandidate? {
        guard let id = place.placeID else { return nil }
        let coord = place.location
        let originLoc = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let placeLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return PlaceCandidate(
            id: id,
            googlePlaceId: id,
            name: place.displayName ?? "Unnamed",
            address: place.formattedAddress,
            suggestedType: mapType(place.types),
            lat: coord.latitude,
            lng: coord.longitude,
            distanceMeters: placeLoc.distance(from: originLoc),
            source: .google
        )
    }

    private static func candidate(from suggestion: AutocompleteSuggestion) -> PlaceCandidate? {
        switch suggestion {
        case .place(let prediction):
            return PlaceCandidate(
                id: prediction.placeID,
                googlePlaceId: prediction.placeID,
                name: String(prediction.attributedPrimaryText.characters),
                address: prediction.attributedSecondaryText.map { String($0.characters) },
                // Type isn't returned by autocomplete — assume restaurant; user can override.
                suggestedType: .restaurant,
                lat: 0, lng: 0,
                distanceMeters: nil,
                source: .google
            )
        @unknown default:
            return nil
        }
    }

    /// Map Google's category set onto our 3-way enum.
    /// Stalls are never returned by Google — only chosen via user override.
    private static func mapType(_ types: Set<GMSType>) -> PlaceType {
        if types.contains(.cafe) || types.contains(.bakery) { return .cafe }
        return .restaurant
    }
}

/// CoreLocation wrapper kept warm so picker calls return instantly.
/// Starts updating as soon as authorization is granted so `manager.location`
/// is already populated by the time the user taps "Tag a place".
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // Tightest practical accuracy — hundred-meter accuracy was producing
        // bad fixes inside malls/buildings where Wi-Fi triangulation already
        // had the user at the wrong storefront. Battery cost is negligible
        // because we only stream while the app is foregrounded.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // Warm the cache *only if permission is already granted*. Prompting
        // here would fire the system alert on app launch, which would race
        // ahead of the welcome carousel's location-prime card. Prompting is
        // owned by:
        //   - WelcomeView's third card (first-time users), or
        //   - `currentCoordinate()` below (contextual fallback when the
        //     picker is opened by someone who skipped the welcome).
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func currentCoordinate() async -> CLLocationCoordinate2D? {
        // Warm-cache hit — the common case if the user has been on the map page.
        if let cached = manager.location?.coordinate { return cached }
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last?.coordinate
        Task { @MainActor in
            self.continuation?.resume(returning: coord)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(returning: nil)
            self.continuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Once the user grants permission we want a continuous stream so the
        // next picker open is instant.
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            Task { @MainActor in manager.startUpdatingLocation() }
        }
    }
}
