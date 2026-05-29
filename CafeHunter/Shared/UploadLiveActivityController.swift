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
        let info = ActivityAuthorizationInfo()
        #if DEBUG
        print("[LiveActivity] start: areActivitiesEnabled=\(info.areActivitiesEnabled) frequentPushesEnabled=\(info.frequentPushesEnabled) existingActivities=\(Activity<UploadActivityAttributes>.activities.count)")
        #endif
        guard info.areActivitiesEnabled else {
            #if DEBUG
            print("[LiveActivity] ABORT — Live Activities disabled for this app (Settings ▸ CafeHunter ▸ Live Activities, and Settings ▸ Face ID & Passcode / Notifications).")
            #endif
            return
        }
        // End any stale activity from a prior upload before starting a new one.
        if activity != nil { finish(failed: false) }
        let initial = UploadActivityAttributes.ContentState(progress: 0, done: false, failed: false)
        do {
            let a = try Activity.request(
                attributes: UploadActivityAttributes(),
                content: .init(state: initial, staleDate: nil)
            )
            activity = a
            #if DEBUG
            print("[LiveActivity] requested OK — id=\(a.id) state=\(a.activityState)")
            #endif
        } catch {
            #if DEBUG
            print("[LiveActivity] request FAILED: \(error)  (\(error.localizedDescription))")
            #endif
            activity = nil
        }
    }

    func update(progress: Double) {
        guard let activity else { return }
        let clamped = min(max(progress, 0), 1)
        let state = UploadActivityAttributes.ContentState(progress: clamped, done: false, failed: false)
        Task {
            await activity.update(.init(state: state, staleDate: nil))
            #if DEBUG
            print("[LiveActivity] update progress=\(String(format: "%.2f", clamped)) state=\(activity.activityState)")
            #endif
        }
    }

    func finish(failed: Bool) {
        guard let activity else { return }
        self.activity = nil
        let final = UploadActivityAttributes.ContentState(
            progress: failed ? 0 : 1, done: !failed, failed: failed
        )
        #if DEBUG
        print("[LiveActivity] finish(failed: \(failed)) — id=\(activity.id)")
        #endif
        Task {
            await activity.update(.init(state: final, staleDate: nil))
            // Keep the done/failed state on screen a few seconds so it's
            // observable when the app is backgrounded, then dismiss.
            await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .after(.now + 4))
        }
    }
}
