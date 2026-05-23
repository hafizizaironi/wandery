import Contacts
import CryptoKit
import Foundation

/// One row pulled from the device's address book, normalised and
/// hashed for friend-find lookup. The plaintext `phoneE164` stays on
/// device; only `phoneHash` is sent to Firestore.
struct ContactRecord: Identifiable, Sendable, Equatable {
    let id: String              // CNContact.identifier — stable per contact
    let displayName: String
    let phoneE164: String       // normalised E.164, owner-only
    let phoneHash: String       // SHA-256 of phoneE164, queryable
    /// Initials for the avatar placeholder when there's no photo.
    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

/// Reads iOS contacts, normalises phone numbers to E.164 against the
/// user's own country code, and produces SHA-256 hashes used by
/// `FriendFindService` to match against `users/{uid}.phoneHash`.
///
/// All work happens on-device; nothing is uploaded except the hashes.
@MainActor
enum ContactsService {

    enum AccessError: LocalizedError {
        case denied
        case restricted
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .denied:        "Contacts access is denied. Enable it in Settings → Privacy → Contacts."
            case .restricted:    "Contacts access is restricted on this device."
            case .unknown(let m): m
            }
        }
    }

    /// Requests authorisation if needed, then returns the current
    /// authorisation status. Throws on permanent denial / restriction
    /// so callers can show settings deep-link copy.
    static func requestAccess() async throws -> CNAuthorizationStatus {
        let current = CNContactStore.authorizationStatus(for: .contacts)
        switch current {
        case .authorized: return .authorized
        case .restricted: throw AccessError.restricted
        case .denied:     throw AccessError.denied
        case .notDetermined, .limited:
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                CNContactStore().requestAccess(for: .contacts) { granted, error in
                    if let error {
                        continuation.resume(throwing: AccessError.unknown(error.localizedDescription))
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            return granted ? .authorized : .denied
        @unknown default:
            return current
        }
    }

    /// Reads all contacts, normalises every phone number, and returns
    /// one `ContactRecord` per phone (so a contact with three numbers
    /// produces three records). `defaultCountryCode` is used to expand
    /// local numbers — pass the user's own country, derived from their
    /// verified E.164 phone.
    static func fetchContacts(defaultCountryCode: String) async throws -> [ContactRecord] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var records: [ContactRecord] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let display = name.isEmpty ? "Unnamed contact" : name
            for phone in contact.phoneNumbers {
                let raw = phone.value.stringValue
                guard let e164 = normaliseToE164(raw, defaultCountryCode: defaultCountryCode) else {
                    continue
                }
                records.append(ContactRecord(
                    id: "\(contact.identifier)-\(e164)",
                    displayName: display,
                    phoneE164: e164,
                    phoneHash: sha256Hex(e164)
                ))
            }
        }
        // Deduplicate by phoneE164 — same number saved under multiple
        // contacts collapses to one row, prefer the first display name.
        var seen: Set<String> = []
        let deduped = records.filter { seen.insert($0.phoneE164).inserted }
        return deduped
    }

    // MARK: - Internals

    /// Best-effort E.164 normalisation. Handles the common cases without
    /// pulling in libphonenumber:
    ///   `+60 12-345 6789`  → `+60123456789`
    ///   `0012 345 6789`    → `+0012345...` *(rare; international prefix)*
    ///   `012-345 6789`     → `+60123456789` *(local, prepend default cc)*
    ///   `(555) 123-4567`   → `+15551234567` *(local, default cc)*
    /// Returns nil for inputs that don't look like phone numbers.
    static func normaliseToE164(_ raw: String, defaultCountryCode: String) -> String? {
        // Strip every separator except a leading +.
        var digits = ""
        var sawPlus = false
        for char in raw {
            if char == "+" && digits.isEmpty {
                sawPlus = true
            } else if char.isNumber {
                digits.append(char)
            }
        }
        guard digits.count >= 6 else { return nil }

        if sawPlus {
            return "+" + digits
        }
        // International access prefix → "+"
        if digits.hasPrefix("00") {
            return "+" + digits.dropFirst(2)
        }
        // Local format: trim leading 0 (national trunk prefix in MY/UK/etc),
        // prepend the user's country code.
        let trimmed = digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
        let cc = defaultCountryCode.hasPrefix("+") ? String(defaultCountryCode.dropFirst()) : defaultCountryCode
        guard !cc.isEmpty else { return nil }
        return "+" + cc + trimmed
    }

    /// SHA-256 → lowercase hex. Must match the hash format
    /// `UserPrivateService.phoneHash` writes to `users/{uid}.phoneHash`,
    /// otherwise lookups won't find any matches.
    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Extracts a country code (digits without `+`) from an E.164 number.
    /// Inputs `+60123456789` → `60`, `+15551234567` → `1`. Best-effort
    /// against the longest matching ITU code; falls back to the first
    /// 1–3 digits which covers most cases.
    static func countryCode(fromE164 phone: String) -> String? {
        let trimmed = phone.hasPrefix("+") ? String(phone.dropFirst()) : phone
        guard !trimmed.isEmpty else { return nil }
        // Heuristic: known 1-digit codes (1 = NANP, 7 = Russia/Kazakhstan).
        // Everything else: assume 2–3 digit code. For our user base (mostly
        // MY = +60) this is fine; libphonenumber would do better.
        let oneDigit: Set<Character> = ["1", "7"]
        if let first = trimmed.first, oneDigit.contains(first) {
            return String(first)
        }
        // Default to 2-digit (covers +60, +65, +62, +91, +44, etc.).
        return String(trimmed.prefix(2))
    }
}
