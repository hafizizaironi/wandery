import WidgetKit
import SwiftUI
import UIKit
import AppIntents
import MapKit
import CoreLocation

// ② Nearby Map widget. A static MKMapSnapshotter image centred on the user's
// last-known location, with nearby food spots dropped as category-coloured pins.
// Reuses WanderyTheme / WidgetAvatar / wanderyHue from the Photo Feed files.
//
// Data: the app mirrors a candidate set of places (recent friend-tagged + saved
// hunt, with coords) into the App Group (`SharedFeedStore.readNearbyPlaces`);
// the provider filters by live location + the configured radius. No live/pannable
// map — tapping deep-links into the app's MainMapView / a place.

// MARK: - Category

enum SpotCategory: String {
    case recent, hunt, trend
    var color: Color {
        switch self {
        case .recent: return WanderyTheme.persimmon
        case .hunt:   return WanderyTheme.olive
        case .trend:  return WanderyTheme.honey
        }
    }
    var label: String {
        switch self {
        case .recent: return "Recently tagged"
        case .hunt:   return "On my hunt"
        case .trend:  return "Trending"
        }
    }
}

// MARK: - Configuration (Edit Widget)

enum NearbyRadius: String, AppEnum {
    case m500, km1, km2
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Radius" }
    static var caseDisplayRepresentations: [NearbyRadius: DisplayRepresentation] {
        [.m500: "500 m", .km1: "1 km", .km2: "2 km"]
    }
    var meters: Int {
        switch self {
        case .m500: return 500
        case .km1:  return 1000
        case .km2:  return 2000
        }
    }
}

/// Medium-family layout. A (full map + callout) and C (map + featured card)
/// both work over the full-bleed map; B (map+list split) is deferred (would
/// need the snapshot re-rendered at a sub-region to keep pins aligned).
enum NearbyMediumLayout: String, AppEnum {
    case full, card
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Medium layout" }
    static var caseDisplayRepresentations: [NearbyMediumLayout: DisplayRepresentation] {
        [.full: "Full map + callout", .card: "Map + featured card"]
    }
}

struct NearbyConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Nearby"
    static var description = IntentDescription("Food spots around you.")

    @Parameter(title: "Recently tagged", default: true) var showRecent: Bool
    @Parameter(title: "On my hunt", default: true) var showHunt: Bool
    @Parameter(title: "Trending", default: false) var showTrend: Bool
    @Parameter(title: "Radius", default: .km1) var radius: NearbyRadius
    @Parameter(title: "Medium layout", default: .full) var mediumLayout: NearbyMediumLayout

    var categories: Set<String> {
        var c: Set<String> = []
        if showRecent { c.insert("recent") }
        if showHunt { c.insert("hunt") }
        if showTrend { c.insert("trend") }
        return c
    }
}

// MARK: - Timeline model

struct NearbyPin: Identifiable {
    let id: String
    let xFrac: Double
    let yFrac: Double
    let category: SpotCategory
    let name: String
    let friendInitial: String?
    let friendHue: Double?
    let distanceM: Int
    let trendCount: Int?

    var distanceLabel: String {
        distanceM < 1000 ? "\(distanceM) m" : String(format: "%.1f km", Double(distanceM) / 1000)
    }
}

struct NearbyEntry: TimelineEntry {
    let date: Date
    let mapImage: Data?
    let youFrac: CGPoint
    /// The signed-in user's profile photo for the "you" marker (nil → dot).
    let youAvatar: Data?
    let pins: [NearbyPin]
    let nearest: NearbyPin?
    let totalCount: Int
    let mediumLayout: NearbyMediumLayout

    init(date: Date, mapImage: Data?, youFrac: CGPoint, youAvatar: Data? = nil,
         pins: [NearbyPin], nearest: NearbyPin?, totalCount: Int,
         mediumLayout: NearbyMediumLayout = .full) {
        self.date = date
        self.mapImage = mapImage
        self.youFrac = youFrac
        self.youAvatar = youAvatar
        self.pins = pins
        self.nearest = nearest
        self.totalCount = totalCount
        self.mediumLayout = mediumLayout
    }

    static var empty: NearbyEntry {
        NearbyEntry(date: Date(), mapImage: nil, youFrac: CGPoint(x: 0.5, y: 0.5),
                    pins: [], nearest: nil, totalCount: 0)
    }
}

// MARK: - Provider

struct NearbyProvider: AppIntentTimelineProvider {
    typealias Entry = NearbyEntry
    typealias Intent = NearbyConfig

    private static let fallback = CLLocationCoordinate2D(latitude: 1.3146, longitude: 103.9000)
    private static let refresh: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> NearbyEntry { .empty }

    func snapshot(for configuration: NearbyConfig, in context: Context) async -> NearbyEntry {
        await Self.build(configuration, size: context.displaySize)
    }

    func timeline(for configuration: NearbyConfig, in context: Context) async -> Timeline<NearbyEntry> {
        let entry = await Self.build(configuration, size: context.displaySize)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(Self.refresh)))
    }

    /// Last-known coarse fix — never a continuous stream (NSWidgetWantsLocation
    /// + the app's When-In-Use authorization). Falls back to a default centre.
    private static func currentLocation() -> CLLocationCoordinate2D {
        CLLocationManager().location?.coordinate ?? fallback
    }

    private static func build(_ config: NearbyConfig, size: CGSize) async -> NearbyEntry {
        let here = currentLocation()
        let radius = config.radius.meters
        let cats = config.categories
        let hereLoc = CLLocation(latitude: here.latitude, longitude: here.longitude)
        let youAvatar = await fetchMeAvatar()

        // Merge recent/hunt (one key) + trending (another), dedup by id with
        // recent/hunt precedence, then filter by category + radius, nearest first.
        var byId: [String: SharedFeedStore.WidgetPlace] = [:]
        for p in SharedFeedStore.readNearbyPlaces() + SharedFeedStore.readTrendingPlaces()
        where cats.contains(p.category) {
            if byId[p.id] == nil { byId[p.id] = p }
        }
        let candidates = byId.values
            .map { (p: $0, d: hereLoc.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng))) }
            .filter { $0.d <= Double(radius) }
            .sorted { $0.d < $1.d }

        let mapSize = (size == .zero) ? CGSize(width: 338, height: 354) : size
        let opts = MKMapSnapshotter.Options()
        opts.region = MKCoordinateRegion(center: here,
            latitudinalMeters: Double(radius) * 2.4, longitudinalMeters: Double(radius) * 2.4)
        opts.size = mapSize
        opts.scale = 2
        opts.mapType = .mutedStandard
        opts.pointOfInterestFilter = .excludingAll
        opts.showsBuildings = true

        guard let snap = try? await MKMapSnapshotter(options: opts).start() else {
            return NearbyEntry(date: Date(), mapImage: nil, youFrac: CGPoint(x: 0.5, y: 0.5),
                               youAvatar: youAvatar, pins: [], nearest: nil,
                               totalCount: candidates.count, mediumLayout: config.mediumLayout)
        }

        func frac(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let p = snap.point(for: coord)
            return CGPoint(x: p.x / opts.size.width, y: p.y / opts.size.height)
        }

        let youFrac = frac(here)
        var pins: [NearbyPin] = []
        for c in candidates.prefix(10) {
            let f = frac(CLLocationCoordinate2D(latitude: c.p.lat, longitude: c.p.lng))
            guard f.x > -0.15, f.x < 1.15, f.y > -0.15, f.y < 1.15 else { continue }
            let cat = SpotCategory(rawValue: c.p.category) ?? .recent
            pins.append(NearbyPin(
                id: c.p.id, xFrac: f.x, yFrac: f.y, category: cat, name: c.p.name,
                friendInitial: c.p.friendName?.first.map { String($0).uppercased() },
                friendHue: c.p.friendId.map { wanderyHue(for: $0) },
                distanceM: Int(c.d), trendCount: c.p.trendCount))
        }

        return NearbyEntry(date: Date(),
                           mapImage: snap.image.jpegData(compressionQuality: 0.9),
                           youFrac: youFrac, youAvatar: youAvatar, pins: pins,
                           nearest: pins.first, totalCount: candidates.count,
                           mediumLayout: config.mediumLayout)
    }

    /// The signed-in user's profile photo for the "you" marker. Cache-first
    /// (kept under "avatar#" so the Photo Feed prune skips it); nil → dot.
    private static func fetchMeAvatar() async -> Data? {
        let key = "avatar#me"
        if let cached = SharedFeedStore.readThumb(key) { return cached }
        guard let s = SharedFeedStore.readMyPhotoURL(), let url = URL(string: s),
              let (raw, _) = try? await URLSession.shared.data(from: url),
              let ui = await ImageDecoding.prepared(from: raw, maxPixel: 120),
              let jpeg = ui.jpegData(compressionQuality: 0.85) else { return nil }
        SharedFeedStore.writeThumb(jpeg, key: key)
        return jpeg
    }
}

// MARK: - Pin / dot / callout views

struct PinView: View {
    let pin: NearbyPin
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pin.category.color)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(45))
                .overlay(Circle().fill(.white).frame(width: 7, height: 7))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            if pin.category == .recent, let initial = pin.friendInitial, let hue = pin.friendHue {
                WidgetAvatar(initials: initial, hue: hue, size: 18).offset(y: -15)
            }
        }
    }
}

struct YouDotView: View {
    var avatar: Data? = nil
    var body: some View {
        ZStack {
            Circle().fill(WanderyTheme.persimmon.opacity(0.22)).frame(width: 34, height: 34)   // halo
            if let avatar, let ui = UIImage(data: avatar) {
                // The user's profile picture as the location marker.
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(WanderyTheme.persimmon, lineWidth: 3))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            } else {
                Circle().fill(WanderyTheme.persimmon).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
        }
    }
}

struct CalloutView: View {
    let pin: NearbyPin
    /// "Close" state — a hunt spot within reach: olive bubble + "nearly there".
    var close: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            if close {
                Image(systemName: "figure.walk").font(.system(size: 11, weight: .bold))
                Text("\(pin.distanceLabel) — nearly there")
                    .font(.system(size: 11.5, weight: .bold)).lineLimit(1)
            } else {
                Circle().fill(pin.category.color).frame(width: 7, height: 7)
                Text(pin.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
                Text(pin.distanceLabel).font(.system(size: 11, weight: .semibold)).opacity(0.65)
            }
        }
        .foregroundStyle(close ? .white : WanderyTheme.ink)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(close ? AnyShapeStyle(WanderyTheme.olive) : AnyShapeStyle(.regularMaterial), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(close ? 0.4 : 0.25)))
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
    }
}

struct NearbyHeaderChip: View {
    let count: Int
    var body: some View {
        Text("Nearby · \(count)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(WanderyTheme.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}

struct RecenterGlyph: View {
    var body: some View {
        Image(systemName: "location.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(WanderyTheme.ink)
            .frame(width: 26, height: 26)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.3)))
    }
}

struct SpotRow: View {
    let pin: NearbyPin
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(pin.category.color).frame(width: 9, height: 9)
            Text(pin.name).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WanderyTheme.ink).lineLimit(1)
            Spacer(minLength: 6)
            if pin.category == .recent, let initial = pin.friendInitial, let hue = pin.friendHue {
                WidgetAvatar(initials: initial, hue: hue, size: 18)
            } else if pin.category == .trend, let n = pin.trendCount {
                Text("🔥\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(WanderyTheme.ink)
            }
            Text(pin.distanceLabel).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WanderyTheme.ink.opacity(0.6))
        }
    }
}

// MARK: - Pin layer (map overlays, positioned by fraction)

struct NearbyPinLayer: View {
    let entry: NearbyEntry
    var linked: Bool
    var callout: Bool
    var maxPins: Int = 8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ForEach(Array(entry.pins.prefix(maxPins))) { pin in
                    pinLink(pin) { PinView(pin: pin) }
                        .position(x: pin.xFrac * w, y: pin.yFrac * h)
                }
                YouDotView(avatar: entry.youAvatar)
                    .position(x: entry.youFrac.x * w, y: entry.youFrac.y * h)
                if callout, let n = entry.nearest {
                    let close = n.category == .hunt && n.distanceM <= 150
                    pinLink(n) { CalloutView(pin: n, close: close) }
                        .position(x: min(max(n.xFrac * w, 64), w - 64),
                                  y: max(22, n.yFrac * h - 24))
                }
            }
        }
    }

    @ViewBuilder
    private func pinLink<V: View>(_ pin: NearbyPin, @ViewBuilder _ content: () -> V) -> some View {
        if linked, let url = URL(string: "wandery://place/\(pin.id)") {
            Link(destination: url) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Family views

struct NearbySmallView: View {
    let entry: NearbyEntry
    var body: some View {
        NearbyPinLayer(entry: entry, linked: false, callout: false, maxPins: 4)
            .overlay(alignment: .bottom) {
                if let n = entry.nearest {
                    HStack(spacing: 5) {
                        Circle().fill(n.category.color).frame(width: 6, height: 6)
                        Text(n.name).font(.system(size: 10.5, weight: .bold)).lineLimit(1)
                        Text(n.distanceLabel).font(.system(size: 10, weight: .semibold)).opacity(0.7)
                    }
                    .foregroundStyle(WanderyTheme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
                }
            }
    }
}

struct NearbyMediumView: View {
    let entry: NearbyEntry
    var body: some View {
        switch entry.mediumLayout {
        case .card: card
        case .full: full
        }
    }

    // A · full map + nearest callout (default).
    private var full: some View {
        NearbyPinLayer(entry: entry, linked: true, callout: true)
            .overlay(alignment: .topLeading) { NearbyHeaderChip(count: entry.totalCount).padding(12) }
            .overlay(alignment: .topTrailing) { RecenterGlyph().padding(12) }
    }

    // C · full-bleed map + a glass featured card for the closest spot.
    private var card: some View {
        NearbyPinLayer(entry: entry, linked: true, callout: false)
            .overlay(alignment: .topLeading) { NearbyHeaderChip(count: entry.totalCount).padding(12) }
            .overlay(alignment: .bottom) {
                if let n = entry.nearest, let url = URL(string: "wandery://place/\(n.id)") {
                    Link(destination: url) {
                        HStack(spacing: 9) {
                            Circle().fill(n.category.color).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.name).font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(WanderyTheme.ink).lineLimit(1)
                                Text(n.distanceLabel).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(WanderyTheme.ink.opacity(0.6))
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(WanderyTheme.ink.opacity(0.5))
                        }
                        .padding(11)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(12)
                    }
                }
            }
    }
}

struct NearbyLargeView: View {
    let entry: NearbyEntry
    var body: some View {
        ZStack(alignment: .bottom) {
            NearbyPinLayer(entry: entry, linked: true, callout: true)
            if !entry.pins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entry.pins.prefix(3))) { pin in
                        if let url = URL(string: "wandery://place/\(pin.id)") {
                            Link(destination: url) { SpotRow(pin: pin) }
                        } else {
                            SpotRow(pin: pin)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WanderyTheme.paper)
            }
        }
        .overlay(alignment: .topLeading) { NearbyHeaderChip(count: entry.totalCount).padding(14) }
    }
}

struct AllQuietLabel: View {
    var body: some View {
        VStack {
            Spacer()
            Text("All quiet nearby. Widen your radius or check back later.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WanderyTheme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(14)
        }
    }
}

// MARK: - Entry view + widget

struct NearbyEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NearbyEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { background }
            .widgetURL(URL(string: "wandery://nearby"))
    }

    @ViewBuilder private var content: some View {
        ZStack {
            switch family {
            case .systemSmall: NearbySmallView(entry: entry)
            case .systemLarge: NearbyLargeView(entry: entry)
            default:           NearbyMediumView(entry: entry)
            }
            if entry.pins.isEmpty { AllQuietLabel() }
        }
    }

    @ViewBuilder private var background: some View {
        ZStack {
            if let data = entry.mapImage, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .saturation(entry.pins.isEmpty ? 0.35 : 1.0)
                WanderyTheme.cream.opacity(0.10)   // faint warmth over Apple's palette
            } else {
                WanderyTheme.paper
            }
        }
    }
}

struct NearbyMapWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "WanderyNearbyMap", intent: NearbyConfig.self, provider: NearbyProvider()) { entry in
            NearbyEntryView(entry: entry)
        }
        .configurationDisplayName("Nearby")
        .description("Food spots around you — tap to open the map.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
