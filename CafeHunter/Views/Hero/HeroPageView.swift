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
    @ObservedObject var socialService: SocialService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = CameraService()

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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                permissionDeniedUI
            }

            // Full-screen reaction burst – sits above everything
            if let em = reactionBurstEmoji {
                fullScreenBurstOverlay(em)
            }
        }
        .photosPicker(isPresented: $showPhotosPicker,
                      selection: $selectedPhoto,
                      matching: .images)
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
        .onChange(of: socialService.feedPosts.map(\.id)) { _, ids in
            guard let current = heroCardID else { return }
            switch current {
            case .post(let id) where !ids.contains(id):
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    heroCardID = .camera
                }
            case .emptyFeed where !ids.isEmpty:
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    heroCardID = .post(ids[0])
                }
            default:
                break
            }
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
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.easeIn(duration: 0.36)) {
                burstOffsetY = -700
            }
            try? await Task.sleep(nanoseconds: 380_000_000)
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
        postError = ""
        isPosting = true
        defer { isPosting = false }
        do {
            try await socialService.uploadAndCreatePost(
                image: camera.capturedImage,
                videoURL: camera.capturedVideoURL,
                caption: previewCaption
            )
            previewCaption = ""
            reviewPostTranslation = .zero
            camera.discardCapture()
            syncCameraSessionForCaptureReview()
        } catch {
            postError = error.localizedDescription
        }
    }

    private func retakeFromReview() {
        previewCaption = ""
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
                .overlay(
                    RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                )
                .frame(width: side, height: side)
                .overlay(
                    Text("No posts yet.\nShare a moment from the camera.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                )
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.cream.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                FeedPostCard(post: post, index: index, socialService: socialService, isVideoActive: isVideoActive)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous))
            }

            // Reactions + comment hug the card; Spacer fills leftover space above navbar.
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    FeedPostReactions(post: post, socialService: socialService, onBurst: triggerFullScreenBurst)
                    FeedCommentBox(post: post)
                }
                .padding(.top, 14)

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
                    .overlay(
                        RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                            .stroke(Color.red.opacity(camera.isRecording ? 0.7 : 0), lineWidth: 2)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                       value: camera.isRecording)
                    )
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

            HStack(alignment: .bottom) {
                Spacer(minLength: 0)
                // Invisible Text drives pill width; overlays render visual + input.
                Text(previewCaption.isEmpty ? "whats on your mind☺️?" : previewCaption)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.clear)
                    .fixedSize()
                    .overlay {
                        if previewCaption.isEmpty {
                            Text("whats on your mind☺️?")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.55))
                                .allowsHitTesting(false)
                        } else {
                            AnimatedWaveText(text: previewCaption,
                                            font: .system(size: 15, weight: .semibold))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        TextField("", text: $previewCaption)
                            .font(.system(size: 15, weight: .semibold))
                            .tint(.white)
                            .foregroundColor(.clear)
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.sentences)
                            .focused($captionFocused)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") { captionFocused = false }
                                        .fontWeight(.semibold)
                                        .foregroundColor(AppTheme.cafeAccent)
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
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .overlay {
            if camera.isProcessingVideo {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.15)
            }
        }
    }

    /// Rear only: **1** ↔ **0.5** (smooth zoom on supported devices).
    private var lensToggleButton: some View {
        Button {
            camera.toggleLens()
        } label: {
            Text(lensToggleLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
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
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.errorRed)
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
        .foregroundColor(emphasized ? AppTheme.cafeAccent : AppTheme.textPrimary.opacity(0.65))
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
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
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
                .font(.system(size: 15, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(past ? AppTheme.cafeAccent : .white)
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
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
                .foregroundColor(AppTheme.cream.opacity(0.5))
            Text("Camera Access Needed")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(AppTheme.cream)
            Text("Allow camera access so you can share cafe moments.")
                .font(.system(size: 14))
                .foregroundColor(AppTheme.cream.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textOnAccent)
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

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if post.mediaURL.isEmpty {
                    deletedMediaPlaceholder
                } else if post.isVideo, let u = URL(string: post.mediaURL) {
                    SquareVideoFillView(url: u, isPlaying: isVideoActive)
                } else if let u = URL(string: post.mediaURL) {
                    AsyncImage(url: u) { phase in
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

            if !post.caption.isEmpty {
                captionPill
                    .padding(.bottom, 16)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: HeroCameraLayout.viewfinderCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var captionPill: some View {
        Text(post.caption)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
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
                    .foregroundColor(.white.opacity(0.5))
                Text("Media unavailable")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

private struct FeedPostReactions: View {
    let post: FriendPost
    @ObservedObject var socialService: SocialService
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
                        .font(.system(size: 24))
                        .padding(6)
                        .background((myEmoji == e) ? AppTheme.cafeAccent.opacity(0.2) : Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Button {
                showEmojiPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
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
        } catch { }
    }
}

private struct FeedCommentBox: View {
    let post: FriendPost

    var body: some View {
        HStack(spacing: 10) {
            Text("Add a comment...")
                .font(.system(size: 14))
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Image(systemName: "paperplane")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.surfacePrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                )
        )
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
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        myEmoji == item.emoji
                                            ? AppTheme.cafeAccent.opacity(0.7)
                                            : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
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
                        .foregroundColor(.white)
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

