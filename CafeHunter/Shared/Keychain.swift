import Foundation
import Security

/// Minimal Keychain wrapper for storing raw secret bytes (the E2EE identity
/// private key). One item per `account`, available after first unlock, and
/// marked **synchronizable** so it rides the user's iCloud Keychain — a new
/// device, a restore, or a delete-and-reinstall gets the same key back (when
/// iCloud Keychain is enabled) instead of regenerating one and orphaning prior
/// message history. Every query below sets the same `synchronizable` flag; if
/// they ever disagree, a lookup could miss the synced key and regenerate it.
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
            // `AfterFirstUnlock` (NOT `…ThisDeviceOnly`) so the E2E identity key
            // is included in the user's ENCRYPTED iCloud/iTunes backup and
            // restored to a new device — otherwise a new phone / restore
            // regenerates the key and orphans prior history ("🔒 can't decrypt").
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            // Sync through the user's iCloud Keychain so the key survives a
            // reinstall / new device (requires `AfterFirstUnlock`, never
            // `…ThisDeviceOnly`).
            kSecAttrSynchronizable as String: true,
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
            // Match whether the stored key is the synced copy or a legacy
            // local-only one (pre-sync installs).
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Like `load`, but distinguishes "genuinely absent" from "read failed".
    /// Returns nil ONLY on `errSecItemNotFound`; throws on any other status
    /// (e.g. `errSecInteractionNotAllowed` when the device is locked). This is
    /// what lets the identity-key loader avoid regenerating — and thereby
    /// orphaning all message history — on a transient keychain miss.
    static func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Remove both the synced copy and any legacy local-only one.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Migrate a legacy local-only key to the iCloud-syncing copy: ADD the
    /// synced item first, THEN delete the old local one. In that order the
    /// keychain is never momentarily empty, so a concurrent `load` can't see
    /// "no key" and trigger regeneration. No-op once already synced.
    static func ensureSynced(_ data: Data, account: String) {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        // `errSecDuplicateItem` ⇒ the synced copy already exists — also fine.
        guard status == errSecSuccess || status == errSecDuplicateItem else { return }
        // The synced copy is now in place; drop the old local-only one.
        let localQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(localQuery as CFDictionary)
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
