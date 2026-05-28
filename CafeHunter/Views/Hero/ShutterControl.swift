import SwiftUI
import UIKit

// MARK: - Shutter directions

/// The four directional commits available from the shutter — drag past the
/// threshold and release: Library (←), Lock (→), Feed (↑), Flip (↓).
enum ShutterDirection { case up, down, left, right }

// MARK: - Shutter haptics

enum HeroShutterHaptics {
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

    /// Light "tick" for zoom-chip taps, snap crossings, and mode changes.
    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }
}

// MARK: - Shutter control

/// Self-contained capture control for the Hero camera. Owns the gesture state
/// machine that maps a single drag onto five actions:
///
///   • **tap**          → photo
///   • **hold** (still) → record video (release to stop; drag-right to lock)
///   • **drag** ← → ↑ ↓ → Library / Lock / Feed / Flip
///
/// `CameraService` stays the source of truth for the recording itself
/// (`isRecording` / `isLocked` / `recordingProgress`); this view only tracks
/// the *touch* via `Phase`. Camera-intrinsic actions are sent straight to the
/// service; the two that aren't (open library, scroll to feed) are delegated
/// to the host. A first-run coach overlay surfaces the otherwise-hidden drag
/// directions.
struct ShutterControl: View {
    var camera: CameraService
    var onOpenLibrary: () -> Void
    var onScrollToFeed: () -> Void

    /// Touch phase. Recording truth lives on `camera`; this is just the finger.
    private enum Phase: Equatable {
        case idle       // no touch
        case arming     // finger down — deciding tap vs hold vs direction
        case recording  // hold fired → recording; release stops
    }

    @State private var phase: Phase = .idle
    @State private var translation: CGSize = .zero
    @State private var holdTask: Task<Void, Never>?
    @State private var coachPulse = false
    @AppStorage("shutter.hasSeenGuide") private var hasSeenGuide = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Tunables.
    private let holdDelay: Duration = .seconds(0.35)
    private let holdMoveSlop: CGFloat = 20   // movement that cancels a hold
    private let tapSlop: CGFloat = 30        // movement under which a release = tap
    private let directionThreshold: CGFloat = 80

    var body: some View {
        ZStack {
            if showCoach {
                coachOverlay
                    .transition(.opacity)
            }
            // Live directional feedback while arming (replaced by the recording
            // UI once a hold fires or lock engages).
            if phase == .arming, !camera.isLocked {
                directionHints
            }
            shutterButton
                .highPriorityGesture(gesture)
        }
        .animation(.easeOut(duration: 0.2), value: showCoach)
    }

    /// First-run only, and only while idle (live hints/recording take over once
    /// the user actually touches the button).
    private var showCoach: Bool {
        !hasSeenGuide && phase == .idle && !camera.isRecording && !camera.isLocked
    }

    // MARK: - Button

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
            } else if camera.isRecording {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
            }
        }
        .scaleEffect(phase != .idle ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.5), value: phase)
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

    // MARK: - Gesture (state machine)

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                translation = value.translation

                guard phase == .idle else { return }
                phase = .arming
                // First real interaction retires the coach.
                if !hasSeenGuide { hasSeenGuide = true }
                // Warm up the recording path now, during the hold window.
                camera.prepareForRecording()

                // Locked recording: the next release just stops it — no hold
                // timer, no new recording.
                guard !camera.isLocked else { return }

                holdTask = Task { @MainActor in
                    try? await Task.sleep(for: holdDelay)
                    // One suspension only: the checks + startRecording() below
                    // run synchronously after it, so a release on the boundary
                    // can't slip .onEnded in and start a phantom recording.
                    guard !Task.isCancelled, phase == .arming else { return }
                    let t = translation
                    guard abs(t.width) < holdMoveSlop, abs(t.height) < holdMoveSlop else { return }
                    phase = .recording
                    camera.startRecording()
                    HeroShutterHaptics.recordStart()
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                holdTask = nil

                let t = value.translation
                let tiny = abs(t.width) < tapSlop && abs(t.height) < tapSlop

                defer {
                    phase = .idle
                    translation = .zero
                }

                // Release on a locked OR hold recording → stop.
                if camera.isLocked || camera.isRecording {
                    HeroShutterHaptics.recordStop()
                    camera.stopRecording()
                    return
                }

                // Tap → photo (discard the unused warm-up).
                if tiny {
                    camera.discardRecordingPreparation()
                    HeroShutterHaptics.photoShutter()
                    camera.capture()
                    return
                }

                // Directional commit. Lock keeps the warm-up (it's about to
                // record); the rest discard it.
                switch dominantDir(t) {
                case .right:
                    HeroShutterHaptics.lockRecordingMode()
                    camera.lockRecording()
                case .left:
                    camera.discardRecordingPreparation()
                    HeroShutterHaptics.openPhotoLibrary()
                    onOpenLibrary()
                case .down:
                    camera.discardRecordingPreparation()
                    HeroShutterHaptics.flipCamera()
                    camera.switchCamera()
                case .up:
                    camera.discardRecordingPreparation()
                    HeroShutterHaptics.scrollToFeed()
                    onScrollToFeed()
                case nil:
                    camera.discardRecordingPreparation()
                    HeroShutterHaptics.photoShutter()
                    camera.capture()
                }
            }
    }

    // MARK: - Direction hints (live, while arming)

    private var directionHints: some View {
        ZStack {
            hint(.up,    icon: "rectangle.stack.person.crop.fill", label: "Feed").offset(y: -62)
            hint(.down,  icon: "camera.rotate.fill",               label: "Flip").offset(y:  62)
            hint(.left,  icon: "photo.on.rectangle",               label: "Library").offset(x: -84)
            hint(.right, icon: "lock.fill",                        label: "Lock").offset(x:  84)
        }
    }

    private func hint(_ dir: ShutterDirection, icon: String, label: String) -> some View {
        let op = hintOpacity(dir)
        return VStack(spacing: 3) {
            Image(systemName: icon).font(.subheadline).bold()
            Text(label).font(.caption2)
        }
        .foregroundStyle(isPastThreshold(dir) ? AppTheme.cafeAccent : .white)
        .opacity(op)
        .animation(.easeOut(duration: 0.1), value: op)
    }

    // MARK: - Coach overlay (first run)

    private var coachOverlay: some View {
        ZStack {
            coachChip(.up,    icon: "rectangle.stack.person.crop.fill", label: "Feed").offset(y: -64)
            coachChip(.down,  icon: "camera.rotate.fill",               label: "Flip").offset(y:  64)
            coachChip(.left,  icon: "photo.on.rectangle",               label: "Library").offset(x: -90)
            coachChip(.right, icon: "lock.fill",                        label: "Lock").offset(x:  90)
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                coachPulse = true
            }
        }
        .task {
            // Auto-retire if the user never tries the shutter.
            try? await Task.sleep(for: .seconds(6))
            hasSeenGuide = true
        }
    }

    private func coachChip(_ dir: ShutterDirection, icon: String, label: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: chevron(dir)).font(.system(size: 9, weight: .bold))
            Image(systemName: icon).font(.footnote).bold()
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(AppTheme.cafeAccent)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        .scaleEffect(reduceMotion ? 1 : (coachPulse ? 1.06 : 0.96))
    }

    private func chevron(_ dir: ShutterDirection) -> String {
        switch dir {
        case .up:    return "chevron.up"
        case .down:  return "chevron.down"
        case .left:  return "chevron.left"
        case .right: return "chevron.right"
        }
    }

    // MARK: - Gesture helpers

    private func magnitude(for dir: ShutterDirection) -> CGFloat {
        switch dir {
        case .left:  return max(0, -translation.width)
        case .right: return max(0,  translation.width)
        case .up:    return max(0, -translation.height)
        case .down:  return max(0,  translation.height)
        }
    }

    private func hintOpacity(_ dir: ShutterDirection) -> Double {
        Double(max(0, min(1, (magnitude(for: dir) - 20) / 60)))
    }

    private func isPastThreshold(_ dir: ShutterDirection) -> Bool {
        magnitude(for: dir) > directionThreshold
    }

    /// Returns nil when the translation is too small to commit a direction.
    private func dominantDir(_ t: CGSize) -> ShutterDirection? {
        let ax = abs(t.width), ay = abs(t.height)
        guard max(ax, ay) >= directionThreshold else { return nil }
        if ax > ay { return t.width  < 0 ? .left : .right }
        else        { return t.height < 0 ? .up   : .down  }
    }
}
