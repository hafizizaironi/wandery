import SwiftUI
import FirebaseAuth

// MARK: - Profile home (tab page)

struct ProfileHomeView: View {
    @ObservedObject var authService:   AuthService
    @ObservedObject var statsService:  UserStatsService
    @ObservedObject var socialService: SocialService
    /// True while this shell page is the visible tab (Map / Hero / Profile pager).
    var isTabActive: Bool

    @Environment(\.scenePhase) private var scenePhase

    @State private var showEditProfile     = false
    @State private var selectedAchievement: Achievement?
    @State private var addFriendQuery      = ""
    @State private var friendBusy          = false
    @State private var friendMessage       = ""

    // MARK: - Computed helpers

    private var user: FirebaseAuth.User? { authService.user }

    private var displayName: String {
        user?.displayName ?? user?.email?.components(separatedBy: "@").first ?? "Explorer"
    }

    private var usernameLine: String {
        if let u = socialService.profile?.username, !u.isEmpty {
            return "@\(u)"
        }
        return "Set a username to add friends"
    }

    private var daysActive: Int {
        guard let created = user?.metadata.creationDate else { return 1 }
        return max(1, Calendar.current.dateComponents([.day], from: created, to: Date()).day ?? 1)
    }

    private var huntingSinceText: String {
        guard let created = user?.metadata.creationDate else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return "Hunting since \(f.string(from: created))"
    }

    // Build chronological milestone cards from unlocked achievements
    private var milestones: [MilestoneItem] {
        var items: [MilestoneItem] = []
        if let created = user?.metadata.creationDate {
            items.append(MilestoneItem(id: "start", icon: "🚀",
                                       title: "First Step",
                                       description: "Joined the hunt",
                                       date: created))
        }
        for a in Achievement.definitions {
            if let date = statsService.stats.unlockedAchievements[a.id] {
                items.append(MilestoneItem(id: a.id, icon: a.icon,
                                           title: a.title,
                                           description: a.flavourText,
                                           date: date))
            }
        }
        return items.sorted { $0.date < $1.date }
    }

    // Anniversary badge is evaluated from account creation date
    private func isUnlocked(_ achievement: Achievement) -> Bool {
        if achievement.id == "anniversary" {
            guard let created = user?.metadata.creationDate else { return false }
            return Date().timeIntervalSince(created) >= 365 * 24 * 3600
        }
        return statsService.stats.unlockedAchievements[achievement.id] != nil
            || achievement.condition(statsService.stats)
    }

    private func unlockDate(for achievement: Achievement) -> Date? {
        if achievement.id == "anniversary" {
            guard let created = user?.metadata.creationDate, isUnlocked(achievement) else { return nil }
            return Calendar.current.date(byAdding: .year, value: 1, to: created)
        }
        return statsService.stats.unlockedAchievements[achievement.id]
    }

    private var unlockedCount: Int {
        Achievement.definitions.filter { isUnlocked($0) }.count
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroHeader
                    statsRow
                    if !socialService.incomingRequests.isEmpty {
                        friendRequestsSection
                    }
                    friendSearchSection
                    storySection
                    achievementsSection
                    settingsSection
                }
                .padding(.bottom, ArcNavBar.frameContentHeight + 24)
            }
        }
        .floatingPanel(isPresented: $showEditProfile) {
            if let u = user {
                EditProfileView(user: u, authService: authService) {
                    showEditProfile = false
                }
            }
        }
        .floatingPanel(item: $selectedAchievement) { achievement in
            AchievementDetailSheet(
                achievement:  achievement,
                isUnlocked:   isUnlocked(achievement),
                unlockedDate: unlockDate(for: achievement)
            )
        }
        .onChange(of: isTabActive) { _, active in
            guard active else { return }
            Task { await authService.refreshCurrentUser() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isTabActive {
                Task { await authService.refreshCurrentUser() }
            }
        }
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.08, blue: 0.04),
                    AppTheme.espresso,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            AppTheme.cafeAccent.opacity(0.04)

            VStack(spacing: 14) {
                Spacer().frame(height: 56)

                Button { showEditProfile = true } label: {
                    ZStack(alignment: .bottomTrailing) {
                        avatarView
                            .frame(width: 100, height: 100)
                            .clipShape(Circle())
                            .overlay(
                                Circle().stroke(
                                    LinearGradient(
                                        colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 3
                                )
                            )
                            .shadow(color: AppTheme.cafeAccent.opacity(0.45), radius: 18)

                        Circle()
                            .fill(AppTheme.cafeAccent)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                            )
                            .shadow(color: AppTheme.cafeAccent.opacity(0.6), radius: 6)
                            .offset(x: 2, y: 2)
                    }
                }
                .buttonStyle(.plain)

                Text(displayName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(AppTheme.cream)

                Text(usernameLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.cream.opacity(0.45))

                if !huntingSinceText.isEmpty {
                    Text(huntingSinceText)
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.cream.opacity(0.3))
                }

                // Share username if set
                if let name = socialService.profile?.username, !name.isEmpty {
                    ShareLink(item: "Add me on CafeHunter: @\(name)") {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppTheme.cafeAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(AppTheme.cafeAccent.opacity(0.1))
                            .cornerRadius(20)
                            .overlay(RoundedRectangle(cornerRadius: 20)
                                .stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1))
                    }
                }

                Button { showEditProfile = true } label: {
                    Text("Edit Profile")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.cafeAccent)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(AppTheme.cafeAccent.opacity(0.12))
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                        )
                }

                Spacer().frame(height: 28)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarView: some View {
        if let url = user?.photoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: initialsCircle
                }
            }
            .id(url.absoluteString)
        } else {
            initialsCircle
        }
    }

    private var initialsCircle: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(AppTheme.cream)
        }
    }

    private var initials: String {
        displayName.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined().uppercased()
    }

    // MARK: - Stats row

    private var statsRow: some View {
        HStack(spacing: 10) {
            ProfileStatCell(value: "\(statsService.stats.cafesVisited)",  label: "Cafés",   icon: "☕")
            ProfileStatCell(value: "\(statsService.stats.stallsVisited)", label: "Stalls",  icon: "🍜")
            ProfileStatCell(value: "\(daysActive)",                       label: "Days",    icon: "📅")
            ProfileStatCell(value: "\(statsService.stats.friendsHunted)", label: "Friends", icon: "👥")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Friend requests

    private var friendRequestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("FRIEND REQUESTS",
                          trailing: "\(socialService.incomingRequests.count) pending")

            ForEach(socialService.incomingRequests) { req in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("@\(req.fromUsername)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.cream)
                        Text("wants to connect")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.cream.opacity(0.45))
                    }
                    Spacer()
                    Button("Decline") {
                        Task { try? await socialService.rejectRequest(req) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.cream.opacity(0.5))

                    Button("Accept") {
                        Task { try? await socialService.acceptRequest(req) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppTheme.cafeAccent)
                    .cornerRadius(10)
                }
                .padding(14)
                .background(AppTheme.cream.opacity(0.05))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppTheme.cafeAccent.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    // MARK: - Friend search

    private var friendSearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("ADD FRIEND")

            HStack(spacing: 10) {
                TextField("username", text: $addFriendQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.cream)
                    .tint(AppTheme.cafeAccent)
                    .padding(12)
                    .background(AppTheme.cream.opacity(0.06))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.cafeAccent.opacity(0.2), lineWidth: 1))

                Button {
                    Task { await sendFriendRequest() }
                } label: {
                    Text("Add")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(friendBusy
                                    ? AppTheme.cafeAccent.opacity(0.4)
                                    : AppTheme.cafeAccent)
                        .cornerRadius(12)
                }
                .disabled(friendBusy || addFriendQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !friendMessage.isEmpty {
                Text(friendMessage)
                    .font(.system(size: 12))
                    .foregroundColor(friendMessage.contains("Sent")
                                     ? AppTheme.successGreen
                                     : AppTheme.errorRed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    // MARK: - Your story

    private var storySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("YOUR STORY SO FAR")
                Text("Milestones from your hunt and achievements — not your Hero feed posts.")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.cream.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)

            if milestones.isEmpty {
                Text("Your story is just beginning —\ngo find your first spot! ☕")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.cream.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(milestones) { item in
                            StoryCard(item: item)
                        }
                        if milestones.count < 4 {
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

    // MARK: - Achievements

    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                "ACHIEVEMENTS",
                trailing: "\(unlockedCount) / \(Achievement.definitions.count)"
            )

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 16
            ) {
                ForEach(Achievement.definitions) { achievement in
                    AchievementBadge(
                        achievement: achievement,
                        isUnlocked:  isUnlocked(achievement)
                    )
                    .onTapGesture { selectedAchievement = achievement }
                }
            }
        }
        .padding(16)
        .padding(.top, 12)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: 12) {
            if authService.isAdmin {
                HStack {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.cafeAccent)
                    Text("Admin Account")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.cafeAccent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppTheme.cafeAccent.opacity(0.1))
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                )
            }

            Button {
                try? authService.signOut()
            } label: {
                Text("Sign out")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.cafeAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.cafeAccent.opacity(0.10))
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Section header helper

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(2)
                .foregroundColor(AppTheme.cream.opacity(0.35))
            Spacer()
            if let t = trailing {
                Text(t)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.cafeAccent)
            }
        }
    }

    // MARK: - Send friend request

    private func sendFriendRequest() async {
        let query = addFriendQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        friendBusy    = true
        friendMessage = ""
        do {
            try await socialService.sendFriendRequest(toUsername: query)
            friendMessage    = "Sent! 🎉"
            addFriendQuery   = ""
        } catch {
            friendMessage = error.localizedDescription
        }
        friendBusy = false
    }
}

// MARK: - Stat cell

private struct ProfileStatCell: View {
    let value: String
    let label: String
    let icon:  String

    var body: some View {
        VStack(spacing: 5) {
            Text(icon).font(.system(size: 18))
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppTheme.cream)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppTheme.cream.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AppTheme.cream.opacity(0.04))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.cafeAccent.opacity(0.14), lineWidth: 1)
        )
    }
}

// MARK: - Milestone model

struct MilestoneItem: Identifiable {
    let id:          String
    let icon:        String
    let title:       String
    let description: String
    let date:        Date
}

// MARK: - Story card

private struct StoryCard: View {
    let item: MilestoneItem

    private var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: item.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.icon)
                .font(.system(size: 32))

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(AppTheme.cream)
                Text(item.description)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.cream.opacity(0.55))
                    .lineLimit(2)
                Text(dateText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppTheme.cafeAccent.opacity(0.8))
            }
        }
        .padding(16)
        .frame(width: 148, height: 160)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.10, blue: 0.05),
                    Color(red: 0.12, green: 0.07, blue: 0.03),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cafeAccent.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - Story teaser card

private struct StoryTeaserCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundColor(AppTheme.cafeAccent.opacity(0.5))
            Text("More milestones\nawaiting you ✨")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.cream.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(width: 148, height: 160)
        .background(AppTheme.cream.opacity(0.03))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cream.opacity(0.07), lineWidth: 1)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
        )
    }
}

// MARK: - Achievement badge (grid cell)

struct AchievementBadge: View {
    let achievement: Achievement
    let isUnlocked:  Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isUnlocked
                          ? AppTheme.cafeAccent.opacity(0.15)
                          : AppTheme.cream.opacity(0.04))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle().stroke(
                            isUnlocked
                                ? AppTheme.cafeAccent.opacity(0.55)
                                : AppTheme.cream.opacity(0.08),
                            lineWidth: isUnlocked ? 2 : 1
                        )
                    )
                    .shadow(
                        color: isUnlocked ? AppTheme.cafeAccent.opacity(0.35) : .clear,
                        radius: 10
                    )

                if isUnlocked {
                    Text(achievement.icon)
                        .font(.system(size: 28))
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18))
                        .foregroundColor(AppTheme.cream.opacity(0.18))
                }
            }

            Text(achievement.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isUnlocked ? AppTheme.cream : AppTheme.cream.opacity(0.28))
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
                        .overlay(
                            Circle().stroke(
                                isUnlocked
                                    ? AppTheme.cafeAccent.opacity(0.55)
                                    : AppTheme.cream.opacity(0.1),
                                lineWidth: 2
                            )
                        )
                        .shadow(
                            color: isUnlocked ? AppTheme.cafeAccent.opacity(0.45) : .clear,
                            radius: 22
                        )

                    if isUnlocked {
                        Text(achievement.icon).font(.system(size: 48))
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 36))
                            .foregroundColor(AppTheme.cream.opacity(0.2))
                    }
                }

                Spacer().frame(height: 24)

                Text(achievement.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(AppTheme.cream)

                Spacer().frame(height: 8)

                Text(isUnlocked ? achievement.flavourText : achievement.subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.cream.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 20)

                if let date = unlockedDate {
                    let f: DateFormatter = {
                        let df = DateFormatter()
                        df.dateFormat = "d MMM yyyy"
                        return df
                    }()
                    Text("Unlocked \(f.string(from: date))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.cafeAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(AppTheme.cafeAccent.opacity(0.12))
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    Text("How to unlock: \(achievement.subtitle)")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.cream.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
        }
    }
}
