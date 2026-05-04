import Foundation
import CoreLocation
import GooglePlacesSwift
import FirebaseAuth
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

    /// Default search radius — small because we want the user's *current* place,
    /// not "anything in the neighborhood." Picker can widen via UI later.
    static let defaultRadiusMeters: Double = 200

    /// Google categories we surface. Stalls have no Google equivalent — user adds those manually.
    private let foodPlaceTypes: Set<GMSType> = [
        .restaurant, .cafe, .bakery, .bar, .mealTakeaway, .mealDelivery, .food, .nightClub,
    ]

    func nearby(_ coord: CLLocationCoordinate2D,
                radius: Double = defaultRadiusMeters) async throws -> [PlaceCandidate] {
        // Run both sources in parallel — each may fail/return empty
        // independently. Google failure must NOT erase DB results (and vice
        // versa), so we collect Result values rather than throwing eagerly.
        async let dbResult: Result<[PlaceCandidate], Error> = {
            do { return .success(try await self.fetchMyNearbyDbPlaces(coord: coord, radius: radius)) }
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
        let merged = (db + filteredGoogle).sorted {
            ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity)
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
            maxResultCount: 15,
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

    /// Fetches places the current user has previously created/tagged, filtered
    /// by distance from `coord`. Reads dict fields directly (not via Codable)
    /// because subtle decode failures previously made places silently vanish.
    /// Other users' places aren't included here — that needs geohash-bound
    /// queries (deferred to Phase 3 with the trending-nearby work).
    private func fetchMyNearbyDbPlaces(coord: CLLocationCoordinate2D,
                                       radius: Double) async throws -> [PlaceCandidate] {
        guard let uid = Auth.auth().currentUser?.uid else {
            #if DEBUG
            print("[PlacePicker] no signed-in user — skipping DB nearby")
            #endif
            return []
        }
        let snap = try await Firestore.firestore()
            .collection("places")
            .whereField("createdBy", isEqualTo: uid)
            .limit(to: 200)
            .getDocuments()

        let origin = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let allowedRadius = max(radius, 500)
        var matched: [PlaceCandidate] = []
        for doc in snap.documents {
            let d = doc.data()
            guard let name = d["name"] as? String,
                  let lat = d["lat"] as? Double,
                  let lng = d["lng"] as? Double else {
                continue
            }
            let placeLoc = CLLocation(latitude: lat, longitude: lng)
            let distance = placeLoc.distance(from: origin)
            guard distance <= allowedRadius else { continue }
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
                source: .db
            ))
        }
        #if DEBUG
        print("[PlacePicker] found \(matched.count) of \(snap.documents.count) of my places within \(Int(allowedRadius))m of (\(coord.latitude), \(coord.longitude))")
        #endif
        return matched
    }

    func autocomplete(_ query: String,
                      around coord: CLLocationCoordinate2D?) async throws -> [PlaceCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let bias: (any CoordinateRegionBias)? = coord.map {
            CircularCoordinateRegion(center: $0, radius: 5_000)
        }
        let filter = AutocompleteFilter(
            types: foodPlaceTypes,
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
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Kick off authorization + a continuous stream so we have a warm
        // location when the picker is later opened.
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
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
