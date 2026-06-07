import SwiftUI
import CoreLocation

// MARK: - Trending Discover sheet
//
// Replaces the legacy "Creator's Pick" surface behind the Map's ✨ HUD button.
// Lists places ranked globally by `globalVisitCount`, with up to 3 preview
// photos per place (all from `discoverable == true` posts — same consent gate
// the rules already permit any signed-in user to read).
//
// Tapping a row drives `onSelect(placeId)`; the host (`MainMapView`) sets
// `pendingPlaceJumpId` and dismisses the sheet, which fires the existing
// place-jump path → centres the map and opens `PlaceDetailSheet`.

struct TrendingDiscoverView: View {
    var service: CircleDiscoverService
    var onSelect: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .padding(.top, 20)
        .background(Color.clear)
        .task { await service.load() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("🔥").font(.title3)
                    // Adaptive label colours: the glass backdrop is light in
                    // light mode and dark in dark mode, so `.primary`/`.secondary`
                    // stay legible on both (plain white only read in dark mode).
                    Text("Trending")
                        .font(.title2).bold()
                        .foregroundStyle(.primary)
                }
                Text("Places people are hunting right now")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: content (loading / empty / list)

    @ViewBuilder
    private var content: some View {
        if service.isLoading && service.trending.isEmpty {
            VStack(spacing: 10) {
                ProgressView().tint(.secondary)
                Text("Finding what's hot…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if service.trending.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Nothing trending yet.")
                    .font(.subheadline).bold()
                    .foregroundStyle(.primary)
                Text("Keep tagging places — they'll show up here as visits add up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 3-column picture-only grid. Names + counts hide behind the tap,
            // so the surface reads as "pure discovery" — the user is curious
            // first, informed second.
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 4) {
                    ForEach(service.trending) { place in
                        TrendingCell(place: place) {
                            onSelect(place.id)
                            onClose()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 36)
            }
            .refreshable { await service.refresh() }
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
    }
}

// MARK: - Grid cell (picture only)

private struct TrendingCell: View {
    let place: TrendingPlace
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let first = place.photos.first {
                    photoBody(first)
                } else {
                    // The server drops places with no clear photo, so this is
                    // a defensive fallback that shouldn't render in practice.
                    Color.black.opacity(0.4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(place.name), \(place.globalVisitCount) visits")
        .accessibilityHint("Opens place details")
    }

    @ViewBuilder
    private func photoBody(_ photo: TrendingPhoto) -> some View {
        if let url = URL(string: photo.url) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Color.black.opacity(0.4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
        } else {
            Color.black.opacity(0.4)
        }
    }
}
