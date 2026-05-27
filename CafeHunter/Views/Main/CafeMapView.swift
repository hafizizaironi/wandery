import SwiftUI
import MapKit
import CoreLocation
import FirebaseFirestore

// MARK: - Avatar store

/// Lazily hydrates `users/{uid}` photo URLs for the small set of authors
/// referenced by visible map pins. Cached in-memory across renders so each
/// uid is fetched at most once per app session. Cheap O(N) fetches with N
/// = number of distinct friend-tag authors currently on the map.
@MainActor
@Observable
final class MapAvatarStore {
    /// uid → photoURL for users where a non-empty photoURL was found.
    private(set) var photoURLByUid: [String: String] = [:]
    private var checked: Set<String> = []
    private var inflight: Set<String> = []
    private let db = Firestore.firestore()

    func hydrate(uids: Set<String>) async {
        let missing = uids.subtracting(checked).subtracting(inflight)
        guard !missing.isEmpty else { return }
        inflight.formUnion(missing)
        await withTaskGroup(of: (String, String?).self) { group in
            for uid in missing {
                group.addTask { [db] in
                    let snap = try? await db.collection("users").document(uid).getDocument()
                    let url = snap?.data()?["photoURL"] as? String
                    return (uid, url)
                }
            }
            for await (uid, url) in group {
                checked.insert(uid)
                inflight.remove(uid)
                if let url, !url.isEmpty {
                    photoURLByUid[uid] = url
                }
            }
        }
    }
}

// MARK: - Avatar arc geometry

/// Computes evenly-spaced offsets along the upper arc of a circle of radius
/// `arcRadius`. Used by the friend-place pins to halo the pin with the
/// profile pictures of the users who tagged that location.
///
/// `count` = how many avatars to lay out (capped at `maxDisplayed`).
/// `spreadDegrees` = angular gap between adjacent avatars.
/// Returned offsets are SwiftUI-coordinate (`y` positive = down).
struct ArcAvatarLayout {
    static let maxDisplayed = 5
    static let spreadDegrees: Double = 30
    static let arcRadius: CGFloat = 26

    static func offsets(count: Int) -> [CGSize] {
        let n = min(count, maxDisplayed)
        guard n > 0 else { return [] }
        let centerAngle: Double = 90  // top of pin in math coords
        let totalSpread = Double(n - 1) * spreadDegrees
        let startAngle = centerAngle - totalSpread / 2
        return (0..<n).map { i in
            let deg = startAngle + Double(i) * spreadDegrees
            let rad = deg * .pi / 180
            // SwiftUI: y positive is down, so negate sin(θ).
            return CGSize(
                width: arcRadius * CGFloat(cos(rad)),
                height: -arcRadius * CGFloat(sin(rad))
            )
        }
    }
}

/// Avatar bubble used by both single-place and cluster pins. Falls back to
/// initials in the accent gradient when there's no photoURL.
struct PinAvatarBubble: View {
    let urlString: String?
    let initials: String
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: initialsBackground
                    }
                }
            } else {
                initialsBackground
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
    }

    private var initialsBackground: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials.prefix(1))
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundColor(AppTheme.cream)
        }
    }
}

// MARK: - User Location Marker

/// The signed-in user's own position on the map: their profile picture ringed
/// in white, sitting over a soft accent halo that pulses outward forever to
/// draw the eye. Replaces MapKit's default blue user-location dot.
struct UserLocationAvatar: View {
    let photoURL: String?
    @State private var pulsing = false

    var body: some View {
        ZStack {
            // Pulsing halo — grows + fades on a loop. The animation is keyed to
            // `pulsing`, flipped once on appear, so it runs continuously.
            Circle()
                .fill(AppTheme.accentAction.opacity(0.35))
                .frame(width: 40, height: 40)
                .scaleEffect(pulsing ? 2.4 : 1.0)
                .opacity(pulsing ? 0.0 : 0.7)

            // Avatar
            Group {
                if let s = photoURL, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: fallback
                        }
                    }
                } else {
                    fallback
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }

    private var fallback: some View {
        ZStack {
            AppTheme.accentAction
            Image(systemName: "person.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Location Manager

@MainActor @Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    var userLocation: CLLocationCoordinate2D?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coord = location.coordinate
        Task { @MainActor in
            self.userLocation = coord
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}

// MARK: - Friend-place clustering
//
// In dense venues (malls, food courts) many distinct places share nearly
// identical coords, which makes pins overlap into an unreadable smudge.
// We greedily group places that are within ~`thresholdMeters` of an existing
// cluster's running-mean center, then render one pin per cluster. Solo
// clusters use the existing `FriendPlacePinView`; multi-place clusters use
// `FriendPlaceClusterPinView` and tap opens a small picker.

struct FriendPlaceCluster: Identifiable {
    /// Stable id derived from the first place in the cluster — survives
    /// cluster reshuffles only when the same place stays as the seed.
    let id: String
    var places: [FriendPlace]
    var center: CLLocationCoordinate2D

    var dominantType: PlaceType {
        let counts = Dictionary(grouping: places, by: \.type).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key ?? .restaurant
    }
}

/// Single-pass greedy cluster: each place either joins the first existing
/// cluster within `thresholdMeters` or seeds a new one. Cheap (O(n × k)) and
/// good enough for the ~hundreds-of-places scale we'll have for a long time.
func clusterFriendPlaces(_ places: [FriendPlace],
                         thresholdMeters: Double = 60) -> [FriendPlaceCluster] {
    var clusters: [FriendPlaceCluster] = []
    for p in places {
        let pLoc = CLLocation(latitude: p.lat, longitude: p.lng)
        if let idx = clusters.firstIndex(where: { c in
            CLLocation(latitude: c.center.latitude, longitude: c.center.longitude)
                .distance(from: pLoc) <= thresholdMeters
        }) {
            clusters[idx].places.append(p)
            let n = Double(clusters[idx].places.count)
            let lat = clusters[idx].places.map(\.lat).reduce(0, +) / n
            let lng = clusters[idx].places.map(\.lng).reduce(0, +) / n
            clusters[idx].center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        } else {
            clusters.append(FriendPlaceCluster(
                id: p.id,
                places: [p],
                center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
            ))
        }
    }
    return clusters
}

// Stable cache-key for the friend-place clustering .task(id:) — see the
// `memoizedFriendClusters` block below.
private struct ClusterInputs: Hashable {
    let placeIds: [String]
    let threshold: Int
}

// MARK: - Cafe Map View

struct CafeMapView: View {
    let cafes: [Cafe]
    let friendPlaces: [FriendPlace]
    let activeCafeId: String?
    let onPinClick: (String) -> Void
    let onFriendPinClick: (FriendPlace) -> Void
    /// Called when the user taps a multi-place cluster. The host should show
    /// a picker that lets them pick which place inside the cluster to open.
    let onClusterTap: ([FriendPlace]) -> Void
    @Binding var centerOnUser: Bool
    @Binding var targetCoordinate: CLLocationCoordinate2D?
    var locationManager: LocationManager
    /// The signed-in user's profile photo, used to render their own location
    /// marker as their avatar (with a pulsing halo) instead of the default
    /// MapKit blue dot. nil → a generic person glyph.
    var userPhotoURL: String?

    /// Tracks current map zoom so we can shrink the cluster threshold as the
    /// user zooms in. Updated via `.onMapCameraChange`. Default matches the
    /// initial `position` span below.
    @State private var currentSpan: CLLocationDegrees = 0.04

    /// Zoom-aware cluster radius. At default zoom (span ≈ 0.04) a mall
    /// collapses into one pin (~60 m). At deep zoom (span ≈ 0.002) the
    /// threshold drops to ~3 m so pins separate to their exact coordinates.
    /// Linear in span — good enough for the visual feel; no need for a
    /// pixel-perfect projection.
    private var clusterThresholdMeters: Double {
        max(2, currentSpan * 1500)
    }

    /// Memoized clustering output — see clusterFriendPlaces(). Re-runs only
    /// when the friendPlaces set or the zoom-derived threshold actually
    /// changes, not on every map gesture. With 30+ pins clustering on every
    /// body re-render was a measurable cost on older devices.
    @State private var memoizedFriendClusters: [FriendPlaceCluster] = []

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 3.3370, longitude: 101.5742),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    )
    // Incremented every time the user taps "center"; lets onChange fire even
    // when the value was already true (e.g. location unavailable last time).
    @State private var centerRequestID: Int = 0

    /// Hydrates author photoURLs for all visible friend places so each pin
    /// can decorate its arc with profile pictures.
    @State private var avatarStore = MapAvatarStore()
    /// Snapshot of `avatarStore.photoURLByUid` passed by-value into pin
    /// views so they re-render when new photoURLs land. Avoiding direct
    /// observation keeps the map subview boundary simple.
    @State private var avatarURLs: [String: String] = [:]

    /// Stable per-place uid list used for hydration triggers — when this
    /// changes (new place tagged, new author on a place), we rerun
    /// hydration in the .task below.
    private var allAuthorIds: [String] {
        friendPlaces.flatMap { $0.posts.map(\.authorId) }
    }

    var body: some View {
        Map(position: $position) {
            // Legacy curated cafes — drawn first so friend pins layer on top.
            ForEach(cafes) { cafe in
                if let id = cafe.id {
                    Annotation(cafe.name,
                               coordinate: CLLocationCoordinate2D(latitude: cafe.lat, longitude: cafe.lng),
                               anchor: .bottom) {
                        CafePinView(cafe: cafe, isActive: id == activeCafeId)
                            .onTapGesture { onPinClick(id) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(cafe.name)
                            .accessibilityHint("Opens place details")
                    }
                }
            }
            // Friend-tagged places — clustered so dense venues (malls,
            // food courts) collapse into a single stacked pin instead of
            // a smudge of overlapping markers.
            ForEach(memoizedFriendClusters) { cluster in
                Annotation(cluster.places.first?.name ?? "",
                           coordinate: cluster.center,
                           anchor: .bottom) {
                    if cluster.places.count == 1, let only = cluster.places.first {
                        FriendPlacePinView(place: only, avatarURLs: avatarURLs)
                            .onTapGesture { onFriendPinClick(only) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(only.name)
                            .accessibilityHint("Opens posts from your friends here")
                    } else {
                        FriendPlaceClusterPinView(cluster: cluster, avatarURLs: avatarURLs)
                            .onTapGesture { onClusterTap(cluster.places) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("\(cluster.places.count) places nearby")
                            .accessibilityHint("Opens the cluster to pick a place")
                    }
                }
            }
            // The user's own location, drawn as their profile picture with a
            // pulsing halo instead of the stock blue dot. MapKit positions and
            // updates this for us as long as location authorization is granted.
            UserAnnotation { _ in
                UserLocationAvatar(photoURL: userPhotoURL)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea()
        .onMapCameraChange { context in
            currentSpan = context.region.span.latitudeDelta
        }
        // Refresh avatar hydration when the set of authors visible on the
        // map changes. Cheap when nothing's new — the store skips uids it
        // has already checked.
        .task(id: allAuthorIds) {
            await avatarStore.hydrate(uids: Set(allAuthorIds))
            avatarURLs = avatarStore.photoURLByUid
        }
        // Re-cluster only when the input places change or the zoom-derived
        // threshold crosses a meaningfully different value. Keying on the
        // place ids + a quantized threshold (rounded to whole meters) avoids
        // re-clustering on every micro-pan.
        .task(id: ClusterInputs(placeIds: friendPlaces.map(\.id), threshold: Int(clusterThresholdMeters))) {
            memoizedFriendClusters = clusterFriendPlaces(friendPlaces, thresholdMeters: clusterThresholdMeters)
        }
        .onAppear { locationManager.requestPermission() }
        .onChange(of: centerOnUser) { _, shouldCenter in
            guard shouldCenter else { return }
            // Always clear the trigger so subsequent taps always fire onChange.
            centerOnUser = false
            if let coord = locationManager.userLocation {
                withAnimation {
                    position = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))
                }
            } else {
                // GPS not ready — record that the user wants to center;
                // we'll fly there once location arrives.
                centerRequestID += 1
            }
        }
        .onChange(of: locationManager.userLocation?.latitude) { _, _ in
            guard let coord = locationManager.userLocation, centerRequestID > 0 else { return }
            centerRequestID = 0
            withAnimation {
                position = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
        .onChange(of: targetCoordinate?.latitude) { _, _ in
            guard let coord = targetCoordinate else { return }
            withAnimation {
                position = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
                ))
            }
            targetCoordinate = nil
        }
    }
}

// MARK: - Pin

struct CafePinView: View {
    let cafe: Cafe
    let isActive: Bool

    private var accent: Color { AppTheme.accent(for: cafe.type) }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(isActive ? accent : AppTheme.espresso)
                    .frame(width: 38, height: 38)
                    .shadow(color: accent.opacity(isActive ? 0.6 : 0.3), radius: isActive ? 10 : 4)
                Text(cafe.type.emoji)
                    .font(.system(size: 17))
            }
            .overlay(Circle().stroke(accent, lineWidth: isActive ? 2.5 : 1.5))
            .scaleEffect(isActive ? 1.2 : 1.0)
            .animation(.spring(response: 0.3), value: isActive)

            PinTail()
                .fill(isActive ? accent : AppTheme.espresso)
                .frame(width: 8, height: 5)
        }
    }
}

/// Pin for a friend-tagged place. Visually distinct from CafePinView so users
/// can distinguish "friend was here" pins from the legacy curated rows.
/// Profile pictures of the users who tagged this place are arranged along
/// the upper arc of the pin so the visitor identity is visible at a glance.
struct FriendPlacePinView: View {
    let place: FriendPlace
    let avatarURLs: [String: String]

    private var accent: Color { AppTheme.accentAction }

    /// Distinct authors of posts at this place, ordered by recency
    /// (`place.posts` is already most-recent-first per FriendPlacesService).
    private var distinctAuthors: [(uid: String, username: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for post in place.posts where !seen.contains(post.authorId) {
            seen.insert(post.authorId)
            out.append((post.authorId, post.authorUsername))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Pin body — emoji-in-circle.
                ZStack {
                    Circle()
                        .fill(accent)
                        .frame(width: 42, height: 42)
                        .shadow(color: accent.opacity(0.5), radius: 8)
                    Text(place.type.emoji)
                        .font(.system(size: 19))
                }
                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))

                // Avatar halo along the upper arc.
                avatarArc(for: distinctAuthors)
            }
            PinTail()
                .fill(accent)
                .frame(width: 8, height: 5)
        }
    }

    @ViewBuilder
    private func avatarArc(for authors: [(uid: String, username: String)]) -> some View {
        let displayed = Array(authors.prefix(ArcAvatarLayout.maxDisplayed))
        let offsets = ArcAvatarLayout.offsets(count: displayed.count)
        ZStack {
            ForEach(Array(zip(displayed.indices, displayed)), id: \.0) { idx, author in
                PinAvatarBubble(
                    urlString: avatarURLs[author.uid],
                    initials: author.username.uppercased(),
                    size: 20
                )
                .offset(offsets[idx])
            }
            // Overflow indicator anchored slightly past the last avatar.
            if authors.count > ArcAvatarLayout.maxDisplayed {
                let overflowOffset = offsets.last ?? .zero
                Text("+\(authors.count - ArcAvatarLayout.maxDisplayed)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(AppTheme.textPrimary))
                    .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                    .offset(
                        x: overflowOffset.width + 14,
                        y: overflowOffset.height
                    )
            }
        }
    }
}

/// Pin for a cluster of multiple distinct places at roughly the same coord
/// (e.g. a mall). A faded duplicate sits behind the main circle to hint
/// "there's more underneath", a count badge shows how many places it
/// contains, and the avatar arc above shows distinct users across the
/// whole cluster.
struct FriendPlaceClusterPinView: View {
    let cluster: FriendPlaceCluster
    let avatarURLs: [String: String]

    private var accent: Color { AppTheme.accentAction }

    /// Distinct authors across every place in the cluster, ordered by
    /// most-recent post overall.
    private var distinctAuthors: [(uid: String, username: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        let allPosts = cluster.places
            .flatMap(\.posts)
            .sorted { $0.createdAt > $1.createdAt }
        for post in allPosts where !seen.contains(post.authorId) {
            seen.insert(post.authorId)
            out.append((post.authorId, post.authorUsername))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        // "Stack" layer behind — offset duplicate hints depth.
                        Circle()
                            .fill(accent.opacity(0.55))
                            .frame(width: 42, height: 42)
                            .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 2))
                            .offset(x: 6, y: 6)

                        // Front circle.
                        Circle()
                            .fill(accent)
                            .frame(width: 42, height: 42)
                            .shadow(color: accent.opacity(0.5), radius: 8)
                        Text(cluster.dominantType.emoji)
                            .font(.system(size: 19))
                    }
                    .overlay(Circle().stroke(Color.white, lineWidth: 2.5))

                    // Place-count badge — how many distinct places live in
                    // this cluster (separate metric from the avatar arc,
                    // which counts people).
                    Text("\(cluster.places.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.textPrimary))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: 8, y: -6)
                }

                avatarArc(for: distinctAuthors)
            }
            PinTail()
                .fill(accent)
                .frame(width: 8, height: 5)
        }
    }

    @ViewBuilder
    private func avatarArc(for authors: [(uid: String, username: String)]) -> some View {
        let displayed = Array(authors.prefix(ArcAvatarLayout.maxDisplayed))
        let offsets = ArcAvatarLayout.offsets(count: displayed.count)
        ZStack {
            ForEach(Array(zip(displayed.indices, displayed)), id: \.0) { idx, author in
                PinAvatarBubble(
                    urlString: avatarURLs[author.uid],
                    initials: author.username.uppercased(),
                    size: 20
                )
                .offset(offsets[idx])
            }
        }
    }
}

struct PinTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
