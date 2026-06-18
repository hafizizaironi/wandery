import SwiftUI
import FirebaseAuth

// MARK: - Achievement badge (grid cell)

struct AchievementBadge: View {
    let achievement: Achievement
    let isUnlocked:  Bool
    /// Secret + still locked → render as a mystery badge.
    private var hidden: Bool { achievement.isSecret && !isUnlocked }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isUnlocked
                          ? AppTheme.cafeAccent.opacity(0.15)
                          : AppTheme.cream.opacity(0.04))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Circle().stroke(
                            isUnlocked
                                ? AppTheme.cafeAccent.opacity(0.55)
                                : AppTheme.cream.opacity(0.08),
                            lineWidth: isUnlocked ? 2 : 1
                        )
                    }
                    .shadow(
                        color: isUnlocked ? AppTheme.cafeAccent.opacity(0.35) : .clear,
                        radius: 10
                    )

                if isUnlocked {
                    Text(achievement.icon)
                        .font(.title)
                } else {
                    Image(systemName: hidden ? "questionmark" : "lock.fill")
                        .font(.title3)
                        .contrastAware(AppTheme.cream, opacity: 0.18)
                }
            }

            Text(hidden ? "???" : achievement.title)
                .font(.caption2)
                .foregroundStyle(isUnlocked ? AppTheme.cream : AppTheme.cream.opacity(0.28))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(isUnlocked ? 1.0 : 0.65)
        .animation(.easeInOut(duration: 0.3), value: isUnlocked)
    }
}

// MARK: - Achievement detail sheet

struct AchievementDetailSheet: View {
    let achievement:  Achievement
    let isUnlocked:   Bool
    let unlockedDate: Date?
    @Environment(\.dismiss) private var dismiss
    /// Secret + still locked → don't reveal the name/condition.
    private var hidden: Bool { achievement.isSecret && !isUnlocked }

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(AppTheme.cream.opacity(0.2))
                    .frame(width: 38, height: 4)
                    .padding(.top, 14)
                    .padding(.bottom, 32)

                ZStack {
                    Circle()
                        .fill(isUnlocked
                              ? AppTheme.cafeAccent.opacity(0.15)
                              : AppTheme.cream.opacity(0.05))
                        .frame(width: 108, height: 108)
                        .overlay {
                            Circle().stroke(
                                isUnlocked
                                    ? AppTheme.cafeAccent.opacity(0.55)
                                    : AppTheme.cream.opacity(0.1),
                                lineWidth: 2
                            )
                        }
                        .shadow(
                            color: isUnlocked ? AppTheme.cafeAccent.opacity(0.45) : .clear,
                            radius: 22
                        )

                    if isUnlocked {
                        Text(achievement.icon).font(.largeTitle)
                    } else {
                        Image(systemName: hidden ? "questionmark" : "lock.fill")
                            .font(.largeTitle)
                            .contrastAware(AppTheme.cream, opacity: 0.2)
                    }
                }

                Spacer().frame(height: 24)

                Text(hidden ? "???" : achievement.title)
                    .font(.title2).bold()
                    .foregroundStyle(AppTheme.cream)

                Spacer().frame(height: 8)

                Text(isUnlocked ? achievement.flavourText : achievement.subtitle)
                    .font(.subheadline)
                    .contrastAware(AppTheme.cream, opacity: 0.55)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 20)

                if let date = unlockedDate {
                    Text("Unlocked \(date.formatted(.dateTime.day().month(.abbreviated).year()))")
                        .font(.caption2).bold()
                        .foregroundStyle(AppTheme.cafeAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(AppTheme.cafeAccent.opacity(0.12))
                        .clipShape(.rect(cornerRadius: 20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                        }
                } else if hidden {
                    Text("Secret achievement — keep hunting to reveal it. 🔎")
                        .font(.caption)
                        .contrastAware(AppTheme.cream, opacity: 0.35)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    Text("How to unlock: \(achievement.subtitle)")
                        .font(.caption)
                        .contrastAware(AppTheme.cream, opacity: 0.35)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
        }
    }
}


// MARK: - AchievementsSection (extracted)

/// Achievement grid. Receives the full `UserStats` value + the account
/// creation date so it can apply the same two-source unlock test the
/// parent's `isUnlocked` uses:
///   1. Stored unlock-timestamp on `users/{uid}.unlockedAchievements`.
///   2. Fallback — the current stats meet the achievement's condition.
/// The fallback is what keeps badges illuminated when the stored unlock
/// never made it into Firestore (e.g. the previous version's broken
/// strict-cast parse silently dropped the map). Both parent and section
/// route through `achievementIsUnlocked(...)` so behavior stays
/// identical to the pre-extraction code.
struct AchievementsSection: View {
    let stats: UserStats
    let accountCreatedAt: Date?
    let unlockedCount: Int
    let onTap: (Achievement) -> Void

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Collapsed default ≈ half the roster (a clean 8 rows of 3). The thematic
    /// order shows entry-tier badges first and keeps the secret / high-tier ones
    /// tucked behind "Show all".
    private let collapsedCount = 24

    private var total: Int { Achievement.definitions.count }
    private var canExpand: Bool { total > collapsedCount }
    private var visible: [Achievement] {
        isExpanded ? Achievement.definitions
                   : Array(Achievement.definitions.prefix(collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "ACHIEVEMENTS",
                trailing: "\(unlockedCount) / \(total)"
            )

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 16
            ) {
                ForEach(visible) { achievement in
                    Button { onTap(achievement) } label: {
                        AchievementBadge(
                            achievement: achievement,
                            isUnlocked: achievementIsUnlocked(
                                achievement,
                                stats: stats,
                                accountCreatedAt: accountCreatedAt
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if canExpand {
                Button {
                    withAnimation(reduceMotion ? nil : Motion.dropdown) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "Show less" : "Show all \(total)")
                            .font(.caption).bold()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(AppTheme.cafeAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(AppTheme.cafeAccent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.scalePress)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .padding(.top, 12)
    }
}

/// Single source of truth for "is this achievement unlocked?". Shared by
/// `ProfileHomeView.isUnlocked` and `AchievementsSection` so the two
/// can't drift apart again the way they did during the perf-pass
/// extraction.
func achievementIsUnlocked(
    _ achievement: Achievement,
    stats: UserStats,
    accountCreatedAt: Date?
) -> Bool {
    if achievement.id == "anniversary" {
        guard let created = accountCreatedAt else { return false }
        return Date.now.timeIntervalSince(created) >= 365 * 24 * 3600
    }
    return stats.unlockedAchievements[achievement.id] != nil
        || achievement.condition(stats)
}
