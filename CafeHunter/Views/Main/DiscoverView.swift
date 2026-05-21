import CoreLocation
import MapKit
import SwiftUI

/// "Worth exploring" surface — places near the user that have a
/// classifier-approved discoverable post but that the user hasn't tagged
/// yet. Renders as a map of place pins by default, with a list fallback.
/// Tap a pin → camera focuses on it + a bottom card slides up showing the
/// place's preview photo (the chosen discoverable post's image).
struct DiscoverView: View {
    /// Plain reference — `LocationManager` is an `@Observable` macro type,
    /// not `ObservableObject`. SwiftUI tracks property reads inside the
    /// body automatically.
    let locationManager: LocationManager
    var onSelect: (DiscoverPlace) -> Void
    var onClose: () -> Void

    @State private var service = DiscoverService()
    @State private var didLoadOnce = false
    @State private var mode: Mode = .map
    @State private var camera: MapCameraPosition = .automatic
    @State private var focused: DiscoverPlace?

    enum Mode: Hashable { case map, list }

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                modeToggle
                content
            }
        }
        .task { await reload() }
        // When fresh results arrive, recentre the camera on the bounding
        // box that contains them all — better than a static city default.
        .onChange(of: service.results) { _, results in
            guard !results.isEmpty else { return }
            withAnimation(Motion.iosDrawer(duration: 0.5)) {
                camera = .region(boundingRegion(for: results))
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Text("✨")
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Worth exploring")
                    .font(.title3).bold()
                    .foregroundStyle(AppTheme.cream)
                Text("Places nearby you haven't been yet")
                    .font(.caption2)
                    .contrastAware(AppTheme.cream, opacity: 0.45)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote).bold()
                    .contrastAware(AppTheme.cream, opacity: 0.7)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.cream.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.scalePress)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 56)
        .padding(.bottom, 8)
    }

    private var modeToggle: some View {
        Picker("View mode", selection: $mode) {
            Label("Map", systemImage: "map.fill").tag(Mode.map)
            Label("List", systemImage: "list.bullet").tag(Mode.list)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if service.isLoading && service.results.isEmpty {
            loading
        } else if service.results.isEmpty {
            emptyState
        } else {
            switch mode {
            case .map:  mapContent
            case .list: listContent
            }
        }
    }

    private var loading: some View {
        VStack {
            Spacer()
            ProgressView().tint(AppTheme.cream)
            Text("Looking around…")
                .font(.caption)
                .contrastAware(AppTheme.cream, opacity: 0.5)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "sparkle.magnifyingglass")
                .font(.largeTitle)
                .contrastAware(AppTheme.cream, opacity: 0.25)
                .accessibilityHidden(true)
            Text("Nothing to discover yet")
                .font(.subheadline).bold()
                .contrastAware(AppTheme.cream, opacity: 0.65)
            Text("Be the first to share a face-free, well-composed shot — those become Discover candidates automatically.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .contrastAware(AppTheme.cream, opacity: 0.4)
                .padding(.horizontal, 32)
            if let err = service.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.errorRed.opacity(0.7))
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Map mode

    private var mapContent: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                ForEach(service.results) { place in
                    Annotation(
                        place.name,
                        coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng)
                    ) {
                        DiscoverPin(place: place, isFocused: focused?.id == place.id) {
                            focusOn(place)
                        }
                    }
                    .annotationTitles(.hidden)
                }
                UserAnnotation()
            }
            .mapStyle(.standard)
            .mapControls {
                MapCompass()
                MapUserLocationButton()
            }

            if let f = focused {
                DiscoverPlaceCard(
                    place: f,
                    onTakeMeThere: {
                        onSelect(f)
                    },
                    onDismiss: {
                        withAnimation(Motion.iosDrawer(duration: 0.32)) {
                            focused = nil
                        }
                    }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(f.id)
            }
        }
        .animation(Motion.iosDrawer(duration: 0.32), value: focused?.id)
    }

    private func focusOn(_ place: DiscoverPlace) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(Motion.iosDrawer(duration: 0.45)) {
            focused = place
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    // Bias the camera down a touch so the pin clears the
                    // bottom card. ~120 m of latitude offset at KL latitude.
                    latitude: place.lat - 0.0012,
                    longitude: place.lng
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
        }
    }

    // Bounding region that contains every Discover candidate plus a 20%
    // margin so the outermost pin isn't flush against the screen edge.
    private func boundingRegion(for places: [DiscoverPlace]) -> MKCoordinateRegion {
        guard let first = places.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 3.1390, longitude: 101.6869),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        var minLat = first.lat
        var maxLat = first.lat
        var minLng = first.lng
        var maxLng = first.lng
        for p in places {
            minLat = min(minLat, p.lat)
            maxLat = max(maxLat, p.lat)
            minLng = min(minLng, p.lng)
            maxLng = max(maxLng, p.lng)
        }
        // Include the user's location in the bounds when available so the
        // initial fit makes "here vs there" obvious.
        if let me = locationManager.userLocation {
            minLat = min(minLat, me.latitude)
            maxLat = max(maxLat, me.latitude)
            minLng = min(minLng, me.longitude)
            maxLng = max(maxLng, me.longitude)
        }
        let centre = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.01, (maxLng - minLng) * 1.4)
        )
        return MKCoordinateRegion(center: centre, span: span)
    }

    // MARK: - List mode

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(service.results) { place in
                    Button { onSelect(place) } label: {
                        DiscoverListRow(place: place)
                    }
                    .buttonStyle(.scalePress)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        let coord = locationManager.userLocation
            ?? CLLocationCoordinate2D(latitude: 3.1390, longitude: 101.6869)
        await service.load(around: coord, radiusMeters: DiscoverService.defaultRadiusMeters)
        didLoadOnce = true
    }
}

// MARK: - Pin

private struct DiscoverPin: View {
    let place: DiscoverPlace
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(AppTheme.cafeAccent)
                    .frame(width: isFocused ? 48 : 38, height: isFocused ? 48 : 38)
                    .shadow(color: AppTheme.cafeAccent.opacity(0.5), radius: isFocused ? 10 : 4)
                Circle()
                    .stroke(.white, lineWidth: 2)
                    .frame(width: isFocused ? 48 : 38, height: isFocused ? 48 : 38)
                Text(place.type.emoji)
                    .font(isFocused ? .title3 : .body)
            }
        }
        .buttonStyle(.scalePress)
        .animation(Motion.cozyReveal, value: isFocused)
        .accessibilityLabel(place.name)
    }
}

// MARK: - Bottom card

private struct DiscoverPlaceCard: View {
    let place: DiscoverPlace
    let onTakeMeThere: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Preview photo — the *only* surface where a stranger sees a
            // user-uploaded image. Already classifier-approved.
            if let url = URL(string: place.previewPhotoURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.black.opacity(0.2)
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(.rect(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(place.type.emoji)
                        .font(.subheadline)
                        .accessibilityHidden(true)
                    Text(place.name)
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.cream)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    statPill(icon: "📍", value: formatDistance(place.distanceMeters))
                    statPill(icon: "👥", value: "\(place.visits)")
                }
                Spacer(minLength: 0)
                Button(action: onTakeMeThere) {
                    Text("Open on map")
                        .font(.caption).bold()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppTheme.cafeAccent)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.scalePress)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2).bold()
                    .contrastAware(AppTheme.cream, opacity: 0.55)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(AppTheme.cream.opacity(0.1)))
            }
            .buttonStyle(.scalePress)
            .accessibilityLabel("Close card")
        }
        .padding(12)
        .frame(height: 108)
        .background(AppTheme.espresso.opacity(0.92))
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
    }

    private func statPill(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(icon).font(.caption2)
            Text(value)
                .font(.caption2.monospacedDigit()).bold()
                .contrastAware(AppTheme.cream, opacity: 0.7)
        }
    }

    private func formatDistance(_ m: Double) -> String {
        if m < 1000 {
            "\(Int(m)) m"
        } else {
            "\((m / 1000).formatted(.number.precision(.fractionLength(1)))) km"
        }
    }
}

// MARK: - List row (fallback view mode)

private struct DiscoverListRow: View {
    let place: DiscoverPlace

    var body: some View {
        HStack(spacing: 12) {
            if let url = URL(string: place.previewPhotoURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.black.opacity(0.2)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(place.type.emoji)
                        .font(.caption)
                    Text(place.name)
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.cream)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    statPill(icon: "👥", value: "\(place.visits)")
                    Text(formatDistance(place.distanceMeters))
                        .font(.caption2.monospacedDigit()).bold()
                        .foregroundStyle(AppTheme.cafeAccent)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption2).bold()
                .contrastAware(AppTheme.cream, opacity: 0.3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(AppTheme.cream.opacity(0.05)))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cafeAccent.opacity(0.16), lineWidth: 1)
        }
    }

    private func statPill(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(icon).font(.caption2)
            Text(value)
                .font(.caption2.monospacedDigit()).bold()
                .contrastAware(AppTheme.cream, opacity: 0.7)
        }
    }

    private func formatDistance(_ m: Double) -> String {
        if m < 1000 {
            "\(Int(m)) m"
        } else {
            "\((m / 1000).formatted(.number.precision(.fractionLength(1)))) km"
        }
    }
}
