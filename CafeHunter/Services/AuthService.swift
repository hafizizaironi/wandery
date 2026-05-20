import Combine
import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import GoogleSignIn
import UIKit

@MainActor
class AuthService: ObservableObject {
    @Published var user: FirebaseAuth.User?
    @Published var isLoading = true

    /// Set your admin Firebase UID in Info.plist under the key "ADMIN_UID".
    let adminUID: String = Bundle.main.object(forInfoDictionaryKey: "ADMIN_UID") as? String ?? ""

    var isAdmin: Bool {
        guard let uid = user?.uid, !adminUID.isEmpty else { return false }
        return uid == adminUID
    }

    private var handle: AuthStateDidChangeListenerHandle?

    init() {
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                self?.user = user
                self?.isLoading = false
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
        try Auth.auth().signOut()
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
        try await request.commitChanges()
        try await user.reload()
        // Firebase Auth's `displayName` is private to the owner; mirror it to
        // the public `users/{uid}` doc so friends' UIs can read it.
        try? await Firestore.firestore()
            .collection("users").document(user.uid)
            .setData(["displayName": trimmed], merge: true)
        self.user = Auth.auth().currentUser
    }

    func updateProfilePhoto(_ image: UIImage) async throws {
        guard let user else { return }
        guard let data = Self.jpegDataForAvatar(image) else { return }
        // New object path each time so `photoURL` changes and other devices / URL caches load fresh bytes.
        let ref = Storage.storage().reference()
            .child("avatars/\(user.uid)/\(UUID().uuidString).jpg")
        _ = try await ref.putDataAsync(data)
        let url = try await ref.downloadURL()
        let request = user.createProfileChangeRequest()
        request.photoURL = url
        try await request.commitChanges()
        try await user.reload()
        // Mirror the new photoURL onto the public user doc so friends' UIs
        // (map pin avatars, friend list, chat header) can render it.
        // Firebase Auth's `photoURL` is only readable by the owner.
        try? await Firestore.firestore()
            .collection("users").document(user.uid)
            .setData(["photoURL": url.absoluteString], merge: true)
        self.user = Auth.auth().currentUser
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

    var errorDescription: String? {
        switch self {
        case .noViewController: return "Unable to present sign-in screen."
        case .missingToken: return "Google sign-in failed. Please try again."
        }
    }
}
