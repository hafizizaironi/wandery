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
                    Text("Trending")
                        .font(.title2).bold()
                        .foregroundStyle(.white)
                }
                Text("Places people are hunting right now")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
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
                ProgressView().tint(.white)
                Text("Finding what's hot…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if service.trending.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Nothing trending yet.")
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                Text("Keep tagging places — they'll show up here as visits add up.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
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
                    PhotoStack(photos: [], place: place)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
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
            .blur(radius: photo.blur ? 12 : 0)
            .clipped()
        } else {
            Color.black.opacity(0.4)
        }
    }
}

// MARK: - Photo stack (1, 2, or 3 photos)

private struct PhotoStack: View {
    let photos: [TrendingPhoto]
    let place: TrendingPlace

    var body: some View {
        ZStack {
            switch photos.count {
            case 0:
                placeholder
            case 1:
                photo(photos[0]).frame(width: 96, height: 96)
            case 2:
                VStack(spacing: 4) {
                    photo(photos[0]).frame(height: 46)
                    photo(photos[1]).frame(height: 46)
                }
                .frame(width: 96, height: 96)
            default:
                ZStack {
                    photo(photos[2])
                        .frame(width: 60, height: 78)
                        .rotationEffect(.degrees(4))
                        .offset(x: 18)
                    photo(photos[1])
                        .frame(width: 60, height: 78)
                        .rotationEffect(.degrees(-4))
                        .offset(x: -18)
                    photo(photos[0])
                        .frame(width: 64, height: 80)
                }
                .frame(width: 96, height: 96)
            }
        }
    }

    /// Renders one photo cell. `blur: true` (set when the post's author has
    /// opted out of Discover) applies a soft blur — the photo is still
    /// surfaced but reads as "private hint" rather than full presence.
    private func photo(_ p: TrendingPhoto) -> some View {
        Group {
            if let url = URL(string: p.url) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.black.opacity(0.4)
                    }
                }
            } else {
                Color.black.opacity(0.4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: p.blur ? 12 : 0)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }

    /// Stylised placeholder used when a place has no qualifying photo yet
    /// (no `discoverable == true` posts, or all photos failed to load).
    /// Hashes the place id into a stable hue so the same place keeps the
    /// same gradient between sessions — feels intentional rather than
    /// "image failed to load."
    private var placeholder: some View {
        let hue = Double(abs(place.id.hashValue) % 360) / 360.0
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.38),
                    Color(hue: hue, saturation: 0.65, brightness: 0.22),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                VStack(spacing: 4) {
                    Text(place.type.emoji)
                        .font(.system(size: 22))
                    Text(place.name.prefix(1).uppercased())
                        .font(.system(size: 26, weight: .heavy, design: .serif))
                        .italic()
                        .foregroundStyle(.white.opacity(0.92))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
            .frame(width: 96, height: 96)
    }
}
