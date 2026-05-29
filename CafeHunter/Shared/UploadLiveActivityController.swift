import ActivityKit
import Foundation

/// Controls the post-upload Live Activity (the Dynamic Island progress ring).
///
/// Starts an `Activity<UploadActivityAttributes>` when an upload begins, pushes
/// progress as bytes go up, and ends it (after a brief done/failed beat) when
/// the upload settles. The actual Dynamic Island + lock-screen UI is declared
/// by the Widget Extension's `UploadLiveActivity` (`ActivityConfiguration`);
/// this controller is the app-side driver.
///
/// Foreground-only to START (the user just tapped Post). Updates/ends work in
/// the background. Safe no-op if Live Activities are disabled or the OS rejects
/// the request — the in-app non-DI pill remains the fallback indicator.
@MainActor
final class UploadLiveActivityController {
    static let shared = UploadLiveActivityController()
    private init() {}

    private var activity: Activity<UploadActivityAttributes>?

    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // End any stale activity from a prior upload before starting a new one.
        if activity != nil { finish(failed: false) }
        let initial = UploadActivityAttributes.ContentState(progress: 0, done: false, failed: false)
        do {
            activity = try Activity.request(
                attributes: UploadActivityAttributes(),
                content: .init(state: initial, staleDate: nil)
            )
        } catch {
            #if DEBUG
            print("[LiveActivity] request failed: \(error.localizedDescription)")
            #endif
            activity = nil
        }
    }

    func update(progress: Double) {
        guard let activity else { return }
        let clamped = min(max(progress, 0), 1)
        let state = UploadActivityAttributes.ContentState(progress: clamped, done: false, failed: false)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func finish(failed: Bool) {
        guard let activity else { return }
        self.activity = nil
        let final = UploadActivityAttributes.ContentState(
            progress: failed ? 0 : 1, done: !failed, failed: failed
        )
        Task {
            await activity.update(.init(state: final, staleDate: nil))
            // Let the done/failed state breathe briefly, then dismiss.
            await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .after(.now + 1.5))
        }
    }
}
