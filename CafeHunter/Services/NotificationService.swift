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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
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
