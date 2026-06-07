import SwiftUI

// MARK: - StorySection (extracted)

/// Horizontal "Your Story So Far" strip showing one card per distinct
/// place the user has personally tagged. Sole dependency is the
/// `[VisitedPlaceItem]` array — when unchanged, SwiftUI skips
/// re-evaluation. Photo source is the user's own post photo for that
/// place, so the section feels like a personal hunting log.
struct StorySection: View {
    let places: [VisitedPlaceItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "YOUR STORY SO FAR")
                Text("Places you've tagged on your hunt.")
                    .font(.caption2)
                    .contrastAware(AppTheme.cream, opacity: 0.35)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)

            if places.isEmpty {
                Text("Your story is just beginning —\ngo find your first spot! ☕")
                    .font(.footnote)
                    .contrastAware(AppTheme.cream, opacity: 0.4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(places) { place in
                            VisitedPlaceCard(item: place)
                        }
                        if places.count < 4 {
                            StoryTeaserCard()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 24)
    }
}


// MARK: - Story teaser card

private struct StoryTeaserCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(AppTheme.cafeAccent.opacity(0.5))
                .accessibilityHidden(true)
            Text("More milestones\nawaiting you ✨")
                .font(.caption2)
                .contrastAware(AppTheme.cream, opacity: 0.35)
                .multilineTextAlignment(.center)
        }
        .frame(width: 148, height: 160)
        .background(AppTheme.cream.opacity(0.03))
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cream.opacity(0.07), lineWidth: 1)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
    }
}


// MARK: - Visited place card (story strip)

/// Card model for one place in "Your Story So Far". Identified by
/// placeId so re-renders are stable across feed updates that don't
/// change the underlying place set.
struct VisitedPlaceItem: Identifiable, Equatable {
    let id: String           // = placeId
    let placeName: String
    let mediaURL: String
    let visitedAt: Date
}

/// One card in the story strip — photo of the place from the user's own
/// post, place name overlay, visit-date caption. Tappable feel matches
/// the friend-strip avatar style (scale-press) so the whole section
/// feels like the same interaction surface.
private struct VisitedPlaceCard: View {
    let item: VisitedPlaceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = URL(string: item.mediaURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.black.opacity(0.2)
                    }
                }
                .frame(width: 148, height: 116)
                .clipped()
            } else {
                Color.black.opacity(0.2)
                    .frame(width: 148, height: 116)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.placeName)
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)
                    .lineLimit(1)
                Text(item.visitedAt, format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.cafeAccent.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 148, height: 164, alignment: .topLeading)
        .background(AppTheme.cream.opacity(0.05))
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cafeAccent.opacity(0.18), lineWidth: 1)
        }
    }
}

