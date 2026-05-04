import SwiftUI
import MapKit
import CoreLocation

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

// MARK: - Cafe Map View

struct CafeMapView: View {
    let cafes: [Cafe]
    let friendPlaces: [FriendPlace]
    let activeCafeId: String?
    let onPinClick: (String) -> Void
    let onFriendPinClick: (FriendPlace) -> Void
    @Binding var centerOnUser: Bool
    @Binding var targetCoordinate: CLLocationCoordinate2D?
    var locationManager: LocationManager

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 3.3370, longitude: 101.5742),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    )
    // Incremented every time the user taps "center"; lets onChange fire even
    // when the value was already true (e.g. location unavailable last time).
    @State private var centerRequestID: Int = 0

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
                    }
                }
            }
            // Friend-tagged places — visually distinct (avatar + accent).
            ForEach(friendPlaces) { place in
                Annotation(place.name,
                           coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng),
                           anchor: .bottom) {
                    FriendPlacePinView(place: place)
                        .onTapGesture { onFriendPinClick(place) }
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea()
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
/// Shows a "+N" badge when more than one friend has visited the place.
struct FriendPlacePinView: View {
    let place: FriendPlace

    private var accent: Color { AppTheme.accentAction }
    private var distinctFriends: Int {
        Set(place.posts.map(\.authorId)).count
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(accent)
                        .frame(width: 42, height: 42)
                        .shadow(color: accent.opacity(0.5), radius: 8)
                    Text(place.type.emoji)
                        .font(.system(size: 19))
                }
                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))

                if distinctFriends > 1 {
                    Text("\(distinctFriends)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.textPrimary))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: 6, y: -4)
                }
            }
            PinTail()
                .fill(accent)
                .frame(width: 8, height: 5)
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
