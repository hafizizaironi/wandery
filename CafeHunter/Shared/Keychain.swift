import Foundation
import Security

/// Minimal Keychain wrapper for storing raw secret bytes (the E2EE identity
/// private key). One item per `account`, scoped to this device only (never
/// synced to iCloud Keychain), available after first unlock so background
/// pushes can still derive keys if ever needed.
enum Keychain {
    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    private static let service = (Bundle.main.bundleIdentifier ?? "TechVision.CafeHunter") + ".e2ee"

    /// Store (or overwrite) the secret for `account`. Delete-then-add keeps it
    /// idempotent so key rotation just overwrites.
    static func save(_ data: Data, account: String) throws {
        try? delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Shared group (app ↔ Notification Service Extension)

    /// Shared keychain group so the Notification Service Extension can read the
    /// E2EE identity key and decrypt a message notification's body on-device.
    ///
    /// ‼️ FILL THIS IN: both the app and the extension must enable the
    /// "Keychain Sharing" capability with the group `TechVision.CafeHunter.shared`,
    /// and this constant must be `<YOUR_TEAM_ID>.TechVision.CafeHunter.shared`
    /// (the 10-char Team ID from Xcode → Signing & Capabilities). Until it's
    /// correct, the shared writes/reads simply fail and notifications fall back
    /// to the generic body — the app's own E2EE is unaffected.
    static let sharedGroup = "5GQ3DBXL52.TechVision.CafeHunter.shared"
    private static let sharedService = "wandery.e2ee.shared"

    /// Store in the shared group, readable ONLY while the device is unlocked —
    /// this is what gives "show message content only when unlocked": locked ⇒
    /// the extension can't read the key ⇒ it can't decrypt ⇒ generic body.
    static func saveShared(_ data: Data, account: String) throws {
        try? deleteShared(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func loadShared(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func deleteShared(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
