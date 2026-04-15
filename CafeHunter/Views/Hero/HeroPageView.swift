import SwiftUI
import PhotosUI

// MARK: - Layout

private enum HeroLayout {
    /// Clearance needed so content sits just above the arc's home-button peak.
    static func bottomChromeHeight(safeBottom: CGFloat) -> CGFloat {
        safeBottom + ArcNavBar.homeButtonFromBottom + 60  // 40pt gap between shutter and home button
    }

    static let horizontalPadding: CGFloat = 8
}

// MARK: - Drag direction

private enum DragDir { case up, down, left, right }

// MARK: - Hero page

struct HeroPageView: View {
    var isActive: Bool = false
    @State private var camera = CameraService()

    // Shutter gesture state
    @State private var isDragging     = false
    @State private var isHolding      = false   // hold timer fired → recording
    @State private var translation    = CGSize.zero
    @State private var holdTask: Task<Void, Never>?

    // Mode state
    @State private var showFeed         = false
    @State private var showPhotosPicker = false
    @State private var selectedPhoto: PhotosPickerItem?

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                GeometryReader { geo in
                    ZStack {
                        cameraContent(geometry: geo)
                            .offset(y: showFeed ? -geo.size.height : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: showFeed)

                        if showFeed {
                            FriendsFeedView(
                                onClose: { withAnimation { showFeed = false } },
                                bottomChromeHeight: HeroLayout.bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
                            )
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom),
                                removal:   .move(edge: .bottom)
                            ))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                permissionDeniedUI
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
    }

    // MARK: - Camera content

    private func cameraContent(geometry geo: GeometryProxy) -> some View {
        let bottomChrome = HeroLayout.bottomChromeHeight(safeBottom: geo.safeAreaInsets.bottom)
        let pad = HeroLayout.horizontalPadding
        let usableW = max(0, geo.size.width - pad * 2)
        // Layout is bottom-anchored: shutter sits just above navbar, preview sits just above shutter.
        let shutterH: CGFloat = 100
        let spacing:  CGFloat = 60
        let availableH = geo.size.height - geo.safeAreaInsets.top - bottomChrome - shutterH - spacing
        let side = max(120, min(usableW, availableH))

        return VStack(spacing: spacing) {
            viewfinder(side: side)
            shutterArea
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomChrome)
    }

    // MARK: - Viewfinder

    private func viewfinder(side: CGFloat) -> some View {
        CameraPreviewView(session: camera.session, isRunning: camera.isSessionRunning)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.red.opacity(camera.isRecording ? 0.7 : 0), lineWidth: 2)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: camera.isRecording)
            )
    }

    // MARK: - Shutter area (button + directional hints)

    private var shutterArea: some View {
        ZStack {
            // Direction hints — visible only while dragging & not yet recording
            if isDragging && !isHolding && !camera.isLocked {
                directionHints
            }

            // Shutter button
            shutterButton
                .gesture(shutterGesture)
        }
        .frame(height: 100)
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
                        isHolding = true
                        camera.startRecording()
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
                    camera.stopRecording()
                    return
                }

                // Release during hold recording → stop
                if camera.isRecording {
                    camera.stopRecording()
                    return
                }

                // Tap (no movement) → photo
                if tiny {
                    camera.capture()
                    return
                }

                // Directional commit (> 80pt in dominant axis)
                switch dominantDir(t) {
                case .left:  showPhotosPicker = true
                case .right: camera.lockRecording()
                case .down:  camera.switchCamera()
                case .up:    withAnimation { showFeed = true }
                case nil:    camera.capture()
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
            Image(systemName: "camera.slash")
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
                    .foregroundColor(AppTheme.espresso)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(AppTheme.cafeAccent)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Friends feed

private struct FriendsFeedView: View {
    let onClose: () -> Void
    /// Matches `HeroLayout.bottomChromeHeight` so post cards sit in the same vertical band as the camera square.
    var bottomChromeHeight: CGFloat = ArcNavBar.frameContentHeight

    @State private var currentIndex = 0
    @State private var dragOffset: CGFloat = 0

    private let posts: [(handle: String, caption: String, isStall: Bool)] = [
        ("@nina_cafehop",  "Morning latte run ☕",          false),
        ("@akmal_lemang",  "Night market hidden gem 🌙",    true),
        ("@sarah_brew",    "Hidden corner, best vibes",     false),
        ("@zafran_eats",   "Teh tarik season is here 🍵",  true),
        ("@lina_wanders",  "Rooftop cold brew sunset",      false),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.espresso.ignoresSafeArea()

            GeometryReader { geo in
                let topInset = geo.safeAreaInsets.top
                let post = posts[currentIndex]
                VStack(spacing: 0) {
                    VStack(spacing: 32) {
                        FeedPostCard(
                            handle: post.handle,
                            caption: post.caption,
                            isStall: post.isStall,
                            index: currentIndex
                        )
                        .padding(.horizontal, HeroLayout.horizontalPadding)
                        .offset(y: dragOffset)
                        Color.clear.frame(height: 100)
                    }
                    VStack(spacing: 4) {
                        Image(systemName: currentIndex < posts.count - 1 ? "chevron.up" : "checkmark")
                            .font(.system(size: 12, weight: .medium))
                        Text(currentIndex < posts.count - 1 ? "swipe up for next" : "you're all caught up")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(AppTheme.cream.opacity(0.3))
                    .padding(.bottom, 10)
                    Spacer(minLength: 0)
                }
                .padding(.top, topInset + 8)
                .padding(.bottom, bottomChromeHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // Top bar — overlays the same layout so the square post aligns with the camera square band.
            HStack {
                Button {
                    onClose()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Camera")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(AppTheme.cream.opacity(0.7))
                }
                Spacer()
                Text("Friends")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(AppTheme.cream)
                Spacer()
                Text("\(currentIndex + 1) / \(posts.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.cream.opacity(0.4))
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)
            .padding(.bottom, 12)
        }
        .gesture(
            DragGesture()
                .onChanged { v in
                    dragOffset = v.translation.height * 0.4 // resist drag
                }
                .onEnded { v in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        dragOffset = 0
                    }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                        if v.translation.height < -60 {
                            currentIndex = min(posts.count - 1, currentIndex + 1)
                        } else if v.translation.height > 60 {
                            if currentIndex == 0 { onClose() }
                            else { currentIndex = max(0, currentIndex - 1) }
                        }
                    }
                }
        )
    }
}

private struct FeedPostCard: View {
    let handle: String
    let caption: String
    let isStall: Bool
    let index: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppTheme.gradient(for: isStall ? .stall : .cafe, index: index))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppTheme.cream.opacity(0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(handle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.cream.opacity(0.85))
                Text(caption)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.cream)
            }
            .padding(20)
        }
    }
}
