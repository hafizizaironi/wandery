import SwiftUI
import FirebaseAuth
import FirebaseFunctions

// MARK: - Profile home (tab page)

struct ProfileHomeView: View {
    @ObservedObject var authService:         AuthService
    @ObservedObject var statsService:        UserStatsService
    @ObservedObject var socialService:       SocialService
    @ObservedObject var conversationService: ConversationService
    /// True while this shell page is the visible tab (Map / Hero / Profile pager).
    var isTabActive: Bool
    /// Flipped to true while a chat overlay is presented from this page so
    /// MainShellView can spring the arc navbar off-screen. Mirrors the
    /// same binding HeroPageView writes to.
    @Binding var isChatActive: Bool
    /// Set by MainShellView. Called when a chat thumbnail tapped here
    /// wants to land on a post in the Hero feed; the shell switches to
    /// the Hero tab and HeroPageView scrolls to the post.
    var onJumpToHeroPost: (String) -> Void = { _ in }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showEditProfile     = false
    @State private var selectedAchievement: Achievement?
    @State private var addFriendQuery      = ""
    @State private var friendBusy          = false
    @State private var friendMessage       = ""
    @State private var showFriendList      = false
    @State private var pendingChat: PendingChat?
    @State private var isBackfilling       = false
    @State private var backfillMessage     = ""
    @State private var signOutError       = ""
    @State private var showDeleteConfirm   = false
    @State private var isDeleting          = false
    @State private var deleteError         = ""
    /// Pre-fetches friend profiles so the friend list panel opens with rows
    /// already cached. Owned here so the cache survives floating-panel
    /// open/close cycles, and so sync can happen while the user is still
    /// looking at the profile (not just when they tap the Friends stat).
    @State private var friendLoader = FriendListLoader()

    /// Memoized derived state — see computeMilestones() / computeUnlockedCount().
    /// Recomputed only via the .task(id:) at the bottom of body, not on
    /// every body re-render.
    @State private var memoizedMilestones: [MilestoneItem] = []
    @State private var memoizedUnlockedCount: Int = 0

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
        return max(1, Calendar.current.dateComponents([.day], from: created, to: Date.now).day ?? 1)
    }

    private var huntingSinceText: String {
        guard let created = user?.metadata.creationDate else { return "" }
        let formatted = created.formatted(.dateTime.month(.abbreviated).year())
        return "Hunting since \(formatted)"
    }

    // Build chronological milestone cards from unlocked achievements.
    // Cached in `memoizedMilestones`; recomputed only when the achievement
    // dictionary or the account creation date changes (driven by .task(id:)
    // on the body below). Avoids running the sort + alloc on every parent
    // re-render — and there are a lot of those since 4 @ObservedObject
    // services feed this view.
    private func computeMilestones() -> [MilestoneItem] {
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
            return Date.now.timeIntervalSince(created) >= 365 * 24 * 3600
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

    private func computeUnlockedCount() -> Int {
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
        .keyboardDismissToolbar()
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
        .floatingPanel(isPresented: $showFriendList) {
            FriendListView(
                socialService: socialService,
                loader: friendLoader,
                onMessage: { row in openChat(otherUid: row.id, title: row.titleText) },
                onClose: { showFriendList = false }
            )
        }
        // Full-screen chat — slides in from the trailing edge. Same pattern
        // as the Hero feed's chat presentation so the surface is consistent.
        .overlay {
            if let chat = pendingChat {
                ChatView(
                    conversationService: conversationService,
                    socialService: socialService,
                    convId: chat.convId,
                    otherUid: chat.otherUid,
                    otherTitle: chat.title,
                    onClose: {
                        conversationService.openThread(nil)
                        pendingChat = nil
                    },
                    onJumpToPost: { postId in
                        conversationService.openThread(nil)
                        pendingChat = nil
                        onJumpToHeroPost(postId)
                    }
                )
                .background(AppTheme.espresso.ignoresSafeArea())
                .ignoresSafeArea(.container)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(40)
            }
        }
        .animation(
            .motionRespecting(
                .spring(response: 0.28, dampingFraction: 0.86),
                reduceMotion: reduceMotion
            ),
            value: pendingChat?.id
        )
        // Pre-hydrate friend profiles while the user is still on the
        // profile page, so opening the Friends panel feels instant
        // instead of "tap → spinner → list".
        .task(id: socialService.friendIds) {
            await friendLoader.sync(with: socialService.friendIds)
        }
        // Recompute milestone + achievement-unlock derived state only when
        // the underlying achievement dictionary changes — not on every
        // parent re-render. The 4-service @ObservedObject pattern means
        // body invalidates often (Firestore listener fires); without this
        // memoization we'd re-sort milestones and re-filter unlock count
        // on every chat message or feed snapshot.
        .task(id: statsService.stats.unlockedAchievements) {
            memoizedMilestones = computeMilestones()
            memoizedUnlockedCount = computeUnlockedCount()
        }
        // Hide the arc navbar while a chat overlay is presented from
        // this page — mirrors HeroPageView's syncChatActiveFlag. Same
        // spring as the shell so the navbar slide and the chat slide-in
        // read as one coupled motion.
        .onChange(of: pendingChat?.id) { _, _ in
            let active = pendingChat != nil
            guard active != isChatActive else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                isChatActive = active
            }
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
                            .overlay {
                                Circle().stroke(
                                    LinearGradient(
                                        colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 3
                                )
                            }
                            .shadow(color: AppTheme.cafeAccent.opacity(0.45), radius: 18)

                        Circle()
                            .fill(AppTheme.cafeAccent)
                            .frame(width: 28, height: 28)
                            .overlay {
                                Image(systemName: "camera.fill")
                                    .font(.caption).bold()
                                    .foregroundStyle(.white)
                            }
                            .shadow(color: AppTheme.cafeAccent.opacity(0.6), radius: 6)
                            .offset(x: 2, y: 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit profile photo")

                Text(displayName)
                    .font(.title2).bold()
                    .foregroundStyle(AppTheme.cream)

                Text(usernameLine)
                    .font(.footnote)
                    .contrastAware(AppTheme.cream, opacity: 0.45)

                if !huntingSinceText.isEmpty {
                    Text(huntingSinceText)
                        .font(.caption2)
                        .contrastAware(AppTheme.cream, opacity: 0.3)
                }

                // Share username if set
                if let name = socialService.profile?.username, !name.isEmpty {
                    ShareLink(item: "Add me on CafeHunter: @\(name)") {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.caption).bold()
                            .foregroundStyle(AppTheme.cafeAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(AppTheme.cafeAccent.opacity(0.1))
                            .clipShape(.rect(cornerRadius: 20))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1)
                            }
                    }
                }

                Button { showEditProfile = true } label: {
                    Text("Edit Profile")
                        .font(.footnote).bold()
                        .foregroundStyle(AppTheme.cafeAccent)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(AppTheme.cafeAccent.opacity(0.12))
                        .clipShape(.rect(cornerRadius: 20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                        }
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
                .font(.largeTitle).bold()
                .foregroundStyle(AppTheme.cream)
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
            // `friendsHunted` is a denormalized stat that wasn't being kept
            // in sync on accept/remove. The friends listener already gives us
            // a live count, so trust that directly. Tap → friend list.
            Button { showFriendList = true } label: {
                ProfileStatCell(value: "\(socialService.friendIds.count)", label: "Friends", icon: "👥")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open friend list")
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
                            .font(.subheadline).bold()
                            .foregroundStyle(AppTheme.cream)
                        Text("wants to connect")
                            .font(.caption2)
                            .contrastAware(AppTheme.cream, opacity: 0.45)
                    }
                    Spacer()
                    Button("Decline") {
                        Task { try? await socialService.rejectRequest(req) }
                    }
                    .font(.caption)
                    .contrastAware(AppTheme.cream, opacity: 0.5)

                    Button("Accept") {
                        Task { try? await socialService.acceptRequest(req) }
                    }
                    .font(.caption).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppTheme.cafeAccent)
                    .clipShape(.rect(cornerRadius: 10))
                }
                .padding(14)
                .background(AppTheme.cream.opacity(0.05))
                .clipShape(.rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppTheme.cafeAccent.opacity(0.2), lineWidth: 1)
                }
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
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.cream)
                    .tint(AppTheme.cafeAccent)
                    .padding(12)
                    .background(AppTheme.cream.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.cafeAccent.opacity(0.2), lineWidth: 1)
                    }

                Button {
                    Task { await sendFriendRequest() }
                } label: {
                    Text("Add")
                        .font(.footnote).bold()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(friendBusy
                                    ? AppTheme.cafeAccent.opacity(0.4)
                                    : AppTheme.cafeAccent)
                        .clipShape(.rect(cornerRadius: 12))
                }
                .disabled(friendBusy || addFriendQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !friendMessage.isEmpty {
                Text(friendMessage)
                    .font(.caption)
                    .foregroundStyle(friendMessage.contains("Sent")
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
                    .font(.caption2)
                    .contrastAware(AppTheme.cream, opacity: 0.35)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)

            if memoizedMilestones.isEmpty {
                Text("Your story is just beginning —\ngo find your first spot! ☕")
                    .font(.footnote)
                    .contrastAware(AppTheme.cream, opacity: 0.4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(memoizedMilestones) { item in
                            StoryCard(item: item)
                        }
                        if memoizedMilestones.count < 4 {
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
                trailing: "\(memoizedUnlockedCount) / \(Achievement.definitions.count)"
            )

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 16
            ) {
                ForEach(Achievement.definitions) { achievement in
                    Button {
                        selectedAchievement = achievement
                    } label: {
                        AchievementBadge(
                            achievement: achievement,
                            isUnlocked:  isUnlocked(achievement)
                        )
                    }
                    .buttonStyle(.plain)
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
                        .font(.caption2)
                        .foregroundStyle(AppTheme.cafeAccent)
                    Text("Admin Account")
                        .font(.caption).bold()
                        .foregroundStyle(AppTheme.cafeAccent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppTheme.cafeAccent.opacity(0.1))
                .clipShape(.rect(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                }
            }

            // Anyone can recompute their own Phase 5 counters. Useful for
            // bringing legacy activity (posts/visits/places from before
            // the achievement triggers shipped) into the achievement
            // grid without waiting for new history to accumulate.
            backfillStatsButton

            // Reviewer-required legal + support surfaces. App Store
            // Guideline 1.2 expects users to reach the developer from
            // inside the app, and 5.1.1 expects the Privacy Policy +
            // Terms of Use to be linkable post-onboarding.
            legalLinks

            Button(action: signOut) {
                Text("Sign out")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cafeAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.cafeAccent.opacity(0.10))
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                    }
            }

            if !signOutError.isEmpty {
                Text(signOutError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.errorRed)
                    .multilineTextAlignment(.center)
            }

            // Permanent in-app account deletion — required by App Store
            // Guideline 5.1.1(v) for any app with account creation.
            Button {
                showDeleteConfirm = true
            } label: {
                Group {
                    if isDeleting {
                        ProgressView()
                            .tint(AppTheme.errorRed)
                    } else {
                        Text("Delete Account")
                            .font(.subheadline).bold()
                            .foregroundStyle(AppTheme.errorRed)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.errorRed.opacity(0.08))
                .clipShape(.rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppTheme.errorRed.opacity(0.3), lineWidth: 1)
                }
            }
            .disabled(isDeleting)
            .alert(
                "Delete your account?",
                isPresented: $showDeleteConfirm
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text("This permanently removes your profile, posts, friends, and chats. This can't be undone.")
            }

            if !deleteError.isEmpty {
                Text(deleteError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.errorRed)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func signOut() {
        do {
            try authService.signOut()
        } catch {
            signOutError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var legalLinks: some View {
        VStack(spacing: 8) {
            legalRow(label: "Contact support",
                     systemImage: "envelope",
                     url: LegalURLs.supportMailto)
            legalRow(label: "Terms of Use",
                     systemImage: "doc.text",
                     url: LegalURLs.termsOfUse)
            legalRow(label: "Privacy Policy",
                     systemImage: "lock.shield",
                     url: LegalURLs.privacyPolicy)
        }
    }

    private func legalRow(label: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.caption).bold()
                    .frame(width: 18)
                Text(label)
                    .font(.footnote)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.cream.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(AppTheme.cream.opacity(0.65))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cream.opacity(0.04))
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.cream.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private func deleteAccount() async {
        deleteError = ""
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await authService.deleteAccount()
            // Success — auth listener flips currentUser to nil and
            // ContentView routes back to LoginView automatically.
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: - Section header helper

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
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

    // MARK: - Backfill stats

    private var backfillStatsButton: some View {
        VStack(spacing: 6) {
            Button { Task { await runBackfill() } } label: {
                HStack(spacing: 8) {
                    if isBackfilling {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption).bold()
                    }
                    Text(isBackfilling ? "Recomputing…" : "Recompute achievements")
                        .font(.caption).bold()
                }
                .contrastAware(AppTheme.cream, opacity: 0.55)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppTheme.cream.opacity(0.04))
                .clipShape(.rect(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppTheme.cream.opacity(0.10), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(isBackfilling)

            if !backfillMessage.isEmpty {
                Text(backfillMessage)
                    .font(.caption2)
                    .contrastAware(AppTheme.cream, opacity: 0.5)
            }
        }
    }

    private func runBackfill() async {
        isBackfilling = true
        backfillMessage = ""
        defer { isBackfilling = false }
        do {
            let callable = Functions.functions().httpsCallable("backfillMyStats")
            let result = try await callable.call([:])
            if let dict = result.data as? [String: Any] {
                let unique = dict["uniquePlacesVisited"] as? Int ?? 0
                let pioneer = dict["pioneerCount"] as? Int ?? 0
                let reactions = dict["reactionsReceived"] as? Int ?? 0
                backfillMessage = "Found \(unique) places, \(pioneer) pioneered, \(reactions) reactions."
            } else {
                backfillMessage = "Done."
            }
        } catch {
            backfillMessage = error.localizedDescription
        }
    }

    // MARK: - Chat entry

    /// Presents the chat sheet immediately with a nil convId, then resolves
    /// the Firestore conversation doc in the background and patches the id
    /// in. Called from FriendListView's per-row Message button.
    ///
    /// Previously this awaited findOrCreateConversation *before* dismissing
    /// the friend list and showing chat, which left a 200-400ms "nothing
    /// happens" gap between tap and visible transition.
    private func openChat(otherUid: String, title: String) {
        showFriendList = false
        pendingChat = PendingChat(convId: nil, otherUid: otherUid, title: title)

        Task {
            do {
                let convId = try await conversationService.findOrCreateConversation(with: otherUid)
                // Only patch if the user hasn't closed the chat or opened a
                // different one in the meantime.
                guard pendingChat?.otherUid == otherUid else { return }
                conversationService.openThread(convId)
                pendingChat?.convId = convId
            } catch {
                // findOrCreateConversation failed (network / rules). Close the
                // chat shell so the user can retry rather than stay stuck on
                // "Connecting…" forever. Realistic causes for v1 are limited.
                if pendingChat?.otherUid == otherUid {
                    pendingChat = nil
                }
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

// MARK: - Pending chat (sheet driver)

/// Identity wrapper so `.floatingPanel(item:)` can present a freshly-opened
/// chat thread. Recreated each time `openChat` runs, even for the same
/// friend, so the sheet always re-presents.
///
/// `convId` is optional because we present the chat shell *immediately* on
/// the user's tap (so it slides in without waiting for Firestore) and patch
/// the convId in once `findOrCreateConversation` resolves. ChatView keeps
/// its @State across the patch since its position in the view tree doesn't
/// change.
struct PendingChat: Identifiable, Equatable {
    let id = UUID()
    var convId: String?
    let otherUid: String
    let title: String
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.icon)
                .font(.largeTitle)

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)
                Text(item.description)
                    .font(.caption2)
                    .contrastAware(AppTheme.cream, opacity: 0.55)
                    .lineLimit(2)
                Text(item.date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption2)
                    .foregroundStyle(AppTheme.cafeAccent.opacity(0.8))
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
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cafeAccent.opacity(0.18), lineWidth: 1)
        }
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
                    Image(systemName: "lock.fill")
                        .font(.title3)
                        .contrastAware(AppTheme.cream, opacity: 0.18)
                }
            }

            Text(achievement.title)
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
                        Image(systemName: "lock.fill")
                            .font(.largeTitle)
                            .contrastAware(AppTheme.cream, opacity: 0.2)
                    }
                }

                Spacer().frame(height: 24)

                Text(achievement.title)
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
