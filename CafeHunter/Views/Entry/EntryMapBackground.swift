import SwiftUI
import MapKit
import CoreLocation

/// The ambient map behind the splash reveal and login sheet. Uses a single
/// `MKMapSnapshotter` still of KL (doc Option A) rather than a live `Map`:
/// buttery at 60fps, no live-tile cost, and a warm wash ties it to the
/// "Clay & Ink" palette. A slow snapshot never flashes blank — the warm
/// `surfaceCanvas` shows underneath until the image lands. Photo pins are
/// SwiftUI overlays positioned via `snapshot.point(for:)`, so they ride the
/// same Ken-Burns transform as the map.
struct EntryMapBackground: View {
    let pins: [EntryPin]

    @State private var snapshot: UIImage?
    @State private var snapPoints: [String: CGPoint] = [:]
    @State private var pan: CGFloat = 0          // 0→1 Ken-Burns progress
    @State private var droppedIDs: Set<String> = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// KL default when the user's location isn't available — matches the
    /// app's existing map default (`MainMapView`), not a hardcoded landmark.
    static let klFallback = CLLocationCoordinate2D(latitude: 3.3370, longitude: 101.5742)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Warm base — also the fallback if the snapshot is slow/fails.
                AppTheme.surfaceCanvas

                if let snapshot {
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: snapshot)
                            .resizable()
                            .frame(width: geo.size.width, height: geo.size.height)

                        ForEach(pins) { pin in
                            if let pt = snapPoints[pin.id] {
                                PhotoPinAnnotation(pin: pin, dropped: droppedIDs.contains(pin.id))
                                    .position(x: pt.x, y: pt.y)
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Slight overfill + slow diagonal drift = the "camera pan".
                    .scaleEffect(reduceMotion ? 1.06 : 1.06 + 0.10 * pan, anchor: .center)
                    .offset(x: reduceMotion ? 0 : -24 * pan,
                            y: reduceMotion ? 0 : -18 * pan)
                    .transition(.opacity)
                }

                // Warm multiply wash over the tiles.
                EntryPalette.mapWash
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
            .task(id: geo.size.width) {
                await loadSnapshot(size: geo.size)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)   // decorative
    }

    // MARK: - Snapshot

    /// Process cache so the splash-reveal map and the login-screen map share
    /// one pixel-identical snapshot (seamless handoff, no second snapshot).
    /// Keyed by rounded centre + size.
    private static var snapCache: [String: MKMapSnapshotter.Snapshot] = [:]

    private func loadSnapshot(size: CGSize) async {
        guard size.width > 1, size.height > 1, snapshot == nil else { return }

        let center = Self.resolveCenter()
        let key = "\(Int(center.latitude * 1e4)),\(Int(center.longitude * 1e4)),\(Int(size.width)),\(Int(size.height))"

        if let cached = Self.snapCache[key] {
            applySnapshot(cached, animated: false)
            startMotion()
            return
        }

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center,
                                            latitudinalMeters: 1400,
                                            longitudinalMeters: 1400)
        options.size = size
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)

        do {
            let snap = try await MKMapSnapshotter(options: options).start()
            Self.snapCache[key] = snap
            applySnapshot(snap, animated: true)
            startMotion()
        } catch {
            // Leave snapshot nil → the warm canvas base carries the screen.
            // Still drop the pins onto the base using a fallback grid so the
            // login screen isn't bare.
            if snapPoints.isEmpty {
                snapPoints = Self.fallbackPoints(for: pins, in: size)
                withAnimation(.easeIn(duration: 0.3)) { self.snapshot = Self.blankCanvas(size) }
            }
            startMotion()
        }
    }

    private func applySnapshot(_ snap: MKMapSnapshotter.Snapshot, animated: Bool) {
        var pts: [String: CGPoint] = [:]
        for pin in pins {
            pts[pin.id] = snap.point(for: pin.coordinate)
        }
        snapPoints = pts
        if animated {
            withAnimation(.easeIn(duration: 0.4)) { snapshot = snap.image }
        } else {
            snapshot = snap.image
        }
    }

    private func startMotion() {
        if reduceMotion {
            droppedIDs = Set(pins.map(\.id))   // settled, no animation
            return
        }
        withAnimation(.linear(duration: 9)) { pan = 1 }
        // Stagger the pin drops ~0.4s apart (doc §4).
        for (i, pin) in pins.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + 0.4 * Double(i)) {
                _ = droppedIDs.insert(pin.id)
            }
        }
    }

    /// Non-prompting locality read: use the cached coordinate only when
    /// location is *already* authorized (the app primes `LocationProvider`
    /// at launch). Never trigger the permission dialog from the entry screen.
    static func resolveCenter() -> CLLocationCoordinate2D {
        let mgr = CLLocationManager()
        let status = mgr.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways,
           let coord = mgr.location?.coordinate {
            return coord
        }
        return klFallback
    }

    /// Even spread of pins for the rare snapshot-failure path so the login
    /// screen still shows life over the warm canvas.
    private static func fallbackPoints(for pins: [EntryPin], in size: CGSize) -> [String: CGPoint] {
        var pts: [String: CGPoint] = [:]
        let cols = max(1, Int(Double(pins.count).squareRoot().rounded(.up)))
        for (i, pin) in pins.enumerated() {
            let col = i % cols, row = i / cols
            pts[pin.id] = CGPoint(
                x: size.width  * (0.22 + 0.56 * Double(col) / Double(max(1, cols - 1))),
                y: size.height * (0.30 + 0.34 * Double(row) / Double(max(1, cols)))
            )
        }
        return pts
    }

    private static func blankCanvas(_ size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(AppTheme.surfaceCanvas).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
