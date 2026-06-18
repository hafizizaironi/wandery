@preconcurrency import FirebaseAuth
import AVFoundation
import Photos
import SwiftUI
import PhotosUI
import UIKit

// MARK: - Hero card identity

// The shutter UI, its gesture state machine, haptics and `ShutterDirection`
// live in `ShutterControl.swift`.

/// Vertical pager targets: camera first, then timeline posts (or one empty placeholder).
private enum HeroCardID: Hashable {
    case camera
    case emptyFeed
    case post(String)
}


// MARK: - Hero page

struct HeroPageView: View {
    var isActive: Bool = false
    var socialService: SocialService
    /// Live inbox snapshot — used to derive the Messages button's unread
    /// dot. Owned by ContentView, passed via MainShellView.
    var conversationService: ConversationService
    /// Spotify connection — lets the poster attach a song to a post.
    var spotifyAuth: SpotifyAuthService
    /// Feed-scoped player — plays the active post's song + previews picker rows.
    var postMusicPlayer: PostMusicPlayer
    /// Two-way binding owned by MainShellView. Set by chat's post-reference
    /// bubble when the user taps it; this view consumes the value by
    /// scrolling to the matching post, then resets the binding to nil so
    /// the same id can fire again later.
    @Binding var pendingPostJumpId: String?
    /// Set by MainShellView when arriving at a post via a notification tap;
    /// this view gives that post a brief highlight, then clears the binding.
    @Binding var highlightedPostId: String?
    /// True while MainShellView is interpreting a drag as an edge-swipe
    /// page-switch. We disable the vertical pager during this window
    /// so the two gestures don't compete and stutter the animation.
    var edgeDragActive: Bool = false
    /// Fired when a feed post's place pill is tapped — parent (MainShellView)
    /// switches to the map page and centers on the tagged place.
    var onJumpToPlace: (String) -> Void = { _ in }
    /// Fired when the user taps the top-trailing Messages button.
    /// MainShellView presents the chat fullScreenCover.
    var onOpenMessages: () -> Void = { }
    /// Fired from the empty-feed "Find friends" button — MainShellView opens
    /// the friend-find sheet.
    var onFindFriends: () -> Void = { }
    /// True when a full-screen surface (chat, friend-find, etc.) is covering
    /// Hero. The cover keeps Hero mounted with `scenePhase == .active`, so we
    /// need this to sleep the camera while the user is in messages and deeper.
    var isObscured: Bool = false
    /// Last feed post id the user has seen at the top. Drives the "New
    /// moments" pill; seeded on first feed load so a fresh launch is quiet.
    @AppStorage("feed.lastSeenPostId") private var lastSeenPostId: String = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = CameraService()

    /// Captured at View init so context-menu predicates ("is this my own
    /// post?") don't hit the Firebase Auth bridge on every body re-render.
    /// Bridge cost is small individually but compounds during scroll with
    /// many post cells in the LazyVStack.
    private let myUid: String = Auth.auth().currentUser?.uid ?? ""

    @State private var previewCaption = ""
    @FocusState private var captionFocused: Bool
    @State private var isPosting = false
    @State private var postError = ""

    // MARK: - Post launch choreography
    /// Whole publish transition in flight (suppresses re-tap, drives the flight
    /// overlay + chrome dissolve).
    @State private var isLaunchingPost = false
    /// Fades the review chrome (audience strip, filmstrip, Retake/Post/Save)
    /// out during launch, then back in once the camera has returned.
    @State private var chromeDissolved = false
    /// First draft's image, rendered as the card that flies up toward the
    /// Dynamic Island (or off the top on non-DI phones).
    @State private var flightImage: UIImage?
    /// True while the card is in flight (hides the static review square so the
    /// moving droplet copy isn't doubled).
    @State private var flightActive = false
    /// Incremented to launch the droplet keyframe animation.
    @State private var flightTrigger = 0
    /// Brief "warming the camera" cue while the + (add another) transition
    /// waits for the session to be ready before swapping to the live camera.
    @State private var addMorePreparing = false

    /// Mirror of the system keyboard's visible height. Driven by
    /// `keyboardWillShow / keyboardWillHide` notifications because the
    /// parent chain (MainShellView's GeometryReader) applies
    /// `.ignoresSafeArea()` with no edge filter, which disables
    /// SwiftUI's automatic keyboard avoidance for descendant overlays.
    /// The inline reply composer reads this to lift above the keyboard.
    @State private var keyboardHeight: CGFloat = 0

    private let maxCaptionLength = 25

    // Shutter gesture state now lives inside the camera control stack.

    /// Capture mode (Polaroid = photo · Video = record). Drives the new shutter.
    @State private var cameraMode: HeroCameraMode = .polaroid
    /// Most-recent Photos thumbnails for the library button (front-most first;
    /// rendered as a small stack). Empty = placeholder.
    @State private var libraryImages: [UIImage] = []

    /// Post-preview: three discrete tap buttons (Retake · Post · Save). Drag removed —
    /// these counters drive the per-tap icon animations.
    @State private var retakeSpinCount = 0
    @State private var savePressTick = 0
    @State private var saveJustSucceeded = false

    @State private var heroCardID: HeroCardID? = .camera
    /// The card whose video is allowed to be *live*. It lags `heroCardID`,
    /// committing only when the slide settles — so the video window (which
    /// player is built / playing) never shifts mid-slide. That shift used to
    /// fire AVPlayer + SwiftUI work on the main thread exactly at the page
    /// midpoint, stalling the slide ("snaps halfway"). Decoupling it from the
    /// live drag keeps the swipe smooth; the new card spins up on settle.
    @State private var activeCardID: HeroCardID? = .camera

    // Custom vertical pager state (replaces the system ScrollView so the slide
    // curve is ours to tune). `currentIndex` drives the layout offset;
    // `heroCardID`/`activeCardID` stay the source of truth for *identity* and
    // are written on settle. The live `dragOffset` lives in `HeroCardPager` so
    // finger-tracking doesn't re-render this (large) body every frame.
    @State private var currentIndex: Int = 0

    /// Posts within ±this of the current one mount the full `FeedPostPage`; the
    /// rest are pure `Color.clear` spacers (see `heroPageStack`). Wide enough that
    /// the entering card is ~5 pages off-screen — so its mount never hitches the
    /// visible settle — and the placeholder is never seen. Caps on-screen cost at
    /// ~`2*radius+1` cards regardless of how long the feed gets. Also gates the
    /// "cut vs. animate" choice in `paginate`.
    private let feedMountRadius = 4

    // Mode state
    @State private var showPhotosPicker = false
    @State private var librarySelection: [PhotosPickerItem] = []

    // Multi-media draft tray (≤6 mixed photos + one video). Camera captures and
    // library imports accumulate here; the review screen edits the current item.
    @State private var drafts: [MediaDraft] = []
    @State private var currentDraftIndex = 0
    /// True while re-opening the live camera to add another item to a non-empty
    /// tray (so review doesn't cover the viewfinder).
    @State private var isCapturingMore = false
    private let maxDrafts = 6

    /// Live-hydrated friend rows (avatar + name) for the audience-selector strip
    /// on the review screen. Reuses the FriendListView loader.
    @State private var audienceLoader = FriendListLoader()
    /// Friends the author DESELECTED for the current draft. Empty (default) =
    /// everyone selected → an unrestricted "everyone" post.
    @State private var excludedFriendUids: Set<String> = []

    // Place tagging
    @State private var pendingPlace: PlaceSelection?
    @State private var showPlacePicker = false

    // Background music (one song per post). Locket-style: while the review screen
    // is open the app polls the user's currently-playing Spotify track and shows
    // its cover; whatever is `.attached` at post time rides into the upload.
    enum ComposerMusicState: Equatable {
        case notConnected                       // not connected yet (tap to connect)
        case nothingPlaying                     // connected, no song (204 / ad / podcast)
        case resolving                          // a new track is resolving to a preview
        case attached(PostMusic)                // colour cover — WILL attach
        case optedOut(PostMusic)                // grey cover — user opted out
        case unresolvable                       // playing, but no preview found anywhere
        case permissionDenied(reconnect: Bool)  // 401 (reconnect) / 403 (dev-mode)
    }
    @State private var musicState: ComposerMusicState = .notConnected
    /// Spotify id of the last polled track, so the poll doesn't re-resolve the
    /// same song and an opt-out stays sticky until the track actually changes.
    @State private var lastSeenTrackId: String?
    /// Drives the neon music button's breathing glow (shadow opacity).
    @State private var musicGlow: Double = 0.4
    /// Shows the neon "play a song" hint popout by the music button (auto-dismiss).
    @State private var showMusicHint = false
    /// Global feed-audio toggle (shared with FeedPolaroidCard's speaker button).
    /// Gates whether the active post's song is audible — default muted, so the
    /// feed never interrupts the user's own audio until they tap unmute.
    @AppStorage("feed.videoMuted") private var feedVideoMuted = true
    /// Read so the vinyl disc's peek clears each feed style's bottom bleed.
    @AppStorage(FeedCardStyle.storageKey) private var feedCardStyle: FeedCardStyle = .plain
    /// Nearest place (top of the picker's nearby list), offered as a one-tap
    /// suggestion next to "Tag a place". Fetched once per compose session.
    @State private var suggestedPlace: PlaceCandidate?

    // Moderation state. Long-press on a feed post surfaces report/block.
    @State private var reportTarget: ReportTarget?
    @State private var pendingBlockUid: String?
    @State private var pendingBlockTitle: String = ""
    /// Long-press focus menu on a feed post (blurred backdrop + lifted post +
    /// action card). Nil = not focused.
    @State private var postFocus: PostFocus? = nil
    /// Post pending a delete confirmation (own posts only).
    @State private var pendingDeletePost: FriendPost? = nil

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                GeometryReader { geo in
                    let pageH = HeroCameraLayout.pageHeight(in: geo)
                    // Custom vertical pager: `HeroCardPager` owns the live drag
                    // offset + gesture (so finger-tracking re-renders only the
                    // thin wrapper, not this whole body), and our own spring owns
                    // the settle curve. The page stack stays non-lazy so the
                    // camera preview + ±1 video players keep their mount lifecycle.
                    HeroCardPager(
                        pageCount: pages.count,
                        pageHeight: pageH,
                        width: geo.size.width,
                        index: $currentIndex,
                        disabled: isPagerDisabled,
                        settle: pagerSettle,
                        onDragStart: { if keyboardHeight > 0 { Self.dismissKeyboard() } },
                        onSettle: { commitSettle(to: $0) }
                    ) {
                        heroPageStack(geometry: geo, pageH: pageH)
                    }
                    // VoiceOver can't drag a custom pager — give it explicit
                    // next/previous page actions.
                    .accessibilityScrollAction { edge in
                        switch edge {
                        case .top, .leading:    paginate(to: pageID(at: currentIndex - 1))
                        case .bottom, .trailing: paginate(to: pageID(at: currentIndex + 1))
                        @unknown default: break
                        }
                    }
                    // Composer lifts itself via a manual `.offset(y:)` driven by
                    // the keyboard observer, so keep the page geometry fixed when
                    // the keyboard appears (otherwise the whole stack would shift).
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                permissionDeniedUI
            }

        }
        // Keyboard observer — composer reads `keyboardHeight` from
        // this view via a parameter and applies it as a vertical
        // offset inside each post page. Observer stays at the
        // HeroPageView level so every post page shares one source
        // of truth (only one composer is focused at a time anyway).
        .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification
        )) { note in
            // `keyboardFrameEnd` is the keyboard's final rect in screen
            // coords; its height is from the bottom of the screen up to
            // the top of the keyboard, including the home-indicator
            // area. Setting padding ≥ this height places the composer
            // 12pt above the keyboard's top edge.
            if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { _ in
            keyboardHeight = 0
        }
        .overlay(alignment: .topTrailing) {
            // Hide during capture review — the capture-preview chrome
            // (caption pill, place pill, post/retake/save control) sits
            // in the same screen region and the messages button would
            // both distract and compete for taps.
            //
            // Parent chain (MainShellView -> GeometryReader.ignoresSafeArea)
            // makes the body's ZStack frame the full screen and *consumes*
            // the safe area, so a child GeometryReader's
            // `proxy.safeAreaInsets.top` reports 0 here. Read the actual
            // inset from the key window — reliable across notch / Dynamic
            // Island / no-notch phones.
            if !isReviewingCapture {
                messagesTopButton
                    .padding(.top, Self.topSafeAreaInset + 8)
                    .padding(.trailing, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        // "New moments" pill — appears when friends have posted since the
        // user last viewed the top of the feed, and they're not already there.
        .overlay(alignment: .top) {
            if isActive, !isReviewingCapture, hasNewMoments {
                newMomentsPill
                    .padding(.top, Self.topSafeAreaInset + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: hasNewMoments)
        // Non-DI phones have no Dynamic Island to fly into, so surface upload
        // progress as a small top pill (DI phones use the Live Activity).
        .overlay(alignment: .top) {
            if isActive, !hasDynamicIsland, socialService.isUploadingPost {
                postingPill
                    .padding(.top, Self.topSafeAreaInset + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: socialService.isUploadingPost)
        // Clear a notification-tap highlight after it has played briefly.
        .onChange(of: highlightedPostId) { _, id in
            guard id != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                highlightedPostId = nil
            }
        }
        .animation(Motion.strongEaseOut(duration: 0.4), value: isReviewingCapture)
        .photosPicker(isPresented: $showPhotosPicker,
                      selection: $librarySelection,
                      maxSelectionCount: max(1, maxDrafts - drafts.count),
                      matching: .images)
        .onChange(of: librarySelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await importLibrarySelection(items) }
        }
        .onChange(of: camera.capturedImage) { _, img in
            guard let img else { return }
            appendDraft(.image(img))
            camera.discardCapture()
        }
        .onChange(of: camera.capturedVideoURL) { _, url in
            guard let url else { return }
            // discardCapture() deletes the file at capturedVideoURL, so move it
            // to a draft-owned temp URL first — otherwise the draft points at a
            // deleted file and the video preview is blank. Preserve the `_sq`
            // marker so upload doesn't needlessly re-export an already-square clip.
            let suffix = url.lastPathComponent.contains("_sq") ? "_sq" : ""
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("draft-\(UUID().uuidString)\(suffix).\(ext)")
            let draftURL = (try? FileManager.default.moveItem(at: url, to: dest)) != nil ? dest : url
            appendDraft(.video(draftURL))
            camera.discardCapture()
        }
        .task {
            await camera.requestAccess()
            loadLatestLibraryThumbnail()
        }
        // Single source of truth for the capture session: run it only when the
        // camera card is the visible, foreground content on Hero. This sleeps
        // the camera when the user leaves Hero, backgrounds the app, browses
        // the feed, or reviews a capture — cutting the heat/battery drain (and
        // the thermal throttling that made paging janky) the always-on session
        // caused. The stop is debounced so a quick scroll-through or a
        // swipe-and-back doesn't thrash start/stop.
        .task(id: cameraShouldRun) {
            if cameraShouldRun {
                camera.startSession()
            } else {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                camera.stopSession()
            }
        }
        // Toggle the live aesthetic-score tap with the same lifecycle as the
        // session, but additionally gated to photo mode. Disabling clears the
        // published score so the ring fades out when leaving the viewfinder.
        .task(id: liveScoringShouldRun) {
            camera.setLiveAestheticScoring(enabled: liveScoringShouldRun)
        }
        // Fetch the nearest place once per compose session so we can offer it as
        // a one-tap suggestion next to "Tag a place". `nearby` returns the list
        // sorted nearest-first, so `.first` is the same top row the picker shows.
        // No-ops gracefully when location is denied or nothing is nearby.
        .task(id: isReviewingCapture) {
            guard isReviewingCapture, suggestedPlace == nil else { return }
            guard let coord = await LocationProvider.shared.currentCoordinate() else { return }
            let results = try? await PlacePickerService.shared.nearby(coord)
            guard let top = results?.first else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                suggestedPlace = top
            }
        }
        // Locket-style auto song: while reviewing a capture, poll the user's
        // currently-playing Spotify track and show its cover. Keyed on
        // (reviewing, connected) so connecting mid-review starts the loop;
        // auto-cancels when the review screen closes.
        .task(id: "\(isReviewingCapture)-\(spotifyAuth.isConnected)") {
            guard isReviewingCapture, spotifyAuth.isConfigured else { return }
            guard spotifyAuth.isConnected else { musicState = .notConnected; return }
            while !Task.isCancelled {
                await refreshCurrentlyPlaying()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // Returning from the Spotify app (scene → active) refreshes the song
        // immediately, so a track started while away shows up without retaking.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, isReviewingCapture, spotifyAuth.isConnected {
                Task { await refreshCurrentlyPlaying() }
            }
        }
        .onChange(of: heroCardID) { _, _ in
            // Paging away from the current post (to camera, empty
            // feed, or a different post) dismisses any active keyboard
            // so the composer doesn't follow the user into a context
            // where it shouldn't be focused.
            Self.dismissKeyboard()
            // Leaving the page exits "add another" mode, so returning to the
            // camera shows the review tray again rather than a stale capture state.
            isCapturingMore = false
            // Warm the disk cache for the post we're on + the next couple, so
            // the upcoming video is local (instant) by the time it's swiped to.
            prefetchFeedVideos()
            // Reaching the newest post marks the feed "seen" so the New
            // moments pill clears and won't re-show for that post.
            if case .post(let id)? = heroCardID, id == socialService.feedPosts.first?.id {
                lastSeenPostId = id
            }
        }
        .onChange(of: cameraMode) { _, mode in
            // Entering Video mode warms the recording path so the first tap
            // starts instantly; leaving discards the unused warm-up.
            if mode == .video { camera.prepareForRecording() }
            else { camera.discardRecordingPreparation() }
        }
        // Watch `.count` instead of `.map(\.id)` so SwiftUI doesn't have to
        // allocate + compare a new id-array on every parent re-render. The
        // realistic invalidation cases here — post deleted, post created,
        // initial feed load — all change the count. A simultaneous
        // delete-and-create in one Firestore snapshot wouldn't trigger
        // this, but the user can scroll/refresh to recover.
        // Moderation block/report alert + sheet extracted to a modifier so
        // the body's modifier chain stays under the SwiftUI type-checker's
        // ceiling. See FeedModerationModifier below.
        .modifier(FeedModerationModifier(
            reportTarget: $reportTarget,
            pendingBlockUid: $pendingBlockUid,
            pendingBlockTitle: $pendingBlockTitle,
            postFocus: $postFocus,
            pendingDeletePost: $pendingDeletePost,
            socialService: socialService
        ))
        .onChange(of: socialService.feedPosts.count) { _, _ in
            // Feed (re)loaded — prefetch the first videos so the top of the
            // feed is ready before the user scrolls into it.
            prefetchFeedVideos()
            // Seed the "seen" marker on first load so a fresh launch doesn't
            // flash a New moments pill against an empty baseline.
            if lastSeenPostId.isEmpty, let firstId = socialService.feedPosts.first?.id {
                lastSeenPostId = firstId
            }
            // Resync the layout index from the stable card identity first, so
            // the offset never points at a stale slot after the feed mutates
            // (e.g. a new moment prepended shifts every post's index).
            if let id = heroCardID, let idx = pages.firstIndex(of: id) {
                currentIndex = idx
            } else {
                currentIndex = min(currentIndex, max(0, pages.count - 1))
            }
            guard let current = heroCardID else { return }
            switch current {
            case .post(let id) where !socialService.feedPosts.contains(where: { $0.id == id }):
                paginate(to: .camera)
            case .emptyFeed where !socialService.feedPosts.isEmpty:
                paginate(to: .post(socialService.feedPosts[0].id))
            default:
                break
            }
        }
        .onChange(of: pendingPostJumpId) { _, newId in
            guard let postId = newId else { return }
            // Confirm the post is still in the feed (it may have been
            // deleted between the time the chat reference was written
            // and this jump). If missing, fall back to the camera.
            let exists = socialService.feedPosts.contains(where: { $0.id == postId })
            paginate(to: exists ? .post(postId) : .camera)
            // Clear the binding so the same id can fire again later.
            pendingPostJumpId = nil
        }
        .task {
            // Initial warm-up in case the feed was already loaded before this
            // view appeared (listener delivered posts while on another tab).
            prefetchFeedVideos()
            // Seed the "seen" marker if the feed arrived before appear (the
            // count-change handler wouldn't have fired in that case).
            if lastSeenPostId.isEmpty, let firstId = socialService.feedPosts.first?.id {
                lastSeenPostId = firstId
            }
        }
        // ── Background music ── start/stop the active post's song as the user
        // pages the feed, toggles mute, leaves Hero, composes, or backgrounds
        // the app. Extracted into a modifier (like FeedModerationModifier) so
        // the six onChange observers don't blow the body's type-check budget.
        .modifier(HeroBackgroundMusicModifier(
            activeCardID:       activeCardID,
            feedVideoMuted:     feedVideoMuted,
            isActive:           isActive,
            isReviewingCapture: isReviewingCapture,
            isObscured:         isObscured,
            scenePhase:         scenePhase,
            update:             { updateBackgroundMusic() }
        ))
    }

    // MARK: - Background music (feed)

    /// The settled feed post whose song should play, or nil while on the camera
    /// card / empty feed.
    private var activeMusicPost: FriendPost? {
        guard case .post(let id)? = activeCardID else { return nil }
        return socialService.feedPosts.first(where: { $0.id == id })
    }

    /// Drive the shared `PostMusicPlayer` from the feed's live state. Music only
    /// plays while Hero is the foreground tab, not composing/obscured, the scene
    /// is active, and the feed is unmuted.
    private func updateBackgroundMusic() {
        let feedAudible = isActive && !isReviewingCapture && !isObscured
        postMusicPlayer.update(
            activePost: feedAudible ? activeMusicPost : nil,
            muted: feedVideoMuted,
            scenePhaseActive: scenePhase == .active
        )
    }

    // MARK: - New moments pill

    /// True when the user is currently parked on the newest post card.
    private var isViewingNewest: Bool {
        guard let first = socialService.feedPosts.first else { return false }
        return heroCardID == .post(first.id)
    }

    /// True when a newer post has arrived than the one the user last saw at
    /// the top, and they're not already viewing it.
    private var hasNewMoments: Bool {
        guard let first = socialService.feedPosts.first else { return false }
        return first.id != lastSeenPostId && !isViewingNewest
    }

    private var newMomentsPill: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard let first = socialService.feedPosts.first else { return }
            paginate(to: .post(first.id))
            lastSeenPostId = first.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.bold))
                Text("New moments")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .liquidGlassChrome(in: Capsule())
        }
        .buttonStyle(.scalePress)
        .accessibilityLabel("New moments — jump to the latest post")
    }

    /// Top progress pill for non-Dynamic-Island phones while a post uploads
    /// in the background (DI phones get the Live Activity instead).
    private var postingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.white)
                .scaleEffect(0.7)
            Text("Posting… \(Int(socialService.uploadProgress * 100))%")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .liquidGlassChrome(in: Capsule())
        .accessibilityLabel("Posting your moment")
        .accessibilityValue("\(Int(socialService.uploadProgress * 100)) percent")
    }

    // MARK: - Messages top button

    /// Reads the top safe-area inset directly from the key window. We do
    /// this instead of relying on a GeometryReader because the parent
    /// chain (MainShellView's outer GeometryReader applies
    /// `.ignoresSafeArea()`) zeroes the safe area for child GeometryReaders.
    private static var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    private static var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    /// Resign whatever's first responder app-wide. Used to dismiss
    /// the keyboard when the user pages between posts or taps outside
    /// the composer pill. Non-private so the extracted `FeedPostPage`
    /// can reuse it.
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    /// Vertical offset for the composer when the keyboard is up.
    /// The composer is rendered inside each post page (inside the
    /// `.ignoresSafeArea(.keyboard)` ScrollView), so SwiftUI's
    /// automatic keyboard avoidance is disabled — we apply this
    /// negative offset manually to lift the pill above the keyboard.
    ///
    /// At rest the composer's bottom edge sits at `bottomChrome` from
    /// the screen bottom (just above the navbar arc). When the
    /// keyboard is up, we want it clear of the post card's bottom
    /// edge — `keyboardClearance = 32pt` keeps a comfortable gap
    /// between the composer top and the lowest visible part of the
    /// post (the caption pill / place chip overlay). `.offset(y: negative)`
    /// moves up.
    private static let composerKeyboardClearance: CGFloat = 48
    private var composerKeyboardLift: CGFloat {
        guard keyboardHeight > 0 else { return 0 }
        let bottomChrome = HeroCameraLayout.bottomChromeHeight(safeBottom: Self.bottomSafeAreaInset)
        return -max(0, keyboardHeight + Self.composerKeyboardClearance - bottomChrome)
    }

    /// Lifts the capture-review card (photo + caption pill + actions) above the
    /// keyboard while editing the caption. The pager's `.ignoresSafeArea(.keyboard)`
    /// disables auto-avoidance, so — like `composerKeyboardLift` — we offset up
    /// manually. The caption pill sits at the bottom edge of the viewfinder square,
    /// i.e. `bottomChrome + belowCardHeight` above the screen bottom.
    private static let captureReviewKeyboardClearance: CGFloat = 24
    private var captureReviewKeyboardLift: CGFloat {
        guard isReviewingCapture, keyboardHeight > 0 else { return 0 }
        let bottomChrome = HeroCameraLayout.bottomChromeHeight(safeBottom: Self.bottomSafeAreaInset)
        let pillDistanceFromBottom = bottomChrome + HeroCameraLayout.belowCardHeight
        return -max(0, keyboardHeight + Self.captureReviewKeyboardClearance - pillDistanceFromBottom)
    }

    /// Unread-conversation count derived from the conversation docs'
    /// server-side `lastReadAt` map, with the legacy local
    /// `@AppStorage` stamp as a fallback for convs that haven't yet
    /// been read on this account on the new schema.
    ///
    /// Reactivity: this computed property reads `conversationService.inbox`,
    /// which is `@Observable` — so any time the inbox listener
    /// delivers an update (including the `lastReadAt` field change
    /// `markRead` writes), Hero re-renders and the badge updates
    /// across devices.
    private var unreadConversationCount: Int {
        let defaults = UserDefaults.standard
        return conversationService.inbox.reduce(into: 0) { partial, conv in
            guard let last = conv.lastMessageAt else { return }
            // My own latest message never counts as unread.
            guard conv.lastMessageSenderId != myUid else { return }
            let serverStamp = conv.lastReadAt[myUid]?.timeIntervalSince1970 ?? 0
            let localStamp  = defaults.double(forKey: "chat.lastRead.\(conv.id)")
            let effective   = max(serverStamp, localStamp)
            if last.timeIntervalSince1970 > effective { partial += 1 }
        }
    }

    @ViewBuilder
    private var messagesTopButton: some View {
        Button {
            let g = UIImpactFeedbackGenerator(style: .light)
            g.impactOccurred()
            onOpenMessages()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    // Project-wide Liquid Glass chrome.
                    .liquidGlassChrome(in: Circle())

                if unreadConversationCount > 0 {
                    Circle()
                        .fill(AppTheme.accentAction)
                        .frame(width: 10, height: 10)
                        .overlay { Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5) }
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unreadConversationCount > 0
                            ? "Messages, \(unreadConversationCount) unread"
                            : "Messages")
    }

    /// Minimal chrome in the same family as the keyboard **Done** control (accent, no heavy fill).
    private var liquidGlassPill: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.cafeAccent.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                AppTheme.cafeAccent,
                                AppTheme.cafeAccent.opacity(0.55),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.25
                    )
            }
            .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
    }

    private var isReviewingCapture: Bool {
        // Review when the tray has items (or a video is still processing),
        // unless we've stepped back to the live camera to add another item.
        (!drafts.isEmpty || camera.isProcessingVideo) && !isCapturingMore
    }

    /// The camera card is the default/top pager card. `nil` is treated as the
    /// camera (initial state before the user has scrolled).
    private var isOnCameraCard: Bool {
        heroCardID == .camera || heroCardID == nil
    }

    /// The capture session runs the whole time Hero is the foreground tab —
    /// **including while browsing the feed and reviewing a capture**. Keeping it
    /// warm means returning to the live camera is instant (no cold-start stutter
    /// or black-preview pop), and the iOS green camera indicator stays on. The
    /// expensive part — the live-scoring Vision tap — is gated separately
    /// (`liveScoringShouldRun`) to the camera card, so the cost in the feed is
    /// just the sensor. The 800ms-debounced stop still sleeps it on
    /// background / obscure / leaving Hero.
    private var cameraShouldRun: Bool {
        isActive
            && scenePhase == .active
            && camera.isAuthorized
            && !isObscured
    }

    /// Live aesthetic scoring (the Neural-Engine frame tap — the real
    /// thermal/battery cost) only runs on the camera card in photo mode. It
    /// stays off in the feed even though the bare session keeps running.
    private var liveScoringShouldRun: Bool {
        cameraShouldRun && isOnCameraCard && cameraMode == .polaroid
    }

    private func scrollToFeedFromCamera() {
        let posts = socialService.feedPosts
        paginate(to: posts.isEmpty ? .emptyFeed : .post(posts[0].id))
    }

    private func postFromCapture() {
        // Re-entrancy guard: tap-to-post can fire twice, and in the animated
        // path the tray isn't cleared until the flight finishes (~450ms).
        guard !isLaunchingPost, !drafts.isEmpty else { return }
        postError = ""
        // Flush the current working-copy (caption + place) into its draft.
        syncWorkingCopyToCurrentDraft()
        // Audience: everyone unless the user deselected friends in the strip.
        // nil = unrestricted; a subset = restricted to those friends (+ author,
        // added in the service). Block posting to a fully-empty audience.
        let friends = socialService.friendIds
        let selected = friends.filter { !excludedFriendUids.contains($0) }
        if !friends.isEmpty && selected.isEmpty {
            postError = "Pick at least one person to share with."
            return
        }
        let recipients: [String]? = (friends.isEmpty || selected.count == friends.count) ? nil : selected
        // Hand the upload to the service (runs in the background); the
        // choreography returns the user to the camera. Errors surface via the
        // app-wide retry banner.
        socialService.enqueuePost(drafts: drafts, recipientUids: recipients, music: committedMusic)
        launchPostChoreography()
    }

    /// True on Dynamic Island phones (top inset ≈59 vs ≈47–50 notch / 20 classic).
    private var hasDynamicIsland: Bool { Self.topSafeAreaInset >= 55 }

    /// Choreographs the publish transition: a beat, chrome dissolves, the
    /// captured card flies into the Dynamic Island (or up, on non-DI), the
    /// camera warms up and springs back, then the chrome un-dissolves.
    /// Reduced-motion takes a plain cross-fade.
    private func launchPostChoreography() {
        guard !reduceMotion, let first = drafts.first else {
            camera.startSession()
            withAnimation(.easeInOut(duration: 0.28)) { clearDraftTray() }
            camera.discardCapture()
            loadLatestLibraryThumbnail()
            return
        }
        // Fly the captured photo into the Dynamic Island.
        switch first.source {
        case .image(let img):
            beginFlightTransition(flyPhoto: img)
        case .video(let url):
            // Grab a poster frame for the flying card; the brief async gen also
            // serves as the deliberate "beat" before the card launches.
            Task { @MainActor in
                beginFlightTransition(flyPhoto: await Self.videoPosterImage(url))
            }
        }
    }

    /// Transition: dissolve chrome, warm the camera, fly the photo card into
    /// the Dynamic Island (droplet) + splash the ring, then return the live
    /// camera and un-dissolve the chrome.
    private func beginFlightTransition(flyPhoto: UIImage) {
        isLaunchingPost = true
        flightActive = true           // hide the static review square underneath
        flightImage = flyPhoto
        camera.startSession()         // warm up so the returning preview isn't black
        withAnimation(.easeOut(duration: 0.28)) { chromeDissolved = true }

        // Defer the launch one runloop so the keyframe animator has the card at
        // its resting frame for a frame before the droplet dives in.
        DispatchQueue.main.async { flightTrigger += 1 }
        // Splash the ring right as the droplet reaches the island.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(480))
            socialService.signalCardImpact()
        }

        Task { @MainActor in
            // Let the full droplet animation finish (~600ms), then hold a clear
            // 500ms so the camera slide-in plays entirely on its own — nothing
            // else animating, so it reads as perfectly smooth.
            try? await Task.sleep(for: .milliseconds(825))
            // Camera's been warm since the tap, so this returns immediately.
            await awaitCameraReady()
            // Swap to the live camera, entering with a springy slide-up.
            withAnimation(Motion.cozyReveal) { clearDraftTray() }
            camera.discardCapture()
            loadLatestLibraryThumbnail()
            flightImage = nil
            flightActive = false
            // Un-dissolve the chrome once the preview has settled.
            try? await Task.sleep(for: .milliseconds(240))
            withAnimation(.easeOut(duration: 0.32)) { chromeDissolved = false }
            isLaunchingPost = false
        }
    }

    /// Warms the capture session and waits until the first frame is realistically
    /// ready, so the heavy `configureSession`/`startRunning` work finishes BEFORE
    /// the live-preview spring — no cold-start stutter, no black-preview pop.
    /// Returns almost immediately when the session is already warm.
    private func awaitCameraReady() async {
        camera.startSession()
        var ticks = 0
        while !camera.isSessionRunning, ticks < 30 {   // ≤ ~1.5s cap
            try? await Task.sleep(for: .milliseconds(50))
            ticks += 1
        }
        try? await Task.sleep(for: .milliseconds(90))  // let 1–2 frames land
    }

    /// Deliberate review → live-camera transition for the "+" (add another)
    /// button: a gentle pre-swap cue while the camera warms, then a smooth swap
    /// once it's ready (so the cold start never janks the cut).
    private func goToAddMore() {
        guard !isCapturingMore else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.22)) { addMorePreparing = true }
            await awaitCameraReady()
            withAnimation(Motion.strongEaseOut(duration: 0.45)) {
                isCapturingMore = true
                addMorePreparing = false
            }
        }
    }

    /// First-frame poster for a video draft (for the flight card). Falls back to
    /// a plain black card if generation fails.
    private static func videoPosterImage(_ url: URL) async -> UIImage {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        if let result = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
            return UIImage(cgImage: result.image)
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: 240, height: 240)))
        }
    }

    private func retakeFromReview() {
        postError = ""
        clearDraftTray()
        camera.discardCapture()
    }

    // MARK: - Draft tray (multi-media compose)

    /// Adds a captured/imported item to the tray, enforcing the ≤6 cap and the
    /// single-video rule, then focuses it. `previewCaption`/`pendingPlace` are
    /// the *working copy* of the focused draft; we flush before switching.
    private func appendDraft(_ source: MediaDraft.Source) {
        guard drafts.count < maxDrafts else { return }
        if case .video = source, drafts.contains(where: \.isVideo) { return }
        syncWorkingCopyToCurrentDraft()
        drafts.append(MediaDraft(source: source, place: nil, caption: nil))
        currentDraftIndex = drafts.count - 1
        isCapturingMore = false
        loadWorkingCopyFromCurrentDraft()
    }

    private func selectDraft(_ index: Int) {
        guard drafts.indices.contains(index) else { return }
        // Tapping a thumbnail returns to review (out of "add another" camera mode).
        isCapturingMore = false
        guard index != currentDraftIndex else { return }
        syncWorkingCopyToCurrentDraft()
        currentDraftIndex = index
        loadWorkingCopyFromCurrentDraft()
    }

    private func deleteDraft(at index: Int) {
        guard drafts.indices.contains(index) else { return }
        syncWorkingCopyToCurrentDraft()
        drafts.remove(at: index)
        if drafts.isEmpty {
            clearDraftTray()
            camera.discardCapture()
            return
        }
        currentDraftIndex = min(currentDraftIndex, drafts.count - 1)
        loadWorkingCopyFromCurrentDraft()
    }

    /// Mirror the focused draft's caption + place into the editable working copy.
    private func loadWorkingCopyFromCurrentDraft() {
        guard drafts.indices.contains(currentDraftIndex) else {
            previewCaption = ""
            pendingPlace = nil
            return
        }
        previewCaption = drafts[currentDraftIndex].caption ?? ""
        pendingPlace = drafts[currentDraftIndex].place
    }

    /// Persist the working-copy edits back onto the focused draft.
    private func syncWorkingCopyToCurrentDraft() {
        guard drafts.indices.contains(currentDraftIndex) else { return }
        drafts[currentDraftIndex].caption = previewCaption.isEmpty ? nil : previewCaption
        drafts[currentDraftIndex].place = pendingPlace
    }

    private func clearDraftTray() {
        drafts = []
        currentDraftIndex = 0
        isCapturingMore = false
        previewCaption = ""
        pendingPlace = nil
        suggestedPlace = nil
        excludedFriendUids = []
        musicState = .notConnected
        lastSeenTrackId = nil
    }

    /// Copies the focused draft's place onto every draft (the common
    /// "all photos at one café" case).
    private func applyCurrentPlaceToAll() {
        syncWorkingCopyToCurrentDraft()
        let place = drafts.indices.contains(currentDraftIndex) ? drafts[currentDraftIndex].place : nil
        for i in drafts.indices { drafts[i].place = place }
    }

    private func importLibrarySelection(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard drafts.count < maxDrafts else { break }
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                appendDraft(.image(img))
            }
        }
        librarySelection = []
    }

    private func saveCaptureToPhotoLibrary() {
        // Read from the current DRAFT — `camera.capturedImage/URL` are nilled
        // the moment a capture is appended to `drafts` (see the onChange
        // handlers up top), so the review screen has nothing left on `camera`.
        guard drafts.indices.contains(currentDraftIndex) else { return }
        let source = drafts[currentDraftIndex].source
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run { postError = "Allow Photos access in Settings to save to your library." }
                return
            }
            do {
                switch source {
                case .image(let image):
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                case .video(let url):
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }
                }
                await MainActor.run {
                    loadLatestLibraryThumbnail()
                    flashSaveSuccess()
                }
            } catch {
                await MainActor.run { postError = error.localizedDescription }
            }
        }
    }

    /// Show the "Saved" confirmation on the Save button briefly, then revert.
    private func flashSaveSuccess() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            saveJustSucceeded = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.25)) {
                saveJustSucceeded = false
            }
        }
    }

    /// Pull the most-recent Photos images (up to 3) for the library button's
    /// stacked preview. Reads only if access is ALREADY granted — never
    /// triggers a Photos prompt on the camera screen (the picker and
    /// save-to-library flows handle their own auth).
    private func loadLatestLibraryThumbnail() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            fetchRecentLibraryImages()
        default:
            // notDetermined/denied/restricted — placeholder stays; never prompt
            // here. The priming queue (or the picker / save-to-library flows)
            // own the Photos prompt, so it stays out of the camera-screen burst.
            break
        }
    }

    private func fetchRecentLibraryImages() {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 3
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        guard assets.count > 0 else { return }
        let count = min(3, assets.count)
        let req = PHImageRequestOptions()
        req.deliveryMode = .opportunistic
        req.isNetworkAccessAllowed = true
        let manager = PHImageManager.default()
        // Assemble in order as each request resolves (opportunistic may call back twice).
        var resolved: [Int: UIImage] = [:]
        for i in 0..<count {
            manager.requestImage(
                for: assets.object(at: i),
                targetSize: CGSize(width: 132, height: 108),
                contentMode: .aspectFill, options: req
            ) { image, _ in
                guard let image else { return }
                Task { @MainActor in
                    resolved[i] = image
                    self.libraryImages = (0..<count).compactMap { resolved[$0] }
                }
            }
        }
    }

    // MARK: - Camera content

    private func cameraContent(geometry geo: GeometryProxy) -> some View {
        let bottomChrome = HeroCameraLayout.bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
        let side = HeroCameraLayout.viewfinderSide(in: geo)

        return ZStack {
            VStack(spacing: HeroCameraLayout.viewfinderShutterSpacing) {
                viewfinder(side: side)
                shutterArea
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HeroCameraLayout.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, bottomChrome)
            .offset(y: captureReviewKeyboardLift)
            .animation(.easeOut(duration: 0.25), value: keyboardHeight)

            // Launch flight: the captured card flies up into the Dynamic Island
            // (or off the top, non-DI). Sits above the chrome so it travels
            // freely while the viewfinder swaps to live camera underneath.
            if let img = flightImage {
                postFlightCard(image: img, geo: geo, side: side, bottomChrome: bottomChrome)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Per-frame state of the droplet flight (anisotropic scale = stretch/squash).
    private struct DropletPhase {
        var y: CGFloat
        var scale: CGFloat = 1
        var stretch: CGFloat = 1   // >1 = tall droplet, <1 = squashed on impact
        var opacity: CGFloat = 1
    }

    /// The flying capture card, animated like a water droplet diving into the
    /// Dynamic Island: it stretches tall as it rises, squashes on impact, then
    /// is absorbed (fades) — which is when the ring splashes. On non-DI phones
    /// the same motion carries it up and off the top.
    private func postFlightCard(image: UIImage, geo: GeometryProxy,
                                side: CGFloat, bottomChrome: CGFloat) -> some View {
        // Resting centre of the viewfinder square (bottom-anchored VStack).
        let restingY = geo.size.height - bottomChrome - HeroCameraLayout.belowCardHeight - side / 2
        let centerX = geo.size.width / 2
        let di = hasDynamicIsland
        // DI capsule centre ≈ 28pt from the top; non-DI flies off the top.
        let targetY: CGFloat = di ? 28 : -side * 0.6
        let targetScale: CGFloat = di ? max(0.12, 37 / side) : 0.5
        let midY = restingY - (restingY - targetY) * 0.62
        let corner: CGFloat = di ? 22 : HeroCameraLayout.viewfinderCornerRadius

        return Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .keyframeAnimator(initialValue: DropletPhase(y: restingY), trigger: flightTrigger) { view, p in
                view
                    .scaleEffect(x: p.scale / p.stretch, y: p.scale * p.stretch, anchor: .center)
                    .opacity(p.opacity)
                    .position(x: centerX, y: p.y)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    CubicKeyframe(midY, duration: 0.30)
                    CubicKeyframe(targetY, duration: 0.18)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(0.55, duration: 0.30)
                    CubicKeyframe(targetScale, duration: 0.18)
                }
                KeyframeTrack(\.stretch) {
                    CubicKeyframe(1.32, duration: 0.26)   // stretch tall while rising
                    CubicKeyframe(0.70, duration: 0.12)   // squash on impact
                    CubicKeyframe(1.0, duration: 0.12)    // settle
                }
                KeyframeTrack(\.opacity) {
                    CubicKeyframe(1.0, duration: 0.42)
                    CubicKeyframe(0.0, duration: 0.12)    // absorbed into the island
                }
            }
    }

    private func heroEmptyFeedPage(geometry geo: GeometryProxy) -> some View {
        let bottomChrome = HeroCameraLayout.bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
        let side = HeroCameraLayout.viewfinderSide(in: geo)
        return VStack(spacing: HeroCameraLayout.viewfinderShutterSpacing) {
            Group {
                FeedCardFrame(username: nil, date: nil, tilt: 0, showTape: false, photoSide: side) {
                    emptyFeedPlaceholder
                } topLeading: {
                    EmptyView()
                } bottomCenter: {
                    EmptyView()
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
            // Matches the camera page's control-stack height so the square
            // doesn't shift when paging between camera and feed.
            Color.clear
                .frame(height: HeroCameraLayout.controlStackHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HeroCameraLayout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomChrome)
    }

    /// Empty-feed placeholder square, shared by both card styles.
    private var emptyFeedPlaceholder: some View {
        RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
            .fill(AppTheme.surfacePrimary)
            .overlay {
                RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            }
            .overlay {
                VStack(spacing: 14) {
                    Text("🌱")
                        .font(.system(size: 40))
                    Text("Your feed's quiet for now.")
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Add a friend or two and their moments will land right here.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onFindFriends()
                    } label: {
                        Label("Find friends", systemImage: "person.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textOnAccent)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(AppTheme.accentAction))
                    }
                    .buttonStyle(.scalePress)
                    .padding(.top, 2)
                }
                .padding(28)
            }
    }

    // MARK: - Vertical pager

    /// Ordered page identities: camera first, then the feed (or the empty-feed
    /// placeholder). `currentIndex` indexes into this.
    private var pages: [HeroCardID] {
        [.camera] + (socialService.feedPosts.isEmpty
            ? [.emptyFeed]
            : socialService.feedPosts.map { .post($0.id) })
    }

    /// The card at `index`, clamped into range (nil only if there are no pages).
    private func pageID(at index: Int) -> HeroCardID? {
        let p = pages
        guard !p.isEmpty else { return nil }
        return p[max(0, min(p.count - 1, index))]
    }

    /// Paging is blocked while the shell is mid edge-swipe, while reviewing a
    /// capture (don't scroll into others' posts mid-compose), and while
    /// recording (a swipe must not leave the camera with a clip rolling).
    private var isPagerDisabled: Bool {
        edgeDragActive || isReviewingCapture || camera.isRecording
    }

    /// The settle curve — smooth and slightly slow, essentially no overshoot.
    /// This is the whole point of the custom pager: a tunable slide the system
    /// `ScrollView` snap couldn't give us.
    private var pagerSettle: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.9)
    }

    /// Commit card identity after the pager (or `paginate`) chooses an index.
    /// Setting `activeCardID` (which gates the live video) only here keeps the
    /// AVPlayer spin-up off the slide. Runs once per settle — never per frame.
    private func commitSettle(to index: Int) {
        let card = pages[max(0, min(pages.count - 1, index))]
        heroCardID = card   // reuses the existing `.onChange(of: heroCardID)` wiring
        activeCardID = card
        prefetchFeedVideos()
    }

    /// Programmatic navigation (pull-for-feed, notification jump, new-moments,
    /// post-delete fallback) — animates the real slide via `currentIndex`.
    private func paginate(to card: HeroCardID?, animated: Bool = true) {
        guard let card, let idx = pages.firstIndex(of: card) else { return }
        // A jump farther than the mount window would animate through spacer pages
        // (a blank flash), so cut instantly past the window; keep the spring for
        // near moves. `currentIndex` and `activeCardID` (set in `commitSettle`)
        // both change in this one synchronous call, so SwiftUI paints the
        // destination as a full card in a single pass — no spacer flash.
        let near = abs(idx - currentIndex) <= feedMountRadius
        if animated && !reduceMotion && near {
            withAnimation(pagerSettle) { currentIndex = idx }
        } else {
            currentIndex = idx
        }
        commitSettle(to: idx)
    }

    /// Index of the settled feed post (nil while on camera / empty). Drives the
    /// warm-video window and prefetch off `activeCardID` (not `heroCardID`), so
    /// the window only shifts once a swipe settles — never mid-slide.
    private var currentFeedIndex: Int? {
        guard case .post(let id)? = activeCardID else { return nil }
        return socialService.feedPosts.firstIndex(where: { $0.id == id })
    }

    /// Warm the on-disk caches for the current + next two posts' videos AND
    /// attached song previews, so both play from local disk (instant) by the
    /// time they're swiped to — keeping the settle slide smooth. Already-cached
    /// / in-flight URLs are no-ops (deduped in the caches).
    private func prefetchFeedVideos() {
        let posts = socialService.feedPosts
        guard !posts.isEmpty else { return }
        let start = currentFeedIndex ?? 0
        let end = min(start + 2, posts.count - 1)
        guard start <= end else { return }
        for i in start...end {
            for media in posts[i].media where media.isVideo {
                guard let url = URL(string: media.url) else { continue }
                Task.detached(priority: .utility) { await VideoCache.shared.prefetch(url) }
            }
            // Warm the song's 30s preview clip too — this is what stops the
            // pager hitching when it settles on a music post.
            if let music = posts[i].music, let url = URL(string: music.previewURL) {
                Task.detached(priority: .utility) { _ = await AudioCache.shared.prefetch(url) }
            }
        }
    }

    /// The full vertical page stack (camera + feed). Extracted into its own
    /// `some View` helper so the type-checker doesn't have to infer this large
    /// `@ViewBuilder` through the generic `HeroCardPager` at the call site —
    /// inlining it there triggered "unable to type-check in reasonable time".
    @ViewBuilder
    private func heroPageStack(geometry geo: GeometryProxy, pageH: CGFloat) -> some View {
        VStack(spacing: 0) {
            cameraContent(geometry: geo)
                .frame(height: pageH)
                .frame(maxWidth: .infinity)
                .id(HeroCardID.camera)

            if socialService.feedPosts.isEmpty {
                heroEmptyFeedPage(geometry: geo)
                    .frame(height: pageH)
                    .frame(maxWidth: .infinity)
                    .id(HeroCardID.emptyFeed)
            } else {
                ForEach(Array(socialService.feedPosts.enumerated()), id: \.element.id) { idx, post in
                    Group {
                        // Virtualize: mount the full page only within ±feedMountRadius
                        // of the current post; everything else is a pure spacer (never
                        // on screen at this radius). Keeps on-screen cost O(window)
                        // regardless of feed length, so lifting the 50-cap stays smooth.
                        // `.frame`/`.id` stay OUTSIDE so the pager's -index*pageH offset
                        // math and each post's identity remain stable.
                        if abs(idx - (currentFeedIndex ?? 0)) <= feedMountRadius {
                            FeedPostPage(
                                post: post,
                                index: idx,
                                side: HeroCameraLayout.viewfinderSide(in: geo),
                                belowCardHeight: HeroCameraLayout.belowCardHeight,
                                bottomChrome: HeroCameraLayout.bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom),
                                isVideoActive: isActive && scenePhase == .active && activeCardID == .post(post.id),
                                videoLive: abs(idx - (currentFeedIndex ?? 0)) <= 1,
                                isHighlighted: highlightedPostId == post.id,
                                myUid: myUid,
                                keyboardHeight: keyboardHeight,
                                composerKeyboardLift: composerKeyboardLift,
                                postMusicPlayer: postMusicPlayer,
                                conversationService: conversationService,
                                onJumpToPlace: onJumpToPlace,
                                postFocus: $postFocus
                            )
                        } else {
                            Color.clear
                        }
                    }
                    .frame(height: pageH)
                    .frame(maxWidth: .infinity)
                    .id(HeroCardID.post(post.id))
                }
            }
        }
    }

    // MARK: - Viewfinder

    private func viewfinder(side: CGFloat) -> some View {
        Group {
            if isReviewingCapture {
                captureReviewSquare(side: side)
                    // Hidden during the flight so the moving copy (postFlightCard)
                    // isn't doubled by the static square underneath. Gently dims
                    // + shrinks while the camera warms for the "+" add-more swap.
                    .scaleEffect(addMorePreparing ? 0.96 : 1)
                    .opacity(flightActive ? 0 : (addMorePreparing ? 0.55 : 1))
            } else {
                let cam = Bindable(camera)
                CameraPreviewView(session: camera.session, isRunning: camera.isSessionRunning,
                                  lensSwitchToken: camera.lensSwitchToken,
                                  cameraPosition: camera.currentPosition)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous))
                    // Front↔rear swap cover: appears instantly to hide the input
                    // swap + rotation correction + mirror toggle, then fades away
                    // once the new feed is ready (driven by camera.isSwapping).
                    .overlay {
                        if camera.isSwapping {
                            RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                                .fill(.black)
                                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.3), value: camera.isSwapping)
                    .overlay {
                        RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    // Live aesthetic-score ring + chip (photo mode only). A live
                    // preview of the on-device Discover gate as the user reframes.
                    .overlay {
                        if cameraMode == .polaroid {
                            // Leaf wrapper: the ~2.5 Hz score read lives inside it,
                            // so score updates invalidate only the ring — not this
                            // whole body (which rebuilds every feed page).
                            LiveAestheticRing(
                                camera: camera,
                                floor: PostClassifier.aestheticFloor,
                                cornerRadius: HeroCameraLayout.viewfinderCornerRadius
                            )
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                            .stroke(Color.red.opacity(camera.isRecording ? 0.7 : 0), lineWidth: 2)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                       value: camera.isRecording)
                    }
                    // Flash top-centre, recording timer beside it while filming.
                    .overlay(alignment: .top) {
                        ZStack {
                            if camera.isRecording || camera.isLocked {
                                // Leaf wrapper: the 20 Hz `recordingProgress` read
                                // is isolated here so it ticks only the badge.
                                RecordingTimerBadge(camera: camera)
                            }
                            HStack {
                                HeroFlashButton(
                                    flashMode: cam.flashMode,
                                    enabled: cameraMode != .video || camera.hasTorchForCurrentCamera
                                )
                                if camera.isRecording || camera.isLocked { Spacer() }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    }
                    // Zoom dial floats over the bottom of the square (iOS-style).
                    .overlay(alignment: .bottom) {
                        HeroZoomDial(
                            zoom: cam.displayedZoom,
                            minZoom: camera.minDisplayedZoom,
                            maxZoom: camera.maxDisplayedZoom,
                            showsHalf: camera.supportsHalfZoom,
                            onZoomChange: { camera.setZoom(displayed: $0, animated: $1) }
                        )
                        .padding(.bottom, 12)
                    }
                    // Springy slide-up as the live camera returns after a post.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func captureReviewSquare(side: CGFloat) -> some View {
        let username = "@\(socialService.profile?.username ?? "you")"
        Group {
            FeedCardFrame(
                username: username, date: Date(), photoSide: side,
                topTrailing: {
                    spotifyAuth.isConfigured
                        ? AnyView(
                            musicControl
                                .opacity(chromeDissolved ? 0 : 1)
                          )
                        : AnyView(EmptyView())
                },
                isComposer: true
            ) {
                captureReviewMedia
            } topLeading: {
                placeTagArea
            } bottomCenter: {
                captionPillBody
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity)
        // Audience selector floats ABOVE the preview square (in the slack above
        // it) with an invisible background and centered avatars — pick which
        // friends can see this post (everyone selected by default).
        .overlay(alignment: .top) {
            audienceSelector(width: side)
                .offset(y: -(audienceStripHeight + 28))
                .opacity(chromeDissolved ? 0 : 1)
        }
    }

    private let audienceStripHeight: CGFloat = 64

    /// Centered avatar scroller floated above the review preview. Hidden when
    /// the user has no friends (nobody to restrict to). Hydrates lazily.
    @ViewBuilder
    private func audienceSelector(width: CGFloat) -> some View {
        if !socialService.friendIds.isEmpty {
            HeroAudienceStrip(rows: audienceLoader.rows,
                              excludedUids: $excludedFriendUids,
                              availableWidth: width)
                .frame(height: audienceStripHeight)
                .task(id: socialService.friendIds) {
                    await audienceLoader.sync(with: socialService.friendIds)
                }
        }
    }

    /// The captured photo/video preview (+ tap-to-dismiss + processing
    /// spinner). Shared by both card styles in `captureReviewSquare`.
    @ViewBuilder
    private var captureReviewMedia: some View {
        ZStack {
            Group {
                if drafts.indices.contains(currentDraftIndex) {
                    switch drafts[currentDraftIndex].source {
                    case .image(let img):
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .video(let url):
                        SquareVideoFillView(url: url, isPlaying: true)
                    }
                } else {
                    Color.black
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Tap-to-dismiss layer: only active while keyboard is up so
            // it doesn't block normal interaction.
            if captionFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { captionFocused = false }
            }

            if camera.isProcessingVideo {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.15)
            }
        }
    }

    /// "Tag a place" pill plus, while still untagged, the nearest-place
    /// suggestion pill beside it. Tapping the suggestion sets `pendingPlace`
    /// (animated), so the suggestion transitions out and the main pill flips to
    /// the place name; tapping the main pill then opens the picker as usual.
    @ViewBuilder
    private var placeTagArea: some View {
        HStack(spacing: 6) {
            placeTagPill
            if pendingPlace == nil, let s = suggestedPlace {
                placeSuggestionPill(s)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    /// Neon green for the music button (green + black only). Shared with the
    /// picker panel so the button and panel read as one set.
    private static let neonGreen = Color.musicNeon

    /// The only song committed to the post is one the user hasn't opted out of.
    private var committedMusic: PostMusic? {
        if case let .attached(m) = musicState { return m }
        return nil
    }

    /// Top-right music control + the neon "play a song" hint popout.
    @ViewBuilder
    private var musicControl: some View {
        musicControlBody
            .overlay(alignment: .topTrailing) {
                if showMusicHint { musicHintPopout }
            }
            .task(id: showMusicHint) {
                guard showMusicHint else { return }
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showMusicHint = false }
            }
    }

    /// Neon-green callout that pops out beside the music button when nothing's
    /// playing — replaces the old red bottom-edge banner for this hint.
    private var musicHintPopout: some View {
        Text("Play a song on Spotify — it'll show here and play in your post.")
            .font(.caption2).bold()
            .foregroundStyle(Self.neonGreen)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 168, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.82))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Self.neonGreen.opacity(0.6), lineWidth: 1))
            )
            .shadow(color: Self.neonGreen.opacity(0.4), radius: 8)
            .offset(y: 46)
            .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            .allowsHitTesting(false)
    }

    /// Top-right music control. Locket-style: the cover of whatever is currently
    /// playing (tap to opt out → greys), or a greyed `music.note` capsule when
    /// nothing's playing / Spotify can't tell us (tap → info or reconnect).
    @ViewBuilder
    private var musicControlBody: some View {
        switch musicState {
        case .attached(let m):
            SongArtworkTile(artworkURL: m.artworkURL)
                .contentShape(Rectangle())
                .onTapGesture { toggleMusicAttach() }
                .accessibilityLabel("Now playing: \(m.trackName) by \(m.artistName). Tap to leave it off this post.")
        case .optedOut(let m):
            SongArtworkTile(artworkURL: m.artworkURL)
                .saturation(0)
                .opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { toggleMusicAttach() }
                .accessibilityLabel("\(m.trackName) won't be added. Tap to add it back.")
        case .resolving:
            musicCapsule { ProgressView().tint(Self.neonGreen).scaleEffect(0.6) }
        case .notConnected:
            musicCapsule(active: true) {
                if spotifyAuth.isConnecting {
                    ProgressView().tint(Self.neonGreen).scaleEffect(0.6)
                } else {
                    Image(systemName: "music.note").font(.caption).bold()
                        .foregroundStyle(Self.neonGreen)
                }
            }
            .onTapGesture { handleMusicControlTap() }
            .accessibilityLabel("Connect Spotify to soundtrack your post")
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    musicGlow = 0.85
                }
            }
        default:   // nothingPlaying / unresolvable / permissionDenied
            musicCapsule {
                Image(systemName: "music.note").font(.caption).bold()
                    .foregroundStyle(.white.opacity(0.5))
            }
            .onTapGesture { handleMusicControlTap() }
            .accessibilityLabel("No song playing. Tap to learn how to add one.")
        }
    }

    /// Shared capsule chrome for the connect / empty / resolving states (mirrors
    /// the old music button). `active` = neon outline + breathing glow.
    @ViewBuilder
    private func musicCapsule<V: View>(active: Bool = false, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(minWidth: 16)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.65)))
            .overlay(Capsule().stroke((active ? Self.neonGreen : .white).opacity(active ? 0.9 : 0.25), lineWidth: 1))
            .shadow(color: Self.neonGreen.opacity(active ? musicGlow : 0), radius: 6)
            .shadow(color: Self.neonGreen.opacity(active ? musicGlow * 0.5 : 0), radius: 12)
            .contentShape(Capsule())
    }

    /// Tap the cover to flip attach ↔ opt-out (grey).
    @MainActor private func toggleMusicAttach() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            switch musicState {
            case .attached(let m): musicState = .optedOut(m)
            case .optedOut(let m): musicState = .attached(m)
            default: break
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Tap routing for the non-cover states: connect, reconnect, or show info.
    @MainActor private func handleMusicControlTap() {
        guard spotifyAuth.isConfigured, !spotifyAuth.isConnecting else { return }
        switch musicState {
        case .notConnected:
            connectThenRefresh(disconnectFirst: false)
        case .permissionDenied(reconnect: true):
            connectThenRefresh(disconnectFirst: true)
        case .permissionDenied(reconnect: false):
            postError = SpotifyError.api(status: 403, message: nil).errorDescription
                ?? "Spotify won't share what's playing for this app right now."
        case .nothingPlaying, .unresolvable:
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showMusicHint = true }
        default:
            break
        }
    }

    /// Run (re)authorization, then immediately pull the current song so the cover
    /// appears without waiting for the next poll tick.
    @MainActor private func connectThenRefresh(disconnectFirst: Bool) {
        Task {
            if disconnectFirst { spotifyAuth.disconnect() }
            do {
                try await spotifyAuth.connect()
                await refreshCurrentlyPlaying()
            } catch SpotifyError.cancelled {
                // user backed out — no-op
            } catch {
                postError = (error as? SpotifyError)?.errorDescription ?? "Couldn't connect to Spotify."
            }
        }
    }

    /// One currently-playing poll tick → update `musicState`. Auth/permission
    /// failures surface as `.permissionDenied`; transient errors keep the state.
    @MainActor private func refreshCurrentlyPlaying() async {
        do {
            let track = try await spotifyAuth.currentlyPlaying()
            applyPolledTrack(track)
        } catch let e as SpotifyError {
            if case .api(let status, _) = e, status == 401 || status == 403 {
                musicState = .permissionDenied(reconnect: e.needsReconnect)
            }
            // transient (offline / 429 / requestFailed) → keep current state
        } catch {
            // transient → keep current state
        }
    }

    /// Apply a polled track, de-duping on the Spotify id so the same song isn't
    /// re-resolved each tick and an opt-out stays sticky until the song changes.
    @MainActor private func applyPolledTrack(_ track: SpotifyTrack?) {
        guard let track else {
            musicState = .nothingPlaying
            lastSeenTrackId = nil
            return
        }
        if track.id == lastSeenTrackId {
            switch musicState {
            case .attached, .optedOut: return   // unchanged song — keep decision
            default: break                       // recover from a prior error state
            }
        }
        lastSeenTrackId = track.id
        musicState = .resolving
        Task {
            let music = await track.toAutoPostMusic()
            guard lastSeenTrackId == track.id else { return }   // a newer song won
            musicState = music.map { .attached($0) } ?? .unresolvable
        }
    }

    /// Pill background. On the polaroid frame, use the default `.ultraThinMaterial`
    /// (matching the feed's place pill) instead of the heavier liquid glass.
    @ViewBuilder
    private func pillChrome<V: View>(_ content: V) -> some View {
        if feedCardStyle == .polaroid {
            content.background(.ultraThinMaterial, in: Capsule())
        } else {
            content.liquidGlassChrome(in: Capsule())
        }
    }

    private func placeSuggestionPill(_ c: PlaceCandidate) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                pendingPlace = PlaceSelection(
                    id: c.source == .db ? c.id : nil,
                    googlePlaceId: c.googlePlaceId,
                    name: c.name,
                    type: c.suggestedType,
                    lat: c.lat, lng: c.lng,
                    isNew: c.source == .google,
                    address: c.address
                )
            }
        } label: {
            pillChrome(
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2).bold()
                    Text(c.name)
                        .font(.caption).bold()
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: 140)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Suggested place: \(c.name)")
        .accessibilityHint("Tag this photo here")
    }

    private var placeTagPill: some View {
        pillChrome(
            HStack(spacing: 4) {
                Image(systemName: pendingPlace == nil ? "mappin.and.ellipse" : "mappin.circle.fill")
                    .font(.caption2).bold()
                if let place = pendingPlace {
                    Text(place.name)
                        .font(.caption).bold()
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        )
        // Tap opens the picker; once tagged, swipe the pill left to clear the
        // place (reverts to the icon-only prompt + re-shows the suggestion).
        // Swipe is inert while untagged. One coordinated gesture so a swipe
        // never also fires the tap.
        .swipeToRemove(.left, enabled: pendingPlace != nil,
            onTap: { showPlacePicker = true },
            onRemove: { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { pendingPlace = nil } })
        .sheet(isPresented: $showPlacePicker) {
            PlacePickerSheet { selection in
                pendingPlace = selection
            }
            .presentationDragIndicator(.visible)
        }
        .contextMenu {
            if drafts.count > 1 {
                Button {
                    applyCurrentPlaceToAll()
                } label: {
                    Label("Use this place for all \(drafts.count) photos",
                          systemImage: "mappin.and.ellipse")
                }
            }
        }
    }

    @ViewBuilder
    private var captionPillBody: some View {
        // Invisible Text drives pill width; overlays render visual + input.
        Text(previewCaption.isEmpty ? "whats on your mind☺️?" : previewCaption)
                    .font(.footnote).bold()
                    .foregroundStyle(.clear)
                    .fixedSize()
                    .overlay {
                        if previewCaption.isEmpty {
                            Text("whats on your mind☺️?")
                                .font(.footnote).bold()
                                .foregroundStyle(.white.opacity(0.55))
                                .allowsHitTesting(false)
                        } else {
                            AnimatedWaveText(text: previewCaption,
                                            font: .footnote.bold())
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        TextField("", text: $previewCaption)
                            .font(.footnote).bold()
                            .tint(.white)
                            .foregroundStyle(.clear)
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.sentences)
                            .focused($captionFocused)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") { captionFocused = false }
                                        .fontWeight(.semibold)
                                        .foregroundStyle(AppTheme.cafeAccent)
                                }
                            }
                            .onChange(of: previewCaption) { _, new in
                                if new.count > maxCaptionLength {
                                    previewCaption = String(new.prefix(maxCaptionLength))
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(liquidGlassPill)
    }

    // (The on-viewfinder lens-toggle button was removed — the zoom dial in the
    // control stack now owns lens/zoom.)

    // MARK: - Shutter area (control stack + capture review)

    private var shutterArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AppTheme.cameraScrim)
                .frame(maxWidth: 360)
                .frame(height: HeroCameraLayout.controlStackHeight)

            VStack(spacing: 6) {
                if isReviewingCapture, !postError.isEmpty {
                    Text(postError)
                        .font(.caption)
                        .foregroundStyle(AppTheme.errorRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                // Draft thumbnails persist across review AND "add another" capture,
                // so the user always sees what's already in the post.
                if !drafts.isEmpty {
                    draftFilmstrip
                }
                if isReviewingCapture {
                    captureReviewActions
                } else {
                    HeroCameraControlStack(
                        camera: camera,
                        mode: $cameraMode,
                        libraryImages: libraryImages,
                        onTapLibrary: { showPhotosPicker = true },
                        onScrollToFeed: { scrollToFeedFromCamera() }
                    )
                }
            }
            // Dissolves the review actions out during launch, then un-dissolves
            // the live camera controls once the preview has returned.
            .opacity(chromeDissolved ? 0 : 1)
        }
        .frame(height: HeroCameraLayout.controlStackHeight)
    }

    /// Three tap buttons: Retake (left) · Post (center) · Save (right). No drag —
    /// each button has its own press animation and the side icons use SF Symbol
    /// replace transitions for visual confirmation.
    private var captureReviewActions: some View {
        let disabled = isPosting
            || camera.isProcessingVideo
            || drafts.isEmpty

        return HStack(spacing: 28) {
            reviewSideButton(
                title: "Retake",
                systemImage: "arrow.uturn.backward",
                tint: AppTheme.textPrimary,
                iconRotation: Double(retakeSpinCount) * -360,
                bounceTrigger: retakeSpinCount,
                disabled: disabled
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    retakeSpinCount += 1
                }
                // Defer the screen transition so the spin animation has time
                // to play — otherwise the review screen tears down before the
                // user sees the icon move.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    retakeFromReview()
                }
            }

            reviewPostButton(disabled: disabled)

            reviewSideButton(
                title: saveJustSucceeded ? "Saved" : "Save",
                systemImage: saveJustSucceeded ? "checkmark" : "square.and.arrow.down",
                tint: saveJustSucceeded ? AppTheme.cafeAccent : AppTheme.textPrimary,
                bounceTrigger: savePressTick + (saveJustSucceeded ? 1000 : 0),
                disabled: disabled || saveJustSucceeded
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                savePressTick += 1
                saveCaptureToPhotoLibrary()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Draft filmstrip

    private var draftFilmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                    draftThumb(draft, index: index)
                }
                if drafts.count < maxDrafts {
                    Button {
                        // Deliberate, camera-ready-gated swap to the live camera
                        // (the photo library is reachable there via left-drag).
                        goToAddMore()
                    } label: {
                        addDraftCell
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 44)
    }

    private func draftThumb(_ draft: MediaDraft, index: Int) -> some View {
        let isCurrent = index == currentDraftIndex
        return ZStack(alignment: .topTrailing) {
            Group {
                switch draft.source {
                case .image(let img):
                    Image(uiImage: img).resizable().scaledToFill()
                case .video:
                    ZStack {
                        Color.black
                        Image(systemName: "video.fill")
                            .font(.caption2).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isCurrent ? AppTheme.cafeAccent : Color.white.opacity(0.3),
                            lineWidth: isCurrent ? 2 : 1)
            }
            .onTapGesture { selectDraft(index) }

            Button { deleteDraft(at: index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
        .frame(width: 42, height: 42)
    }

    private var addDraftCell: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
            }
    }

    /// Smaller circular tap button used for Retake and Save. `iconRotation`
    /// drives the per-tap spin on Retake; `bounceTrigger` fires an SF Symbol
    /// bounce on every tap; the symbol-replace transition handles the Save →
    /// checkmark morph.
    private func reviewSideButton(
        title: String,
        systemImage: String,
        tint: Color,
        iconRotation: Double = 0,
        bounceTrigger: Int = 0,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .stroke(tint.opacity(0.22), lineWidth: 1)
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                        .rotationEffect(.degrees(iconRotation))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: bounceTrigger)
                }
                .frame(width: 54, height: 54)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint.opacity(0.85))
                    .contentTransition(.opacity)
            }
            // Solid hit region — the VStack has gaps between the circle and
            // text, which would otherwise drop taps that landed in the gap.
            .contentShape(Rectangle())
        }
        .buttonStyle(.scalePress)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(title)
    }

    /// Centered post button. Keeps a subtle breathing scale while idle so the
    /// primary action stays the visual anchor; tap = post.
    @ViewBuilder
    private func reviewPostButton(disabled: Bool) -> some View {
        let idleAnimate = !disabled && !isPosting
        Button {
            postFromCapture()
        } label: {
            ZStack {
                Circle()
                    .stroke(AppTheme.accentAction.opacity(isPosting ? 0.4 : 1), lineWidth: 3)
                    .frame(width: 70, height: 70)
                Circle()
                    .fill(AppTheme.accentAction.opacity((isPosting || camera.isProcessingVideo || disabled) ? 0.45 : 1))
                    .frame(width: 56, height: 56)
                if isPosting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.title2).bold()
                        .foregroundStyle(.white)
                }
            }
            .phaseAnimator([1.0, 1.05]) { content, scale in
                content.scaleEffect(idleAnimate ? scale : 1.0)
            } animation: { _ in
                .easeInOut(duration: 1.4)
            }
        }
        .buttonStyle(.scalePress)
        .disabled(disabled)
        .accessibilityLabel("Post")
    }

    // The shutter button, its gesture state machine, direction hints and the
    // first-run coach overlay now live in `ShutterControl` (ShutterControl.swift).

    // MARK: - Permission denied

    private var permissionDeniedUI: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .symbolVariant(.slash)
                .font(.system(size: 48, weight: .light))
                .contrastAware(AppTheme.cream, opacity: 0.5)
                .accessibilityHidden(true)
            Text("Camera Access Needed")
                .font(.title3).bold()
                .foregroundStyle(AppTheme.cream)
            Text("Allow camera access so you can share cafe moments.")
                .font(.subheadline)
                .contrastAware(AppTheme.cream, opacity: 0.6)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.callout).bold()
                    .foregroundStyle(AppTheme.textOnAccent)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(AppTheme.cafeAccent)
                    .clipShape(Capsule())
            }
        }
    }
}

/// Observes the feed-music drivers and re-evaluates playback on any change.
/// Lives here (not inline in `HeroPageView.body`) so the six `onChange`
/// observers don't blow the body's already-large type-check budget — same
/// reason `FeedModerationModifier` is extracted.
private struct HeroBackgroundMusicModifier: ViewModifier {
    let activeCardID: HeroCardID?
    let feedVideoMuted: Bool
    let isActive: Bool
    let isReviewingCapture: Bool
    let isObscured: Bool
    let scenePhase: ScenePhase
    let update: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: activeCardID) { _, _ in update() }
            .onChange(of: feedVideoMuted) { _, _ in update() }
            .onChange(of: isActive) { _, _ in update() }
            .onChange(of: isReviewingCapture) { _, _ in update() }
            .onChange(of: isObscured) { _, _ in update() }
            .onChange(of: scenePhase) { _, _ in update() }
    }
}

// MARK: - High-frequency camera reads, isolated to leaf views

/// Wraps `HeroAestheticIndicator` so the ~2.5 Hz `camera.liveAestheticScore`
/// update (Vision frame-tap; the camera page is always mounted and keeps
/// scoring even while browsing the feed) invalidates only this ring — not
/// `HeroPageView.body`, which rebuilds every feed page. Reading the score
/// *inside* this view is the whole point; passing `camera` by reference creates
/// no dependency until a property is accessed.
private struct LiveAestheticRing: View {
    let camera: CameraService
    let floor: Double
    let cornerRadius: CGFloat

    var body: some View {
        HeroAestheticIndicator(
            score: camera.liveAestheticScore,
            floor: floor,
            cornerRadius: cornerRadius
        )
    }
}

/// Wraps `HeroRecordingTimer` so the 20 Hz `camera.recordingProgress` tick is
/// isolated to the badge instead of re-running `HeroPageView.body` while filming.
private struct RecordingTimerBadge: View {
    let camera: CameraService

    var body: some View {
        HeroRecordingTimer(elapsed: camera.recordingProgress * 5,
                           isLocked: camera.isLocked)
    }
}

// MARK: - One feed post page (extracted from HeroPageView)

/// A single full-height feed page: the polaroid card + the below-card reply
/// composer. Extracted from the old `heroFeedPostPage(...)` *function* into its
/// own `View` so each post has structural identity — when `HeroPageView.body`
/// re-runs (e.g. on a settle), SwiftUI can skip the posts whose inputs are
/// unchanged instead of rebuilding all ~50. `FriendPost` is `Equatable` and the
/// observable refs / `onJumpToPlace` closure / `postFocus` binding are stable,
/// so only the entering/leaving cards actually re-render.
private struct FeedPostPage: View {
    let post: FriendPost
    let index: Int
    let side: CGFloat
    let belowCardHeight: CGFloat
    let bottomChrome: CGFloat
    let isVideoActive: Bool
    let videoLive: Bool
    let isHighlighted: Bool
    let myUid: String
    let keyboardHeight: CGFloat
    let composerKeyboardLift: CGFloat
    let postMusicPlayer: PostMusicPlayer
    var conversationService: ConversationService
    let onJumpToPlace: (String) -> Void
    @Binding var postFocus: PostFocus?

    var body: some View {
        VStack(spacing: 0) {
            FeedPolaroidCard(
                post: post,
                index: index,
                isVideoActive: isVideoActive,
                side: side,
                postMusicPlayer: postMusicPlayer,
                // Pass `onJumpToPlace` directly (not re-wrapped) so this view's
                // inputs stay stable across renders and memoization holds.
                onPlaceTap: onJumpToPlace,
                // Off-window posts show the poster (no live player) so only the
                // current ±1 cards spin up AVPlayers — caps memory/bandwidth and
                // lets the prefetch actually win.
                staticPreview: !videoLive,
                // Brief glow when arriving here via a notification tap.
                isHighlighted: isHighlighted
            )
            // Long-press → focus menu (blurred backdrop + lifted post +
            // action card). Report/Block for others' posts (App Store
            // Guideline 1.2), Delete + Hide-from-Discover for your own.
            .postFocusLongPress { frame in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                // Low damping → the post overshoots and settles, giving a
                // springy "bounce" that lands with the haptic.
                withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) {
                    postFocus = PostFocus(
                        post: post,
                        index: index,
                        side: side,
                        anchor: frame,
                        isMine: post.authorId == myUid
                    )
                }
            }

            // Below-card area: a Color.clear spacer pushes the reply composer to
            // the bottom of this 160pt zone (just above the navbar arc /
            // bottomChrome). The song's album cover now lives at the photo's
            // top-right (inside `FeedPolaroidCard`), not as a chip under the card.
            VStack(spacing: 0) {
                Color.clear
                if post.authorId != myUid {
                    PostReplyComposer(
                        post: post,
                        conversationService: conversationService
                    )
                    // Manual keyboard lift — see `composerKeyboardLift`
                    // doc-comment. The ScrollView's
                    // `.ignoresSafeArea(.keyboard)` disables automatic
                    // keyboard avoidance, so we offset upward here.
                    .offset(y: composerKeyboardLift)
                    .animation(.easeOut(duration: 0.25), value: keyboardHeight)
                }
            }
            .frame(height: belowCardHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HeroCameraLayout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomChrome)
        // Tap anywhere on the page that isn't consumed by a Button /
        // TextField → dismiss keyboard. Covers the post image, header
        // text, and the empty zone above the composer. The composer's
        // internal Buttons/TextField consume their own taps so the
        // user can still interact with the pill normally.
        .contentShape(Rectangle())
        .onTapGesture {
            if keyboardHeight > 0 {
                HeroPageView.dismissKeyboard()
            }
        }
    }
}

