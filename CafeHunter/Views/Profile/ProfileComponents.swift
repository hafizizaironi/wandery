import SwiftUI

// MARK: - Section header (shared)

/// Small reusable header for the labelled sections in this profile. Promoted
/// to a fileprivate View so the extracted private subviews below
/// (StatsRow, StorySection, AchievementsSection) can share it without
/// reaching into ProfileHomeView's private methods.
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.caption2).bold()
                .tracking(2)
                .contrastAware(AppTheme.cream, opacity: 0.35)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let t = trailing {
                Text(t)
                    .font(.caption2).bold()
                    .foregroundStyle(AppTheme.cafeAccent)
            }
        }
    }
}


// MARK: - StatsRow (extracted)

/// 3-tile row at the top of the profile (Cafés / Stalls / Days). Equatable
/// so SwiftUI's `.equatable()` modifier can skip body re-evaluation when
/// the three integer inputs are unchanged from the previous render — which
/// is the common case while surrounding state churns (friend strip,
/// requests, story timeline, etc).
struct StatsRow: View, Equatable {
    let cafes: Int
    let stalls: Int
    let days: Int

    var body: some View {
        HStack(spacing: 10) {
            ProfileStatCell(value: "\(cafes)",  label: "Cafés",  icon: "☕")
            ProfileStatCell(value: "\(stalls)", label: "Stalls", icon: "🍜")
            ProfileStatCell(value: "\(days)",   label: "Days",   icon: "📅")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}


// MARK: - Stat cell

private struct ProfileStatCell: View {
    let value: String
    let label: String
    let icon:  String

    var body: some View {
        VStack(spacing: 5) {
            Text(icon).font(.title3)
            Text(value)
                .font(.title2).bold()
                .foregroundStyle(AppTheme.cream)
            Text(label)
                .font(.caption2)
                .contrastAware(AppTheme.cream, opacity: 0.4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AppTheme.cream.opacity(0.04))
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.cafeAccent.opacity(0.14), lineWidth: 1)
        }
    }
}


// MARK: - Streak flame card

/// Posting-streak "hero" card. Shows the current run + personal best and a live
/// today-nudge. The status is derived from `lastPostDay` (not the stored
/// `currentStreak`, which goes stale until the next post), so it's always
/// accurate: secured today, at risk (post today to keep it), or broken/none.
struct StreakCard: View {
    let current: Int
    let longest: Int
    let lastPostDay: String

    private enum StreakState { case secured, atRisk, broken }

    private var state: StreakState {
        if lastPostDay == Self.dayString(0) { return .secured }
        if lastPostDay == Self.dayString(-1) && current > 0 { return .atRisk }
        return .broken
    }

    /// Device-local day (yyyy-MM-dd) at the given day offset — matches the
    /// format the uploader stamps on each post (`SocialService+Upload`).
    private static func dayString(_ dayOffset: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                Text("🔥")
                    .font(.system(size: 36))
                    .grayscale(state == .broken ? 1 : 0)
                    .opacity(state == .broken ? 0.5 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    if state == .broken {
                        Text("Start a streak")
                            .font(.title3).bold()
                            .foregroundStyle(AppTheme.cream)
                    } else {
                        Text("\(current)")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(AppTheme.cream)
                        Text("day streak")
                            .font(.caption)
                            .contrastAware(AppTheme.cream, opacity: 0.55)
                    }
                }

                Spacer(minLength: 8)

                if longest > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(longest)")
                            .font(.headline).bold()
                            .foregroundStyle(AppTheme.cafeAccent)
                        Text("best")
                            .font(.caption2)
                            .contrastAware(AppTheme.cream, opacity: 0.45)
                    }
                }
            }

            Rectangle()
                .fill(AppTheme.cafeAccent.opacity(0.15))
                .frame(height: 1)

            HStack(spacing: 6) {
                Text(statusIcon)
                Text(statusText)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(statusColor)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cafeAccent.opacity(state == .broken ? 0.14 : 0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state == .broken
            ? "No active streak. \(statusText)"
            : "\(current) day streak. Best \(longest). \(statusText)")
    }

    @ViewBuilder private var cardFill: some View {
        switch state {
        case .broken:
            AppTheme.cream.opacity(0.04)
        default:
            LinearGradient(
                colors: [AppTheme.cafeAccent.opacity(0.16), AppTheme.cafeAccent.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var statusIcon: String {
        switch state {
        case .secured: "✅"
        case .atRisk:  "⏰"
        case .broken:  "✨"
        }
    }

    private var statusText: String {
        switch state {
        case .secured: "Locked in today"
        case .atRisk:  current == 1
            ? "Post today to keep your streak alive!"
            : "Post today to keep your \(current)-day streak!"
        case .broken:  "Post today to light the flame"
        }
    }

    private var statusColor: Color {
        switch state {
        case .secured: AppTheme.successGreen
        case .atRisk:  AppTheme.cafeAccent
        case .broken:  AppTheme.cream.opacity(0.5)
        }
    }
}

