import Foundation
import CryptoKit

/// Basic end-to-end encryption primitives for 1:1 messages.
///
/// Each user has a long-term X25519 identity keypair: the private key lives in
/// the Keychain (this device only), the public key is published to
/// `users/{uid}.publicKey`. A per-conversation symmetric key is derived
/// deterministically from ECDH(myPrivate, theirPublic) + HKDF, so both sides
/// compute the same key with nothing exchanged or stored. Message bodies are
/// sealed with AES-GCM (fresh nonce per message).
///
/// Caveat (v1): the conversation key is a pure function of the two identity
/// keys, so if either user rotates keys (reinstall / new device) the key
/// changes and prior ciphertext in that thread can no longer be decrypted by
/// either party. New messages work once both have republished keys.
/// FUTURE: wrapped per-conversation content key (CEK) sealed to each
/// participant would limit that loss to only the reinstaller.
enum MessageCrypto {
    enum CryptoError: Error { case badPublicKey, badEnvelope, notUTF8 }

    private static let info = Data("wandery-msg-v1".utf8)

    private static func account(_ uid: String) -> String { "identityPrivateKey.\(uid)" }

    // MARK: - Identity

    /// Returns the device's identity private key for `uid`, generating and
    /// persisting one in the Keychain on first use.
    static func loadOrCreateIdentityKey(uid: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = Keychain.load(account: account(uid)),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try Keychain.save(key.rawRepresentation, account: account(uid))
        return key
    }

    static func publicKeyBase64(for priv: Curve25519.KeyAgreement.PrivateKey) -> String {
        priv.publicKey.rawRepresentation.base64EncodedString()
    }

    static func deleteIdentityKey(uid: String) {
        try? Keychain.delete(account: account(uid))
    }

    // MARK: - Shared mirror (for the Notification Service Extension)

    /// Fixed account for the shared-group copy of the current user's private
    /// key. Fixed (not uid-suffixed) so the extension can read it without
    /// knowing the signed-in uid — there's only ever one current user/device.
    static let sharedIdentityAccount = "e2ee.identity.current"

    /// Copy the current user's private key into the shared keychain group so
    /// the Notification Service Extension can decrypt message notifications.
    /// `WhenUnlocked` accessibility ⇒ only works while the phone is unlocked.
    /// No-op (silently) if the shared-group entitlement isn't configured yet.
    static func mirrorIdentityKeyToSharedGroup(uid: String) {
        guard let priv = try? loadOrCreateIdentityKey(uid: uid) else { return }
        try? Keychain.saveShared(priv.rawRepresentation, account: sharedIdentityAccount)
    }

    /// Remove the shared-group key copy (sign-out / account deletion).
    static func clearSharedIdentityKey() {
        try? Keychain.deleteShared(account: sharedIdentityAccount)
    }

    // MARK: - Conversation key

    static func conversationKey(
        myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        theirPublicKeyBase64: String,
        convId: String
    ) throws -> SymmetricKey {
        guard let pubData = Data(base64Encoded: theirPublicKeyBase64),
              let theirPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData) else {
            throw CryptoError.badPublicKey
        }
        let shared = try myPrivateKey.sharedSecretFromKeyAgreement(with: theirPub)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(convId.utf8),
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    // MARK: - Message body

    /// AES-GCM seal → base64 of the combined (nonce|ciphertext|tag) box.
    static func seal(_ plaintext: String, key: SymmetricKey) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = box.combined else { throw CryptoError.badEnvelope }
        return combined.base64EncodedString()
    }

    /// Inverse of `seal`. Throws on a tampered/wrong-key envelope (e.g. after a
    /// key rotation), which the caller maps to a placeholder render.
    static func open(_ base64Combined: String, key: SymmetricKey) throws -> String {
        guard let combined = Data(base64Encoded: base64Combined) else { throw CryptoError.badEnvelope }
        let box = try AES.GCM.SealedBox(combined: combined)
        let data = try AES.GCM.open(box, using: key)
        guard let text = String(data: data, encoding: .utf8) else { throw CryptoError.notUTF8 }
        return text
    }
}
