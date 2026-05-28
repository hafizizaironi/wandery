import SwiftUI
import UIKit
import AVFoundation

// MARK: - Camera mode
//
// The redesigned camera surfaces every action explicitly (iOS-camera
// vocabulary) instead of overloading one gesture. Photo vs video is now a
// visible MODE rather than tap-vs-hold.

enum HeroCameraMode: String, CaseIterable, Identifiable {
    case polaroid
    case video

    var id: String { rawValue }
    var title: String {
        switch self {
        case .polaroid: return "Polaroid"
        case .video:    return "Video"
        }
    }
}

// MARK: - Control stack (replaces the old ShutterControl in `shutterArea`)

/// The bottom control block of the camera page: top rail (flash · timer),
/// zoom dial, mode swiper, and the library · shutter · flip row, plus the
/// "pull for feed" hint. Chrome-only — it sits in the cream area beneath the
/// square viewfinder and drives `CameraService` directly. Actions that aren't
/// camera-intrinsic (open library, scroll to feed) are delegated to the host.
struct HeroCameraControlStack: View {
    @Bindable var camera: CameraService
    @Binding var mode: HeroCameraMode
    var libraryImages: [UIImage]
    var onTapLibrary: () -> Void
    var onScrollToFeed: () -> Void

    private var isVideo: Bool { mode == .video }
    private var isRecording: Bool { camera.isRecording || camera.isLocked }

    // NOTE: flash and the zoom dial are NOT in this stack — they overlay the
    // viewfinder square (flash top-centre, zoom bottom-centre) so this stack
    // stays short and the square keeps its full size. See `viewfinder(side:)`.
    var body: some View {
        VStack(spacing: 12) {
            HeroModeSwiper(mode: $mode)

            HeroShutterRow(
                isVideo: isVideo,
                isRecording: isRecording,
                isLocked: camera.isLocked,
                recordingProgress: camera.recordingProgress,
                libraryImages: libraryImages,
                onTapLibrary: onTapLibrary,
                onTapShutter: onTapShutter,
                onLongPressShutter: onLongPressShutter,
                onTapFlip: {
                    HeroShutterHaptics.flipCamera()
                    camera.switchCamera()
                },
                onTapLock: {
                    HeroShutterHaptics.lockRecordingMode()
                    camera.lockRecording()
                }
            )
            .padding(.horizontal, 28)

            HeroFeedHint(onTap: onScrollToFeed)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Shutter behaviour (mode-routed)

    private func onTapShutter() {
        switch mode {
        case .polaroid:
            HeroShutterHaptics.photoShutter()
            camera.capture()
        case .video:
            if isRecording {
                HeroShutterHaptics.recordStop()
                camera.stopRecording()
            } else {
                HeroShutterHaptics.recordStart()
                camera.startRecording()
            }
        }
    }

    /// Long-press in Polaroid mode kicks off a quick recording — the one bit of
    /// gesture muscle memory worth keeping from the old shutter.
    private func onLongPressShutter() {
        guard mode == .polaroid, !isRecording else { return }
        HeroShutterHaptics.recordStart()
        camera.startRecording()
    }
}

// MARK: - Flash button (overlays the viewfinder, top-centre)

struct HeroFlashButton: View {
    @Binding var flashMode: AVCaptureDevice.FlashMode
    /// Dimmed/disabled when the current camera can't flash (front camera in Video mode).
    var enabled: Bool = true

    var body: some View {
        let isOn = flashMode != .off
        Button {
            flashMode = isOn ? .off : .on
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(isOn ? "FLASH ON" : "FLASH")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? .black : .white.opacity(0.92))
            .background(
                Capsule()
                    .fill(isOn ? Color.white.opacity(0.92) : Color.black.opacity(0.45))
                    .overlay(Capsule().stroke(.white.opacity(isOn ? 0 : 0.18), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .accessibilityLabel(isOn ? "Flash on" : "Flash off")
    }
}

// MARK: - Recording timer (overlays the viewfinder top while recording)

struct HeroRecordingTimer: View {
    let elapsed: TimeInterval
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.white).frame(width: 7, height: 7)
            Text(formatted)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(isLocked ? AppTheme.cafeAccent : Color.red))
    }

    private var formatted: String {
        let m = Int(elapsed) / 60
        let s = Int(elapsed) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Zoom dial (collapsed chips ↔ scrubbable curved wheel)

struct HeroZoomDial: View {
    @Binding var zoom: CGFloat
    var minZoom: CGFloat
    var maxZoom: CGFloat
    var showsHalf: Bool
    var onZoomChange: (CGFloat) -> Void

    @State private var expanded = false
    @State private var idleTask: Task<Void, Never>?
    @State private var dragStartZoom: CGFloat = 1.0
    @State private var isDragging = false
    @State private var lastSnapped: CGFloat = 0

    private let dialWidth: CGFloat = 280
    private let dialHeight: CGFloat = 56
    private let snapTolerance: CGFloat = 0.06

    // Arc geometry — the virtual wheel pivot sits well below the visible pill so
    // the top of the wheel curves gently across the dial.
    private let arcRadius: CGFloat = 360
    private let arcSpanDeg: CGFloat = 110
    private let visibleHalfDeg: CGFloat = 32

    private var allSnaps: [CGFloat] { [0.5, 1.0, 2.0].filter { $0 >= minZoom - 0.001 } }
    private var presetChips: [CGFloat] {
        var v: [CGFloat] = []
        if showsHalf { v.append(0.5) }
        v.append(1.0)
        if maxZoom >= 2 { v.append(2.0) }
        return v
    }

    private var minL: CGFloat { log(minZoom) }
    private var maxL: CGFloat { log(maxZoom) }
    private var t: CGFloat { (maxL - minL) <= 0 ? 0 : (log(zoom) - minL) / (maxL - minL) }

    var body: some View {
        ZStack {
            if expanded {
                expandedDial
                    .transition(.scale(scale: 0.75).combined(with: .opacity))
            } else {
                collapsedChips
                    .transition(.opacity)
            }
        }
        .frame(height: dialHeight)
        // One drag gesture for both states: a horizontal drag expands the dial
        // and scrubs; a plain tap (no movement) falls through to the chip
        // buttons below, which just set the zoom + tick (no scale shown).
        .highPriorityGesture(scrubGesture)
    }

    // MARK: collapsed — preset chips

    private var collapsedChips: some View {
        HStack(spacing: 10) {
            ForEach(presetChips, id: \.self) { preset in
                let active = abs(zoom - preset) < snapTolerance
                Button {
                    setZoomSnapped(preset)
                    HeroShutterHaptics.selection()
                } label: {
                    Text(active ? formatZoom(zoom) : label(for: preset))
                        .font(.system(size: active ? 11.5 : 10, weight: .bold))
                        .foregroundStyle(active ? AppTheme.cafeAccent : .white.opacity(0.92))
                        .frame(width: active ? 38 : 30, height: active ? 38 : 30)
                        .background(
                            Circle()
                                .fill(active ? Color.white.opacity(0.92) : Color.black.opacity(0.5))
                                .overlay(Circle().stroke(.white.opacity(active ? 0 : 0.18), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: expanded — curved dial

    private var expandedDial: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 100, style: .continuous)
                .fill(.black.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 100, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1))
                .frame(width: dialWidth + 40, height: dialHeight)
                .background(.ultraThinMaterial.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 100, style: .continuous))

            ZStack {
                ForEach(arcTicks) { tick in tickView(tick) }
                ForEach(arcLabels, id: \.value) { lbl in labelView(lbl) }
            }
            .frame(width: dialWidth + 40, height: dialHeight)
            .clipShape(RoundedRectangle(cornerRadius: 100, style: .continuous))

            Text(formatZoom(zoom))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(AppTheme.cafeAccent))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .offset(y: -dialHeight / 2 + 16)

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black.opacity(0.55), location: 0.0),
                    .init(color: .clear,               location: 0.18),
                    .init(color: .clear,               location: 0.82),
                    .init(color: .black.opacity(0.55), location: 1.0),
                ]),
                startPoint: .leading, endPoint: .trailing
            )
            .allowsHitTesting(false)
            .frame(width: dialWidth + 40, height: dialHeight)
            .clipShape(RoundedRectangle(cornerRadius: 100, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 100, style: .continuous))
        // Drag handled by the shared `scrubGesture` on the dial's root.
    }

    // MARK: gesture (shared by collapsed + expanded states)

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartZoom = zoom
                    HeroShutterHaptics.selection()   // tick on grab
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) {
                        expanded = true              // bouncy reveal — only on a drag
                    }
                }
                let startT = (maxL - minL) <= 0 ? 0 : (log(dragStartZoom) - minL) / (maxL - minL)
                // Swipe RIGHT lowers the zoom (toward 0.5×); swipe LEFT raises it.
                let nextT = max(0, min(1, startT - value.translation.width / dialWidth))
                setZoomSnapped(exp(minL + nextT * (maxL - minL)))
                bumpIdle()
            }
            .onEnded { _ in
                isDragging = false
                bumpIdle()
            }
    }

    // MARK: arc placement

    private struct ArcTick: Identifiable { let id: Int; let tt: CGFloat; let isMajor: Bool }
    private struct ArcLabel { let value: CGFloat; let tt: CGFloat }

    private var arcTicks: [ArcTick] {
        (0...40).map { i in
            let tt = CGFloat(i) / 40
            let z = exp(minL + tt * (maxL - minL))
            let isMajor = allSnaps.contains { abs(z - $0) < snapTolerance * 2 }
                || abs(z - 4) < 0.15 || abs(z - 8) < 0.3
            return ArcTick(id: i, tt: tt, isMajor: isMajor)
        }
    }
    private var arcLabels: [ArcLabel] {
        (allSnaps + [4, 8]).filter { $0 <= maxZoom + 0.001 }.map {
            ArcLabel(value: $0, tt: (maxL - minL) <= 0 ? 0 : (log($0) - minL) / (maxL - minL))
        }
    }

    private func tickView(_ tick: ArcTick) -> some View {
        let h: CGFloat = tick.isMajor ? 16 : 8
        return placeOnArc(tickT: tick.tt, radius: arcRadius - h / 2) {
            Rectangle()
                .fill(tick.isMajor ? Color.white.opacity(0.92) : Color.white.opacity(0.35))
                .frame(width: 1, height: h)
        }
    }
    private func labelView(_ lbl: ArcLabel) -> some View {
        placeOnArc(tickT: lbl.tt, radius: arcRadius - 14) {
            Text(lbl.value < 1 ? String(format: "%.1f", lbl.value) : "\(Int(lbl.value))×")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize()
        }
    }

    @ViewBuilder
    private func placeOnArc<Content: View>(
        tickT: CGFloat, radius: CGFloat, @ViewBuilder _ content: () -> Content
    ) -> some View {
        let relDeg = (tickT - t) * arcSpanDeg
        let rad = relDeg * .pi / 180
        let dx =  radius * sin(rad)
        let dy = -radius * cos(rad) + radius
        let visible = abs(relDeg) < visibleHalfDeg
        let fade = max(0, 1 - abs(relDeg) / visibleHalfDeg * 0.6)

        content()
            .rotationEffect(.degrees(relDeg))
            .offset(x: dx, y: -dialHeight / 2 + dy)
            .opacity(visible ? fade : 0)
            .allowsHitTesting(false)
            .animation(isDragging ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: zoom)
    }

    // MARK: helpers

    private func setZoomSnapped(_ value: CGFloat) {
        var next = max(minZoom, min(maxZoom, value))
        var landed: CGFloat? = nil
        for sp in allSnaps where abs(next - sp) < snapTolerance { next = sp; landed = sp; break }
        // Tick each time a scrub crosses into a new snap point (0.5 / 1× / 2×).
        if isDragging {
            if let s = landed, s != lastSnapped { HeroShutterHaptics.selection() }
            lastSnapped = landed ?? 0
        }
        onZoomChange(next)
    }

    private func label(for preset: CGFloat) -> String {
        preset < 1 ? String(format: "%.1f", preset) : "\(Int(preset))×"
    }

    private func bumpIdle() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { expanded = false }
            }
        }
    }

    private func formatZoom(_ z: CGFloat) -> String {
        if z < 1 { return String(format: "%.1f", z) }
        if z < 10 && abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))×" }
        return String(format: "%.1f×", z)
    }
}

// MARK: - Mode swiper (Polaroid · Video)

struct HeroModeSwiper: View {
    @Binding var mode: HeroCameraMode

    @State private var dragOffset: CGFloat = 0
    private let stride: CGFloat = 110

    private var modes: [HeroCameraMode] { HeroCameraMode.allCases }

    var body: some View {
        ZStack {
            ForEach(Array(modes.enumerated()), id: \.element.id) { idx, m in
                let activeIdx = modes.firstIndex(of: mode) ?? 0
                let delta = CGFloat(idx - activeIdx)
                Text(m.title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(m == mode ? AppTheme.cafeAccent : .white.opacity(0.55))
                    .offset(x: delta * stride + dragOffset)
                    .opacity(abs(delta) > 1 ? 0.35 : 1)
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: mode)
                    // Tap an inactive label to jump to it.
                    .onTapGesture { if m != mode { select(m) } }
            }

            Circle().fill(AppTheme.cafeAccent).frame(width: 4, height: 4).offset(y: 14)
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Swipe to change modes — high priority so the horizontal drag beats
        // the vertical feed pager underneath.
        .highPriorityGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { dragOffset = $0.translation.width }
                .onEnded { value in
                    let activeIdx = modes.firstIndex(of: mode) ?? 0
                    let shift = -Int((value.translation.width / (stride * 0.55)).rounded())
                    let next = max(0, min(modes.count - 1, activeIdx + shift))
                    if modes[next] != mode { select(modes[next]) }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Camera mode: \(mode.title). Swipe or tap to change.")
    }

    private func select(_ next: HeroCameraMode) {
        HeroShutterHaptics.selection()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { mode = next }
    }
}

// MARK: - Shutter row (library · shutter · flip)

struct HeroShutterRow: View {
    let isVideo: Bool
    let isRecording: Bool
    let isLocked: Bool
    let recordingProgress: Double
    let libraryImages: [UIImage]

    let onTapLibrary: () -> Void
    let onTapShutter: () -> Void
    let onLongPressShutter: () -> Void
    let onTapFlip: () -> Void
    let onTapLock: () -> Void

    var body: some View {
        // Shutter dead-centre (so it lines up with the centred mode strip),
        // with the library + flip pinned to the edges via an overlay HStack —
        // their differing widths no longer pull the shutter off-centre.
        ZStack {
            HeroBigShutter(
                isVideo: isVideo,
                isRecording: isRecording,
                isLocked: isLocked,
                progress: recordingProgress,
                onTap: onTapShutter,
                onLongPress: onLongPressShutter
            )
            if isVideo && isRecording && !isLocked {
                HeroLockPill(action: onTapLock)
                    .offset(y: -62)
                    .transition(.scale.combined(with: .opacity))
            }

            HStack {
                HeroLibraryThumbnail(images: libraryImages, onTap: onTapLibrary)
                Spacer()
                HeroFlipButton(action: onTapFlip)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isVideo)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isRecording)
    }
}

// MARK: - Library thumbnail
//
// NOTE: AppTheme.cream is a DARK ink colour, so the polaroid backing here uses
// a light surface with dark label (the reference's cream-on-black was wrong).

struct HeroLibraryThumbnail: View {
    /// Most-recent library photos (front-most first). Empty = placeholder.
    let images: [UIImage]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Recent shots fan out behind the front polaroid card.
                if images.count > 2 {
                    backCard(images[2]).rotationEffect(.degrees(7)).offset(x: 6, y: 3)
                }
                if images.count > 1 {
                    backCard(images[1]).rotationEffect(.degrees(-6)).offset(x: -5, y: 1)
                }
                frontCard
            }
            .shadow(color: .black.opacity(0.45), radius: 8, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open photo library")
    }

    private func backCard(_ img: UIImage) -> some View {
        Image(uiImage: img)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 46, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 1.5))
    }

    private var frontCard: some View {
        VStack(spacing: 3) {
            ZStack {
                if let first = images.first {
                    Image(uiImage: first).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color(hue: 0.08, saturation: 0.5, brightness: 0.48),
                                 Color(hue: 0.05, saturation: 0.5, brightness: 0.26)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: 44, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

            Text("LIBRARY")
                .font(.system(size: 7, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(.black.opacity(0.7))
        }
        .padding(4)
        .frame(width: 52, height: 60)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .rotationEffect(.degrees(-3))
    }
}

// MARK: - Big shutter

struct HeroBigShutter: View {
    let isVideo: Bool
    let isRecording: Bool
    let isLocked: Bool
    let progress: Double
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var recordPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recordTint: Color { isLocked ? AppTheme.cafeAccent : Color.red }

    var body: some View {
        ZStack {
            // Thin progress sweep — leads while recording.
            if isRecording {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(recordTint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 82, height: 82)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.05), value: progress)
            }

            // Outer ring — dims while recording so the indicator reads as the focus.
            Circle()
                .stroke(.white.opacity(isRecording ? 0.4 : 0.95), lineWidth: 3.5)
                .frame(width: 78, height: 78)
                .animation(.easeOut(duration: 0.25), value: isRecording)

            // Inner indicator: white disc (Polaroid) · red disc (Video idle) ·
            // small glowing, gently pulsing rounded-square (recording).
            Group {
                if isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(recordTint)
                        .frame(width: 28, height: 28)
                        .scaleEffect(reduceMotion ? 1 : (recordPulse ? 0.82 : 1.0))
                        .shadow(color: recordTint.opacity(0.6), radius: 8)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                                recordPulse = true
                            }
                        }
                        .onDisappear { recordPulse = false }
                } else if isVideo {
                    Circle().fill(Color.red).frame(width: 60, height: 60)
                } else {
                    Circle().fill(.white).frame(width: 64, height: 64)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isRecording)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isVideo)
        }
        .contentShape(Circle())
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in onLongPress() }
                .simultaneously(with: TapGesture().onEnded { onTap() })
        )
        .accessibilityLabel(isRecording ? "Stop recording" : (isVideo ? "Start recording" : "Take photo"))
    }
}

// MARK: - Flip button

struct HeroFlipButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black.opacity(0.45))
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Flip camera")
    }
}

// MARK: - Lock pill (only while recording video)

struct HeroLockPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                Text("LOCK").font(.system(size: 10, weight: .bold)).tracking(1.2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(AppTheme.cafeAccent))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Lock recording (hands-free)")
    }
}

// MARK: - Pull-for-feed hint

struct HeroFeedHint: View {
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                Text("PULL FOR FEED").font(.system(size: 9, weight: .bold)).tracking(1.4)
            }
            .foregroundStyle(.white.opacity(0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show feed")
    }
}
