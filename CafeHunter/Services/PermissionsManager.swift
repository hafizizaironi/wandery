import AVFoundation
import Contacts
import Observation
import Photos
import UIKit
import UserNotifications

/// The permissions the priming queue can ask for, in the order they're asked.
///
/// **Location is intentionally absent.** It's primed once on the pre-login
/// `WelcomeView` card (and asked contextually from the map's locate button), so
/// queuing it here too would show a second, identical "Allow Location" page.
enum PermissionKind: CaseIterable, Identifiable {
    case cameraMic
    case notifications
    case contacts
    case photos

    var id: Self { self }
}

/// Single source of truth for the app's OS-permission status, plus the `async`
/// request methods the priming queue awaits one at a time.
///
/// Created once in `WanderyEntryView` and handed to `RootRouterView`. The queue
/// (`PermissionPrimingView`) is the ONLY place that proactively fires these
/// prompts; feature screens read the cached status instead of re-requesting, so
/// the OS prompts never burst on top of each other. Each `request*` method is
/// `async` — the caller `await`ing it before showing the next card is what
/// serializes the system prompts into a smooth one-at-a-time flow.
@MainActor @Observable
final class PermissionsManager {

    // MARK: - Cached status (read synchronously by the gate + cards)

    private(set) var cameraStatus:     AVAuthorizationStatus
    private(set) var microphoneStatus: AVAuthorizationStatus
    private(set) var contactsStatus:   CNAuthorizationStatus
    private(set) var photosStatus:     PHAuthorizationStatus
    /// Notification status can only be read asynchronously — seeded
    /// `.notDetermined` and corrected by `refreshAllStatuses()`.
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

    init() {
        cameraStatus     = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        contactsStatus   = CNContactStore.authorizationStatus(for: .contacts)
        photosStatus     = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - Gate inputs

    /// True while ANY queued permission is still undecided — drives whether the
    /// priming gate shows at all.
    var hasUndeterminedCorePermission: Bool { !pendingPermissions.isEmpty }

    /// The still-`.notDetermined` permissions, in queue order. The priming view
    /// snapshots this so each card maps to one undecided permission; anything
    /// already answered is absent here, so the queue silently skips it.
    var pendingPermissions: [PermissionKind] {
        PermissionKind.allCases.filter(isUndetermined)
    }

    private func isUndetermined(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .cameraMic:     cameraStatus == .notDetermined || microphoneStatus == .notDetermined
        case .notifications: notificationStatus == .notDetermined
        case .contacts:      contactsStatus == .notDetermined
        case .photos:        photosStatus == .notDetermined
        }
    }

    // MARK: - Status refresh

    /// Re-reads every status. Notification status requires an `await`, so call
    /// this from the priming view's `.task` and when returning from Settings.
    func refreshAllStatuses() async {
        cameraStatus     = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        contactsStatus   = CNContactStore.authorizationStatus(for: .contacts)
        photosStatus     = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        notificationStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    // MARK: - Requests (awaited by the queue → prompts are serialized)

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .cameraMic:     await requestCameraAndMicrophone()
        case .notifications: await requestNotifications()
        case .contacts:      await requestContacts()
        case .photos:        await requestPhotos()
        }
    }

    func requestCameraAndMicrophone() async {
        if cameraStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if microphoneStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        cameraStatus     = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
        // Register regardless of the alert grant — silent push (Phone Auth)
        // needs only the APNs device token, which registration provides.
        UIApplication.shared.registerForRemoteNotifications()
        notificationStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    func requestContacts() async {
        // Reuse the existing wrapper (prompts when `.notDetermined`, throws on
        // permanent denial — which we don't care about here, the card is done).
        _ = try? await ContactsService.requestAccess()
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestPhotos() async {
        // `.readWrite` covers both the recent-photos strip (read) and the
        // save-to-library path (`.readWrite` ⊇ `.addOnly`).
        photosStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
}
