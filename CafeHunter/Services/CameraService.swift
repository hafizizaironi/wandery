import AVFoundation
import CoreImage
import Observation
import QuartzCore
import UIKit

/// Rear only: 1× vs 0.5×. Uses virtual dual-wide / triple camera + smooth zoom ramp when available; otherwise swaps ultra-wide vs wide.
enum CameraLensSlot: CaseIterable, Sendable {
    case primary
    case wide
}

extension CameraLensSlot: Equatable {
    nonisolated static func == (lhs: CameraLensSlot, rhs: CameraLensSlot) -> Bool {
        switch (lhs, rhs) {
        case (.primary, .primary), (.wide, .wide): return true
        default: return false
        }
    }
}

@Observable
final class CameraService: NSObject {

    // MARK: - Observable state

    var isAuthorized    = false
    /// Drives SwiftUI preview refresh after `startRunning()` / `stopRunning()` (session object identity is unchanged).
    var isSessionRunning = false
    var capturedImage: UIImage?
    /// Set when video recording finishes successfully (preview + upload); square export when possible.
    var capturedVideoURL: URL?
    /// True while square video export runs after recording (preview shows a spinner).
    var isProcessingVideo = false
    var isRecording     = false
    var isLocked        = false          // recording continues without holding
    var recordingProgress: Double = 0   // 0 → 1 over maxDuration seconds
    var currentPosition: AVCaptureDevice.Position = .back
    /// Rear: 1× vs 0.5× (virtual zoom ramp or physical lens).
    var lensSlot: CameraLensSlot = .primary
    /// Displayed zoom factor shown on the dial (0.5–8×). The dial reads and
    /// writes this; `setZoom(displayed:)` maps it to the device's
    /// `videoZoomFactor`. Reset to 1× on camera flip.
    var displayedZoom: CGFloat = 1.0
    /// Photo flash + video torch. `.off` default. Drives `AVCapturePhotoSettings.flashMode`
    /// in `capture()` and the device torch while recording.
    var flashMode: AVCaptureDevice.FlashMode = .off

    // MARK: - Session

    let session = AVCaptureSession()

    private let photoOutput  = AVCapturePhotoOutput()
    private let movieOutput  = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.cafehunter.camera.session")
    private var currentInput: AVCaptureDeviceInput?
    /// Added on `startRecording`, removed in the file-output delegate. Keeping it off the
    /// capture session outside recording prevents iOS from putting connected Bluetooth
    /// audio devices into HFP call mode.
    private var audioInput: AVCaptureDeviceInput?

    private var progressTask: Task<Void, Never>?
    private var videoExportTask: Task<Void, Never>?
    private var pendingRawVideoURL: URL?
    private let maxDuration: TimeInterval = 5
    /// Set by `prepareForRecording()` on shutter touch-down. When true,
    /// `startRecording()` skips the (already-applied) video connection config
    /// so the start path only has to add audio + roll the file — shaving the
    /// device-lock + stabilization work off the moment recording begins.
    private var recordingConfigPrepared = false
    /// Cancels in-flight linear zoom steps when the user toggles again.
    private var zoomRampGeneration: UInt = 0

    /// Incremented just before a physical lens swap so `CameraPreviewView` can apply a crossfade transition.
    var lensSwitchToken: Int = 0

    // MARK: - Live aesthetic scoring (viewfinder ring)

    /// On-device aesthetic score (0…1) of the current viewfinder frame, or
    /// `nil` when scoring is disabled / not yet computed. Uses the *same*
    /// Vision model and `PostClassifier.aestheticFloor` the Discover gate runs
    /// at publish time, so the live ring predicts the eventual verdict.
    /// Published on the main actor ~2.5×/sec; drives `HeroAestheticIndicator`.
    private(set) var liveAestheticScore: Double?

    /// Frame tap for live scoring. Added in `configureSession` only when the
    /// hardware allows a 3rd output beside the photo/movie outputs — guarded so
    /// it can never disturb the capture path.
    @ObservationIgnored private let videoDataOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let videoDataQueue = DispatchQueue(label: "com.cafehunter.camera.framescore", qos: .utility)
    /// Reused across frames so we don't spin up a new GPU context per tick.
    /// Low request priority keeps it from competing with the live preview.
    /// `let` (not lazy) so `nonisolated` is valid; CIContext is thread-safe after init.
    @ObservationIgnored nonisolated private let frameScoreContext = CIContext(options: [.priorityRequestLow: true])
    /// The next three are touched ONLY on `videoDataQueue` (serial) — no locks.
    /// nonisolated(unsafe) lets the nonisolated AVCapture delegate access them.
    @ObservationIgnored nonisolated(unsafe) private var liveScoringEnabled = false
    @ObservationIgnored nonisolated(unsafe) private var isScoringInFlight = false
    @ObservationIgnored nonisolated(unsafe) private var lastScoredAt: CFTimeInterval = 0
    /// Min seconds between scored frames. ~2.5 Hz feels live while keeping the
    /// Neural Engine load (and thermals) low; single-flight prevents pile-ups.
    @ObservationIgnored private let scoreThrottle: CFTimeInterval = 0.4

    /// Rear only: 0.5 / 1 toggle when ultra-wide exists or a virtual wide + ultra-wide camera supports zoom.
    var hasLensToggleForCurrentCamera: Bool {
        currentPosition == .back && Self.rearHasHalfWideCapability
    }

    /// Displayed-zoom floor for the live camera. 0.5× is only reachable
    /// *continuously* on a virtual rear camera (dual-wide / triple); front and
    /// non-virtual devices floor at 1.0 (digital zoom only). MainActor-safe:
    /// reads `currentPosition` + a static device-discovery check (no `currentInput`).
    var minDisplayedZoom: CGFloat {
        (currentPosition == .back && Self.backVirtualDevice() != nil) ? 0.5 : 1.0
    }
    /// UI ceiling for the zoom dial. The actual `videoZoomFactor` is additionally
    /// clamped to the device's real max inside `setZoom(displayed:)`.
    var maxDisplayedZoom: CGFloat { 8.0 }
    /// Whether the dial should offer a 0.5× chip.
    var supportsHalfZoom: Bool { minDisplayedZoom < 1.0 }
    /// Torch only exists on the rear camera (front has no flash). Used to dim
    /// the flash control in Video mode. MainActor-safe (no `currentInput` read).
    var hasTorchForCurrentCamera: Bool { currentPosition == .back }

    func toggleLens() {
        print("[Camera] toggleLens: hasToggle=\(hasLensToggleForCurrentCamera) currentSlot=\(lensSlot) position=\(currentPosition.rawValue)")
        guard hasLensToggleForCurrentCamera else { return }
        setLensSlot(lensSlot == .primary ? .wide : .primary)
    }

    // MARK: - Authorization

    func requestAccess() async {
        for mediaType: AVMediaType in [.video, .audio] {
            if AVCaptureDevice.authorizationStatus(for: mediaType) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: mediaType)
            }
        }
        isAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard isAuthorized else { return }
        let slotSnapshot = lensSlot
        DispatchQueue.main.async { [weak self] in
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }

                let wasRunning = self.session.isRunning

                if self.session.inputs.isEmpty {
                    self.configureSession()
                }
                if !wasRunning {
                    self.session.startRunning()
                    self.applyRearZoom(slot: slotSnapshot, animated: false, effectivePosition: .back)
                }

                let running = self.session.isRunning
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isSessionRunning = running
                    if !wasRunning {
                        self.resetExposureTargetBiasToDefault()
                    }
                }
            }
        }
    }

    /// Clears preview state and removes temporary video file if any.
    func discardCapture() {
        videoExportTask?.cancel()
        videoExportTask = nil
        if let raw = pendingRawVideoURL {
            try? FileManager.default.removeItem(at: raw)
            pendingRawVideoURL = nil
        }
        if let url = capturedVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        capturedVideoURL = nil
        capturedImage = nil
        isProcessingVideo = false
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if session.isRunning {
                session.stopRunning()
            }
            DispatchQueue.main.async { [weak self] in
                self?.isSessionRunning = false
            }
        }
    }

    // MARK: - Live aesthetic scoring control

    /// Enable/disable the live aesthetic-score tap. Driven by the camera UI:
    /// on only while the viewfinder is visible in photo mode (never during
    /// video recording or capture review — those modes don't turn it on).
    /// Disabling clears the published score so the ring fades out.
    func setLiveAestheticScoring(enabled: Bool) {
        videoDataQueue.async { [weak self] in
            guard let self else { return }
            self.liveScoringEnabled = enabled
            if !enabled { self.lastScoredAt = 0 }
        }
        if !enabled {
            Task { @MainActor in self.liveAestheticScore = nil }
        }
    }

    // MARK: - Photo

    func capture() {
        capturedVideoURL = nil

        #if targetEnvironment(simulator)
        deliverBlankCapturePlaceholder()
        #else
        guard session.isRunning else { return }
        sessionQueue.sync { self.applyVideoMirroringToOutputs() }

        guard hasReadyPhotoVideoConnection else {
            deliverBlankCapturePlaceholder()
            return
        }

        let settings = AVCapturePhotoSettings()
        if #available(iOS 16.0, *) {
            let maxDim = photoOutput.maxPhotoDimensions
            if maxDim.width > 0, maxDim.height > 0 {
                settings.maxPhotoDimensions = maxDim
            }
        }
        // Apply flash only if the active output/device supports the chosen mode
        // (front cameras report only `.off`).
        if photoOutput.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
        #endif
    }

    /// Simulator and other no-camera paths: still image so review / upload flows can run.
    private var hasReadyPhotoVideoConnection: Bool {
        guard let conn = photoOutput.connection(with: .video) else { return false }
        return conn.isEnabled && conn.isActive
    }

    private func deliverBlankCapturePlaceholder() {
        let image = Self.blankCapturePlaceholder()
        Task { @MainActor in
            self.capturedImage = image
        }
    }

    private static func blankCapturePlaceholder() -> UIImage {
        let side: CGFloat = 1080
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { ctx in
            UIColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .medium),
                .foregroundColor: UIColor(white: 0.55, alpha: 1),
                .paragraphStyle: paragraph,
            ]
            let text = "Simulator\n(no camera)" as NSString
            let bounds = text.boundingRect(
                with: CGSize(width: side - 80, height: 200),
                options: [.usesLineFragmentOrigin],
                attributes: attrs,
                context: nil
            )
            text.draw(
                in: CGRect(
                    x: (side - bounds.width) / 2,
                    y: (side - bounds.height) / 2,
                    width: bounds.width,
                    height: bounds.height
                ),
                withAttributes: attrs
            )
        }
    }

    // MARK: - Video

    func startRecording() {
        #if targetEnvironment(simulator)
        return
        #else
        guard session.isRunning, !isRecording else { return }
        capturedImage = nil
        capturedVideoURL = nil

        // Activate audio session before adding the input so iOS doesn't briefly
        // negotiate the wrong category. Failure is non-fatal (recording still
        // captures video); we only log in debug.
        do {
            try AppAudioSession.activateForRecording()
        } catch {
            #if DEBUG
            print("[Camera] activateForRecording failed: \(error.localizedDescription)")
            #endif
        }

        let prepared = recordingConfigPrepared
        sessionQueue.sync { [weak self] in
            guard let self else { return }
            self.addAudioInputIfNeeded()
            // Skip the connection config if a touch-down warm-up already ran
            // it (the serial queue guarantees that block finished before this
            // one). Falls back to applying inline for any non-warmed caller.
            if !prepared {
                self.applyVideoMirroringToOutputs()
                self.reapplyDeviceRecordingFrameDuration()
                self.applyVideoStabilization()
            }
        }
        recordingConfigPrepared = false
        // Light the torch for the duration if flash is on (no-op on front / no-torch).
        applyTorch(on: flashMode != .off)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mov")
        movieOutput.maxRecordedDuration = CMTime(seconds: maxDuration,
                                                  preferredTimescale: 600)
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true

        let start = Date()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                recordingProgress = min(1.0, elapsed / maxDuration)
                if elapsed >= maxDuration { stopRecording(); break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        #endif
    }

    func stopRecording() {
        guard isRecording else { return }
        progressTask?.cancel()
        progressTask = nil
        movieOutput.stopRecording()
        applyTorch(on: false)
        isRecording      = false
        isLocked         = false
        recordingProgress = 0
    }

    /// Starts recording and keeps it running after the button is released.
    func lockRecording() {
        isLocked = true
        startRecording()
    }

    /// Front-runs the recording connection config on shutter touch-down, so the
    /// device-lock / frame-rate / stabilization work happens during the
    /// hold-to-record window instead of at the instant recording starts.
    /// Idempotent and cheap; the matching `startRecording()` consumes it.
    func prepareForRecording() {
        #if !targetEnvironment(simulator)
        guard session.isRunning, !isRecording else { return }
        recordingConfigPrepared = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyVideoMirroringToOutputs()
            self.reapplyDeviceRecordingFrameDuration()
            self.applyVideoStabilization()
        }
        #endif
    }

    /// Touch ended without recording (tap / library / flip / feed). Invalidate
    /// the warm-up so the next touch — or a camera flip — re-applies fresh
    /// config. The already-applied connection settings are harmless to leave.
    func discardRecordingPreparation() {
        recordingConfigPrepared = false
    }

    // MARK: - Continuous zoom

    /// Set the camera to a DISPLAYED zoom factor (the 0.5–8× the user sees on
    /// the dial). Maps to `videoZoomFactor` via `displayed * oneXVideoZoom` —
    /// the same endpoints `applyRearZoom` uses — then clamps to the device's
    /// real range. Called from the dial on the main actor; the device write
    /// runs on `sessionQueue`. Bumps `zoomRampGeneration` so a stale lens-toggle
    /// ramp can't fight the scrub.
    func setZoom(displayed: CGFloat) {
        let clamped = min(max(displayed, minDisplayedZoom), maxDisplayedZoom)
        displayedZoom = clamped
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            let oneX = Self.oneXVideoZoom(for: device)
            let zf = min(max(clamped * oneX, device.minAvailableVideoZoomFactor),
                         device.maxAvailableVideoZoomFactor)
            self.zoomRampGeneration += 1
            device.cancelVideoZoomRamp()
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = zf
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Turn the device torch on/off for video recording. No-op on cameras
    /// without a torch (front camera, flash-less hardware).
    private func applyTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device,
                  device.hasTorch, device.isTorchAvailable else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Camera flip

    func switchCamera() {
        // The new device needs its own recording config, so drop any warm-up
        // that targeted the old one.
        recordingConfigPrepared = false
        // A rolling torch belongs to the old device; kill it before the swap,
        // and reset the dial to 1× so it doesn't show a stale zoom for the new camera.
        applyTorch(on: false)
        displayedZoom = 1.0
        let newPos: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        let slot = lensSlot
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let d = currentInput?.device {
                d.cancelVideoZoomRamp()
            }
            session.beginConfiguration()
            if let cur = currentInput { session.removeInput(cur) }

            var outLensSlot = slot
            if newPos == .front {
                outLensSlot = .primary
            } else {
                if Self.ultraWideDevice(for: .back) == nil, slot == .wide, Self.backVirtualDevice() == nil {
                    outLensSlot = .primary
                }
            }

            if let device = Self.videoDevice(position: newPos, lensSlot: outLensSlot),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                Self.applyHD60VideoRecordingSettings(device: device, session: session)
            } else if let device = Self.videoDevice(position: newPos, lensSlot: .primary),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                outLensSlot = .primary
                Self.applyHD60VideoRecordingSettings(device: device, session: session)
            }

            session.commitConfiguration()
            applyVideoMirroringToOutputs()
            applyVideoStabilization()
            let lensForMainActor = outLensSlot
            applyRearZoom(slot: lensForMainActor, animated: false, effectivePosition: newPos)
            Task { @MainActor in
                self.currentPosition = newPos
                self.lensSlot = lensForMainActor
            }
        }
    }

    func setLensSlot(_ slot: CameraLensSlot) {
        print("[Camera] setLensSlot: requested=\(slot) current=\(lensSlot) rearHasHalf=\(Self.rearHasHalfWideCapability) isVirtual=\(Self.isVirtualRearCamera(currentInput?.device))")
        guard slot != lensSlot else { print("[Camera] setLensSlot: already at slot, skipping"); return }
        if slot == .wide, !Self.rearHasHalfWideCapability { print("[Camera] setLensSlot: no wide capability, skipping"); return }
        lensSlot = slot
        let positionSnapshot = currentPosition
        let isVirtual = Self.isVirtualRearCamera(currentInput?.device)
        // Increment token before dispatching so SwiftUI updates CameraPreviewView
        // (which adds a CATransition) before the session queue runs the physical swap.
        if !isVirtual {
            lensSwitchToken += 1
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard positionSnapshot == .back else { return }
            if isVirtual {
                self.applyRearZoom(slot: slot, animated: true, effectivePosition: .back)
            } else {
                self.reconfigureVideoInput()
            }
        }
    }

    // MARK: - Private setup

    private func configureSession() {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            applyVideoMirroringToOutputs()
        }
        session.sessionPreset = .hd1920x1080

        if lensSlot == .wide, !Self.rearHasHalfWideCapability {
            Task { @MainActor in self.lensSlot = .primary }
        }

        let effectiveSlot: CameraLensSlot
        if Self.backVirtualDevice() != nil {
            effectiveSlot = .primary
        } else {
            effectiveSlot = (lensSlot == .wide && Self.ultraWideDevice(for: .back) != nil) ? .wide : .primary
            if lensSlot == .wide, effectiveSlot == .primary {
                Task { @MainActor in self.lensSlot = .primary }
            }
        }

        guard let device = Self.videoDevice(position: .back, lensSlot: effectiveSlot),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }

        print("[Camera] configureSession: device=\(device.deviceType.rawValue) slot=\(effectiveSlot)")
        print("[Camera] configureSession: virtualDevice=\(String(describing: Self.backVirtualDevice()?.deviceType.rawValue))")
        print("[Camera] configureSession: virtualSwitchFactors=\(device.virtualDeviceSwitchOverVideoZoomFactors) minZoom=\(device.minAvailableVideoZoomFactor) maxZoom=\(device.maxAvailableVideoZoomFactor)")
        print("[Camera] configureSession: rearHasHalfWide=\(Self.rearHasHalfWideCapability)")

        session.addInput(input)
        currentInput = input

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        // Live frame tap for the aesthetic-score ring (photo mode only). Guarded
        // by `canAddOutput` so if the device won't allow a video-data output
        // alongside the movie file output, live scoring just stays unavailable —
        // the photo/video capture path is never affected.
        if session.canAddOutput(videoDataOutput) {
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
            session.addOutput(videoDataOutput)
        }

        // Audio input is added lazily in `startRecording` and removed when the file
        // output finishes. See `audioInput` declaration for the BT-HFP rationale.

        Self.applyHD60VideoRecordingSettings(device: device, session: session)
        applyVideoStabilization()

        // Zoom is applied in `startSession` after `startRunning()` so fused devices honor factors.
    }

    /// 1080p-class HD at 60 fps when the hardware supports it; falls back to `hd1920x1080` preset + 60 fps frame duration.
    private static func applyHD60VideoRecordingSettings(device: AVCaptureDevice, session: AVCaptureSession) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if let format = preferredFormat1080p60fps(on: device) {
                session.sessionPreset = .inputPriority
                device.activeFormat = format
            } else {
                session.sessionPreset = .hd1920x1080
            }

            // Clamp to what the (now-active) format supports — front cameras that
            // don't expose a 60 fps 1080p format would otherwise crash here.
            let duration = supportedFrameDuration(maxFPS: 60, for: device.activeFormat)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            session.sessionPreset = .hd1920x1080
        }
    }

    /// Picks a full HD format that advertises 60 fps in its supported frame-rate range.
    private static func preferredFormat1080p60fps(on device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            let is1080p = (w == 1920 && h == 1080) || (w == 1080 && h == 1920)
            guard is1080p else { continue }
            let supports60 = format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= 60 && range.maxFrameRate >= 60
            }
            if supports60 { return format }
        }
        return nil
    }

    /// The fastest constant frame duration ≤ `target` fps that `format` actually
    /// advertises. Front cameras (and many formats) top out at 30 fps; assigning
    /// an unsupported `activeVideoMin/MaxFrameDuration` raises an *uncaught*
    /// `NSInvalidArgumentException` — an ObjC exception that Swift `do/catch` can't
    /// trap — which is exactly the selfie-record crash. Always clamp to a value
    /// the active format supports.
    private static func supportedFrameDuration(maxFPS target: Double,
                                               for format: AVCaptureDevice.Format) -> CMTime {
        let ranges = format.videoSupportedFrameRateRanges
        // If some range brackets the target, lock to a clean 1/target duration.
        if ranges.contains(where: { $0.minFrameRate <= target && target <= $0.maxFrameRate }) {
            return CMTime(value: 1, timescale: CMTimeScale(target.rounded()))
        }
        // Otherwise use the fastest duration the format genuinely advertises
        // (its smallest `minFrameDuration`), which is always valid to assign.
        let fastest = ranges.min {
            CMTimeGetSeconds($0.minFrameDuration) < CMTimeGetSeconds($1.minFrameDuration)
        }
        return fastest?.minFrameDuration ?? CMTime(value: 1, timescale: 30)
    }

    /// Add the audio capture input. Call from `sessionQueue`.
    private func addAudioInputIfNeeded() {
        guard audioInput == nil else { return }
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        session.commitConfiguration()
    }

    /// Remove the audio capture input. Call from `sessionQueue` after the file output finishes.
    private func removeAudioInput() {
        guard let input = audioInput else { return }
        session.beginConfiguration()
        session.removeInput(input)
        session.commitConfiguration()
        audioInput = nil
    }

    /// Mirror front-camera stills/video so the capture matches the mirrored
    /// "feels like a mirror" preview (a selfie shouldn't flip on snap). The
    /// rear camera stays unmirrored. Must run on `sessionQueue`.
    private func applyVideoMirroringToOutputs() {
        let mirror = currentInput?.device.position == .front
        for output in [photoOutput as AVCaptureOutput, movieOutput] {
            guard let c = output.connection(with: .video), c.isVideoMirroringSupported else { continue }
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirror
        }
    }

    /// iOS removed frame-rate APIs on `AVCaptureConnection`; match capture rate on the device instead.
    /// Targets 60 fps but clamps to the active format's real ceiling (the front camera commonly
    /// caps at 30) — forcing an unsupported duration raises an uncaught NSException.
    private func reapplyDeviceRecordingFrameDuration() {
        guard let device = currentInput?.device else { return }
        let duration = Self.supportedFrameDuration(maxFPS: 60, for: device.activeFormat)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {}
    }

    /// Turn on the strongest video stabilization the *current* camera's active
    /// format supports, on the movie-recording connection. Front and rear
    /// formats advertise different modes (front cameras typically top out at
    /// `.standard`, rear wide/virtual cameras support `.cinematicExtended`), so
    /// we probe the active format and fall down the list. Re-applied on every
    /// input / format change because the connection's capabilities follow the
    /// device. Setting an unsupported mode is a no-op, so `.auto` is a safe
    /// floor. Call from `sessionQueue`.
    private func applyVideoStabilization() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let format = currentInput?.device.activeFormat
        let preferred: [AVCaptureVideoStabilizationMode] = [.cinematicExtended, .cinematic, .standard]
        let chosen = preferred.first { format?.isVideoStabilizationModeSupported($0) == true } ?? .auto
        connection.preferredVideoStabilizationMode = chosen
    }

    /// Uses neutral EV bias (0) so exposure follows automatic metering without a baked-in offset.
    func resetExposureTargetBiasToDefault() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let neutral: Float = 0
                let target = max(device.minExposureTargetBias, min(neutral, device.maxExposureTargetBias))
                device.setExposureTargetBias(target, completionHandler: nil)
            } catch {}
        }
    }

    private func reconfigureVideoInput() {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            applyVideoMirroringToOutputs()
            applyVideoStabilization()
            applyRearZoom(slot: lensSlot, animated: false, effectivePosition: .back)
        }

        if let cur = currentInput {
            cur.device.cancelVideoZoomRamp()
            session.removeInput(cur)
            currentInput = nil
        }

        let slot = lensSlot

        if let device = Self.videoDevice(position: .back, lensSlot: slot),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            Self.applyHD60VideoRecordingSettings(device: device, session: session)
        } else if let device = Self.videoDevice(position: .back, lensSlot: .primary),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            Self.applyHD60VideoRecordingSettings(device: device, session: session)
            Task { @MainActor in self.lensSlot = .primary }
        }
    }

    /// Virtual dual-wide / triple: ramp zoom so 1 ↔ 0.5 feels like continuous zoom. Physical ultra-wide: swap inputs (no ramp).
    /// - Note: Pass `effectivePosition` from `switchCamera` — `currentPosition` is updated on MainActor after this runs.
    private func applyRearZoom(slot: CameraLensSlot, animated: Bool, effectivePosition: AVCaptureDevice.Position? = nil) {
        let pos = effectivePosition ?? currentPosition
        guard pos == .back, let device = currentInput?.device else {
            print("[Camera] applyRearZoom: skipped — pos=\(effectivePosition?.rawValue ?? -1) device=\(String(describing: currentInput?.device.deviceType.rawValue))")
            return
        }

        print("[Camera] applyRearZoom: slot=\(slot) device=\(device.deviceType.rawValue) isVirtual=\(Self.isVirtualRearCamera(device)) animated=\(animated) currentZoom=\(device.videoZoomFactor)")

        if Self.isVirtualRearCamera(device) {
            let oneX = Self.oneXVideoZoom(for: device)
            let target = slot == .wide ? device.minAvailableVideoZoomFactor : oneX
            let clamped = min(max(target, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            print("[Camera] applyRearZoom: virtual → target=\(target) clamped=\(clamped)")
            if animated {
                device.cancelVideoZoomRamp()
                let from = device.videoZoomFactor
                zoomRampGeneration += 1
                let gen = zoomRampGeneration
                scheduleSmoothZoom(device: device, from: from, to: clamped, generation: gen)
            } else {
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = clamped
                    device.unlockForConfiguration()
                } catch {}
            }
            return
        }

        guard device.minAvailableVideoZoomFactor < 0.999 else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let oneX = Self.oneXVideoZoom(for: device)
            device.videoZoomFactor = slot == .wide ? device.minAvailableVideoZoomFactor : oneX
        } catch {}
    }

    /// Smooth zoom-out / zoom-in like the system Camera app (hardware `ramp` is unreliable across OS versions).
    private func scheduleSmoothZoom(device: AVCaptureDevice, from start: CGFloat, to end: CGFloat, generation: UInt) {
        let steps = 32
        let duration: TimeInterval = 0.42
        let minZ = device.minAvailableVideoZoomFactor
        let maxZ = device.maxAvailableVideoZoomFactor
        for step in 1...steps {
            let delay = duration * Double(step) / Double(steps)
            sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard generation == self.zoomRampGeneration else { return }
                guard self.currentInput?.device === device else { return }
                let t = CGFloat(step) / CGFloat(steps)
                let u = t * t * (3.0 - 2.0 * t)
                let z = step == steps ? end : start + (end - start) * u
                let clamped = min(max(z, minZ), maxZ)
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = clamped
                    device.unlockForConfiguration()
                } catch {}
            }
        }
    }

    /// 1× target for `videoZoomFactor`.
    /// For virtual cameras (dual-wide / triple), the first `virtualDeviceSwitchOverVideoZoomFactors` entry
    /// is the zoom factor where the device switches from ultra-wide to wide (the 1x optical point).
    /// For single physical cameras, `videoZoomFactor = 1.0` is always 1x.
    private static func oneXVideoZoom(for device: AVCaptureDevice) -> CGFloat {
        let oneX = device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat($0.doubleValue) } ?? 1.0
        print("[Camera] oneXVideoZoom: device=\(device.deviceType.rawValue) virtualSwitchFactors=\(device.virtualDeviceSwitchOverVideoZoomFactors) → oneX=\(oneX)")
        return oneX
    }

    private static var rearHasHalfWideCapability: Bool {
        backVirtualDevice() != nil || ultraWideDevice(for: .back) != nil
    }

    private static func isVirtualRearCamera(_ device: AVCaptureDevice?) -> Bool {
        guard let device else { return false }
        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera:
            return true
        default:
            return false
        }
    }

    private static func backVirtualDevice() -> AVCaptureDevice? {
        if let d = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) { return d }
        if let d = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) { return d }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first(where: { $0.deviceType == .builtInTripleCamera })
            ?? discovery.devices.first(where: { $0.deviceType == .builtInDualWideCamera })
    }

    private static func ultraWideDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if let d = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) {
            return d
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    private static func videoDevice(position: AVCaptureDevice.Position, lensSlot: CameraLensSlot) -> AVCaptureDevice? {
        if position == .back, let v = backVirtualDevice() {
            return v
        }
        switch (position, lensSlot) {
        case (_, .primary):
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        case (_, .wide):
            return ultraWideDevice(for: position)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        }
    }
}

// MARK: - Photo delegate

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor in
            guard let image = UIImage(data: data) else { return }
            self.capturedImage = CameraCaptureProcessing.squareCenterUIImage(image)
        }
    }
}

// MARK: - Movie delegate

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        // Tear down the audio path now that the file is finalized — keeps Bluetooth
        // devices in A2DP between recordings. Also ensure the torch is off in case
        // the recording ended via interruption rather than `stopRecording()`.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.removeAudioInput()
            if let device = self.currentInput?.device, device.hasTorch,
               device.isTorchAvailable, device.torchMode != .off {
                try? device.lockForConfiguration()
                device.torchMode = .off
                device.unlockForConfiguration()
            }
        }
        Task { @MainActor in
            AppAudioSession.deactivate()
        }
        guard error == nil else { return }
        let rawURL = outputFileURL
        Task { @MainActor in
            self.isProcessingVideo = true
            self.pendingRawVideoURL = rawURL
            self.videoExportTask = Task { @MainActor in
                defer {
                    self.isProcessingVideo = false
                    self.videoExportTask = nil
                }
                do {
                    let square = try await CameraCaptureProcessing.exportSquareVideo(from: rawURL)
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: rawURL)
                    self.capturedVideoURL = square
                    self.pendingRawVideoURL = nil
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: rawURL)
                    self.pendingRawVideoURL = nil
                } catch {
                    self.capturedVideoURL = rawURL
                    self.pendingRawVideoURL = nil
                }
            }
        }
    }
}

// MARK: - Live frame tap (aesthetic scoring)

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Runs on `videoDataQueue` (serial). Cheap early-outs first so the
        // common disabled/throttled/busy case costs almost nothing.
        guard liveScoringEnabled, !isScoringInFlight else { return }
        let now = CACurrentMediaTime()
        guard now - lastScoredAt >= scoreThrottle else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Downscale to ~512px and snapshot a standalone CGImage on this queue,
        // so the capture buffer pool can recycle `sampleBuffer` immediately —
        // nothing pool-backed escapes into the async Vision call below. The
        // aesthetic model resizes internally, so 512px barely shifts the score
        // versus the full-res publish-time gate while costing far less.
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let maxSide = max(source.extent.width, source.extent.height)
        let scale = maxSide > 512 ? 512 / maxSide : 1
        let scaled = scale < 1
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source
        guard let cgImage = frameScoreContext.createCGImage(scaled, from: scaled.extent) else { return }

        lastScoredAt = now
        isScoringInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let score = await PostClassifier.aestheticScore(cgImage: cgImage)
            await MainActor.run {
                // Exponential smoothing: the raw per-frame score is jittery, which
                // would make the ring colour flicker. Blending toward each new
                // value trades a little latency (fine — the ring is a hint, not a
                // readout) for a calm, gliding colour. The published value doubles
                // as the EMA accumulator; `nil` (just after enable) seeds it raw.
                self.liveAestheticScore = self.liveAestheticScore.map { $0 * 0.6 + score * 0.4 } ?? score
            }
            self.videoDataQueue.async { self.isScoringInFlight = false }
        }
    }
}
