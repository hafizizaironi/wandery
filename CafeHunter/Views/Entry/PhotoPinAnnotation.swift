import SwiftUI
import CoreLocation

/// One pin on the entry map — a hunt photo tag + profile badge over a
/// teardrop. Backed either by a remote photo (`photoURL`, real-data pins) or
/// an asset/`MockImage` name (`photoName`, demo pins on the signed-out login
/// screen).
struct EntryPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    var photoURL: URL?
    var photoName: String?
    var profileLetter: String
    /// 0…1 badge hue.
    var hue: Double
    var isStall: Bool

    /// A curated scatter of demo pins around `center` for the signed-out
    /// login screen, where no authenticated place data is available. Photos
    /// resolve through `MockImage` (branded placeholders until real art ships).
    static func demoPins(around center: CLLocationCoordinate2D) -> [EntryPin] {
        let specs: [(dLat: Double, dLng: Double, photo: String, letter: String, hue: Double, stall: Bool)] = [
            (0.0026, -0.0030, "mock_cafe1",  "A", 0.05, false),
            (-0.0021, 0.0034, "mock_food1",  "S", 0.55, false),
            (0.0038, 0.0018, "mock_stall1",  "H", 0.30, true),
            (-0.0034, -0.0022, "mock_cafe2", "M", 0.95, false),
            (0.0009, 0.0040, "mock_food2",   "R", 0.12, false),
            (-0.0040, 0.0007, "mock_stall2", "N", 0.40, true),
        ]
        return specs.enumerated().map { i, s in
            EntryPin(
                id: "demo-\(i)",
                coordinate: CLLocationCoordinate2D(latitude: center.latitude + s.dLat,
                                                   longitude: center.longitude + s.dLng),
                photoURL: nil,
                photoName: s.photo,
                profileLetter: s.letter,
                hue: s.hue,
                isStall: s.stall
            )
        }
    }

    /// Real "trending" places cached from a prior signed-in Discover load,
    /// nearest to `center` first. Empty when there's no cache (true first
    /// launch) → the caller falls back to `demoPins`. These carry no profile
    /// letter: `discoverFeed` strips uids, so the signed-out login screen
    /// reveals nothing about who posted (the badge is hidden when empty).
    static func trendingPins(near center: CLLocationCoordinate2D, limit: Int = 6) -> [EntryPin] {
        let items = EntryTrendingStore.load()
        guard !items.isEmpty else { return [] }
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return items
            .sorted { a, b in
                CLLocation(latitude: a.lat, longitude: a.lng).distance(from: here)
                    < CLLocation(latitude: b.lat, longitude: b.lng).distance(from: here)
            }
            .prefix(limit)
            .map { item in
                EntryPin(
                    id: item.id,
                    coordinate: CLLocationCoordinate2D(latitude: item.lat, longitude: item.lng),
                    photoURL: URL(string: item.photoURL),
                    photoName: nil,
                    profileLetter: "",
                    hue: 0,
                    isStall: PlaceType(rawValue: item.type) == .stall
                )
            }
    }

    /// Pins for the signed-out login fly-over: real trending if we have a
    /// decent cache, otherwise the curated demo scatter. Memoized for the
    /// process so repeated body evaluations don't re-read the cache from disk.
    static func loginPins(around center: CLLocationCoordinate2D) -> [EntryPin] {
        if let cached = cachedLoginPins { return cached }
        let trending = trendingPins(near: center)
        let result = trending.count >= 3 ? trending : demoPins(around: center)
        cachedLoginPins = result
        return result
    }

    private static var cachedLoginPins: [EntryPin]?
}

/// Drop-in annotation: teardrop pops first, the photo card drops from above
/// with a slight overshoot, and a ripple ring expands out. The parent toggles
/// `dropped` per pin on a stagger. Under Reduce Motion everything renders in
/// its settled state with no movement.
struct PhotoPinAnnotation: View {
    let pin: EntryPin
    let dropped: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settled: Bool { dropped || reduceMotion }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Ripple ring — expands and fades as the pin lands.
            Circle()
                .stroke(AppTheme.cafeAccent, lineWidth: 2)
                .frame(width: 38, height: 38)
                .scaleEffect(settled ? 2.6 : 0.5)
                .opacity(settled ? 0 : 0.55)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: dropped)

            // Teardrop tail anchored at the coordinate.
            PinTail()
                .fill(pin.isStall ? AppTheme.stallAccent : AppTheme.cafeAccent)
                .frame(width: 15, height: 17)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .scaleEffect(settled ? 1 : 0.01, anchor: .bottom)

            // Photo card with profile badge — drops in from above the tail.
            photoCard
                .offset(y: settled ? -40 : -70)
                .scaleEffect(settled ? 1 : 0.6, anchor: .bottom)
                .opacity(settled ? 1 : 0)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.62), value: dropped)
    }

    private var photoCard: some View {
        let side: CGFloat = 46
        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = pin.photoURL {
                    CachedAsyncImage(url: url, maxPixelSize: 256) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            MockImage(name: pin.photoName ?? "mock_cafe1")
                        }
                    }
                } else {
                    MockImage(name: pin.photoName ?? "mock_cafe1")
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.25), radius: 5, y: 3)

            // Demo pins carry a contributor initial for social proof; real
            // trending pins have none (uids are stripped), so hide it.
            if !pin.profileLetter.isEmpty {
                Text(pin.profileLetter)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(Color(hue: pin.hue, saturation: 0.5, brightness: 0.72))
                    )
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: 6, y: 6)
            }
        }
    }
}
