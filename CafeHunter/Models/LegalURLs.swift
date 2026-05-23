import Foundation

/// Centralized constants for legal documents + support contact.
///
/// **App Store reviewer requirements (Guideline 1.2 + 5.1.1):**
/// - `termsOfUse` and `privacyPolicy` must be publicly accessible URLs.
///   The Terms must forbid objectionable content and commit to acting on
///   user reports within 24 hours. Both URLs must also be set in App Store
///   Connect (Privacy Policy URL field + EULA URL or Terms in description).
/// - `supportEmail` is the published contact reviewers reach the developer
///   at when a user wants to escalate beyond the in-app report flow.
///
/// **Pre-submission TODO for Hafiz:**
/// 1. Host the Terms + Privacy pages somewhere stable (GitHub Pages,
///    Notion public page, your own domain — Apple doesn't care which).
/// 2. Update the placeholder URLs below to the real ones.
/// 3. Mirror the Privacy Policy URL into App Store Connect → App Privacy.
/// 4. Mirror the Terms URL into App Store Connect → EULA (or paste the
///    full Terms text into the EULA field if it's short).
enum LegalURLs {
    /// Hosted via GitHub Pages from this repo's /docs directory. If the
    /// repo is renamed (e.g. wandery → cafehunter) or moved to a custom
    /// domain, update both URLs here.
    static let termsOfUse = URL(string: "https://hafizizaironi.github.io/wandery/terms")!

    static let privacyPolicy = URL(string: "https://hafizizaironi.github.io/wandery/privacy")!

    /// Published support contact. Reviewers expect this to be reachable
    /// from inside the app — Profile → Settings → Contact support.
    static let supportEmail = "hafizizaironi@gmail.com"

    /// `mailto:` URL with a default subject so support requests are
    /// easier to triage.
    static var supportMailto: URL {
        URL(string: "mailto:\(supportEmail)?subject=Wandery%20Support")!
    }

    /// Version identifiers for the Terms of Use and Privacy Policy. Bumped
    /// whenever the hosted documents change in a material way. The signup
    /// flow records the accepted version on the user's private doc; if the
    /// version here doesn't match what the user accepted, they're re-
    /// prompted on next launch. Date-based so the "what did they accept"
    /// answer is grep-able from Firestore.
    static let termsVersion = "2026-05-23"
    static let privacyVersion = "2026-05-23"

    /// Minimum age required to use the app. 13 mirrors COPPA in the US and
    /// the most common floor across regions. Some EU member states require
    /// 16 — leave country-specific tightening for later.
    static let minimumAge = 13
}
