import SwiftUI
import MapKit
import UIKit

// MARK: - MyHuntView
//
// Personal retrospective surface presented as a `.fullScreenCover` from
// `ProfileHomeView`'s YOUR MAP block. Distinct from the Map tab:
//   • Personal — only the user's own visited places, no friend pins
//   • Temporal — places grouped by month
//   • Stats-led — the headline is the numbers

struct MyHuntView: View {
    let myUid: String
    var friendPlacesService: FriendPlacesService
    /// The signed-in user's handle + join date, for the header subtitle.
    var username: String?
    var joinedAt: Date?
    /// Top safe-area inset — the overlay is hosted under MainShellView's
    /// `.ignoresSafeArea()`, so it gets no automatic top inset.
    var topInset: CGFloat = 0
    var onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var myPlaces: [FriendPlace] {
        friendPlacesService.places
            .filter { $0.posts.contains(where: { $0.authorId == myUid }) }
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

    /// Places grouped by month (most-recent month first) with month label.
    private var groupedByMonth: [(label: String, places: [FriendPlace])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        let grouped = Dictionary(grouping: myPlaces) { place -> Date in
            let mineHere = place.posts
                .filter { $0.authorId == myUid }
                .map(\.createdAt)
            let latest = mineHere.max() ?? .distantPast
            var comps = Calendar.current.dateComponents([.year, .month], from: latest)
            comps.day = 1
            return Calendar.current.date(from: comps) ?? latest
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (formatter.string(from: $0.key), $0.value) }
    }

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        heroMap
                        milestoneStrip
                        filterRow
                        ForEach(groupedByMonth, id: \.label) { group in
                            monthGroup(group.label, places: group.places)
                        }
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
    }

    // MARK: - Header

    /// "since May 2026 · @feez" — built from the real join date + handle,
    /// falling back to the earliest visit when no join date is available.
    private var sinceLabel: String {
        var pieces: [String] = []
        if let date = joinedAt ?? earliestVisit {
            let f = DateFormatter()
            f.dateFormat = "LLLL yyyy"
            pieces.append("since \(f.string(from: date))")
        }
        if let username, !username.isEmpty { pieces.append("@\(username)") }
        return pieces.joined(separator: " · ")
    }

    /// Real top safe-area inset, read from the key window — the overlay is
    /// hosted under MainShellView's `.ignoresSafeArea()`, so the passed
    /// `topInset` can come through as 0 and let the ✕ slide under the notch /
    /// Dynamic Island. Take the larger of the two, plus a little breathing room.
    private var safeTop: CGFloat {
        let windowTop = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
        return max(topInset, windowTop)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.textPrimary.opacity(0.06)))
            }
            .buttonStyle(.scalePress)
            .accessibilityLabel("Close")

            VStack(alignment: .leading, spacing: 2) {
                Text("My Hunt")
                    .font(.huntSerif(26))
                    .foregroundStyle(AppTheme.textPrimary)
                if !sinceLabel.isEmpty {
                    Text(sinceLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .kerning(1.5)
                        .foregroundStyle(AppTheme.textSecondary)
                        .textCase(.uppercase)
                }
            }
            Spacer()

            ShareLink(item: "Check out my hunt on Wandery") {
                Image(systemName: "square.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.textPrimary.opacity(0.06)))
            }
            .buttonStyle(.scalePress)
        }
        .padding(.horizontal, 16)
        .padding(.top, safeTop + 10)
        .padding(.bottom, 10)
    }

    // MARK: - Hero map

    private var heroMap: some View {
        ZStack(alignment: .top) {
            HuntingMapPreview(places: myPlaces, isInteractive: true)
                .frame(height: 360)

            HStack(spacing: 8) {
                statCard(counts.cafes,       "cafés")
                statCard(counts.restaurants, "restaurants")
                statCard(counts.stalls,      "stalls")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
        }
    }

    private func statCard(_ num: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%02d", num))
                .font(.huntSerif(26))
                .foregroundStyle(AppTheme.textPrimary)
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

    // MARK: - Milestone strip

    private var milestoneStrip: some View {
        VStack(spacing: 8) {
            Text("YOU'VE BEEN BUSY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .kerning(1.8)
                .foregroundStyle(AppTheme.cafeAccent)
                .textCase(.uppercase)
            Text("\(myPlaces.count) places across \(cityCount) cities in \(daysActive) days.")
                .font(.huntSerif(22))
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var cityCount: Int { Set(myPlaces.compactMap(\.cityName)).count }

    /// Earliest of the user's own visits across all places.
    private var earliestVisit: Date? {
        myPlaces
            .flatMap(\.posts)
            .filter { $0.authorId == myUid }
            .map(\.createdAt)
            .min()
    }

    /// Days since the user joined (or their earliest visit if no join date).
    private var daysActive: Int {
        let start = joinedAt ?? earliestVisit ?? Date()
        return max(1, Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 1)
    }

    // MARK: - Filter row

    @State private var activeFilter: PlaceType? = nil

    private var filterRow: some View {
        HStack(spacing: 8) {
            filterChip(nil, emoji: "📍", count: myPlaces.count, accent: nil)
            // Only surface a type chip when there's at least one of that type.
            if counts.cafes > 0 {
                filterChip(.cafe, emoji: "☕", count: counts.cafes, accent: AppTheme.cafeAccent)
            }
            if counts.restaurants > 0 {
                filterChip(.restaurant, emoji: "🍽️", count: counts.restaurants, accent: AppTheme.accentAction)
            }
            if counts.stalls > 0 {
                filterChip(.stall, emoji: "🍜", count: counts.stalls, accent: AppTheme.stallAccent)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(AppTheme.textPrimary.opacity(0.04)))
            .overlay(Capsule().stroke(AppTheme.borderSubtle, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.borderSubtle).frame(height: 0.5)
        }
    }

    private func filterChip(_ type: PlaceType?, emoji: String, count: Int, accent: Color?) -> some View {
        let isActive = (type == activeFilter) || (type == nil && activeFilter == nil)
        let chipAccent = accent ?? AppTheme.cafeAccent
        return Button {
            activeFilter = type
        } label: {
            HStack(spacing: 6) {
                Text(emoji).font(.system(size: 14))
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? chipAccent : AppTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(
                isActive ? chipAccent.opacity(0.14) : AppTheme.textPrimary.opacity(0.04)
            ))
            .overlay(Capsule().stroke(
                isActive ? chipAccent.opacity(0.55) : AppTheme.borderSubtle,
                lineWidth: isActive ? 1.2 : 0.8
            ))
            .scaleEffect(isActive ? 1.0 : 0.96)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Month groups

    @ViewBuilder
    private func monthGroup(_ label: String, places: [FriendPlace]) -> some View {
        let filtered = activeFilter == nil
            ? places
            : places.filter { $0.type == activeFilter }
        if !filtered.isEmpty {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.huntSerif(22))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text("\(filtered.count) place\(filtered.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .kerning(1.5)
                        .foregroundStyle(AppTheme.textSecondary)
                        .textCase(.uppercase)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

                ForEach(filtered) { place in
                    PlaceRow(place: place, myUid: myUid)
                }
            }
        }
    }
}

// MARK: - PlaceRow

private struct PlaceRow: View {
    let place: FriendPlace
    let myUid: String

    private var myVisits: Int {
        place.posts.filter { $0.authorId == myUid }.count
    }
    private var lastMineAt: Date? {
        place.posts.filter { $0.authorId == myUid }.map(\.createdAt).max()
    }
    private var lastVisitLabel: String {
        guard let date = lastMineAt else { return "" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 1 { return "TODAY" }
        if days == 1 { return "YESTERDAY" }
        if days < 7 { return "\(days) DAYS AGO" }
        let weeks = days / 7
        if weeks < 4 { return "\(weeks) WEEK\(weeks == 1 ? "" : "S") AGO" }
        let f = DateFormatter()
        f.dateFormat = "MMM dd"
        return f.string(from: date).uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place.name)
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    if myVisits >= 5 {
                        Text("★ MOST")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .kerning(0.8)
                            .foregroundStyle(AppTheme.cafeAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(AppTheme.cafeAccent.opacity(0.12)))
                    }
                }
                HStack(spacing: 6) {
                    Text(place.type.emoji)
                    Text(place.cityName ?? "Unknown")
                    Text("·").foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                    Text("\(myVisits)× visited")
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Text(lastVisitLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .kerning(0.6)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.borderSubtle).frame(height: 0.5)
                .padding(.leading, 84)
        }
    }

    private var thumbnail: some View {
        let url: URL? = {
            guard let post = place.mostRecent else { return nil }
            return URL(string: post.isVideo
                       ? (post.thumbnailURL ?? post.mediaURL)
                       : post.mediaURL)
        }()
        return CachedAsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    AppTheme.textPrimary.opacity(0.08)
                    Text(place.type.emoji).font(.system(size: 22)).opacity(0.6)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 0.5)
        }
    }
}
