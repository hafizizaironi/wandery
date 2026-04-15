import AVFoundation
import Observation
import UIKit

@Observable
final class CameraService: NSObject {

    // MARK: - Observable state

    var isAuthorized    = false
    /// Drives SwiftUI preview refresh after `startRunning()` / `stopRunning()` (session object identity is unchanged).
    var isSessionRunning = false
    var capturedImage: UIImage?
    var isRecording     = false
    var isLocked        = false          // recording continues without holding
    var recordingProgress: Double = 0   // 0 → 1 over maxDuration seconds
    var currentPosition: AVCaptureDevice.Position = .back

    // MARK: - Session

    let session = AVCaptureSession()

    private let photoOutput  = AVCapturePhotoOutput()
    private let movieOutput  = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.cafehunter.camera.session")
    private var currentInput: AVCaptureDeviceInput?

    private var progressTask: Task<Void, Never>?
    private let maxDuration: TimeInterval = 5

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
        // Configure `AVAudioSession` on the main queue (see `AppAudioSession`), then start capture.
        DispatchQueue.main.async { [weak self] in
            try? AppAudioSession.configureForCameraCapture()
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.session.inputs.isEmpty {
                    self.configureSession()
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let running = self.session.isRunning
                DispatchQueue.main.async { [weak self] in
                    self?.isSessionRunning = running
                }
            }
        }
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

    // MARK: - Photo

    func capture() {
        guard session.isRunning else { return }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Video

    func startRecording() {
        guard session.isRunning, !isRecording else { return }
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
    }

    func stopRecording() {
        guard isRecording else { return }
        progressTask?.cancel()
        progressTask = nil
        movieOutput.stopRecording()
        isRecording      = false
        isLocked         = false
        recordingProgress = 0
    }

    /// Starts recording and keeps it running after the button is released.
    func lockRecording() {
        isLocked = true
        startRecording()
    }

    // MARK: - Camera flip

    func switchCamera() {
        let newPos: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            if let cur = currentInput { session.removeInput(cur) }
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video,
                                                     position: newPos),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                Task { @MainActor in self.currentPosition = newPos }
            }
            session.commitConfiguration()
        }
    }

    // MARK: - Private setup

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }

        session.addInput(input)
        currentInput = input

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput  = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
    }
}

// MARK: - Photo delegate

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil,
              let data  = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        Task { @MainActor in self.capturedImage = image }
    }
}

// MARK: - Movie delegate

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        // TODO: offer save-to-library or video preview
    }
}
