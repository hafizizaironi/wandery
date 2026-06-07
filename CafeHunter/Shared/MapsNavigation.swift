import Foundation
import CoreLocation

/// Builds Google Maps + Waze navigation deep links for a place.
///
/// Tiering (per the place-navigation spec):
///  • **Google Maps + a Google `place_id`** → route to the exact POI by id
///    (`destination_place_id`) instead of the raw coordinate.
///  • **Google Maps + app-created place** (no stored id) → the caller first
///    resolves a `place_id` by name+coordinate
///    (`PlacePickerService.resolveGooglePlaceId`); if found we use it, otherwise
///    we fall back to the coordinate here.
///  • **Waze** (no place-id concept anywhere) → search the name centered on the
///    coordinate (`q` + `ll`). Waze itself matches the named POI near there, or
///    routes to the coordinate when there's no distinct match — its native
///    name+coordinate comparison. Coordinate-only when the place is unnamed.
///
/// Each builder returns an `app` scheme URL (tried first) and a `web`
/// universal-link fallback, matching the existing `openMapsURL` flow.
enum MapsNavigation {

    // MARK: - Google Maps

    /// `googlePlaceId` is the place's stored id, or one resolved by
    /// name+coordinate for an app-created place; `nil` → coordinate fallback.
    static func googleMaps(name: String,
                           coordinate: CLLocationCoordinate2D,
                           googlePlaceId: String?) -> (app: URL?, web: URL?) {
        let latlng = "\(coordinate.latitude),\(coordinate.longitude)"

        if let pid = googlePlaceId, !pid.isEmpty {
            // Universal directions link carrying the exact POI id. `destination`
            // is required alongside `destination_place_id`; opens the Google Maps
            // app via universal links when installed, else the web. The
            // comgooglemaps:// scheme can't carry a place_id, so this link is the
            // only form that preserves it — use it directly (no app-scheme URL).
            let dest = enc(name.isEmpty ? latlng : name)
            let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(dest)&destination_place_id=\(enc(pid))&travelmode=driving")
            return (app: nil, web: web)
        }

        // Coordinate fallback — directions straight to the point.
        let app = URL(string: "comgooglemaps://?daddr=\(latlng)&directionsmode=driving")
        let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(latlng)&travelmode=driving")
        return (app: app, web: web)
    }

    // MARK: - Waze

    static func waze(name: String, coordinate: CLLocationCoordinate2D) -> (app: URL?, web: URL?) {
        let latlng = "\(coordinate.latitude),\(coordinate.longitude)"
        let trimmed = name.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return (URL(string: "waze://?ll=\(latlng)&navigate=yes"),
                    URL(string: "https://waze.com/ul?ll=\(latlng)&navigate=yes"))
        }
        // `q` searched near `ll`: Waze matches the named POI when distinct, else
        // routes to the coordinate — its built-in name+coordinate fallback.
        let q = enc(trimmed)
        return (URL(string: "waze://?q=\(q)&ll=\(latlng)&navigate=yes"),
                URL(string: "https://waze.com/ul?q=\(q)&ll=\(latlng)&navigate=yes"))
    }

    // MARK: - Name matching (used by the app-created resolver)

    /// Lowercased, diacritic-folded, punctuation-stripped tokens joined by
    /// single spaces — so "Häus Café!" and "haus cafe" compare equal.
    static func normalizedName(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 0…1 similarity between two already-normalized names: exact = 1,
    /// containment = 0.85, otherwise Jaccard overlap of word tokens.
    static func nameSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) { return 0.85 }
        let ta = Set(a.split(separator: " "))
        let tb = Set(b.split(separator: " "))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    // MARK: - Helpers

    /// Percent-encode a query VALUE — stricter than `.urlQueryAllowed`, which
    /// leaves `&=+?/#` intact and would break the surrounding params.
    private static func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
