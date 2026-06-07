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

