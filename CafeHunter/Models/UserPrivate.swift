import Foundation

/// Owner-only profile fields stored at `userPrivate/{uid}`. Split from the
/// public `users/{uid}` doc so friends can read public profile data (name,
/// photo, bio) without ever seeing birthdate, phone, or consent timestamps.
///
/// All optional because the doc is hydrated incrementally — birthdate is
/// captured during onboarding, phone is added later when the user opts in.
struct UserPrivate: Equatable, Sendable {
    var birthdate: Date?
    /// When the user first confirmed their birthdate (proves the age gate
    /// was passed, separate from `birthdate` itself in case we ever allow
    /// editing the displayed birthday).
    var ageConfirmedAt: Date?

    var tosAcceptedAt: Date?
    var tosVersion: String?
    var privacyAcceptedAt: Date?
    var privacyVersion: String?

    /// E.164-formatted phone number (e.g. `+60123456789`). Owner-only.
    /// Friends never see this — `users/{uid}.phoneHash` is the queryable
    /// surface used by friend-find.
    var phoneNumber: String?
    /// Set when Firebase Phone Auth successfully links to the account.
    /// Different from `phoneNumber != nil` because we never write the
    /// number unless verification succeeded.
    var phoneVerifiedAt: Date?
    /// True for users who passed through the *new* signup flow (which
    /// includes a required phone step) but haven't completed the phone
    /// part yet. Used by routing to distinguish a *new* user mid-flow
    /// from a *legacy* user who onboarded before the phone gate existed:
    /// new users are hard-gated, legacy users get a dismissible prompt.
    /// Set in `acceptOnboarding`, cleared in `setVerifiedPhone`.
    var phoneOnboardingPending: Bool?

    /// Whether the user has already been shown (and accepted or
    /// dismissed) the "find friends from contacts" suggestion panel.
    /// Used so the panel only nags once. The full FriendFind screen
    /// stays accessible from Profile regardless.
    var contactsPromptShown: Bool?

    /// Soft-delete marker. A Cloud Function tears the account down after a
    /// grace period; nil = active.
    var deletionRequestedAt: Date?

    var createdAt: Date?
    var updatedAt: Date?
}
