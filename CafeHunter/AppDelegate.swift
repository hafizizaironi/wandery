import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
import FirebaseMessaging
import UIKit

/// Hosts all Firebase initialization + manual notification forwarding.
///
/// **Why FirebaseApp.configure() lives here (not in App.init):** Firebase
/// Phone Auth in SwiftUI requires `FirebaseAppDelegateProxyEnabled = NO`
/// in Info.plist (swizzling disabled), which means this delegate must
/// forward APNs token + remote notifications + URLs to Firebase Auth and
/// FCM manually. Calling `Auth.auth().setAPNSToken(...)` from
/// `didRegisterForRemoteNotifications` requires Firebase to already be
/// configured, but it also requires Auth's internal `tokenManager` to
/// have completed init — which doesn't happen reliably if `configure()`
/// runs in `App.init` before this AppDelegate is even instantiated. By
/// configuring inside `didFinishLaunchingWithOptions`, ordering is
/// deterministic. Pattern from Peter Friese's recommended SwiftUI +
/// Phone Auth setup (stackoverflow.com/q/65409563).
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // AppCheck must be installed before FirebaseApp.configure so the
        // provider factory is locked in for every Firebase product.
        AppCheck.setAppCheckProviderFactory(CafeHunterAppCheckProviderFactory())
        FirebaseApp.configure()

        // Share the signed-in Firebase user with the FriendsFeedWidget process
        // via the shared keychain access group (the same group the NSE uses), so
        // the widget's one-shot Firestore reads run authenticated. A no-op until
        // the widget+app both carry the group entitlement; safe to call always.
        try? Auth.auth().useUserAccessGroup(SharedFeedStore.sharedKeychainGroup)

        // NOTE: `appVerificationDisabledForTesting` is deliberately not
        // set. With APNs swizzling disabled + manual setAPNSToken
        // forwarding + Encoded App ID URL scheme + uiDelegate, Phone
        // Auth attempts silent-push verification first and falls back
        // to reCAPTCHA web view. Real SMS is sent. To switch back to
        // bypass for offline dev, set the flag here.

        NotificationService.shared.configure()
        // Silent APNs registration only (no visible prompt) — Phone Auth needs
        // the device token early. The visible notification permission is asked
        // later in the post-onboarding priming queue (PermissionsManager).
        NotificationService.shared.registerForRemoteNotifications()
        return true
    }

    // MARK: - APNs token

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        // `.sandbox` for Xcode debug / TestFlight, `.prod` for App Store.
        // Use `.unknown` to let Firebase pick automatically from the
        // provisioning profile — the safer default across configurations.
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
        dlog("[Push] APNs token registered (\(deviceToken.count) bytes), handed to FCM + Auth")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        dlog("[Push] APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Silent push

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if Auth.auth().canHandleNotification(userInfo) {
            completionHandler(.noData)
            return
        }
        Messaging.messaging().appDidReceiveMessage(userInfo)
        completionHandler(.newData)
    }

    // URL handling (Firebase Auth reCAPTCHA return + Google Sign-In callback)
    // moved into `CafeHunterApp.body`'s `.onOpenURL` for iOS 26 — the
    // AppDelegate `application(_:open:options:)` path was deprecated in
    // favour of UIScene-based URL contexts. SwiftUI's `.onOpenURL` is the
    // scene-aware equivalent and feeds both Firebase Auth and Google
    // Sign-In handlers there.
}
