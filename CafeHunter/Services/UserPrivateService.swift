import CryptoKit
import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

/// Listener + writer for the owner-only `userPrivate/{uid}` doc plus the
/// `lastSeenAt` field on the public `users/{uid}` doc. Mirrors the
/// SocialService lifecycle — `start(for:)` on auth, `reset()` on sign-out.
@MainActor
@Observable
final class UserPrivateService {
    private(set) var profile: UserPrivate?
    private(set) var isLoading = true

    /// True once the listener has heard back at least once (used by the
    /// routing gate to avoid showing the birthdate screen before we know
    /// whether the user already has one).
    private(set) var didHydrate = false

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var currentUid: String?

    /// In-memory throttle for `lastSeenAt` writes. Avoids burning a write
    /// every time the app foregrounds within a short window — the user's
    /// CLAUDE.md flags Firebase write cost as a deliberate ceiling.
    private var lastSeenWrittenAt: Date?
    private static let lastSeenInterval: TimeInterval = 5 * 60

    // MARK: - Lifecycle

    func start(for user: FirebaseAuth.User?) {
        reset()
        guard let user else {
            isLoading = false
            didHydrate = true
            return
        }
        currentUid = user.uid
        isLoading = true
        didHydrate = false
        let ref = db.collection("userPrivate").document(user.uid)
        listener = ref.addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self else { return }
                defer {
                    self.isLoading = false
                    self.didHydrate = true
                }
                guard let data = snap?.data() else {
                    self.profile = UserPrivate()
                    return
                }
                self.profile = UserPrivate(
                    birthdate: (data["birthdate"] as? Timestamp)?.dateValue(),
                    ageConfirmedAt: (data["ageConfirmedAt"] as? Timestamp)?.dateValue(),
                    tosAcceptedAt: (data["tosAcceptedAt"] as? Timestamp)?.dateValue(),
                    tosVersion: data["tosVersion"] as? String,
                    privacyAcceptedAt: (data["privacyAcceptedAt"] as? Timestamp)?.dateValue(),
                    privacyVersion: data["privacyVersion"] as? String,
                    phoneNumber: data["phoneNumber"] as? String,
                    phoneVerifiedAt: (data["phoneVerifiedAt"] as? Timestamp)?.dateValue(),
                    phoneOnboardingPending: data["phoneOnboardingPending"] as? Bool,
                    contactsPromptShown: data["contactsPromptShown"] as? Bool,
                    deletionRequestedAt: (data["deletionRequestedAt"] as? Timestamp)?.dateValue(),
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
                    updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue()
                )
            }
        }
    }

    func reset() {
        listener?.remove()
        listener = nil
        currentUid = nil
        profile = nil
        isLoading = true
        didHydrate = false
        lastSeenWrittenAt = nil
    }

    // MARK: - Routing helpers

    /// True when the user hasn't passed the birthdate gate yet.
    var needsBirthdate: Bool {
        guard didHydrate else { return false }
        return profile?.birthdate == nil
    }

    /// True when the user hasn't accepted the *current* ToS / Privacy
    /// versions (either never accepted, or accepted an older version that
    /// has since been superseded).
    var needsConsent: Bool {
        guard didHydrate else { return false }
        let p = profile
        let tosOk = p?.tosVersion == LegalURLs.termsVersion
        let privacyOk = p?.privacyVersion == LegalURLs.privacyVersion
        return !(tosOk && privacyOk)
    }

    /// Hard-gate flag: user is mid-signup and must complete phone
    /// verification before reaching the main app. Only true for users
    /// who came through the *new* onboarding flow (where birthdate write
    /// also sets `phoneOnboardingPending`). Legacy users — who finished
    /// onboarding before the phone gate existed — are excluded here so
    /// they aren't locked out on next launch; they see the soft prompt
    /// inside MainShell instead via `shouldPromptPhone`.
    var needsPhone: Bool {
        guard didHydrate else { return false }
        let n = profile?.phoneNumber ?? ""
        let pending = profile?.phoneOnboardingPending ?? false
        return n.isEmpty && pending
    }

    /// Soft-prompt flag: any signed-in, hydrated user who hasn't added a
    /// phone number yet. Used by MainShellView to surface a dismissible
    /// "add your phone" panel once per launch.
    var shouldPromptPhone: Bool {
        guard didHydrate else { return false }
        let n = profile?.phoneNumber ?? ""
        return n.isEmpty
    }

    /// True when the user has a phone number but hasn't yet been shown
    /// the "find friends from contacts" suggestion. MainShellView checks
    /// this to surface the ContactsSuggestionPanel exactly once. The
    /// full FriendFindView remains accessible from Profile regardless.
    var shouldSuggestContacts: Bool {
        guard didHydrate else { return false }
        let hasPhone = !(profile?.phoneNumber ?? "").isEmpty
        let alreadyShown = profile?.contactsPromptShown ?? false
        return hasPhone && !alreadyShown
    }

    /// Records that the contacts suggestion has been shown, so the
    /// panel doesn't reappear. Called whether the user tapped Allow or
    /// Skip — either way they made a decision. A write failure here is
    /// non-fatal: worst case the user sees the panel again next launch.
    func markContactsPromptShown() async {
        guard let uid = currentUid else { return }
        do {
            try await db.collection("userPrivate").document(uid).setData([
                "contactsPromptShown": true,
                "updatedAt": FieldValue.serverTimestamp(),
            ], merge: true)
        } catch {
            #if DEBUG
            print("[UserPrivate] markContactsPromptShown failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Writes

    /// Persists the birthdate + the *current* ToS / Privacy version + the
    /// matching consent timestamps in a single batch. Called once from the
    /// post-username onboarding screen; can also be called again later to
    /// re-record consent after a version bump.
    func acceptOnboarding(birthdate: Date) async throws {
        guard let uid = currentUid else {
            throw NSError(domain: "UserPrivateService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        let now = FieldValue.serverTimestamp()
        let payload: [String: Any] = [
            "birthdate":              Timestamp(date: birthdate),
            "ageConfirmedAt":         now,
            "tosAcceptedAt":          now,
            "tosVersion":             LegalURLs.termsVersion,
            "privacyAcceptedAt":      now,
            "privacyVersion":         LegalURLs.privacyVersion,
            // Marks this user as having entered the *new* signup flow.
            // The phone gate uses this to hard-route them into
            // `PhoneOnboardingView`; legacy users without this flag get
            // the soft prompt instead.
            "phoneOnboardingPending": true,
            "createdAt":              now,
            "updatedAt":              now,
        ]
        try await db.collection("userPrivate").document(uid)
            .setData(payload, merge: true)
    }

    /// Records consent for the *current* ToS / Privacy versions without
    /// touching the birthdate. Used when the user has already onboarded
    /// but a new version of the legal docs needs re-acceptance.
    func recordConsent() async throws {
        guard let uid = currentUid else { return }
        let now = FieldValue.serverTimestamp()
        try await db.collection("userPrivate").document(uid).setData([
            "tosAcceptedAt":     now,
            "tosVersion":        LegalURLs.termsVersion,
            "privacyAcceptedAt": now,
            "privacyVersion":    LegalURLs.privacyVersion,
            "updatedAt":         now,
        ], merge: true)
    }

    /// Records the user's verified phone number after Firebase Phone Auth
    /// has successfully linked it to the account. Performs two writes:
    ///   1. `userPrivate/{uid}` gets the plaintext E.164 number (owner-only).
    ///   2. `users/{uid}` gets `phoneHash` — SHA-256 of the same number —
    ///      which the friend-find query reads in PR 3 to match against
    ///      hashed contact lists. The plaintext never leaves the owner's
    ///      doc, so a friend who looks up someone else's hash can confirm
    ///      "this number is on the app" but cannot recover the digits.
    func setVerifiedPhone(_ phoneE164: String) async throws {
        guard let uid = currentUid else {
            throw NSError(domain: "UserPrivateService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        let now = FieldValue.serverTimestamp()

        try await db.collection("userPrivate").document(uid).setData([
            "phoneNumber":            phoneE164,
            "phoneVerifiedAt":        now,
            // Clear the hard-gate flag so future cold launches don't
            // re-enter the onboarding phone screen.
            "phoneOnboardingPending": FieldValue.delete(),
            "updatedAt":              now,
        ], merge: true)

        // The cross-readable `users/{uid}.phoneHash` is now written SERVER-SIDE
        // by the `commitVerifiedPhone` callable, which derives it from the
        // VERIFIED phone number on our Auth token — not from this client — which
        // closes the phone-hash impersonation hole. Force-refresh the ID token
        // first so the `phone_number` claim is present right after linking.
        // Best-effort: a failure here only delays contact-matching (recoverable
        // on a later verify) and must not strand phone onboarding.
        do {
            _ = try await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
            _ = try await Functions.functions().httpsCallable("commitVerifiedPhone").call()
        } catch {
            #if DEBUG
            print("[UserPrivate] commitVerifiedPhone failed (will retry on next verify): \(error.localizedDescription)")
            #endif
        }
    }

    /// SHA-256(E.164) as a lowercase hex string. Normalise upstream — the
    /// hash of `+60123456789` is different from `60123456789` or
    /// `0123456789`, so callers must pass the canonical E.164 form.
    static func phoneHash(_ phoneE164: String) -> String {
        let digest = SHA256.hash(data: Data(phoneE164.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort presence update. Throttled to once per
    /// `lastSeenInterval` seconds so foreground churn (notification
    /// glance, control-centre swipe) doesn't burn writes.
    func touchLastSeen() {
        guard let uid = currentUid else { return }
        let now = Date()
        if let last = lastSeenWrittenAt, now.timeIntervalSince(last) < Self.lastSeenInterval {
            return
        }
        lastSeenWrittenAt = now
        Task {
            try? await db.collection("users").document(uid).setData([
                "lastSeenAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }
}
