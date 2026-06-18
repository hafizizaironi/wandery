import Foundation
@preconcurrency import FirebaseAuth
import FirebaseCore
import UIKit

/// Thin wrapper around Firebase Phone Auth's send-code + verify flow.
/// Stateless on purpose — the calling view owns the two-step UI state
/// (entering number → entering code) and just hands the verificationID
/// back when it's time to verify.
///
/// Both flows expect the user to already be signed in via Apple/Google/
/// Email. We use `currentUser.link(with:)` to attach phone as a *secondary*
/// auth method rather than `Auth.auth().signIn(with:)` which would create
/// or switch accounts.
@MainActor
enum PhoneAuthService {

    /// Key under which the most recent verificationID is persisted, so an
    /// app relaunch mid-flow can still complete sign-in (per Firebase's docs).
    private static let verificationIDKey = "authVerificationID"

    /// The verificationID persisted by the last `sendCode`, if any. Used as
    /// a fallback when the in-memory view state was lost (e.g. app killed
    /// while the user was reading the SMS).
    static var savedVerificationID: String? {
        UserDefaults.standard.string(forKey: verificationIDKey)
    }

    /// Sends the SMS code and returns the Firebase verificationID.
    /// Passes a uiDelegate so Firebase can present its reCAPTCHA web
    /// view when silent-push verification is unavailable.
    static func sendCode(to phoneE164: String) async throws -> String {
        let uiDelegate = PresentingUIDelegate()
        #if DEBUG
        print("[PhoneAuth-DEBUG] sendCode for \(phoneE164)")
        let app = FirebaseApp.app()
        print("[PhoneAuth-DEBUG] FirebaseApp present: \(app != nil)")
        print("[PhoneAuth-DEBUG] Options.clientID: \(app?.options.clientID ?? "<nil>")")
        print("[PhoneAuth-DEBUG] Options.googleAppID: \(app?.options.googleAppID ?? "<nil>")")
        print("[PhoneAuth-DEBUG] Options.bundleID: \(app?.options.bundleID ?? "<nil>")")
        print("[PhoneAuth-DEBUG] Options.projectID: \(app?.options.projectID ?? "<nil>")")
        #endif
        do {
            let id = try await PhoneAuthProvider.provider()
                .verifyPhoneNumber(phoneE164, uiDelegate: uiDelegate)
            UserDefaults.standard.set(id, forKey: Self.verificationIDKey)
            return id
        } catch {
            #if DEBUG
            let nsError = error as NSError
            print("[PhoneAuth-DEBUG] verifyPhoneNumber FAILED")
            print("[PhoneAuth-DEBUG]   domain: \(nsError.domain)")
            print("[PhoneAuth-DEBUG]   code: \(nsError.code)")
            print("[PhoneAuth-DEBUG]   description: \(nsError.localizedDescription)")
            print("[PhoneAuth-DEBUG]   userInfo keys: \(nsError.userInfo.keys.sorted())")
            for (key, value) in nsError.userInfo {
                print("[PhoneAuth-DEBUG]   userInfo[\(key)] = \(value)")
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("[PhoneAuth-DEBUG]   underlying.domain: \(underlying.domain)")
                print("[PhoneAuth-DEBUG]   underlying.code: \(underlying.code)")
                print("[PhoneAuth-DEBUG]   underlying.userInfo: \(underlying.userInfo)")
            }
            #endif
            // Map to friendly, actionable copy *here* too — not just in
            // `verifyAndLink`. The send path is where the App Check / APNs /
            // reCAPTCHA / backend-503 failures land, and the raw Firebase
            // error ("An internal error has occurred…", code 17999) is
            // useless to a user trying to sign up.
            throw map(error as NSError)
        }
    }

    /// Verifies the user-entered code and links the resulting credential
    /// to the currently signed-in user. After this returns, the user's
    /// FirebaseAuth.User has `phoneNumber` populated.
    static func verifyAndLink(verificationID: String, code: String) async throws {
        guard let user = Auth.auth().currentUser else {
            throw PhoneAuthError.notSignedIn
        }
        let credential = PhoneAuthProvider.provider().credential(
            withVerificationID: verificationID,
            verificationCode: code
        )
        do {
            _ = try await user.link(with: credential)
            UserDefaults.standard.removeObject(forKey: Self.verificationIDKey)
        } catch let error as NSError {
            let mapped = map(error)
            // A dead/expired verificationID is useless for retry — clear it so a
            // stale token doesn't linger in UserDefaults (and device backups).
            // Keep it for a mistyped code (.invalidCode) so the user can retry.
            if mapped == .codeExpired {
                UserDefaults.standard.removeObject(forKey: Self.verificationIDKey)
            }
            throw mapped
        }
    }

    // MARK: - Error mapping

    /// Translates raw Firebase errors into user-facing copy. Falls back to
    /// the SDK's localizedDescription when an unfamiliar code shows up so
    /// nothing is silently swallowed.
    private static func map(_ error: NSError) -> PhoneAuthError {
        guard let code = AuthErrorCode(rawValue: error.code) else {
            return .unknown(error.localizedDescription)
        }
        switch code {
        case .invalidPhoneNumber, .missingPhoneNumber:
            return .invalidPhoneNumber
        case .invalidVerificationCode, .missingVerificationCode:
            return .invalidCode
        case .invalidVerificationID, .missingVerificationID, .sessionExpired:
            return .codeExpired
        case .credentialAlreadyInUse, .providerAlreadyLinked:
            return .phoneTaken
        case .quotaExceeded, .tooManyRequests:
            return .rateLimited
        case .networkError:
            return .network
        case .appNotVerified, .captchaCheckFailed, .missingAppToken,
             .notificationNotForwarded, .missingAppCredential, .internalError:
            // App Check / APNs silent-push / reCAPTCHA verification couldn't
            // complete, or the backend returned a transient 503 (the
            // "Error code: 39" / 17999 case). These are project-config or
            // rate-window issues, not anything the user mistyped. Carry the
            // raw code through so a tester's screenshot is enough to triage
            // remotely (the #if DEBUG log above is stripped on TestFlight).
            return .verificationUnavailable(code: error.code)
        case .webContextCancelled:
            return .verificationCancelled
        default:
            return .unknown(error.localizedDescription)
        }
    }
}

/// Bridges Firebase Auth's `AuthUIDelegate` (which expects a UIKit view
/// controller for presentation) to a SwiftUI app. Finds the topmost
/// presented view controller via the active scene and forwards present /
/// dismiss to it. Used by Phone Auth to surface the reCAPTCHA verification
/// web view when APNs silent-push verification is unavailable.
@MainActor
private final class PresentingUIDelegate: NSObject, AuthUIDelegate {
    nonisolated func present(_ viewControllerToPresent: UIViewController,
                             animated flag: Bool,
                             completion: (() -> Void)? = nil) {
        Task { @MainActor in
            guard let top = Self.topViewController() else {
                completion?()
                return
            }
            top.present(viewControllerToPresent, animated: flag, completion: completion)
        }
    }

    nonisolated func dismiss(animated flag: Bool,
                             completion: (() -> Void)? = nil) {
        Task { @MainActor in
            guard let top = Self.topViewController() else {
                completion?()
                return
            }
            top.dismiss(animated: flag, completion: completion)
        }
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene),
              let root = scene.keyWindow?.rootViewController
                      ?? scene.windows.first?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

/// User-facing phone auth errors. Each case carries the exact copy the
/// view shows inline — keeps error rendering trivial and uniform.
enum PhoneAuthError: LocalizedError, Equatable {
    case notSignedIn
    case invalidPhoneNumber
    case invalidCode
    case codeExpired
    case phoneTaken
    case rateLimited
    case network
    case verificationUnavailable(code: Int)
    case verificationCancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:        "You'll need to sign in again first."
        case .invalidPhoneNumber: "That number looks a little off — don't forget the country code (like +60 for Malaysia) 📱"
        case .invalidCode:        "That code's not it 👀 Peek at your texts and try again."
        case .codeExpired:        "That code timed out ⏳ Tap resend for a fresh one."
        case .phoneTaken:         "This number's already paired with another account 🤔"
        case .rateLimited:        "Too many tries! Give it a few minutes and come back ☕"
        case .network:            "Can't reach us right now — check your connection and try again 📶"
        case .verificationUnavailable(let code):
            "Couldn't send your code right now 😅 Make sure you're on the latest version, then try again in a few. (ref \(code))"
        case .verificationCancelled:   "Cancelled that one — tap Send code whenever you're ready."
        case .unknown(let msg):   msg
        }
    }
}
