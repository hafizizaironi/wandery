import Combine
import Foundation
import FirebaseAuth
import FirebaseStorage
import GoogleSignIn
import UIKit

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

    // MARK: - Profile updates

    func updateDisplayName(_ name: String) async throws {
        guard let user else { return }
        let request = user.createProfileChangeRequest()
        request.displayName = name.trimmingCharacters(in: .whitespaces)
        try await request.commitChanges()
        try await user.reload()
        await MainActor.run { self.user = Auth.auth().currentUser }
    }

    func updateProfilePhoto(_ image: UIImage) async throws {
        guard let user,
              let data = image.jpegData(compressionQuality: 0.75) else { return }
        let ref = Storage.storage().reference().child("avatars/\(user.uid).jpg")
        _ = try await ref.putDataAsync(data)
        let url = try await ref.downloadURL()
        let request = user.createProfileChangeRequest()
        request.photoURL = url
        try await request.commitChanges()
        try await user.reload()
        await MainActor.run { self.user = Auth.auth().currentUser }
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
