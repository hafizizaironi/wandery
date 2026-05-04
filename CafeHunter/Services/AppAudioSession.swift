import AVFoundation
import Foundation

/// Audio session management for camera capture.
///
/// **Why no `.allowBluetoothHFP`:** enabling that option forces every connected Bluetooth
/// audio device (AirPods, car radio, BT speaker) out of A2DP (high-quality stereo playback)
/// and into HFP (mono call mode, mic-active). That switch is expensive — audible glitches,
/// music interruption, battery drain — and previously happened the moment the camera screen
/// appeared. We now keep BT devices in A2DP at all times; recording uses the iPhone's
/// built-in mic only.
///
/// **Lifecycle:** the audio session is dormant by default and only activated for the
/// duration of an actual video recording (`activateForRecording()` → `deactivate()`).
/// Photo capture and live preview don't touch the audio session at all.
///
/// **Threading:** activation / deactivation must run on the main queue.
enum AppAudioSession {

    /// True while a recording is in flight. Used by the route-change observer to decide
    /// whether to reapply the configuration after BT/AirPods bounce.
    private(set) static var isRecordingActive = false

    private static var didRegisterObservers = false

    // MARK: - Public

    /// Install one-time interruption / route-change observers. Call from app launch.
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
            // Only reapply mid-recording. Routine BT events shouldn't poke the audio session.
            guard isRecordingActive else { return }
            reapplyIfNeeded(reason: "routeChange")
        }
    }

    /// Activate `.playAndRecord` for the duration of a video recording. Built-in mic only.
    static func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.mixWithOthers, .defaultToSpeaker]
        )
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true, options: [])
        isRecordingActive = true
    }

    /// Release the session and notify other apps so paused/ducked playback can resume.
    static func deactivate() {
        isRecordingActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            #if DEBUG
            print("AppAudioSession deactivate: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Private

    private static func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .ended:
            guard isRecordingActive else { return }
            reapplyIfNeeded(reason: "interruptionEnded")
        case .began:
            break
        @unknown default:
            break
        }
    }

    private static func reapplyIfNeeded(reason: String) {
        do {
            try activateForRecording()
        } catch {
            #if DEBUG
            print("AppAudioSession reapply (\(reason)): \(error.localizedDescription)")
            #endif
        }
    }
}
