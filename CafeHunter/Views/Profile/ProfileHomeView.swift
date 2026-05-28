import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// MARK: - Profile home (tab page)

struct ProfileHomeView: View {
    var authService:         AuthService
    var statsService:        UserStatsService
    var socialService:       SocialService
    var userPrivateService:  UserPrivateService
    /// True while this shell page is the visible tab (Map / Hero / Profile pager).
    var isTabActive: Bool
    /// Map data + My Hunt open-state, owned by MainShellView so the overlay
    /// can be hosted above the navbar.
    var friendPlacesService: FriendPlacesService
    @Binding var showMyHunt: Bool
    /// Fired when the user taps the per-row chat icon in the friends
    /// floating panel. MainShellView responds by presenting the chat
    /// fullScreenCover already opened to this friend's thread.
    var onMessageFriend: (FriendRow) -> Void = { _ in }
    /// Admin-only hook to re-present the "What's New" tutorial — bypasses
    /// the once-per-release AppStorage gate so the admin can preview the
    /// sheet without reinstalling. MainShellView toggles its own
    /// `showWhatsNew` from this closure.
    var onPreviewWhatsNew: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showEditProfile     = false
    @State private var selectedAchievement: Achievement?
    @State private var addFriendQuery      = ""
    @State private var friendBusy          = false
    @State private var friendMessage       = ""
    @State private var showFriendList      = false
    /// Tracks which friend request is currently being accepted or declined
    /// so the row can show a spinner in place of the button label and the
    /// other action is disabled. Cleared once the await returns. The
    /// request id (not just a bool) is needed because incoming requests
    /// render in a ForEach — the busy state has to be per-row.
    @State private var processingRequestId: String?
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

    /// Feed display style. Off = plain cards (default); on = polaroid frames.
    /// Read by HeroPageView's feed + capture-review via the same key.
    @AppStorage("feed.usePolaroidFrame") private var usePolaroidFrame = false


    // Long-press-on-avatar moderation surface state. The .contextMenu on
    // each FriendAvatarChip routes through these.
    @State private var pendingUnfriend: FriendRow?
    @State private var pendingBlock: FriendRow?
    @State private var reportTarget: ReportTarget?

    /// Presents the Creator's Pick curation surface (admin-only).
    @State private var showCreatorPicksAdmin = false
    @State private var showClassifierTuning = false
    /// Presents the FriendFind contact-scan surface.
    @State private var showFriendFind = false

    /// Memoized derived state. Recomputed via the .task(id:) at the bottom
    /// of body, not on every body re-render.
    /// `memoizedVisitedPlaces` drives the new "Your Story So Far" strip:
    /// one card per distinct place the user has tagged in their own image
    /// posts, most-recent visit first. Built from `socialService.feedPosts`
    /// (which already includes the user's own posts).
    @State private var memoizedVisitedPlaces: [VisitedPlaceItem] = []
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

    // Build the "Your Story So Far" cards from the user's own image posts.
    // One card per distinct place the user has tagged; most-recent visit
    // wins when the same place was tagged multiple times so a fresh photo
    // surfaces on top. Memoized via `.task(id: …)` on body so the group +
    // dedup work doesn't run on every parent re-render.
    private func computeVisitedPlaces() -> [VisitedPlaceItem] {
        guard let myUid = user?.uid else { return [] }
        // Dedup by placeId, keeping the most recent post per place.
        var byPlace: [String: FriendPost] = [:]
        for post in socialService.feedPosts {
            guard post.authorId == myUid,
                  post.mediaType == "image",
                  !post.mediaURL.isEmpty,
                  let placeId = post.placeId, !placeId.isEmpty
            else { continue }
            if let existing = byPlace[placeId], existing.createdAt > post.createdAt {
                continue
            }
            byPlace[placeId] = post
        }
        return byPlace.values
            .map { VisitedPlaceItem(
                id: $0.placeId ?? $0.id,
                placeName: $0.placeName ?? "Unnamed place",
                mediaURL: $0.mediaURL,
                visitedAt: $0.createdAt
            )}
            .sorted { $0.visitedAt > $1.visitedAt }
    }

    // Routes through the fileprivate `achievementIsUnlocked` so this and
    // the extracted `AchievementsSection` can never drift apart on what
    // counts as "unlocked".
    private func isUnlocked(_ achievement: Achievement) -> Bool {
        achievementIsUnlocked(
            achievement,
            stats: statsService.stats,
            accountCreatedAt: user?.metadata.creationDate
        )
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
                    if !socialService.incomingRequests.isEmpty {
                        friendRequestsSection
                    }
                    if !socialService.outgoingRequests.isEmpty {
                        sentRequestsSection
                    }
                    friendsSection
                    // YOUR MAP — rolls up the old statsRow + storySection into a
                    // tappable map that opens MyHunt.
                    HuntingMapSection(
                        myUid: authService.user?.uid ?? "",
                        friendPlacesService: friendPlacesService,
                        onTap: {
                            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                                showMyHunt = true
                            }
                        }
                    )
                    achievementsSection
                    settingsSection
                }
                .padding(.bottom, ArcNavBar.frameContentHeight + 24)
            }
            // Drag-to-dismiss replaces the previous `.keyboardDismissToolbar()`
            // accessory bar. That toolbar was leaking into ChatView's keyboard
            // (ChatView is presented as an overlay of this view, so it
            // inherits any `.toolbar(placement: .keyboard)` modifier) and
            // crowding out the iOS predictive-emoji bar. Drag-to-dismiss
            // covers the same intent without sitting on top of every
            // TextField keyboard the user opens anywhere in the profile.
            .scrollDismissesKeyboard(.interactively)
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
        .floatingPanel(isPresented: $showFriendList) {
            FriendListView(
                socialService: socialService,
                loader: friendLoader,
                onMessage: { row in
                    // Close the panel first so the fullScreenCover lands
                    // on the underlying ProfileHomeView, not on top of
                    // the floating panel (which then jumps to dismiss).
                    showFriendList = false
                    onMessageFriend(row)
                },
                onClose: { showFriendList = false }
            )
        }
        // Long-press friend-avatar moderation flows. Mirror the pattern
        // FriendListView already uses internally — alert for destructive
        // confirms, sheet for the Report flow.
        .alert(
            "Unfriend \(pendingUnfriend?.titleText ?? "")?",
            isPresented: Binding(
                get: { pendingUnfriend != nil },
                set: { if !$0 { pendingUnfriend = nil } }
            ),
            presenting: pendingUnfriend
        ) { row in
            Button("Cancel", role: .cancel) { pendingUnfriend = nil }
            Button("Unfriend", role: .destructive) {
                Task {
                    pendingUnfriend = nil
                    try? await socialService.removeFriend(uid: row.id)
                }
            }
        } message: { _ in
            Text("They'll no longer see your posts and you won't see theirs.")
        }
        .alert(
            "Block \(pendingBlock?.titleText ?? "")?",
            isPresented: Binding(
                get: { pendingBlock != nil },
                set: { if !$0 { pendingBlock = nil } }
            ),
            presenting: pendingBlock
        ) { row in
            Button("Cancel", role: .cancel) { pendingBlock = nil }
            Button("Block", role: .destructive) {
                Task {
                    pendingBlock = nil
                    try? await socialService.blockUser(uid: row.id)
                }
            }
        } message: { _ in
            Text("They'll be removed from your friends, can't message you, and won't appear in your feed.")
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(
                targetType: target.type,
                targetId: target.targetId,
                socialService: socialService
            )
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showCreatorPicksAdmin) {
            CreatorPicksAdminView(onClose: { showCreatorPicksAdmin = false })
        }
        .fullScreenCover(isPresented: $showClassifierTuning) {
            AdminClassifierTuningView(onClose: { showClassifierTuning = false })
        }
        .fullScreenCover(isPresented: $showFriendFind) {
            FriendFindView(
                socialService:      socialService,
                userPrivateService: userPrivateService,
                onClose:            { showFriendFind = false }
            )
        }
        // Pre-hydrate friend profiles while the user is still on the
        // profile page, so opening the Friends panel feels instant
        // instead of "tap → spinner → list".
        .task(id: socialService.friendIds) {
            await friendLoader.sync(with: socialService.friendIds)
        }
        // Recompute milestone + achievement-unlock derived state only when
        // the underlying achievement dictionary changes — not on every
        // parent re-render. With the @Observable migration, only views
        // that read `stats.unlockedAchievements` invalidate on change, but
        // memoizing here still avoids redundant sorting + filtering on
        // unrelated body re-evaluations.
        // body invalidates often (Firestore listener fires); without this
        // memoization we'd re-sort milestones and re-filter unlock count
        // on every chat message or feed snapshot.
        .task(id: statsService.stats.unlockedAchievements) {
            memoizedUnlockedCount = computeUnlockedCount()
        }
        // Story-strip cards depend on the user's own posts. Recompute when
        // the feed changes (which fires when a new post lands or when the
        // listener re-emits after sign-in).
        .task(id: socialService.feedPosts.count) {
            memoizedVisitedPlaces = computeVisitedPlaces()
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
            CachedAsyncImage(url: url) { phase in
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
    //
    // Implementation lives in `StatsRow` further down the file. Wrapping in
    // `.equatable()` lets SwiftUI skip body re-evaluation when the three
    // ints are unchanged from the previous render — which is almost always
    // true even when surrounding state (friend strip, requests, story)
    // updates several times a second from Firestore listeners.

    private var statsRow: some View {
        StatsRow(
            cafes: statsService.stats.cafesVisited,
            stalls: statsService.stats.stallsVisited,
            days: daysActive
        )
        .equatable()
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

    // MARK: - Sent requests (outgoing, cancellable)

    private var sentRequestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("SENT REQUESTS",
                          trailing: "\(socialService.outgoingRequests.count) pending")

            ForEach(socialService.outgoingRequests) { req in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(req.toUsername.map { "@\($0)" } ?? "Pending request")
                            .font(.subheadline).bold()
                            .foregroundStyle(AppTheme.cream)
                        Text("Awaiting their reply")
                            .font(.caption2)
                            .contrastAware(AppTheme.cream, opacity: 0.45)
                    }
                    Spacer()
                    let busy = processingRequestId == req.id

                    Button {
                        Task { await cancelSentRequest(req) }
                    } label: {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AppTheme.errorRed.opacity(0.7))
                                .frame(minWidth: 44)
                        } else {
                            Text("Cancel")
                        }
                    }
                    .font(.caption).bold()
                    .foregroundStyle(AppTheme.errorRed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppTheme.errorRed.opacity(0.12))
                    .clipShape(.rect(cornerRadius: 10))
                    .disabled(processingRequestId != nil)
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
            // Belt-and-suspenders: never render a row for someone in our
            // blocked list. The blockUser cascade should keep them out of
            // friendIds, but if the friends listener ever drifts (Firestore
            // listener silent failure) a blocked user could ghost back in.
            let visibleRows = friendLoader.rows.filter {
                !socialService.blockedUserIds.contains($0.id)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(visibleRows.indices, id: \.self) { index in
                        let row = visibleRows[index]
                        FriendAvatarChip(row: row)
                        // Long-press a friend's avatar for moderation
                        // affordances. The tap target used to open a chat
                        // thread; with chat removed, the avatar is no
                        // longer interactive on tap — only via long-press.
                        .contextMenu {
                            Button {
                                reportTarget = ReportTarget(type: .user, targetId: row.id)
                            } label: {
                                Label("Report \(row.titleText)", systemImage: "exclamationmark.triangle")
                            }
                            Button {
                                pendingBlock = row
                            } label: {
                                Label("Block", systemImage: "hand.raised")
                            }
                            Button(role: .destructive) {
                                pendingUnfriend = row
                            } label: {
                                Label("Unfriend", systemImage: "person.badge.minus")
                            }
                        }
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
                ForEach(friendSearch.suggestions) { hit in
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

                    if hit.id != friendSearch.suggestions.last?.id {
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
    //
    // Implementation lives in `StorySection` further down the file. Only
    // depends on the memoized milestone array — body skips diffing when
    // it's unchanged.

    private var storySection: some View {
        StorySection(places: memoizedVisitedPlaces)
    }

    // MARK: - Achievements
    //
    // Implementation lives in `AchievementsSection` further down the file.
    // Receives the unlocked-date map directly so SwiftUI can diff it as a
    // single value rather than re-reading every achievement off the stats
    // service on each parent re-render.

    private var achievementsSection: some View {
        AchievementsSection(
            stats: statsService.stats,
            accountCreatedAt: user?.metadata.creationDate,
            unlockedCount: memoizedUnlockedCount,
            onTap: { selectedAchievement = $0 }
        )
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showFriendFind = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accentAction)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Find friends from contacts")
                            .font(.subheadline).bold()
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("See who's already on the app")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.textPrimary.opacity(0.04))
                .clipShape(.rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Find friends from contacts")

            if authService.isAdmin {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showCreatorPicksAdmin = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cafeAccent)
                        Text("Manage Creator's Pick")
                            .font(.caption).bold()
                            .foregroundStyle(AppTheme.cafeAccent)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cafeAccent.opacity(0.6))
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
                .buttonStyle(.plain)
                .accessibilityLabel("Manage Creator's Pick")

                // Admin-only: inspect on-device classifier scores for
                // recent placed-tagged posts. Lets the admin slide a
                // hypothetical aesthetic floor and see how each photo
                // would be classified — used to pick a real threshold.
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showClassifierTuning = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cafeAccent)
                        Text("Classifier Tuning")
                            .font(.caption).bold()
                            .foregroundStyle(AppTheme.cafeAccent)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cafeAccent.opacity(0.6))
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
                .buttonStyle(.plain)
                .accessibilityLabel("Open classifier tuning")

                // Admin-only: re-open the "What's New" tour. Bypasses the
                // once-per-release AppStorage gate so we can preview copy/
                // animations on the spot.
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onPreviewWhatsNew()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cafeAccent)
                        Text("Preview What's New")
                            .font(.caption).bold()
                            .foregroundStyle(AppTheme.cafeAccent)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cafeAccent.opacity(0.6))
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
                .buttonStyle(.plain)
                .accessibilityLabel("Preview What's New tutorial")
            }

            // (Manual "Recompute achievements" button was removed — the
            // user-doc listener + `persistNewlyUnlocked` chain in
            // UserStatsService.subscribe now lays down unlock timestamps
            // automatically the moment a stat-bumping trigger fires
            // server-side. The backfillMyStats Cloud Function is kept on
            // the server for support emergencies but no longer surfaced
            // in the UI.)

            // Display preference: polaroid frames vs. plain feed cards.
            // Local-only (@AppStorage); read by HeroPageView's feed +
            // capture-review under the same "feed.usePolaroidFrame" key.
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.accentAction)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Polaroid frames")
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Frame feed photos like printed prints")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $usePolaroidFrame)
                    .labelsHidden()
                    .tint(AppTheme.accentAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppTheme.textPrimary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Polaroid frames")
            .accessibilityValue(usePolaroidFrame ? "On" : "Off")

            // Friend-of-friend Discover opt-out. The Cloud Function checks
            // `users/{uid}.optedOutOfDiscovery` before letting this user's
            // visits surface in others' circle pins. UI reads as opt-IN
            // ("Help") while the stored field stays opt-OUT (default-falsey
            // → an absent field is treated as opted in).
            helpsCircleDiscoverRow

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

    /// Inverse of the stored `optedOutOfDiscovery` field: the toggle reads
    /// "Help your circle discover" (on = contributing). The write goes
    /// through `SocialService.setOptedOutOfDiscovery(_:)`; the Firestore
    /// listener feeds the latest value back via `socialService.profile`.
    private var helpsCircleDiscoverRow: some View {
        let helping = !(socialService.profile?.optedOutOfDiscovery ?? false)
        return HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(AppTheme.cafeAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Help your circle discover")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Your visits may appear (blurred) to friends-of-friends.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { helping },
                set: { newValue in
                    Task { try? await socialService.setOptedOutOfDiscovery(!newValue) }
                }
            ))
            .labelsHidden()
            .tint(AppTheme.accentAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.textPrimary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Help your circle discover")
        .accessibilityValue(helping ? "On" : "Off")
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

    /// Shim so existing call sites in this struct's body continue to work
    /// after `sectionHeader` was promoted into a fileprivate `SectionHeader`
    /// View (so the extracted private subviews below can share it).
    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        SectionHeader(title: title, trailing: trailing)
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

    private func cancelSentRequest(_ req: FriendRequestModel) async {
        guard processingRequestId == nil else { return }
        processingRequestId = req.id
        defer { processingRequestId = nil }
        do {
            try await socialService.cancelRequest(req)
        } catch {
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

// MARK: - Section header (shared)

/// Small reusable header for the labelled sections in this profile. Promoted
/// to a fileprivate View so the extracted private subviews below
/// (StatsRow, StorySection, AchievementsSection) can share it without
/// reaching into ProfileHomeView's private methods.
fileprivate struct SectionHeader: View {
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
fileprivate struct StatsRow: View, Equatable {
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

// MARK: - StorySection (extracted)

/// Horizontal "Your Story So Far" strip showing one card per distinct
/// place the user has personally tagged. Sole dependency is the
/// `[VisitedPlaceItem]` array — when unchanged, SwiftUI skips
/// re-evaluation. Photo source is the user's own post photo for that
/// place, so the section feels like a personal hunting log.
fileprivate struct StorySection: View {
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
fileprivate struct AchievementsSection: View {
    let stats: UserStats
    let accountCreatedAt: Date?
    let unlockedCount: Int
    let onTap: (Achievement) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "ACHIEVEMENTS",
                trailing: "\(unlockedCount) / \(Achievement.definitions.count)"
            )

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 16
            ) {
                ForEach(Achievement.definitions) { achievement in
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
        }
        .padding(16)
        .padding(.top, 12)
    }
}

/// Single source of truth for "is this achievement unlocked?". Shared by
/// `ProfileHomeView.isUnlocked` and `AchievementsSection` so the two
/// can't drift apart again the way they did during the perf-pass
/// extraction.
fileprivate func achievementIsUnlocked(
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
