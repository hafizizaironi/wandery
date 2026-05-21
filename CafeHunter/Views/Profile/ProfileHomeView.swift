import SwiftUI
import FirebaseAuth
import FirebaseFirestore
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
    /// Tracks which friend request is currently being accepted or declined
    /// so the row can show a spinner in place of the button label and the
    /// other action is disabled. Cleared once the await returns. The
    /// request id (not just a bool) is needed because incoming requests
    /// render in a ForEach — the busy state has to be per-row.
    @State private var processingRequestId: String?
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

    /// Debounced username-prefix search driving the autocomplete dropdown
    /// under the Add Friend input. Owned at the view level so the
    /// suggestions survive across re-renders triggered by other state.
    @State private var friendSearch = FriendSearchModel()

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
                    friendsSection
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
                    ShareLink(item: "Add me on Wandery: @\(name)") {
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
                    let busy = processingRequestId == req.id
                    let anyBusy = processingRequestId != nil

                    Button {
                        Task { await handleRequest(req, accept: false) }
                    } label: {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AppTheme.cream.opacity(0.6))
                        } else {
                            Text("Decline")
                        }
                    }
                    .font(.caption)
                    .contrastAware(AppTheme.cream, opacity: 0.5)
                    .disabled(anyBusy)

                    Button {
                        Task { await handleRequest(req, accept: true) }
                    } label: {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                .frame(minWidth: 44)
                        } else {
                            Text("Accept")
                        }
                    }
                    .font(.caption).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppTheme.cafeAccent.opacity(anyBusy && !busy ? 0.5 : 1.0))
                    .clipShape(.rect(cornerRadius: 10))
                    .disabled(anyBusy)
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

    // MARK: - Friends (combined avatar strip + add-friend input)

    /// One section that owns everything friend-related on the profile:
    /// a horizontal scroll of friend avatars with stagger-on-appear, a
    /// "See all" affordance, the add-friend input + button, and a status
    /// line that fades in on success/error. Replaces the old standalone
    /// Friends stat tile + Add Friend form.
    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                "FRIENDS",
                trailing: socialService.friendIds.isEmpty
                    ? nil
                    : "\(socialService.friendIds.count) total"
            )

            friendAvatarStrip
                .animation(Motion.dropdown, value: friendLoader.rows.count)

            addFriendField

            if !friendMessage.isEmpty {
                Text(friendMessage)
                    .font(.caption)
                    .foregroundStyle(friendMessage.contains("Sent")
                                     ? AppTheme.successGreen
                                     : AppTheme.errorRed)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .animation(Motion.dropdown, value: friendMessage)
    }

    @ViewBuilder
    private var friendAvatarStrip: some View {
        if friendLoader.rows.isEmpty {
            // Empty state — keeps the same vertical footprint as the strip
            // so the section doesn't visibly jump when the first friend
            // lands. Soft dashed circle + a single-line nudge to use the
            // input below.
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AppTheme.cream.opacity(0.04))
                        .frame(width: 60, height: 60)
                        .overlay {
                            Circle().stroke(
                                AppTheme.cream.opacity(0.12),
                                style: StrokeStyle(lineWidth: 1, dash: [4])
                            )
                        }
                    Text("👋")
                        .font(.title2)
                        .accessibilityHidden(true)
                }
                Text("No friends yet — add someone with their username below.")
                    .font(.caption)
                    .contrastAware(AppTheme.cream, opacity: 0.5)
                Spacer(minLength: 0)
            }
            .frame(height: 92)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(friendLoader.rows.enumerated()), id: \.element.id) { index, row in
                        Button {
                            openChat(otherUid: row.id, title: row.titleText)
                        } label: {
                            FriendAvatarChip(row: row)
                        }
                        .buttonStyle(.scalePress)
                        .transition(Motion.coziedScaleFade)
                        // 50ms cascade between bubbles — fast enough to
                        // feel snappy on a short list, slow enough to
                        // read as motion even with five+ friends.
                        .animation(
                            reduceMotion
                                ? Motion.staggerReveal
                                : Motion.staggerReveal.delay(Double(index) * 0.05),
                            value: friendLoader.rows.count
                        )
                    }

                    Button { showFriendList = true } label: {
                        seeAllChip
                    }
                    .buttonStyle(.scalePress)
                    .accessibilityLabel("Open friend list")
                }
                .padding(.vertical, 4)
            }
            .frame(height: 92)
        }
    }

    private var seeAllChip: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(AppTheme.cream.opacity(0.06))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Circle().stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                    }
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(AppTheme.cafeAccent)
            }
            Text("See all")
                .font(.caption2).bold()
                .foregroundStyle(AppTheme.cafeAccent)
        }
        .frame(width: 64)
    }

    private var addFriendField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Add by @username", text: $addFriendQuery)
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
                    .onChange(of: addFriendQuery) { _, newValue in
                        var excludes: Set<String> = Set(socialService.friendIds)
                        if let uid = authService.user?.uid { excludes.insert(uid) }
                        friendSearch.queryChanged(newValue, excludeUids: excludes)
                    }

                Button {
                    Task { await sendFriendRequest() }
                } label: {
                    Group {
                        if friendBusy {
                            ProgressView()
                                .tint(.white)
                                .frame(minWidth: 28)
                        } else {
                            Text("Add")
                                .font(.footnote).bold()
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(friendBusy
                                ? AppTheme.cafeAccent.opacity(0.4)
                                : AppTheme.cafeAccent)
                    .clipShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.scalePress)
                .disabled(friendBusy || addFriendQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if shouldShowSuggestions {
                suggestionsDropdown
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .animation(Motion.dropdown, value: friendSearch.suggestions.map(\.id))
        .animation(Motion.dropdown, value: friendSearch.isSearching)
    }

    /// Hide the dropdown once the typed text exactly matches the only
    /// suggestion — that's the "user just tapped a row" state, so echoing
    /// the same row back would be visual noise.
    private var shouldShowSuggestions: Bool {
        let trimmed = addFriendQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.count >= 2 else { return false }
        if friendSearch.suggestions.count == 1,
           let only = friendSearch.suggestions.first,
           (only.username ?? "").lowercased() == trimmed {
            return false
        }
        return !friendSearch.suggestions.isEmpty || friendSearch.isSearching
    }

    @ViewBuilder
    private var suggestionsDropdown: some View {
        VStack(spacing: 0) {
            if friendSearch.suggestions.isEmpty {
                // Searching with no results yet — show a single-line loader
                // so the user knows something's happening behind the text
                // field rather than an empty silence.
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.cafeAccent)
                    Text("Searching…")
                        .font(.caption)
                        .contrastAware(AppTheme.cream, opacity: 0.55)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                ForEach(Array(friendSearch.suggestions.enumerated()), id: \.element.id) { index, hit in
                    Button {
                        // Send immediately — the user explicitly picked this
                        // row out of the dropdown, that's the confirmation.
                        // Setting `addFriendQuery` first means sendFriendRequest
                        // reads the chosen username, and on success the field
                        // clears itself (plus we clear the dropdown below).
                        guard let username = hit.username, !username.isEmpty,
                              !friendBusy else { return }
                        addFriendQuery = username
                        friendSearch.clear()
                        Task { await sendFriendRequest() }
                    } label: {
                        suggestionRow(hit: hit)
                    }
                    .buttonStyle(.scalePress)
                    .disabled(friendBusy)

                    if index < friendSearch.suggestions.count - 1 {
                        Rectangle()
                            .fill(AppTheme.cream.opacity(0.08))
                            .frame(height: 0.5)
                            .padding(.leading, 54)
                    }
                }
            }
        }
        .background(AppTheme.cream.opacity(0.05))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.cafeAccent.opacity(0.18), lineWidth: 1)
        }
    }

    private func suggestionRow(hit: FriendSearchHit) -> some View {
        HStack(spacing: 12) {
            // 32px avatar — small enough to fit several rows, big enough
            // to be recognisable.
            Group {
                if let urlString = hit.photoURL, let url = URL(string: urlString) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: suggestionInitials(for: hit)
                        }
                    }
                } else {
                    suggestionInitials(for: hit)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("@\(hit.username ?? "")")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)
                    .lineLimit(1)
                if let n = hit.displayName, !n.isEmpty {
                    Text(n)
                        .font(.caption2)
                        .contrastAware(AppTheme.cream, opacity: 0.5)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "person.badge.plus")
                .font(.footnote).bold()
                .foregroundStyle(AppTheme.cafeAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AppTheme.cafeAccent.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func suggestionInitials(for hit: FriendSearchHit) -> some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.cafeAccent.opacity(0.85), AppTheme.stallAccent.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(suggestionInitialString(for: hit))
                .font(.caption).bold()
                .foregroundStyle(.white)
        }
    }

    private func suggestionInitialString(for hit: FriendSearchHit) -> String {
        let source = hit.displayName ?? hit.username ?? "?"
        return source.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined().uppercased()
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

    /// Presents the chat sheet immediately. The conversation document is
    /// *lazy-created* by ChatView on first send — see ChatView.send().
    ///
    /// Previous attempts (a) awaited findOrCreateConversation before
    /// presenting (200–400ms blank gap) and (b) ran it in the background
    /// after presenting (silently dismissed the chat if the create failed).
    /// Both surprised the user. The lazy-on-send pattern matches the
    /// expected mental model: tap Message → chat opens → type → first
    /// send creates the thread + delivers the message.
    private func openChat(otherUid: String, title: String) {
        showFriendList = false
        pendingChat = PendingChat(convId: nil, otherUid: otherUid, title: title)
    }

    // MARK: - Accept / decline friend request

    /// Shared handler so the row shows a spinner while the callable
    /// runs (acceptFriendRequest takes ~400–800ms with the friend-cap
    /// transaction). Without this the user saw no feedback between
    /// tap and the request disappearing from the list.
    private func handleRequest(_ req: FriendRequestModel, accept: Bool) async {
        guard processingRequestId == nil else { return }
        processingRequestId = req.id
        defer { processingRequestId = nil }
        do {
            if accept {
                try await socialService.acceptRequest(req)
            } else {
                try await socialService.rejectRequest(req)
            }
        } catch {
            // Surface via the friend-search message slot — same spot the
            // user already looks for friend-related errors.
            friendMessage = error.localizedDescription
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
            // Dismiss any lingering autocomplete dropdown — the user just
            // sent to whoever was in the field, so further suggestions
            // would be noise.
            friendSearch.clear()
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

// MARK: - Friend search (autocomplete dropdown)

/// One row in the username-autocomplete dropdown under the "Add friend"
/// input. Hydrated from `users/{uid}` after a prefix match on the
/// lowercased `usernames` collection.
struct FriendSearchHit: Identifiable, Equatable {
    let id: String   // = uid
    let username: String?
    let displayName: String?
    let photoURL: String?
}

@MainActor
@Observable
final class FriendSearchModel {
    private(set) var suggestions: [FriendSearchHit] = []
    private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?
    private let db = Firestore.firestore()

    /// Debounce + fan-out search. `usernames/{lowercase}` doc IDs are the
    /// canonical case-insensitive index — a doc-ID prefix range there
    /// gives us matching uids in one query, then we fetch each user's
    /// public profile in parallel. Excludes self + existing friends so
    /// the dropdown only ever shows actionable add-targets.
    func queryChanged(_ text: String, excludeUids: Set<String>) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        searchTask?.cancel()
        guard trimmed.count >= 2 else {
            suggestions = []
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            // Debounce — keystrokes within 220ms collapse to one query so
            // typing a 6-char name doesn't trigger six round-trips.
            try? await Task.sleep(for: .milliseconds(220))
            if Task.isCancelled { return }
            await self?.run(trimmed, excludeUids: excludeUids)
        }
    }

    func clear() {
        searchTask?.cancel()
        suggestions = []
        isSearching = false
    }

    private func run(_ q: String, excludeUids: Set<String>) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let upper = q + "\u{f8ff}"
            let snap = try await db.collection("usernames")
                .whereField(FieldPath.documentID(), isGreaterThanOrEqualTo: q)
                .whereField(FieldPath.documentID(), isLessThan: upper)
                .limit(to: 10)
                .getDocuments()
            if Task.isCancelled { return }
            let uids = snap.documents.compactMap { ($0.data()["uid"] as? String) }
                .filter { !excludeUids.contains($0) }
            let hits = await fetchProfiles(uids: uids)
            if Task.isCancelled { return }
            suggestions = hits.sorted { ($0.username ?? "") < ($1.username ?? "") }
        } catch {
            #if DEBUG
            print("[FriendSearch] query '\(q)' failed: \(error.localizedDescription)")
            #endif
            suggestions = []
        }
    }

    private func fetchProfiles(uids: [String]) async -> [FriendSearchHit] {
        await withTaskGroup(of: FriendSearchHit?.self) { group in
            for uid in uids {
                group.addTask { [db] in
                    guard let doc = try? await db.collection("users").document(uid).getDocument(),
                          let data = doc.data() else { return nil }
                    return FriendSearchHit(
                        id: uid,
                        username: data["username"] as? String,
                        displayName: data["displayName"] as? String,
                        photoURL: data["photoURL"] as? String
                    )
                }
            }
            var arr: [FriendSearchHit] = []
            for await item in group { if let item { arr.append(item) } }
            return arr
        }
    }
}

// MARK: - Friend avatar chip (horizontal strip on profile)

/// One circle in the profile's friend strip. Renders the friend's photo if
/// available, falls back to gradient initials. Username text under the
/// avatar so the user recognises faces *and* handles at a glance.
private struct FriendAvatarChip: View {
    let row: FriendRow

    var body: some View {
        VStack(spacing: 6) {
            avatar
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(AppTheme.cafeAccent.opacity(0.35), lineWidth: 2)
                }

            Text(labelText)
                .font(.caption2)
                .foregroundStyle(AppTheme.cream)
                .lineLimit(1)
                .frame(maxWidth: 72)
        }
        .frame(width: 72)
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = row.photoURL, let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: initialsCircle
                }
            }
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
                .font(.headline).bold()
                .foregroundStyle(.white)
        }
    }

    private var labelText: String {
        if let u = row.username, !u.isEmpty { return "@\(u)" }
        if let n = row.displayName, !n.isEmpty { return n }
        return "Friend"
    }

    private var initials: String {
        let source = row.displayName ?? row.username ?? "?"
        return source.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined().uppercased()
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
