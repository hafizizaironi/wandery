import AVFoundation
import Foundation

/// Single place to configure `AVAudioSession` for camera + microphone capture while keeping
/// Taptic / system haptics available (same idea as Apple’s Camera use case).
///
/// **Threading:** `configureForCameraCapture()` must run on the **main** queue. `AVAudioSession`
/// is main-thread–friendly for UI apps; capture still runs on `CameraService`’s session queue.
enum AppAudioSession {

    // MARK: - Public

    /// Category + mode + options, then opt in to haptics while the mic path is active, then activate.
    static func configureForCameraCapture() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        if #available(iOS 13.0, *) {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        try session.setActive(true, options: [])
    }

    /// Call once from app launch. Re-applies the same configuration after interruptions / route changes.
    static func registerObservers() {
        guard !didRegisterObservers else { return }
        didRegisterObservers = true

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            handleInterruption(notification)
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            reapplyIfNeeded(reason: "routeChange")
        }
    }

    // MARK: - Private

    private static var didRegisterObservers = false

    private static func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .ended:
            reapplyIfNeeded(reason: "interruptionEnded")
        case .began:
            break
        @unknown default:
            break
        }
    }

    private static func reapplyIfNeeded(reason: String) {
        do {
            try configureForCameraCapture()
        } catch {
            #if DEBUG
            print("AppAudioSession reapply (\(reason)): \(error.localizedDescription)")
            #endif
        }
    }
}
