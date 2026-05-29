import CoreLocation
import MapKit

/// Reverse-geocoding with an iOS-version split: `MKReverseGeocodingRequest`
/// (iOS 26) for current users, `CLGeocoder` (iOS 18–25) for everyone below.
/// Single source of truth so both the login locality hint and the My Hunt
/// city labels behave the same on every OS.
enum Geocoding {
    /// City / locality name for a coordinate, or nil if it can't be resolved.
    static func cityName(at location: CLLocation) async -> String? {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            let items = (try? await request.mapItems) ?? []
            let city = items.first?.addressRepresentations?.cityName
            return (city?.isEmpty == false) ? city : nil
        } else {
            let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
            let city = placemarks?.first?.locality
            return (city?.isEmpty == false) ? city : nil
        }
    }
}
