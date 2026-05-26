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


// MARK: - Hero page

struct HeroPageView: View {
    var isActive: Bool = false
    var socialService: SocialService
    /// Live inbox snapshot — used to derive the Messages button's unread
    /// dot. Owned by ContentView, passed via MainShellView.
    var conversationService: ConversationService
    /// Two-way binding owned by MainShellView. Set by chat's post-reference
    /// bubble when the user taps it; this view consumes the value by
    /// scrolling to the matching post, then resets the binding to nil so
    /// the same id can fire again later.
    @Binding var pendingPostJumpId: String?
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

    /// Mirror of the system keyboard's visible height. Driven by
    /// `keyboardWillShow / keyboardWillHide` notifications because the
    /// parent chain (MainShellView's GeometryReader) applies
    /// `.ignoresSafeArea()` with no edge filter, which disables
    /// SwiftUI's automatic keyboard avoidance for descendant overlays.
    /// The inline reply composer reads this to lift above the keyboard.
    @State private var keyboardHeight: CGFloat = 0

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
    @State private var librarySelection: [PhotosPickerItem] = []

    // Multi-media draft tray (≤6 mixed photos + one video). Camera captures and
    // library imports accumulate here; the review screen edits the current item.
    @State private var drafts: [MediaDraft] = []
    @State private var currentDraftIndex = 0
    /// True while re-opening the live camera to add another item to a non-empty
    /// tray (so review doesn't cover the viewfinder).
    @State private var isCapturingMore = false
    private let maxDrafts = 6

    // Place tagging
    @State private var pendingPlace: PlaceSelection?
    @State private var showPlacePicker = false

    // Moderation state. Long-press on a feed post surfaces report/block.
    @State private var reportTarget: ReportTarget?
    @State private var pendingBlockUid: String?
    @State private var pendingBlockTitle: String = ""

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
                    // Disable the vertical pager while MainShellView
                    // is interpreting a horizontal edge-swipe as a
                    // page-switch. Otherwise both gestures fight for
                    // ownership of the drag and the page-switch
                    // animation stutters when the user's finger
                    // crosses the Hero region.
                    .scrollDisabled(edgeDragActive)
                    // The composer manages its own keyboard lift via
                    // a manual `.offset(y:)` driven by the
                    // keyboardWillShow/Hide observer — so we still
                    // tell the ScrollView itself to ignore the
                    // keyboard edge (otherwise the WHOLE pager would
                    // shift up when the keyboard appears, breaking
                    // page geometry).
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    // Interactive dismissal: as the user drags the
                    // pager vertically, the keyboard tracks the
                    // gesture and slides off-screen in lock-step. By
                    // the time the next post snaps into view the
                    // keyboard is gone — composer's `keyboardHeight`
                    // observer drops to 0 in sync, so the composer's
                    // `.offset(y:)` lift unwinds back to its resting
                    // position.
                    .scrollDismissesKeyboard(.interactively)
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
        .animation(Motion.iosDrawer(duration: 0.22), value: isReviewingCapture)
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
            appendDraft(.video(url))
            camera.discardCapture()
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
        .onChange(of: heroCardID) { _, _ in
            // Paging away from the current post (to camera, empty
            // feed, or a different post) dismisses any active keyboard
            // so the composer doesn't follow the user into a context
            // where it shouldn't be focused.
            Self.dismissKeyboard()
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
        .onChange(of: pendingPostJumpId) { _, newId in
            guard let postId = newId else { return }
            // Confirm the post is still in the feed (it may have been
            // deleted between the time the chat reference was written
            // and this jump). If missing, fall back to the camera.
            let exists = socialService.feedPosts.contains(where: { $0.id == postId })
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                heroCardID = exists ? .post(postId) : .camera
            }
            // Clear the binding so the same id can fire again later.
            pendingPostJumpId = nil
        }
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
    /// the composer pill.
    private static func dismissKeyboard() {
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
        // Flush the current working-copy (caption + place) into its draft.
        syncWorkingCopyToCurrentDraft()
        do {
            try await socialService.uploadAndCreatePost(drafts: drafts)
            clearDraftTray()
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
        postError = ""
        reviewPostTranslation = .zero
        clearDraftTray()
        camera.discardCapture()
        syncCameraSessionForCaptureReview()
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
        guard drafts.indices.contains(index), index != currentDraftIndex else { return }
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
            syncCameraSessionForCaptureReview()
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
            PolaroidFrame(
                username: nil,
                date: nil,
                placeName: nil,
                caption: nil,
                tilt: 0,
                showTape: false,
                photoSide: side
            ) {
                RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                    .fill(AppTheme.surfacePrimary)
                    .overlay {
                        RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                            .stroke(AppTheme.borderSubtle, lineWidth: 1)
                    }
                    .overlay {
                        Text("No posts yet.\nShare a moment from the camera.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(24)
                    }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
            Color.clear
                .frame(height: HeroCameraLayout.shutterAreaHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HeroCameraLayout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomChrome)
    }

    /// Deterministic per-post tilt so each polaroid sits at a slightly
    /// different angle (a scattered-pile look), stable across renders and
    /// launches (FNV-1a over the post id) so cards never jitter on scroll.
    private static func polaroidTilt(for id: String) -> Double {
        var h: UInt64 = 1469598103934665603        // FNV-1a offset basis
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(Int(h % 121)) / 20.0 - 3.0   // -3.0 … +3.0 degrees
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
            PolaroidFrame(
                username: "@\(post.authorUsername)",
                date: post.createdAt,
                placeName: post.placeName,
                caption: post.caption,
                tilt: Self.polaroidTilt(for: post.id),
                photoSide: side
            ) {
                FeedPostCard(
                    post: post,
                    index: index,
                    socialService: socialService,
                    isVideoActive: isVideoActive,
                    onPlaceTap: { placeId in onJumpToPlace(placeId) },
                    hideOverlays: true
                )
            }
            // Photo stays full `side`; the cream frame bleeds past this square
            // slot. Slot size is unchanged, so the composer below doesn't move.
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
            // Long-press surfaces moderation actions — App Store
            // Guideline 1.2 requires report + block affordances on
            // user-generated content. Hidden for your own posts.
            .contextMenu {
                if post.authorId != myUid {
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
                } else if post.discoverable {
                    // Own post that the classifier marked safe — let
                    // the author retract it from Discover without
                    // deleting the post. Sets discoverable=false; the
                    // post stays visible to friends.
                    Button(role: .destructive) {
                        Task {
                            try? await socialService.setDiscoverable(postId: post.id, false)
                        }
                    } label: {
                        Label("Hide from Discover", systemImage: "eye.slash")
                    }
                }
            }

            // Below-card area: composer pinned to the bottom of this
            // 160pt zone (just above the navbar arc / bottomChrome),
            // with a Color.clear above it filling the leftover space.
            // By living *inside* the post page (not as a body overlay),
            // the composer pages vertically with the post — same scroll
            // animation as the image card itself, no separate
            // transition needed.
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
                Self.dismissKeyboard()
            }
        }
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
        PolaroidFrame(
            username: "@\(socialService.profile?.username ?? "you")",
            date: Date(),
            photoSide: side
        ) {
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
        } topLeading: {
            placeTagPill
        } bottomCenter: {
            captionPillBody
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity)
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
                VStack(spacing: 6) {
                    if !postError.isEmpty {
                        Text(postError)
                            .font(.caption)
                            .foregroundStyle(AppTheme.errorRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    if drafts.count > 1 || drafts.count < maxDrafts {
                        draftFilmstrip
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
            || drafts.isEmpty

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

    // MARK: - Draft filmstrip

    private var draftFilmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                    draftThumb(draft, index: index)
                }
                if drafts.count < maxDrafts {
                    Menu {
                        Button { isCapturingMore = true } label: {
                            Label("Camera", systemImage: "camera")
                        }
                        Button { showPhotosPicker = true } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        addDraftCell
                    }
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
    var socialService: SocialService
    /// Only the page aligned with the vertical pager should play; keeps off-screen and background posts silent.
    let isVideoActive: Bool
    var onPlaceTap: (String) -> Void = { _ in }
    /// When wrapped by PolaroidFrame, the frame owns the place/caption pills
    /// and the photo border, so suppress this card's internal ones.
    var hideOverlays: Bool = false

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

            if !hideOverlays, !post.caption.isEmpty || post.placeName != nil {
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
            if !hideOverlays {
                RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            }
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
        .liquidGlassChrome(in: Capsule())
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
            .liquidGlassChrome(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
    var socialService: SocialService

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

