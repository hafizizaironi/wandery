import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import Foundation
import UIKit
import UserNotifications

/// FCM token lifecycle + Firestore storage at `users/{uid}/fcmTokens/{tokenId}`.
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    private let db = Firestore.firestore()

    private override init() {
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
    }

    func requestAuthorizationAndRegister() {
        // Register for remote notifications unconditionally — silent-push
        // (used by Firebase Phone Auth verification) only needs an APNs
        // device token, not visible-notification permission. Gating this
        // on `granted` would break Phone Auth for any user who declines
        // the alerts prompt.
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    func saveFCMToken(_ token: String?) {
        guard let token, let uid = Auth.auth().currentUser?.uid else { return }
        let doc = db.collection("users").document(uid).collection("fcmTokens").document(tokenHash(token))
        doc.setData([
            "token": token,
            "updatedAt": FieldValue.serverTimestamp(),
            "platform": "ios",
        ], merge: true)
    }

    /// Fetches the current FCM registration token and persists it. Needed
    /// because `didReceiveRegistrationToken` usually fires *before* auth
    /// resolves at launch — at that point `saveFCMToken` bails (no uid) and
    /// nothing re-saves it, so `users/{uid}/fcmTokens` stays empty and pushes
    /// (friend requests, posts, messages) never reach this device. Call once
    /// a user is signed in.
    func saveCurrentToken() {
        Messaging.messaging().token { [weak self] token, error in
            if let error {
                #if DEBUG
                print("[NotificationService] FCM token fetch failed: \(error.localizedDescription)")
                #endif
                return
            }
            self?.saveFCMToken(token)
        }
    }

    func removeAllTokensForCurrentUser() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        db.collection("users").document(uid).collection("fcmTokens").getDocuments { snap, _ in
            snap?.documents.forEach { $0.reference.delete() }
        }
    }

    private func tokenHash(_ token: String) -> String {
        String(token.prefix(32)).replacingOccurrences(of: "/", with: "_")
    }
}

extension NotificationService: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        saveFCMToken(fcmToken)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
