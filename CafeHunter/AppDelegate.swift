import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
import FirebaseMessaging
import GoogleSignIn
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

        // NOTE: `appVerificationDisabledForTesting` is deliberately not
        // set. With APNs swizzling disabled + manual setAPNSToken
        // forwarding + Encoded App ID URL scheme + uiDelegate, Phone
        // Auth attempts silent-push verification first and falls back
        // to reCAPTCHA web view. Real SMS is sent. To switch back to
        // bypass for offline dev, set the flag here.

        NotificationService.shared.configure()
        NotificationService.shared.requestAuthorizationAndRegister()
        return true
    }

    // MARK: - APNs token

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        // `.sandbox` for Xcode debug / TestFlight, `.prod` for App Store.
        // Use `.unknown` to let Firebase pick automatically from the
        // provisioning profile — the safer default across configurations.
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
        print("[Push] APNs token registered (\(deviceToken.count) bytes), handed to FCM + Auth")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] APNs registration failed: \(error.localizedDescription)")
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

    // MARK: - URL handling (reCAPTCHA return, Google Sign-In)

    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if Auth.auth().canHandle(url) {
            return true
        }
        return GIDSignIn.sharedInstance.handle(url)
    }
}
