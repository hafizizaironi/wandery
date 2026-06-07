import UserNotifications
import CryptoKit
import WidgetKit

/// Notification Service Extension principal class. Named distinctly (NOT
/// `NotificationService`) so it can never collide with the app's
/// `NotificationService` singleton. iOS wakes this when a push has
/// `mutable-content: 1` to rewrite the notification before it's shown:
///   • `message` → decrypt the E2EE body on-device, but ONLY while the phone
///     is unlocked (the identity key lives in a `WhenUnlocked` shared keychain
///     item; locked ⇒ unreadable ⇒ the generic "New message" body stands).
///   • `newPost` → download the post photo and attach it (iOS then shows the
///     photo + replaces the app-icon thumbnail).
///
/// Shares `MessageCrypto.swift` + `Keychain.swift` with the app via target
/// membership — no duplicated crypto. Set this class as the extension's
/// `NSExtensionPrincipalClass` (`$(PRODUCT_MODULE_NAME).NotificationServiceExtension`).
final class NotificationServiceExtension: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let attempt = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.bestAttempt = attempt
        let info = request.content.userInfo

        switch info["type"] as? String {
        case "message":
            decryptBody(into: attempt, info: info)
            contentHandler(attempt)

        case "newPost":
            // A friend posted — nudge the Home Screen widget to pull the new
            // post even while the app is closed (the background-fresh path).
            WidgetCenter.shared.reloadAllTimelines()
            if let urlString = info["imageURL"] as? String, let url = URL(string: urlString) {
                attachImage(from: url, to: attempt) { contentHandler(attempt) }
            } else {
                contentHandler(attempt)
            }

        default:
            contentHandler(attempt)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt { contentHandler(bestAttempt) }
    }

    // MARK: - Message decryption (unlocked only)

    private func decryptBody(into content: UNMutableNotificationContent, info: [AnyHashable: Any]) {
        guard
            let encText = info["encText"] as? String,
            // Readable only while unlocked → this is the "only when unlocked" gate.
            let privData = Keychain.loadShared(account: MessageCrypto.sharedIdentityAccount),
            let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privData)
        else { return }   // leave the generic body on any failure (incl. locked)

        // encv comes through APNs as a number (NSNumber) or string — accept both.
        let encv = (info["encv"] as? Int) ?? Int(info["encv"] as? String ?? "") ?? 0

        let key: SymmetricKey?
        if encv >= 2, let ek = info["cekEk"] as? String, let ct = info["cekCt"] as? String {
            // Current: unwrap the per-conversation content key wrapped to me.
            key = try? MessageCrypto.unwrap(ek: ek, ct: ct, myPrivateKey: priv)
        } else if let senderPub = info["senderPublicKey"] as? String,
                  let convId = info["convId"] as? String {
            // Legacy encv 1: static-ECDH conversation key from the sender's pub.
            key = try? MessageCrypto.conversationKey(
                myPrivateKey: priv, theirPublicKeyBase64: senderPub, convId: convId)
        } else {
            key = nil
        }

        guard let key, let plain = try? MessageCrypto.open(encText, key: key) else { return }
        content.body = plain
    }

    // MARK: - Post image attachment

    private func attachImage(
        from url: URL,
        to content: UNMutableNotificationContent,
        completion: @escaping () -> Void
    ) {
        URLSession.shared.downloadTask(with: url) { tmp, _, _ in
            defer { completion() }
            guard let tmp else { return }
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let dest = tmp.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + "." + ext)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                let attachment = try UNNotificationAttachment(identifier: "postImage", url: dest)
                content.attachments = [attachment]
            } catch {
                // Best-effort — fall through to the plain notification.
            }
        }.resume()
    }
}
