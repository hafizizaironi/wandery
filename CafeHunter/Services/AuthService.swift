import AuthenticationServices
import Combine
import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import GoogleSignIn
import UIKit

@MainActor
@Observable
final class AuthService {
    var user: FirebaseAuth.User?
    var isLoading = true

    /// Set your admin Firebase UID in Info.plist under the key "ADMIN_UID".
    let adminUID: String = Bundle.main.object(forInfoDictionaryKey: "ADMIN_UID") as? String ?? ""

    var isAdmin: Bool {
        guard let uid = user?.uid, !adminUID.isEmpty else { return false }
        return uid == adminUID
    }

    // `nonisolated(unsafe)` lets `deinit` (which is nonisolated) read the
    // handle to detach the listener. Only ever touched during init + deinit
    // so there's no real concurrency to protect against.
    //
    // NOTE: Swift's "consider using `nonisolated`" warning here is misleading
    // Listener token only accessed in init/deinit — not UI state, skip
    // observation tracking. nonisolated(unsafe) lets the nonisolated deinit
    // detach the listener from a @MainActor-isolated @Observable class.
    @ObservationIgnored nonisolated(unsafe) private var handle: AuthStateDidChangeListenerHandle?

    init() {
        // `appVerificationDisabledForTesting` is set up in `CafeHunterApp.init`
        // so the flag lands before any other code touches Auth.
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                self?.user = user
                self?.isLoading = false
                // FCM's registration-token callback often fires before auth
                // resolves at launch, so the token is dropped (no uid yet).
                // Re-persist it once a user is present — otherwise this device
                // never lands in users/{uid}/fcmTokens and gets no pushes.
                if user != nil {
                    NotificationService.shared.saveCurrentToken()
                }
            }
        }
    }

    deinit {
        if let handle { Auth.auth().removeStateDidChangeListener(handle) }
    }

    // MARK: - Google Sign-In

    func signInWithGoogle() async throws {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            throw AuthServiceError.noViewController
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.missingToken
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await Auth.auth().signIn(with: credential)
    }

    // MARK: - Sign in with Apple

    /// Completes Firebase sign-in after `SignInWithAppleButton` returns an
    /// `ASAuthorization`. The caller is responsible for generating + storing
    /// the raw nonce, passing the SHA-256 of it to Apple's request, and
    /// then handing the raw nonce here.
    ///
    /// On first sign-in Apple delivers `fullName`; mirror it onto Firebase's
    /// displayName so friends see a real name in the friend list / chat.
    /// Subsequent sign-ins return `nil` for `fullName` (Apple's design),
    /// which is why we have to capture it on the first try.
    func signInWithApple(
        authorization: ASAuthorization,
        rawNonce: String
    ) async throws {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw AuthServiceError.missingToken
        }
        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            throw AuthServiceError.missingToken
        }
        let oauthCredential = OAuthProvider.appleCredential(
            withIDToken: identityToken,
            rawNonce: rawNonce,
            fullName: credential.fullName
        )
        let result = try await Auth.auth().signIn(with: oauthCredential)

        // First-time-only fullName mirror.
        if let fullName = credential.fullName,
           let display = Self.formatPersonName(fullName),
           !display.isEmpty,
           result.user.displayName == nil || result.user.displayName == "" {
            let request = result.user.createProfileChangeRequest()
            request.displayName = display
            try? await request.commitChanges()
            try? await result.user.reload()
            self.user = Auth.auth().currentUser
        }
    }

    private static func formatPersonName(_ components: PersonNameComponents) -> String? {
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted = formatter.string(from: components).trimmingCharacters(in: .whitespaces)
        return formatted.isEmpty ? nil : formatted
    }

    // MARK: - Email / Password

    func signIn(email: String, password: String) async throws {
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func signUp(email: String, password: String, name: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        let request = result.user.createProfileChangeRequest()
        request.displayName = name
        try await request.commitChanges()
    }

    func signOut() throws {
        NotificationService.shared.removeAllTokensForCurrentUser()
        // Drop the E2EE identity key so a different account on this device
        // can't reuse it. (Same-account re-login regenerates + republishes.)
        if let uid = Auth.auth().currentUser?.uid {
            MessageCrypto.deleteIdentityKey(uid: uid)
        }
        MessageCrypto.clearSharedIdentityKey()
        try Auth.auth().signOut()
    }

    /// Permanent in-app account deletion (App Store Guideline 5.1.1(v)).
    /// Cascades server-side via the `deleteMyAccount` Cloud Function — that
    /// removes the user doc, username reservation, friend edges, posts +
    /// reactions, conversations + messages, FCM tokens, and Storage objects
    /// under `avatars/{uid}/` and `social/{uid}/`. Then deletes the Firebase
    /// Auth user itself. Auth listener in init() fires once the user is gone
    /// and ContentView routes back to LoginView.
    ///
    /// Firebase Auth requires a recent sign-in for `delete()`. If the session
    /// is stale this throws `AuthServiceError.recentLoginRequired`; the UI
    /// surfaces a "sign in again, then try" message.
    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthServiceError.notSignedIn
        }
        // Best-effort token cleanup before the user disappears — the
        // cascade also deletes the fcmTokens subcollection, but unregistering
        // the FCM token locally now avoids a stale device receiving
        // notifications until the next launch.
        NotificationService.shared.removeAllTokensForCurrentUser()
        MessageCrypto.deleteIdentityKey(uid: user.uid)
        MessageCrypto.clearSharedIdentityKey()

        let callable = Functions.functions().httpsCallable("deleteMyAccount")
        _ = try await callable.call([:])

        do {
            try await user.delete()
        } catch {
            let ns = error as NSError
            if ns.code == AuthErrorCode.requiresRecentLogin.rawValue {
                throw AuthServiceError.recentLoginRequired
            }
            throw error
        }
    }

    /// Reloads the signed-in user from Firebase (e.g. after avatar/name changed on another device).
    func refreshCurrentUser() async {
        guard let user = Auth.auth().currentUser else { return }
        do {
            try await user.reload()
            self.user = Auth.auth().currentUser
        } catch {
            // Keep existing cached user on failure.
        }
    }

    // MARK: - Profile updates

    func updateDisplayName(_ name: String) async throws {
        guard let user else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let request = user.createProfileChangeRequest()
        request.displayName = trimmed
        // Critical wait — `commitChanges()` is the only step that affects
        // what the user perceives as "saved". Auth's local cache updates
        // immediately and the server ack syncs the change across devices.
        try await request.commitChanges()
        // Immediate @Published update — consumers reading `authService.user`
        // see the new name as soon as this returns. Stop the caller's
        // spinner here, not after the trailing housekeeping below.
        self.user = Auth.auth().currentUser
        // Background housekeeping: reload pulls any unrelated server-side
        // fields; the Firestore mirror is what friends' UIs read for the
        // display name. Neither needs to block the caller — Firestore's
        // offline persistence retries the mirror on failure.
        let uid = user.uid
        Task {
            try? await user.reload()
            try? await Firestore.firestore()
                .collection("users").document(uid)
                .setData(["displayName": trimmed], merge: true)
        }
    }

    func updateProfilePhoto(_ image: UIImage) async throws {
        guard let user else { return }
        guard let data = Self.jpegDataForAvatar(image) else { return }
        // New object path each time so `photoURL` changes and other devices / URL caches load fresh bytes.
        let ref = Storage.storage().reference()
            .child("avatars/\(user.uid)/\(UUID().uuidString).jpg")
        // Critical waits: image upload + download URL + Auth commit must
        // all complete before we can call the photo "saved".
        _ = try await ref.putDataAsync(data)
        let url = try await ref.downloadURL()
        let request = user.createProfileChangeRequest()
        request.photoURL = url
        try await request.commitChanges()
        self.user = Auth.auth().currentUser
        // Background housekeeping — reload + public Firestore mirror so
        // friends' UIs (map pin avatars, friend list, chat header) render
        // the new photoURL. Doesn't block the caller's spinner.
        let uid = user.uid
        Task {
            try? await user.reload()
            try? await Firestore.firestore()
                .collection("users").document(uid)
                .setData(["photoURL": url.absoluteString], merge: true)
        }
    }

    /// Downscales to keep uploads fast; Auth photo URL is app-specific (not Google account).
    private static func jpegDataForAvatar(_ image: UIImage, maxEdge: CGFloat = 1024, quality: CGFloat = 0.78) -> Data? {
        jpegData(from: downscaleImage(image, maxEdge: maxEdge), quality: quality)
    }

    private static func downscaleImage(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let maxSide = max(size.width, size.height)
        guard maxSide > maxEdge else { return image }
        let scale = maxEdge / maxSide
        let newSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func jpegData(from image: UIImage, quality: CGFloat) -> Data? {
        image.jpegData(compressionQuality: quality)
    }
}

enum AuthServiceError: LocalizedError {
    case noViewController
    case missingToken
    case notSignedIn
    case recentLoginRequired

    var errorDescription: String? {
        switch self {
        case .noViewController: return "Unable to present sign-in screen."
        case .missingToken: return "Google sign-in failed. Please try again."
        case .notSignedIn: return "No user is signed in."
        case .recentLoginRequired:
            return "For security, please sign out and sign back in before deleting your account."
        }
    }
}
