import SwiftUI
import MapKit
import CoreLocation

/// The looping map fly-over behind the login sheet. A live `Map` whose camera
/// glides along a closed path threading the trending pins; each photo pops in
/// as the camera nears it and eases back as it passes, so the loop is seamless
/// (no jarring reset — the path ends where it began).
///
/// Pins are real cached "trending" places (`EntryTrendingStore`) when we have
/// them, or a curated demo scatter on a true first launch. Under Reduce Motion
/// the camera holds a static frame that fits every pin, all settled.
///
/// A live `Map` (rather than the static snapshot used by `EntryMapBackground`)
/// is the right tool here: the camera animation and map-anchored annotations
/// are exactly what a fly-over needs. The camera is driven by animating the
/// `position` binding leg-by-leg — reliable, and it lets each pin "settle" for
/// a beat as the photo lands. The warm wash on top mutes the standard tiles to
/// the "Clay & Ink" palette.
struct EntryMapFlyover: View {
    let pins: [EntryPin]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: MapCameraPosition
    @State private var nearIDs: Set<String> = []
    /// The visible vertical extent (metres) MapKit actually reports at our
    /// fixed camera distance — measured once on the first camera change, then
    /// used to bias framing and the pop threshold. Distance is constant, so
    /// this settles to a stable value and stops churning.
    @State private var spanMeters: Double?

    /// Seconds the camera spends gliding from one pin to the next, then the
    /// beat it holds on the pin so the photo can land and be seen.
    private let legGlide: Double = 2.4
    private let pinHold: Double = 0.55

    /// The login sheet covers the lower ~60% of the screen, so a pin framed at
    /// the map's true centre would land *behind* the panel. Shift the camera
    /// centre south of each target by this fraction of the visible span, so the
    /// pin rides up to ~25% from the top — comfortably in the visible strip.
    private let shiftFraction: Double = 0.25

    // Precomputed once from `pins` (cheap; a handful of coordinates).
    private let ordered: [EntryPin]
    private let centroid: CLLocationCoordinate2D
    private let tourDistance: CLLocationDistance
    private let fitDistance: CLLocationDistance

    init(pins: [EntryPin]) {
        self.pins = pins
        let coords = pins.map(\.coordinate)
        let c = Self.centroid(of: coords)
        let spread = Self.spreadMeters(coords, centroid: c)
        let orderedPins = Self.orderedAroundCentroid(pins, centroid: c)
        self.centroid = c
        self.ordered = orderedPins
        // Close enough to feel each pin while gliding; clamped so a tight demo
        // cluster doesn't zoom to rooftops and a wide spread stays watchable.
        self.tourDistance = min(2600, max(1100, spread * 1.2))
        // Reduce Motion: pull back far enough to frame every pin at once.
        self.fitDistance = min(6000, max(900, spread * 2.6))

        // Span isn't known until the map reports it, so seed the very first
        // frame with a rough guess (span ≈ 0.6·distance for muted top-down).
        let start = orderedPins.first?.coordinate ?? EntryMapBackground.klFallback
        let seedBiasDeg = (tourDistance * 0.6 * 0.25) / 111_000
        _camera = State(initialValue: .camera(MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: start.latitude - seedBiasDeg,
                                                     longitude: start.longitude),
            distance: tourDistance, heading: 0, pitch: 0)))
    }

    /// After the start pin: the rest of the ring, then back to the start so the
    /// loop closes onto itself with no visible seam.
    private var tourLegs: [EntryPin] {
        guard ordered.count > 1 else { return ordered }
        return Array(ordered.dropFirst()) + [ordered[0]]
    }

    /// Camera centre for a pin: shifted south by a fraction of the *visible
    /// span* so the pin appears in the strip above the login sheet.
    private func framing(for coordinate: CLLocationCoordinate2D,
                         distance: CLLocationDistance) -> MapCameraPosition {
        let span = spanMeters ?? (distance * 0.6)
        let biasDegrees = (span * shiftFraction) / 111_000
        return .camera(MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: coordinate.latitude - biasDegrees,
                                                     longitude: coordinate.longitude),
            distance: distance, heading: 0, pitch: 0))
    }

    var body: some View {
        ZStack {
            // Warm base shows while the first tiles load.
            AppTheme.surfaceCanvas

            Map(position: $camera, interactionModes: []) {
                ForEach(pins) { pin in
                    Annotation("", coordinate: pin.coordinate, anchor: .bottom) {
                        PhotoPinAnnotation(pin: pin, dropped: nearIDs.contains(pin.id))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat,
                                pointsOfInterest: .excludingAll,
                                showsTraffic: false))
            .mapControlVisibility(.hidden)
            .disabled(true)
            .onMapCameraChange(frequency: .continuous) { context in
                updateProximity(context)
            }

            EntryPalette.mapWash
                .blendMode(.multiply)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)   // decorative
        .task { await runTour() }
    }

    // MARK: - Tour

    private func runTour() async {
        guard !reduceMotion, ordered.count >= 2 else {
            // Static frame fitting every pin, all settled.
            camera = framing(for: centroid, distance: fitDistance)
            nearIDs = Set(pins.map(\.id))
            return
        }
        // Let the first frame settle so we know the real visible span, then
        // bias every leg (including the first) accurately.
        for _ in 0..<12 where spanMeters == nil {
            try? await Task.sleep(for: .seconds(0.05))
            if Task.isCancelled { return }
        }
        // Glide start → each remaining pin → back to start, then repeat. We
        // begin already parked on the start pin, so every loop is seamless.
        while !Task.isCancelled {
            for pin in tourLegs {
                withAnimation(.easeInOut(duration: legGlide)) {
                    camera = framing(for: pin.coordinate, distance: tourDistance)
                }
                try? await Task.sleep(for: .seconds(legGlide + pinHold))
                if Task.isCancelled { return }
            }
        }
    }

    /// Pop a pin in once the camera comes within ~42% of the visible span of
    /// its centre, and let it recede as the camera moves on — drives the
    /// "photos appear along the path" feel and re-fires every loop. Also the
    /// place we learn the real visible span.
    private func updateProximity(_ context: MapCameraUpdateContext) {
        guard !reduceMotion else { return }
        let visibleMeters = context.region.span.latitudeDelta * 111_000
        if spanMeters == nil || abs((spanMeters ?? 0) - visibleMeters) > 20 {
            spanMeters = visibleMeters
        }

        let center = context.region.center
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let threshold = max(220, visibleMeters * 0.42)

        var near: Set<String> = []
        for pin in pins {
            let d = CLLocation(latitude: pin.coordinate.latitude,
                               longitude: pin.coordinate.longitude).distance(from: here)
            if d < threshold { near.insert(pin.id) }
        }
        if near != nearIDs { nearIDs = near }
    }

    // MARK: - Geometry

    private static func centroid(of coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !coords.isEmpty else { return EntryMapBackground.klFallback }
        let lat = coords.reduce(0) { $0 + $1.latitude } / Double(coords.count)
        let lng = coords.reduce(0) { $0 + $1.longitude } / Double(coords.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private static func spreadMeters(_ coords: [CLLocationCoordinate2D],
                                     centroid c: CLLocationCoordinate2D) -> CLLocationDistance {
        let cl = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return coords
            .map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: cl) }
            .max() ?? 600
    }

    /// Order pins by bearing around the centroid so the camera traces a smooth
    /// ring rather than zig-zagging across the cluster.
    private static func orderedAroundCentroid(_ pins: [EntryPin],
                                              centroid c: CLLocationCoordinate2D) -> [EntryPin] {
        pins.sorted { bearing(from: c, to: $0.coordinate) < bearing(from: c, to: $1.coordinate) }
    }

    private static func bearing(from: CLLocationCoordinate2D,
                                to: CLLocationCoordinate2D) -> Double {
        atan2(to.longitude - from.longitude, to.latitude - from.latitude)
    }
}
