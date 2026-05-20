import CryptoKit
import Foundation
import Security

/// Sign in with Apple requires a nonce for replay protection. We send the
/// SHA-256-hashed nonce to Apple's authorization request, and forward the
/// raw nonce to Firebase Auth alongside the identity token. Firebase
/// verifies the token's `nonce` claim matches the hash of what we sent.
///
/// Apple's reference implementation:
/// https://firebase.google.com/docs/auth/ios/apple
enum AppleSignInNonce {
    /// Cryptographically secure random nonce, URL-safe ASCII charset.
    static func random(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status != errSecSuccess {
            fatalError("SecRandomCopyBytes failed: \(status)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    /// Hex-encoded SHA-256 of the nonce. Sent to Apple in the authorization
    /// request; Apple includes it in the returned identity token's claims.
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
