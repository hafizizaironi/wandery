@preconcurrency import FirebaseAuth
import Photos
import SwiftUI
import PhotosUI
import UIKit

// MARK: - Drag direction

private enum DragDir { case up, down, left, right }

// MARK: - Shutter haptics

private enum HeroShutterHaptics {
    static func photoShutter() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred()
    }

    static func recordStart() {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare()
        g.impactOccurred(intensity: 1.0)
    }

    static func recordStop() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred(intensity: 0.85)
    }

    static func scrollToFeed() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }

    static func flipCamera() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }

    static func openPhotoLibrary() {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare()
        g.impactOccurred()
    }

    static func lockRecordingMode() {
        let g = UIImpactFeedbackGenerator(style: .rigid)
        g.prepare()
        g.impactOccurred()
    }
}

/// Vertical pager targets: camera first, then timeline posts (or one empty placeholder).
private enum HeroCardID: Hashable {
    case camera
    case emptyFeed
    case post(String)
}

// MARK: - Circular reveal transition

/// View modifier that masks `content` to a circle anchored at `origin` and
/// scaled by `progress`. Pair with `AnyTransition.modifier(active:identity:)`
/// to drive a circular open/close from a tap point.
private struct CircularRevealModifier: ViewModifier {
    let origin: CGPoint
    let progress: CGFloat

    func body(content: Content) -> some View {
        content.mask(
            // Fixed-size disc much larger than any phone screen so when
            // `scaleEffect = 1` the mask covers the entire view, and when
            // it's 0 it hides everything.
            Circle()
                .frame(width: 2400, height: 2400)
                .position(origin)
                .scaleEffect(progress)
        )
    }
}

private extension AnyTransition {
    static func circularReveal(origin: CGPoint) -> AnyTransition {
        .modifier(
            active: CircularRevealModifier(origin: origin, progress: 0),
            identity: CircularRevealModifier(origin: origin, progress: 1)
        )
    }
}

/// PreferenceKey we use to bubble the Messages button's screen-space center
/// up to HeroPageView so the circular reveal originates from the tap point.
private struct MessageButtonOriginKey: PreferenceKey {
    static var defaultValue: CGPoint = CGPoint(x: 0, y: 0)
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

/// Per-post screen-space frame of the in-feed reply pill. The composer
/// overlay uses this so the focused input bar can settle at exactly the
/// pill's resting position when the keyboard is hidden — making the
/// pill→focused-input transition feel like one object morphing in place.
private struct ReplyPillFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Hero page

struct HeroPageView: View {
    var isActive: Bool = false
    @ObservedObject var socialService: SocialService
    @ObservedObject var conversationService: ConversationService
    /// Set by the parent shell. We flip it whenever the inbox or a chat
    /// thread is open so MainShellView can spring the arc navbar away.
    @Binding var isChatActive: Bool
    /// External "scroll to this post" trigger — set by the shell when a
    /// chat thumbnail tapped on a different page jumps here. Cleared after
    /// consumption.
    @Binding var pendingHeroJumpPostId: String?
    /// Fired when a feed post's place pill is tapped — parent (MainShellView)
    /// switches to the map page and centers on the tagged place.
    var onJumpToPlace: (String) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = CameraService()

    @State private var showInbox = false
    @State private var pendingChat: PendingChat?
    /// Screen-space center of the Messages button. Captured by the button
    /// background's GeometryReader and consumed by the circular-reveal
    /// transition so the inbox spirals open from where the user tapped.
    @State private var inboxRevealOrigin: CGPoint = CGPoint(x: 360, y: 80)

    @State private var previewCaption = ""
    @FocusState private var captionFocused: Bool
    @State private var isPosting = false
    @State private var postError = ""

    // Full-screen reaction burst
    @State private var reactionBurstEmoji: String? = nil
    @State private var burstRenderId = UUID()
    @State private var burstOffsetY: CGFloat = 700

    private let maxCaptionLength = 25

    // Shutter gesture state
    @State private var isDragging     = false
    @State private var isHolding      = false   // hold timer fired → recording
    @State private var translation    = CGSize.zero
    @State private var holdTask: Task<Void, Never>?

    /// Post-preview: drag the centered post control (left = retake, right = save to library).
    @State private var isDraggingReviewPost = false
    @State private var reviewPostTranslation = CGSize.zero

    @State private var heroCardID: HeroCardID? = .camera

    // Mode state
    @State private var showPhotosPicker = false
    @State private var selectedPhoto: PhotosPickerItem?

    // Place tagging
    @State private var pendingPlace: PlaceSelection?
    @State private var showPlacePicker = false

    // Reply composer state. Tapping the in-feed reply pill sets
    // `replyTargetPost`, which renders the composer in a separate overlay
    // above the feed. Drafts persist per-post so dismissing without
    // sending doesn't lose what the user typed.
    @State private var replyTargetPost: FriendPost?
    @State private var replyDrafts: [String: String] = [:]

    // Moderation state. Long-press on a feed post surfaces report/block.
    @State private var reportTarget: ReportTarget?
    @State private var pendingBlockUid: String?
    @State private var pendingBlockTitle: String = ""
    /// Live screen-space frame of each post's reply pill — the composer
    /// uses the active post's frame to anchor its idle position so the
    /// pill→focused-input morph feels like a single object.
    @State private var replyPillFrames: [String: CGRect] = [:]

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                GeometryReader { geo in
                    let pageH = HeroCameraLayout.pageHeight(in: geo)
                    ScrollView(.vertical) {
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
                                    heroFeedPostPage(geometry: geo, post: post, index: idx,
                                                       isVideoActive: isActive && scenePhase == .active && heroCardID == .post(post.id))
                                        .frame(height: pageH)
                                        .frame(maxWidth: .infinity)
                                        .id(HeroCardID.post(post.id))
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $heroCardID)
                    // The reply composer renders as a separate overlay
                    // and floats above the keyboard on its own — we don't
                    // want the feed page to also lift, so ignore the
                    // keyboard inset here.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                permissionDeniedUI
            }

            // Full-screen reaction burst – sits above everything
            if let em = reactionBurstEmoji {
                fullScreenBurstOverlay(em)
            }

            // Top-right Messages button — sits in the safe-area inset on
            // every Hero card (camera, empty feed, post). Hidden while the
            // inbox or a chat thread is open so it doesn't fight the panel.
            messagesTopButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(showInbox || pendingChat != nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.18), value: showInbox)
                .animation(.easeInOut(duration: 0.18), value: pendingChat?.id)
        }
        .photosPicker(isPresented: $showPhotosPicker,
                      selection: $selectedPhoto,
                      matching: .images)
        // Full-screen inbox with a circular reveal anchored at the Messages
        // button's tap point. We use overlay-with-transition rather than
        // floatingPanel so the surface fills the screen and the entry/exit
        // animation is custom.
        .overlay {
            if showInbox {
                ConversationsListView(
                    conversationService: conversationService,
                    socialService: socialService,
                    onClose: { closeInbox() },
                    onJumpToPost: { postId in
                        closeInbox()
                        scrollFeedToPost(postId)
                    }
                )
                .background(AppTheme.espresso.ignoresSafeArea())
                .ignoresSafeArea()
                .transition(.circularReveal(origin: inboxRevealOrigin))
                .zIndex(30)
            }
        }
        // Full-screen chat (opened from FriendList → Message). Slides in
        // from the trailing edge instead of circular-revealing — the entry
        // point isn't a single tap target, so the circular metaphor
        // wouldn't read.
        .overlay {
            if let chat = pendingChat {
                ChatView(
                    conversationService: conversationService,
                    socialService: socialService,
                    convId: chat.convId,
                    otherUid: chat.otherUid,
                    otherTitle: chat.title,
                    onClose: { closePendingChat() },
                    onJumpToPost: { postId in
                        closePendingChat()
                        scrollFeedToPost(postId)
                    }
                )
                .background(AppTheme.espresso.ignoresSafeArea())
                .ignoresSafeArea(.container)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(31)
            }
        }
        // Reply composer — renders above the feed so the post stays put.
        // The composer floats above the keyboard via SwiftUI's automatic
        // safe-area avoidance (the feed itself ignores the keyboard inset).
        .overlay {
            if let post = replyTargetPost {
                ReplyComposerOverlay(
                    post: post,
                    messageButtonOrigin: inboxRevealOrigin,
                    pillFrame: replyPillFrames[post.id] ?? .zero,
                    draft: Binding(
                        get: { replyDrafts[post.id] ?? "" },
                        set: { replyDrafts[post.id] = $0 }
                    ),
                    onSend: {
                        let trimmed = (replyDrafts[post.id] ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let media = post.isVideo
                            ? (post.thumbnailURL ?? post.mediaURL)
                            : post.mediaURL
                        try await conversationService.mirrorReply(
                            toAuthor: post.authorId,
                            text: trimmed,
                            postId: post.id,
                            postPreview: post.caption,
                            postMediaURL: media,
                            postIsVideo: post.isVideo
                        )
                        replyDrafts[post.id] = ""
                    },
                    // Tap-away dismiss → springy fade so the pill
                    // re-emerges underneath as the input bar settles.
                    onClose: {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                            replyTargetPost = nil
                        }
                    },
                    // Send completes after the swoosh — bypass the
                    // animation so the input bar doesn't morph back to
                    // the pill on its way to the messages button.
                    onSendComplete: {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            replyTargetPost = nil
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(35)
            }
        }
        .onPreferenceChange(ReplyPillFramesKey.self) { newValue in
            replyPillFrames.merge(newValue) { _, new in new }
        }
        .animation(
            .motionRespecting(
                .spring(response: 0.32, dampingFraction: 0.78),
                reduceMotion: reduceMotion
            ),
            value: showInbox
        )
        .animation(
            .motionRespecting(
                .spring(response: 0.28, dampingFraction: 0.86),
                reduceMotion: reduceMotion
            ),
            value: pendingChat?.id
        )
        // Spring-driven flag the shell observes to slide the arc navbar away.
        .onChange(of: showInbox) { _, _ in syncChatActiveFlag() }
        .onChange(of: pendingChat?.id) { _, _ in syncChatActiveFlag() }
        // Profile-side chat sets this when its thumbnail is tapped; we
        // consume it here once Hero is the visible tab.
        .onChange(of: pendingHeroJumpPostId) { _, newValue in
            guard let postId = newValue else { return }
            scrollFeedToPost(postId)
            pendingHeroJumpPostId = nil
        }
        .task {
            // Cover first-launch case where the post id was set before
            // Hero appeared on screen.
            if let postId = pendingHeroJumpPostId {
                scrollFeedToPost(postId)
                pendingHeroJumpPostId = nil
            }
        }
        .task {
            await camera.requestAccess()
            // `onChange(of: isActive)` does not run for the initial value, so on first launch
            // (Hero is the default tab) we must start here after auth succeeds.
            if isActive && camera.isAuthorized {
                camera.startSession()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                if camera.isAuthorized {
                    camera.startSession()
                }
            } else {
                camera.stopSession()
            }
        }
        .onChange(of: camera.isAuthorized) { _, authorized in
            if authorized && isActive {
                camera.startSession()
            }
        }
        .onChange(of: camera.capturedImage) { _, _ in
            syncCameraSessionForCaptureReview()
        }
        .onChange(of: camera.capturedVideoURL) { _, _ in
            syncCameraSessionForCaptureReview()
        }
        .onChange(of: camera.isProcessingVideo) { _, _ in
            syncCameraSessionForCaptureReview()
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
            pendingBlockTitle: pendingBlockTitle,
            socialService: socialService
        ))
        .onChange(of: socialService.feedPosts.count) { _, _ in
            guard let current = heroCardID else { return }
            switch current {
            case .post(let id) where !socialService.feedPosts.contains(where: { $0.id == id }):
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    heroCardID = .camera
                }
            case .emptyFeed where !socialService.feedPosts.isEmpty:
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    heroCardID = .post(socialService.feedPosts[0].id)
                }
            default:
                break
            }
        }
    }

    // MARK: - Messages top button

    /// Top-right liquid-glass HUD that opens the inbox. Sits well below the
    /// status bar / dynamic island so it doesn't fight the system overlay.
    /// Visibility is gated above by `showInbox || pendingChat != nil`.
    private var messagesTopButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Drive the spring via the .animation modifier on the overlay.
            // We just flip the bool — the circular reveal reads
            // `inboxRevealOrigin` which is already up-to-date from the
            // GeometryReader inside the label below.
            showInbox = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.callout).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    // Same liquid-glass recipe used on the map's "center on
                    // me" HUD: real iOS 26 Liquid Glass + faint terracotta
                    // tint, white→accent rim highlight, lifted shadow.
                    .glassEffect(
                        .regular
                            .tint(AppTheme.accentAction.opacity(0.07)),
                        in: Circle()
                    )
                    .liquidGlassShine(in: Circle(), strength: 1.0)
                    .overlay {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.70),
                                        Color.white.opacity(0.18),
                                        AppTheme.accentAction.opacity(0.22),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    }
                    .shadow(color: AppTheme.accentAction.opacity(0.14),
                            radius: 8, x: 0, y: 3)
                    .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)

                if unreadCount > 0 {
                    Text("\(min(unreadCount, 99))")
                        .font(.caption2).bold()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppTheme.accentAction))
                        .overlay {
                            Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1)
                        }
                        .offset(x: 4, y: -3)
                }
            }
            .contentShape(Circle())
            // Capture inside the label — measures the actual button
            // content (44×44 icon), NOT the outer frame inflated by
            // .padding(.top, 60). With the prior placement the captured
            // midX/midY was the padded-frame center, which sat well above
            // and left of the visible button → reveal originated near
            // screen-center instead of from the tap point.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MessageButtonOriginKey.self,
                        value: CGPoint(
                            x: proxy.frame(in: .global).midX,
                            y: proxy.frame(in: .global).midY
                        )
                    )
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open messages")
        .padding(.trailing, 16)
        // Pad past the status bar / dynamic island. Matches the map page's
        // top-button placement so the two pages feel consistent.
        .padding(.top, 60)
        .onPreferenceChange(MessageButtonOriginKey.self) { center in
            // Only update when the value is plausible — preference key
            // briefly emits .zero during view rebuilds which would launch
            // the reveal from the top-left corner.
            if center.x > 0, center.y > 0 {
                inboxRevealOrigin = center
            }
        }
    }

    private func closeInbox() {
        showInbox = false
    }

    private func closePendingChat() {
        conversationService.openThread(nil)
        pendingChat = nil
    }

    /// "Unread-ish" count: any inbox conversation whose last message wasn't
    /// authored by me. Cheap heuristic until we wire per-uid unread counters.
    private var unreadCount: Int {
        let myUid = Auth.auth().currentUser?.uid ?? ""
        return conversationService.inbox.filter { conv in
            !conv.lastMessageSenderId.isEmpty && conv.lastMessageSenderId != myUid
        }.count
    }

    private func syncChatActiveFlag() {
        let active = showInbox || pendingChat != nil
        guard active != isChatActive else { return }
        // Spring with a touch of overshoot — the shell mirrors this so the
        // arc navbar slide and the panel rise are visually coupled.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
            isChatActive = active
        }
    }

    /// Scrolls the Hero pager to the given post id. Called when a chat
    /// thumbnail is tapped — the chat sheet has already been dismissed by
    /// the call site, so this just lines up the destination.
    private func scrollFeedToPost(_ postId: String) {
        guard socialService.feedPosts.contains(where: { $0.id == postId }) else {
            // Post is no longer in the feed (deleted or fell off the
            // window). Bail silently — the chat is already dismissed and
            // the user lands back on whatever was visible.
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            heroCardID = .post(postId)
        }
    }

    // MARK: - Full-screen reaction burst

    /// Slides a large animated emoji from below the screen to center, then out through the top.
    @MainActor
    private func triggerFullScreenBurst(_ emoji: String) {
        burstRenderId = UUID()
        burstOffsetY = 700
        reactionBurstEmoji = emoji

        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            burstOffsetY = 0
        }
        Task { @MainActor in
            // Hold at center (~1.1 s) while the Lottie plays through, then exit upward.
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeIn(duration: 0.36)) {
                burstOffsetY = -700
            }
            try? await Task.sleep(for: .milliseconds(380))
            reactionBurstEmoji = nil
        }
    }

    @ViewBuilder
    private func fullScreenBurstOverlay(_ emoji: String) -> some View {
        ZStack {
            if !reduceMotion, let slug = NotoEmojiLottie.notoSlug(for: emoji) {
                NotoEmojiLottieView(notoSlug: slug, fallbackEmoji: emoji, size: 180, loop: false)
                    .id(burstRenderId)
            } else {
                Text(emoji)
                    .font(.system(size: 180))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .offset(y: burstOffsetY)
        .allowsHitTesting(false)
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
        camera.capturedImage != nil || camera.capturedVideoURL != nil || camera.isProcessingVideo
    }

    /// Stop the session only during capture review (preview covers the viewfinder anyway).
    /// Scrolling to feed pages keeps the session alive so returning to camera is instant.
    private func syncCameraSessionForCaptureReview() {
        if isReviewingCapture {
            camera.stopSession()
        } else if isActive, camera.isAuthorized {
            camera.startSession()
        }
    }

    private func scrollToFeedFromCamera() {
        let posts = socialService.feedPosts
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            if posts.isEmpty {
                heroCardID = .emptyFeed
            } else {
                heroCardID = .post(posts[0].id)
            }
        }
    }

    private func postFromCapture() async {
        // Re-entrancy guard: tap-to-post fires from a gesture that can deliver
        // twice in quick succession. Without this we'd race two uploads + two
        // findOrCreatePlace calls (the "GTMSessionFetcher already running" log).
        guard !isPosting else { return }
        postError = ""
        isPosting = true
        defer { isPosting = false }
        do {
            try await socialService.uploadAndCreatePost(
                image: camera.capturedImage,
                videoURL: camera.capturedVideoURL,
                caption: previewCaption,
                place: pendingPlace
            )
            previewCaption = ""
            pendingPlace = nil
            reviewPostTranslation = .zero
            camera.discardCapture()
            syncCameraSessionForCaptureReview()
        } catch {
            postError = friendlyPostError(error)
        }
    }

    /// Translate raw NSError / FunctionsError into something the user can act on.
    private func friendlyPostError(_ error: Error) -> String {
        let ns = error as NSError
        let lower = ns.localizedDescription.lowercased()
        if lower.contains("not found") || ns.code == 5 /* FunctionsErrorCode.notFound */ {
            return "Couldn't reach the place service. Try again in a moment."
        }
        if lower.contains("network") || lower.contains("offline") {
            return "No internet — your post wasn't saved."
        }
        if pendingPlace != nil && lower.contains("location") {
            return "Couldn't get your location to save the place. Enable Location and try again."
        }
        return "Couldn't post: \(ns.localizedDescription)"
    }

    private func retakeFromReview() {
        previewCaption = ""
        pendingPlace = nil
        postError = ""
        reviewPostTranslation = .zero
        camera.discardCapture()
        syncCameraSessionForCaptureReview()
    }

    private func saveCaptureToPhotoLibrary() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run { postError = "Allow Photos access in Settings to save to your library." }
                return
            }
            do {
                if let image = camera.capturedImage {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                } else if let url = camera.capturedVideoURL {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }
                } else {
                    return
                }
            } catch {
                await MainActor.run { postError = error.localizedDescription }
            }
        }
    }

    // MARK: - Camera content

    private func cameraContent(geometry geo: GeometryProxy) -> some View {
        let bottomChrome = HeroCameraLayout.bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
        let side = HeroCameraLayout.viewfinderSide(in: geo)

        return VStack(spacing: HeroCameraLayout.viewfinderShutterSpacing) {
            viewfinder(side: side)
            shutterArea
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HeroCameraLayout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomChrome)
    }

    private func heroEmptyFeedPage(geometry geo: GeometryProxy) -> some View {
        let bottomChrome = HeroCameraLayout.bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
        let side = HeroCameraLayout.viewfinderSide(in: geo)
        return VStack(spacing: HeroCameraLayout.viewfinderShutterSpacing) {
            RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                .fill(AppTheme.surfacePrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                }
                .frame(width: side, height: side)
                .overlay {
                    Text("No posts yet.\nShare a moment from the camera.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            Color.clear
                .frame(height: HeroCameraLayout.shutterAreaHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HeroCameraLayout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomChrome)
    }

    private func heroFeedPostPage(geometry geo: GeometryProxy, post: FriendPost, index: Int, isVideoActive: Bool) -> some View {
        let bottomChrome = HeroCameraLayout.bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
        let side = HeroCameraLayout.viewfinderSide(in: geo)
        // Total reserved height below the card stays identical to the camera layout
        // (viewfinderShutterSpacing + shutterAreaHeight) so the card Y doesn't shift.
        // Within that block reactions float to the top (hugging the card) and a
        // Spacer absorbs the leftover space above the navbar.
        let belowCardHeight = HeroCameraLayout.viewfinderShutterSpacing + HeroCameraLayout.shutterAreaHeight
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("@\(post.authorUsername)")
                    .font(.footnote).bold()
                    .contrastAware(AppTheme.cream, opacity: 0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                FeedPostCard(
                    post: post,
                    index: index,
                    socialService: socialService,
                    isVideoActive: isVideoActive,
                    onPlaceTap: { placeId in onJumpToPlace(placeId) }
                )
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous))
                // Long-press surfaces moderation actions — App Store
                // Guideline 1.2 requires report + block affordances on
                // user-generated content. Hidden for your own posts.
                .contextMenu {
                    if post.authorId != Auth.auth().currentUser?.uid {
                        Button {
                            reportTarget = ReportTarget(type: .post, targetId: post.id)
                        } label: {
                            Label("Report post", systemImage: "exclamationmark.triangle")
                        }
                        Button {
                            reportTarget = ReportTarget(type: .user, targetId: post.authorId)
                        } label: {
                            Label("Report user", systemImage: "person.crop.circle.badge.exclamationmark")
                        }
                        Button(role: .destructive) {
                            pendingBlockUid = post.authorId
                            pendingBlockTitle = post.authorUsername
                        } label: {
                            Label("Block \(post.authorUsername)", systemImage: "hand.raised")
                        }
                    }
                }
            }

            // Reactions + comment hug the card; Spacer fills leftover space above navbar.
            // Own posts skip the reaction/reply chrome — there's nobody to
            // react/reply to yourself. Just keep the image and fill space.
            VStack(spacing: 0) {
                if post.authorId != Auth.auth().currentUser?.uid {
                    VStack(spacing: 12) {
                        FeedPostReactions(post: post,
                                          socialService: socialService,
                                          conversationService: conversationService,
                                          onBurst: triggerFullScreenBurst)
                        ReplyTriggerPill(
                            draftPreview: replyDrafts[post.id] ?? ""
                        ) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                replyTargetPost = post
                            }
                        }
                        // Hidden while the composer is up — the overlay's
                        // input bar takes over at this exact Y, so the
                        // user perceives one object morphing into focus.
                        .opacity(replyTargetPost?.id == post.id ? 0 : 1)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ReplyPillFramesKey.self,
                                    value: [post.id: proxy.frame(in: .global)]
                                )
                            }
                        )
                    }
                    .padding(.top, 14)
                }

                Spacer(minLength: 0)
            }
            .frame(height: belowCardHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HeroCameraLayout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomChrome)
    }

    // MARK: - Viewfinder

    private func viewfinder(side: CGFloat) -> some View {
        Group {
            if isReviewingCapture {
                captureReviewSquare(side: side)
            } else {
                CameraPreviewView(session: camera.session, isRunning: camera.isSessionRunning,
                                  lensSwitchToken: camera.lensSwitchToken)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                            .stroke(Color.red.opacity(camera.isRecording ? 0.7 : 0), lineWidth: 2)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                       value: camera.isRecording)
                    }
                    .overlay(alignment: .top) {
                        if camera.hasLensToggleForCurrentCamera {
                            lensToggleButton
                                .padding(.top, 10)
                        }
                    }
            }
        }
    }

    private func captureReviewSquare(side: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if let img = camera.capturedImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                } else if camera.isProcessingVideo {
                    Color.black
                } else if let url = camera.capturedVideoURL {
                    SquareVideoFillView(url: url, isPlaying: true)
                        .frame(width: side, height: side)
                } else {
                    Color.black
                }
            }
            .frame(width: side, height: side)
            .clipped()

            // Tap-to-dismiss layer: sits above media but below the pill.
            // Only active while keyboard is up so it doesn't block normal interaction.
            if captionFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { captionFocused = false }
            }

            VStack(spacing: 8) {
                Spacer(minLength: 0)
                placeTagPill
                HStack(alignment: .bottom) {
                    Spacer(minLength: 0)
                    captionPillBody
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .overlay {
            if camera.isProcessingVideo {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.15)
            }
        }
    }

    private var placeTagPill: some View {
        Button {
            showPlacePicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pendingPlace == nil ? "mappin.and.ellipse" : "mappin.circle.fill")
                    .font(.footnote).bold()
                Text(pendingPlace?.name ?? "Tag a place")
                    .font(.footnote).bold()
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPlacePicker) {
            PlacePickerSheet { selection in
                pendingPlace = selection
            }
        }
    }

    @ViewBuilder
    private var captionPillBody: some View {
        // Invisible Text drives pill width; overlays render visual + input.
        Text(previewCaption.isEmpty ? "whats on your mind☺️?" : previewCaption)
                    .font(.subheadline).bold()
                    .foregroundStyle(.clear)
                    .fixedSize()
                    .overlay {
                        if previewCaption.isEmpty {
                            Text("whats on your mind☺️?")
                                .font(.subheadline).bold()
                                .foregroundStyle(.white.opacity(0.55))
                                .allowsHitTesting(false)
                        } else {
                            AnimatedWaveText(text: previewCaption,
                                            font: .subheadline.bold())
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        TextField("", text: $previewCaption)
                            .font(.subheadline).bold()
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(liquidGlassPill)
    }

    /// Rear only: **1** ↔ **0.5** (smooth zoom on supported devices).
    private var lensToggleButton: some View {
        Button {
            camera.toggleLens()
        } label: {
            Text(lensToggleLabel)
                .font(.footnote).bold()
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.92))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lensAccessibilityLabel)
    }

    private var lensToggleLabel: String {
        camera.lensSlot == .wide ? "0.5" : "1"
    }

    private var lensAccessibilityLabel: String {
        camera.lensSlot == .wide ? "Half x zoom, tap for one x" : "One x zoom, tap for half x"
    }

    // MARK: - Shutter area (button + directional hints)

    private var shutterArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AppTheme.cameraScrim)
                .frame(width: 320, height: 140)

            if isReviewingCapture {
                VStack(spacing: 8) {
                    if !postError.isEmpty {
                        Text(postError)
                            .font(.caption)
                            .foregroundStyle(AppTheme.errorRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    captureReviewActions
                }
            } else {
                // Direction hints — visible only while dragging & not yet recording
                if isDragging && !isHolding && !camera.isLocked {
                    directionHints
                }
                shutterButton
                    .highPriorityGesture(shutterGesture)
            }
        }
        .frame(height: 100)
    }

    /// Centered post control: **tap** = post, **drag left** = retake, **drag right** = save to Photos.
    private var captureReviewActions: some View {
        let disabled = isPosting
            || camera.isProcessingVideo
            || (camera.capturedImage == nil && camera.capturedVideoURL == nil)

        return ZStack {
            HStack {
                reviewSwipeHint(
                    title: "Retake",
                    systemImage: "arrow.uturn.backward",
                    emphasized: reviewPostTranslation.width < -18
                )
                Spacer(minLength: 0)
                reviewSwipeHint(
                    title: "Save",
                    systemImage: "square.and.arrow.down",
                    emphasized: reviewPostTranslation.width > 18
                )
            }
            .padding(.horizontal, 8)
            .opacity(disabled ? 0.35 : 1)

            reviewPostControlGroup(disabled: disabled)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: reviewPostOffsetX)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .highPriorityGesture(reviewPostGesture(disabled: disabled))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Post. Drag left to retake, drag right to save to library, tap to post.")
    }

    private var reviewPostOffsetX: CGFloat {
        let t = reviewPostTranslation.width
        let rubber: CGFloat = 0.45
        let maxOffset: CGFloat = 44
        return max(-maxOffset, min(maxOffset, t * rubber))
    }

    private func shouldRunReviewPostIdleAnimation(disabled: Bool) -> Bool {
        !disabled && !isPosting
    }

    @ViewBuilder
    private func reviewPostControlGroup(disabled: Bool) -> some View {
        if shouldRunReviewPostIdleAnimation(disabled: disabled) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let nudge = reviewPostIdleNudge(t: t)
                let scale = reviewPostIdleOrDragScale(t: t)
                reviewPostCircle(disabled: disabled)
                    .offset(x: reviewPostOffsetX + nudge)
                    .scaleEffect(scale)
            }
        } else {
            reviewPostCircle(disabled: disabled)
                .offset(x: reviewPostOffsetX)
                .scaleEffect(isDraggingReviewPost ? 1.05 : 1)
        }
    }

    private func reviewPostIdleNudge(t: TimeInterval) -> CGFloat {
        if isDraggingReviewPost { return 0 }
        return sin(t * 2.2) * 5.0
    }

    private func reviewPostIdleOrDragScale(t: TimeInterval) -> CGFloat {
        if isDraggingReviewPost {
            let u = min(1, abs(reviewPostOffsetX) / 44.0)
            return 1.05 + 0.1 * u
        }
        return 1.0 + 0.06 * (0.5 + 0.5 * sin(t * 1.85 + 0.3))
    }

    private func reviewSwipeHint(title: String, systemImage: String, emphasized: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: emphasized ? 18 : 14, weight: .semibold))
            Text(title)
                .font(.system(size: emphasized ? 11 : 10, weight: .medium))
        }
        .foregroundStyle(emphasized ? AppTheme.cafeAccent : AppTheme.textPrimary.opacity(0.65))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Group {
                if emphasized {
                    Capsule()
                        .fill(AppTheme.cafeAccent.opacity(0.14))
                } else {
                    Color.clear
                }
            }
        )
        .scaleEffect(emphasized ? 1.12 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: emphasized)
    }

    private func reviewPostCircle(disabled: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(AppTheme.accentAction.opacity(isPosting ? 0.4 : 1), lineWidth: 3)
                .frame(width: 70, height: 70)
            Circle()
                .fill(AppTheme.accentAction.opacity((isPosting || camera.isProcessingVideo || disabled) ? 0.45 : 1))
                .frame(width: 56, height: 56)
            if isPosting {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.title2).bold()
                    .foregroundStyle(.white)
            }
        }
    }

    private func reviewPostGesture(disabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !disabled else { return }
                if !isDraggingReviewPost {
                    isDraggingReviewPost = true
                }
                reviewPostTranslation = value.translation
            }
            .onEnded { value in
                guard !disabled else {
                    isDraggingReviewPost = false
                    reviewPostTranslation = .zero
                    return
                }
                let t = value.translation
                let commit: CGFloat = 72
                let tapMax: CGFloat = 22

                defer {
                    isDraggingReviewPost = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        reviewPostTranslation = .zero
                    }
                }

                let ax = abs(t.width), ay = abs(t.height)
                if ax < tapMax && ay < tapMax {
                    Task { await postFromCapture() }
                    return
                }
                guard ax >= ay, ax >= commit else { return }
                if t.width < -commit {
                    retakeFromReview()
                } else if t.width > commit {
                    saveCaptureToPhotoLibrary()
                }
            }
    }

    // MARK: - Direction hints

    private var directionHints: some View {
        ZStack {
            hint(dir: .up,    icon: "rectangle.stack.person.crop.fill", label: "Feed")
                .offset(y: -62)
            hint(dir: .down,  icon: "camera.rotate.fill",               label: "Flip")
                .offset(y:  62)
            hint(dir: .left,  icon: "photo.on.rectangle",               label: "Library")
                .offset(x: -84)
            hint(dir: .right, icon: "lock.fill",                        label: "Lock")
                .offset(x:  84)
        }
    }

    private func hint(dir: DragDir, icon: String, label: String) -> some View {
        let op    = hintOpacity(dir)
        let past  = isPastThreshold(dir)
        return VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.subheadline).bold()
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(past ? AppTheme.cafeAccent : .white)
        .opacity(op)
        .animation(.easeOut(duration: 0.1), value: op)
    }

    // MARK: - Shutter button

    private var shutterButton: some View {
        ZStack {
            // Progress ring (recording)
            Circle()
                .trim(from: 0, to: camera.recordingProgress)
                .stroke(
                    camera.isLocked ? AppTheme.cafeAccent : Color.red,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 84, height: 84)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.05), value: camera.recordingProgress)

            // Outer ring
            Circle()
                .stroke(ringColor, lineWidth: 3)
                .frame(width: 70, height: 70)

            // Inner fill
            Circle()
                .fill(fillColor)
                .frame(width: 60, height: 60)

            // Icon overlay
            if camera.isLocked {
                Image(systemName: "lock.fill")
                    .font(.title3).bold()
                    .foregroundStyle(.white)
            } else if isHolding || camera.isRecording {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
            }
        }
        .scaleEffect(isDragging ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.5), value: isDragging)
    }

    private var ringColor: Color {
        if camera.isLocked    { return AppTheme.cafeAccent }
        if camera.isRecording { return .red }
        return .white.opacity(0.85)
    }

    private var fillColor: Color {
        if camera.isLocked    { return AppTheme.cafeAccent.opacity(0.3) }
        if camera.isRecording { return Color.red.opacity(0.3) }
        return Color.white.opacity(0.15)
    }

    // MARK: - Gesture

    private var shutterGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                translation = value.translation

                guard !isDragging else { return }
                isDragging = true

                // If locked recording, any touch will stop it on release —
                // don't start another hold timer.
                guard !camera.isLocked else { return }

                holdTask = Task {
                    try? await Task.sleep(for: .seconds(0.35))
                    guard !Task.isCancelled else { return }
                    let t = translation
                    if abs(t.width) < 20 && abs(t.height) < 20 {
                        await MainActor.run {
                            isHolding = true
                            camera.startRecording()
                            HeroShutterHaptics.recordStart()
                        }
                    }
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                holdTask = nil

                let t    = value.translation
                let tiny = abs(t.width) < 30 && abs(t.height) < 30

                defer {
                    isDragging  = false
                    isHolding   = false
                    translation = .zero
                }

                // Tap on locked button → stop
                if camera.isLocked {
                    HeroShutterHaptics.recordStop()
                    camera.stopRecording()
                    return
                }

                // Release during hold recording → stop
                if camera.isRecording {
                    HeroShutterHaptics.recordStop()
                    camera.stopRecording()
                    return
                }

                // Tap (no movement) → photo
                if tiny {
                    HeroShutterHaptics.photoShutter()
                    camera.capture()
                    return
                }

                // Directional commit (> 80pt in dominant axis)
                switch dominantDir(t) {
                case .left:
                    HeroShutterHaptics.openPhotoLibrary()
                    showPhotosPicker = true
                case .right:
                    HeroShutterHaptics.lockRecordingMode()
                    camera.lockRecording()
                case .down:
                    HeroShutterHaptics.flipCamera()
                    camera.switchCamera()
                case .up:
                    HeroShutterHaptics.scrollToFeed()
                    scrollToFeedFromCamera()
                case nil:
                    HeroShutterHaptics.photoShutter()
                    camera.capture()
                }
            }
    }

    // MARK: - Gesture helpers

    private func magnitude(for dir: DragDir) -> CGFloat {
        switch dir {
        case .left:  return max(0, -translation.width)
        case .right: return max(0,  translation.width)
        case .up:    return max(0, -translation.height)
        case .down:  return max(0,  translation.height)
        }
    }

    private func hintOpacity(_ dir: DragDir) -> Double {
        Double(max(0, min(1, (magnitude(for: dir) - 20) / 60)))
    }

    private func isPastThreshold(_ dir: DragDir) -> Bool {
        magnitude(for: dir) > 80
    }

    /// Returns nil when translation is too small to commit.
    private func dominantDir(_ t: CGSize) -> DragDir? {
        let threshold: CGFloat = 80
        let ax = abs(t.width), ay = abs(t.height)
        guard max(ax, ay) >= threshold else { return nil }
        if ax > ay { return t.width  < 0 ? .left  : .right }
        else        { return t.height < 0 ? .up    : .down  }
    }

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

private struct FeedPostCard: View {
    let post: FriendPost
    let index: Int
    @ObservedObject var socialService: SocialService
    /// Only the page aligned with the vertical pager should play; keeps off-screen and background posts silent.
    let isVideoActive: Bool
    var onPlaceTap: (String) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if post.mediaURL.isEmpty {
                    deletedMediaPlaceholder
                } else if post.isVideo, let u = URL(string: post.mediaURL) {
                    SquareVideoFillView(url: u, isPlaying: isVideoActive)
                } else if let u = URL(string: post.mediaURL) {
                    CachedAsyncImage(url: u) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        case .failure: deletedMediaPlaceholder
                        case .empty: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default: Color.gray.opacity(0.2)
                        }
                    }
                } else {
                    deletedMediaPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if !post.caption.isEmpty || post.placeName != nil {
                VStack(spacing: 6) {
                    if let placeName = post.placeName, let placeId = post.placeId {
                        Button {
                            onPlaceTap(placeId)
                        } label: {
                            placePill(name: placeName)
                        }
                        .buttonStyle(.plain)
                    }
                    if !post.caption.isEmpty {
                        captionPill
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    private func placePill(name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "mappin.circle.fill")
                .font(.caption).bold()
            Text(name)
                .font(.footnote).bold()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 2)
        )
        .padding(.horizontal, 20)
    }

    private var captionPill: some View {
        Text(post.caption)
            .font(.subheadline).bold()
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 2)
            )
            .padding(.horizontal, 20)
    }

    private var deletedMediaPlaceholder: some View {
        ZStack {
            AppTheme.gradient(for: .cafe, index: index)
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .symbolVariant(.slash)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityHidden(true)
                Text("Media unavailable")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct FeedPostReactions: View {
    let post: FriendPost
    @ObservedObject var socialService: SocialService
    @ObservedObject var conversationService: ConversationService
    var onBurst: (String) -> Void = { _ in }

    @State private var myEmoji: String?
    @State private var showEmojiPicker = false

    private let reactionOptions = ["❤️", "🔥", "😂", "👏"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(reactionOptions, id: \.self) { e in
                Button {
                    Task { @MainActor in
                        await onTapReaction(e)
                    }
                } label: {
                    Text(e)
                        .font(.title2)
                        .padding(6)
                        .background((myEmoji == e) ? AppTheme.cafeAccent.opacity(0.2) : Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React with \(e)")
            }

            Button {
                showEmojiPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.callout).bold()
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
        }
        .frame(minHeight: 64)
        .task(id: post.id) {
            myEmoji = await socialService.myReactionEmoji(for: post)
        }
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerSheet(myEmoji: myEmoji) { e in
                Task { @MainActor in
                    await onTapReaction(e)
                }
            }
            .presentationDetents([.fraction(0.55)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
    }

    @MainActor
    private func onTapReaction(_ e: String) async {
        if myEmoji == e {
            try? await socialService.removeReaction(from: post)
            myEmoji = nil
            return
        }
        do {
            try await socialService.react(to: post, emoji: e)
            myEmoji = e
            onBurst(e)
            // Mirror the reaction into the 1:1 chat between the reactor and
            // the post author so the author sees it in their inbox alongside
            // direct messages. Self-reactions are skipped inside the service.
            do {
                // For videos use the thumbnail URL since `mediaURL` is the
                // .mp4. For images both fields are absent and `mediaURL`
                // is the rendered image — same effect.
                let media = post.isVideo
                    ? (post.thumbnailURL ?? post.mediaURL)
                    : post.mediaURL
                try await conversationService.mirrorReaction(
                    toAuthor: post.authorId,
                    emoji: e,
                    postId: post.id,
                    postPreview: post.caption,
                    postMediaURL: media,
                    postIsVideo: post.isVideo
                )
            } catch {
                print("[FeedPostReactions] reaction mirror failed: \(error)")
            }
        } catch { }
    }
}

// MARK: - Reply trigger pill (in-feed)

/// Liquid-glass pill that lives inline with the post. It does NOT host a
/// real TextField — tapping it opens the dedicated ReplyComposerOverlay.
/// This keeps the feed page itself out of the keyboard's hair.
private struct ReplyTriggerPill: View {
    let draftPreview: String
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(draftPreview.isEmpty ? "Send a message" : draftPreview)
                    .font(.subheadline)
                    .foregroundStyle(draftPreview.isEmpty
                                     ? Color.white.opacity(0.7)
                                     : Color.white)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "paperplane.fill")
                    .font(.footnote).bold()
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(
                .regular.tint(Color.white.opacity(0.08)),
                in: Capsule(style: .continuous)
            )
            .liquidGlassShine(in: Capsule(style: .continuous), strength: 0.85)
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.55),
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.30),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Reply composer overlay

/// Full-screen overlay that hosts the actual TextField. The dark backdrop
/// signals "reply mode"; tapping it dismisses without losing the draft.
///
/// We drive the keyboard lift manually via NotificationCenter — SwiftUI's
/// automatic safe-area avoidance doesn't reach into nested `.overlay`
/// content reliably, so the input bar stayed pinned to the bottom of the
/// screen while the keyboard slid up over it. With the manual observer +
/// a spring animation, the bar travels in lock-step with the keyboard.
///
/// On send, the input bar swooshes diagonally toward `messageButtonOrigin`
/// (the screen-space center of the top-right Messages HUD) so the user
/// sees their reply land in the inbox. On tap-away dismiss, the keyboard
/// hides first and the bar springs down with it before the overlay fades.
private struct ReplyComposerOverlay: View {
    let post: FriendPost
    let messageButtonOrigin: CGPoint
    /// Screen-space frame of the in-feed pill. Used as the input bar's
    /// idle anchor so when the keyboard is down the bar sits on top of
    /// the pill exactly — and the cross-fade reads as one object.
    let pillFrame: CGRect
    @Binding var draft: String
    var onSend: () async throws -> Void
    var onClose: () -> Void
    var onSendComplete: () -> Void

    @FocusState private var focused: Bool
    @State private var isSending = false
    @State private var sendError: String?
    @State private var keyboardLift: CGFloat = 0
    /// Captured ONCE on first appear, before the keyboard pops up. On
    /// iOS 26 `safeAreaInsets.bottom` flips to the keyboard frame the
    /// moment `keyboardWillShow` fires, so reading it inside the
    /// notification handler returns the wrong value.
    @State private var homeIndicator: CGFloat = 34
    @State private var sentFlying = false
    @State private var dismissingAfterClose = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Dimmed backdrop. The keyboard sits on top; tapping
                // anywhere else dismisses the composer.
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { handleClose() }

                VStack(spacing: 6) {
                    if let err = sendError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(AppTheme.errorRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                    }
                    inputBar
                }
                .frame(width: max(geo.size.width - 32, 0))
                .position(x: geo.size.width / 2, y: anchorY(in: geo))
                .scaleEffect(sentFlying ? 0.12 : 1.0, anchor: .center)
                .offset(
                    x: sentFlying ? swooshOffsetX(in: geo) : 0,
                    y: sentFlying ? swooshOffsetY(in: geo) : 0
                )
                .opacity(sentFlying ? 0 : 1)
                .animation(.spring(response: 0.48, dampingFraction: 0.82),
                           value: keyboardLift)
                .animation(.spring(response: 0.55, dampingFraction: 0.78),
                           value: sentFlying)
            }
            // Disable SwiftUI's auto avoidance — we drive the lift
            // ourselves so we get a single, spring-tuned motion.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onAppear {
                homeIndicator = geo.safeAreaInsets.bottom
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    focused = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard
                let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
            else { return }
            keyboardLift = max(0, frame.cgRectValue.height - homeIndicator)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardLift = 0
        }
    }

    /// The input bar's anchor Y. With the keyboard hidden it sits exactly
    /// where the in-feed pill is (so the cross-fade looks like a morph).
    /// With the keyboard up it floats just above the keyboard's top edge.
    private func anchorY(in geo: GeometryProxy) -> CGFloat {
        if keyboardLift > 0 {
            // Above keyboard, with a small breathing-room margin.
            return geo.size.height - keyboardLift - 8 - estimatedBarHalfHeight
        }
        // Idle: lock onto pill's center if we have it, else fall back
        // to a sensible bottom-anchored position.
        if pillFrame.height > 0 {
            return pillFrame.midY
        }
        return geo.size.height - homeIndicator - 8 - estimatedBarHalfHeight
    }

    private var estimatedBarHalfHeight: CGFloat { 25 }

    /// Horizontal flight offset = where the messages button is, minus
    /// the bar's resting center (which is at screen midX).
    private func swooshOffsetX(in geo: GeometryProxy) -> CGFloat {
        messageButtonOrigin.x - geo.size.width / 2
    }

    /// Vertical flight offset = messages button Y minus the bar's
    /// current anchor Y (which is where it actually sits when sending).
    private func swooshOffsetY(in geo: GeometryProxy) -> CGFloat {
        messageButtonOrigin.y - anchorY(in: geo)
    }

    /// Tap-away dismiss. Resigns the keyboard so the bar can spring back
    /// to the pill's resting position in lock-step with the keyboard
    /// slide-down, then tells the parent to fade the overlay.
    private func handleClose() {
        guard !dismissingAfterClose else { return }
        dismissingAfterClose = true
        focused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            onClose()
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text("Send a message")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .allowsHitTesting(false)
                }
                // Single-line on purpose — Return submits, doesn't add a
                // newline. Both the keyboard's return key and the
                // paperplane button hit the same trySend path.
                TextField("", text: $draft)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { Task { await trySend() } }
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
            }

            Button {
                Task { await trySend() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.subheadline).bold()
                    .foregroundStyle(canSend
                                     ? .white
                                     : Color.white.opacity(0.45))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend || isSending)
            .accessibilityLabel("Send reply")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(
            .regular.tint(Color.white.opacity(0.10)),
            in: Capsule(style: .continuous)
        )
        .liquidGlassShine(in: Capsule(style: .continuous), strength: 1.0)
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.70),
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.35),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.30), radius: 18, y: 6)
    }

    private func trySend() async {
        guard canSend, !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            try await onSend()
            // Trigger the swoosh AFTER the message has actually landed,
            // so we never claim success on a failed send.
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                sentFlying = true
            }
            // Wait for the swoosh to land, then tear the overlay down
            // without a transition (the swoosh did the visual work).
            try? await Task.sleep(for: .milliseconds(430))
            onSendComplete()
        } catch {
            print("[ReplyComposerOverlay] reply mirror failed: \(error)")
            withAnimation(.easeInOut(duration: 0.18)) {
                sendError = error.localizedDescription
            }
        }
    }
}

// MARK: - Emoji picker sheet

private struct EmojiPickerSheet: View {
    var myEmoji: String?
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            // Handle + title row
            HStack {
                Text("React")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close emoji picker")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()
                .opacity(0.4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(NotoEmojiLottie.catalog, id: \.slug) { item in
                        Button {
                            onSelect(item.emoji)
                            dismiss()
                        } label: {
                            NotoEmojiLottieView(
                                notoSlug: item.slug,
                                fallbackEmoji: item.emoji,
                                size: 36,
                                loop: true
                            )
                            .frame(width: 50, height: 50)
                            .background(
                                myEmoji == item.emoji
                                    ? AppTheme.cafeAccent.opacity(0.28)
                                    : Color.white.opacity(0.06)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        myEmoji == item.emoji
                                            ? AppTheme.cafeAccent.opacity(0.7)
                                            : Color.clear,
                                        lineWidth: 1.5
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - Feed moderation modifier

/// Hosts the report-content sheet + block-user confirmation alert for the
/// Hero feed. Extracted from HeroPageView.body because attaching both
/// modifiers inline tipped the SwiftUI type-checker over its complexity
/// limit ("the compiler is unable to type-check this expression in
/// reasonable time"). Same behaviour, different attachment surface.
private struct FeedModerationModifier: ViewModifier {
    @Binding var reportTarget: ReportTarget?
    @Binding var pendingBlockUid: String?
    let pendingBlockTitle: String
    @ObservedObject var socialService: SocialService

    func body(content: Content) -> some View {
        content
            .alert(
                "Block \(pendingBlockTitle)?",
                isPresented: Binding(
                    get: { pendingBlockUid != nil },
                    set: { if !$0 { pendingBlockUid = nil } }
                ),
                presenting: pendingBlockUid
            ) { uid in
                Button("Cancel", role: .cancel) { pendingBlockUid = nil }
                Button("Block", role: .destructive) {
                    Task {
                        try? await socialService.blockUser(uid: uid)
                        pendingBlockUid = nil
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
    }
}

// MARK: - Animated wave text

/// Renders each character of `text` with a left-to-right sine-wave vertical jitter,
/// driven by a TimelineView so the animation is smooth and clock-independent.
private struct AnimatedWaveText: View {
    let text: String
    let font: Font

    private let amplitude: CGFloat = 3.2   // max vertical travel in points
    private let period: Double     = 0.9   // seconds per full cycle
    private let phasePerChar: Double = 0.18  // wave phase offset between adjacent chars

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { idx, char in
                    Text(String(char))
                        .font(font)
                        .foregroundStyle(.white)
                        .offset(y: yOffset(t: t, index: idx))
                }
            }
        }
    }

    /// Wave travels left → right: earlier characters lead; later ones follow.
    private func yOffset(t: Double, index: Int) -> CGFloat {
        amplitude * CGFloat(sin((t / period - Double(index) * phasePerChar) * .pi * 2))
    }
}

