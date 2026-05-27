import SwiftUI
import MapKit

// MARK: - Hunting Map Section
//
// Replaces the old StatsRow + StorySection on ProfileHomeView with a single
// tappable map block that shows the user's own visited pins, with three glass
// stat cards (cafés / restaurants / stalls) floating over the top edge and a
// liquid-glass legend strip pinned to the bottom.
//
// Tapping the map presents `MyHuntView` as a `.fullScreenCover` from
// ProfileHomeView. Driven by FriendPlacesService filtered to the current
// user's own posts.

struct HuntingMapSection: View {
    let myUid: String
    var friendPlacesService: FriendPlacesService
    var onTap: () -> Void

    // Mine-only: filter the shared FriendPlacesService snapshot down to places
    // the current user has personally tagged.
    private var myPlaces: [FriendPlace] {
        friendPlacesService.places.filter { place in
            place.posts.contains(where: { $0.authorId == myUid })
        }
    }

    private var counts: (cafes: Int, restaurants: Int, stalls: Int) {
        var c = 0, r = 0, s = 0
        for p in myPlaces {
            switch p.type {
            case .cafe:       c += 1
            case .restaurant: r += 1
            case .stall:      s += 1
            }
        }
        return (c, r, s)
    }

    private var cityCount: Int {
        Set(myPlaces.compactMap(\.cityName)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader

            Button(action: onTap) {
                mapCard
            }
            .buttonStyle(.scalePress)
            // Not tappable until there's at least one place to open into.
            .disabled(myPlaces.isEmpty)
            .accessibilityLabel(myPlaces.isEmpty
                ? "No places hunted yet"
                : "Open my hunt — \(myPlaces.count) places hunted")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    // MARK: - Section header

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("YOUR MAP")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.8)
                .contrastAware(AppTheme.cream, opacity: 0.45)
            Spacer()
            if !myPlaces.isEmpty {
                Text("\(myPlaces.count) places · \(cityCount) cities")
                    .font(.system(size: 11, weight: .medium))
                    .contrastAware(AppTheme.cream, opacity: 0.35)
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - Map card

    private var mapCard: some View {
        ZStack(alignment: .top) {
            // Real MapKit underlay — non-interactive so the whole card stays a
            // single tap target. Camera fitted to the bounding region on appear.
            HuntingMapPreview(places: myPlaces, isInteractive: false)
                .frame(height: 320)
                // Soft-focus the empty map so the "start your journey" line reads.
                .blur(radius: myPlaces.isEmpty ? 10 : 0)

            statCardsOverlay
                .padding(.horizontal, 12)
                .padding(.top, 12)

            // Bottom legend pill — only once there's something to count.
            VStack {
                Spacer(minLength: 0)
                if !myPlaces.isEmpty {
                    HStack {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppTheme.cafeAccent)
                                .frame(width: 7, height: 7)
                                .shadow(color: AppTheme.cafeAccent.opacity(0.6),
                                        radius: 2)
                            Text("\(myPlaces.count) places hunted")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        Spacer()
                        Text(citiesLabel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .kerning(0.6)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .liquidGlassChrome(in: Capsule())
                    .padding(10)
                }
            }
            .frame(height: 320)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private var citiesLabel: String {
        let cities = Set(myPlaces.compactMap(\.cityName)).sorted()
        return cities.prefix(4).joined(separator: " · ")
    }

    // MARK: - Stat cards

    @ViewBuilder
    private var statCardsOverlay: some View {
        if myPlaces.isEmpty {
            // Nothing hunted yet — an inviting line instead of 00 / 00 / 00.
            emptyStateCard
        } else {
            HStack(spacing: 8) {
                // Only show a counter card for a type the user actually has.
                if counts.cafes > 0 {
                    statCard(num: counts.cafes, label: "cafés")
                }
                if counts.restaurants > 0 {
                    statCard(num: counts.restaurants, label: "restaurants")
                }
                if counts.stalls > 0 {
                    statCard(num: counts.stalls, label: "stalls")
                }
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 5) {
            Text("Your journey hasn't started — yet")
                .font(.huntSerif(19))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Tag your first spot and watch the map come alive.")
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .liquidGlassChrome(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statCard(num: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%02d", num))
                .font(.huntSerif(26))
                .foregroundStyle(AppTheme.textPrimary)
                .kerning(-0.2)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(1.3)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassChrome(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Map preview (shared between section card and MyHuntView hero)

struct HuntingMapPreview: View {
    let places: [FriendPlace]
    var isInteractive: Bool

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position, interactionModes: isInteractive ? .all : []) {
            ForEach(places) { place in
                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: place.lat,
                    longitude: place.lng
                )) {
                    PersimmonPin()
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat,
                            pointsOfInterest: .excludingAll))
        .onAppear { fitToPlaces() }
        .onChange(of: places.map(\.id)) { _, _ in fitToPlaces() }
        .allowsHitTesting(isInteractive)
    }

    private func fitToPlaces() {
        guard !places.isEmpty else {
            position = .automatic
            return
        }
        let lats = places.map(\.lat)
        let lngs = places.map(\.lng)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLng = lngs.min()!, maxLng = lngs.max()!
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta:  max(0.02, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.02, (maxLng - minLng) * 1.4)
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
    }
}

private struct PersimmonPin: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.cafeAccent)
                .frame(width: 16, height: 16)
                .overlay {
                    Circle().stroke(Color.white, lineWidth: 2)
                }
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            Circle().fill(.white).frame(width: 5, height: 5)
        }
    }
}
