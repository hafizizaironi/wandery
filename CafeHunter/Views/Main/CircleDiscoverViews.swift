import SwiftUI
import MapKit
import CoreLocation

// MARK: - Circle pin (map annotation)

/// Map pin for a friend-of-friend ("Circle") place. Visually distinct from
/// `FriendPlacePinView`: smaller (28pt), dashed-ring outline (the "tease, not
/// presence" cue), and the photo — when there is one — is rendered BLURRED.
/// The photo only ever comes from a `discoverable == true` post (the existing
/// consent gate enforced server-side in `discoverFeed`).
struct CirclePinView: View {
    let place: CirclePlace

    private let diameter: CGFloat = 28

    var body: some View {
        ZStack {
            // Backing: blurred photo or frosted placeholder.
            if let urlString = place.photoURL, let url = URL(string: urlString) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .blur(radius: 10)
                .clipShape(Circle())   // re-clip after blur to keep the disc shape
            } else {
                placeholder
            }
        }
        .frame(width: diameter, height: diameter)
        // Dashed terracotta ring — the discovery signature.
        .overlay {
            Circle()
                .strokeBorder(
                    AppTheme.cafeAccent.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1.4, dash: [3, 2])
                )
        }
        .shadow(color: AppTheme.cafeAccent.opacity(0.25), radius: 4, y: 1)
        .accessibilityLabel("\(place.name), visited by \(place.viaCount) people in your circle")
        .accessibilityHint("Opens a preview card. The photo is blurred.")
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Text(place.type.emoji)
                .font(.system(size: 13))
                .opacity(0.6)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Circle place detail card (floating, blurred preview)

/// Floating, non-modal detail card shown when the user taps a Circle pin.
/// The photo stays blurred. No author names. No posts list. The intent is to
/// tease curiosity — "go visit and find out."
struct CirclePlaceCard: View {
    let place: CirclePlace
    var userLocation: CLLocationCoordinate2D?
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            blurredPhoto
            metaRow
            actionsRow
            Text("Photo blurred to keep it a surprise.")
                .font(.caption2).italic()
                .foregroundStyle(AppTheme.cream.opacity(0.6))
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(place.type.emoji).font(.title3)
            Text(place.name)
                .font(.headline).bold()
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var blurredPhoto: some View {
        let frame: CGFloat = 200
        ZStack {
            if let s = place.photoURL, let url = URL(string: s) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.black.opacity(0.4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: frame)
                .clipped()
                .blur(radius: 14)
                .clipShape(Rectangle())
                .overlay(Color.black.opacity(0.10))    // subtle dim to deter brightness pumping
            } else {
                LinearGradient(
                    colors: [AppTheme.cafeAccent.opacity(0.55), .black.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .frame(maxWidth: .infinity, maxHeight: frame)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: frame)
        .clipped()
        .padding(.horizontal, 16)
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            Label("\(place.viaCount) in your circle", systemImage: "person.2.fill")
                .font(.footnote).bold()
            if let me = userLocation {
                let km = haversineKm(me, CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng))
                Text(km < 1 ? String(format: "%.0f m away", km * 1000)
                            : String(format: "%.1f km away", km))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button(action: openInMaps) {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.footnote).bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(AppTheme.cafeAccent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func openInMaps() {
        // iOS 26 replaced `MKMapItem(placemark:)`/`MKPlacemark` with location+
        // address. Use the new initialiser on 26, the classic one on 18–25.
        let coord = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng)
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: CLLocation(latitude: place.lat, longitude: place.lng), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        }
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func haversineKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let la1 = a.latitude * .pi / 180
        let la2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) +
                cos(la1) * cos(la2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
