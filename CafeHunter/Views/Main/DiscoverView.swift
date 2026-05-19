import CoreLocation
import SwiftUI

/// "Worth exploring" feed — places near the user that have racked up
/// activity (visits + engagement) but the user hasn't personally been to.
/// Driven by `DiscoverService`. Tap a row → host centers the map on that
/// place via `onSelect`.
struct DiscoverView: View {
    /// Plain reference — `LocationManager` is an `@Observable` macro type,
    /// not `ObservableObject`. SwiftUI tracks property reads inside the
    /// body automatically.
    let locationManager: LocationManager
    var onSelect: (DiscoverPlace) -> Void
    var onClose: () -> Void

    @State private var service = DiscoverService()
    @State private var didLoadOnce = false

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
        }
        .task {
            await reload()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("✨")
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 1) {
                Text("Worth exploring")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.cream)
                Text("Popular spots you haven't been yet")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.cream.opacity(0.45))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.cream.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.cream.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        // Same top padding pattern as other full-screen overlays so the
        // close button clears the dynamic island / status bar.
        .padding(.top, 56)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if service.isLoading && service.results.isEmpty {
            VStack {
                Spacer()
                ProgressView().tint(AppTheme.cream)
                Text("Looking around…")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.cream.opacity(0.5))
                    .padding(.top, 8)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if service.results.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(service.results) { place in
                        row(place)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable { await reload() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(AppTheme.cream.opacity(0.25))
            Text("Nothing trending nearby yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.cream.opacity(0.65))
            Text("Be the first to tag a place — your friends' future visits will start to surface here.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundColor(AppTheme.cream.opacity(0.4))
                .padding(.horizontal, 32)
            if let err = service.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.errorRed.opacity(0.7))
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ place: DiscoverPlace) -> some View {
        Button {
            onSelect(place)
        } label: {
            HStack(spacing: 12) {
                Text(place.type.emoji)
                    .font(.system(size: 22))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.cream.opacity(0.06)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.cream)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        statPill(icon: "👥", value: "\(place.visits)")
                        statPill(icon: "❤️", value: "\(place.engagement)")
                        Text(formatDistance(place.distanceMeters))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(AppTheme.cafeAccent)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.cream.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppTheme.cream.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cafeAccent.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func statPill(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(icon).font(.system(size: 10))
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(AppTheme.cream.opacity(0.7))
        }
    }

    private func formatDistance(_ m: Double) -> String {
        m < 1000 ? "\(Int(m)) m" : String(format: "%.1f km", m / 1000)
    }

    private func reload() async {
        // Prefer the live user location; fall back to a sensible default
        // (KL city centre) so the empty state doesn't appear to fail
        // silently for users who haven't granted location yet.
        let coord = locationManager.userLocation
            ?? CLLocationCoordinate2D(latitude: 3.1390, longitude: 101.6869)
        await service.load(around: coord)
        didLoadOnce = true
    }
}
