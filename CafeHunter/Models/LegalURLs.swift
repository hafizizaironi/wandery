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

    /// Public download / share link used in invites. Until the App Store
    /// listing exists, this points at the Wandery landing page (GitHub Pages,
    /// which loads today) so invite messages are never a dead link. Once the
    /// app is live, change this one line to
    /// `https://apps.apple.com/app/id<APP_ID>`.
    static let appStoreURL = URL(string: "https://hafizizaironi.github.io/wandery/")!

    /// Limited TestFlight beta invite for the final testing phase. Apple
    /// caps public TestFlight links at 100 testers, so this is shared widely
    /// while seats remain. Once the public App Store listing is live, point
    /// invites at `appStoreURL` instead and retire this constant.
    static let testFlightInvite = URL(string: "https://testflight.apple.com/join/fhTBWC45")!

    /// Subject line for invite emails sent from the share sheet.
    static let inviteSubject = "Come hunt with me on Wandery 🔥"

    /// Warm, on-brand invite copy for the share sheet. Shared as plain text
    /// with the link inline — so the message + link travel intact across
    /// every channel (Messages, WhatsApp, Instagram DMs, email), not only
    /// the ones that render a URL preview. Makes the recipient feel
    /// hand-picked for the beta rather than cold-blasted.
    static var inviteShareText: String {
        """
        You're invited to Wandery 🔥

        I'm building a little app for hunting down the best cafés & food spots — and sharing the finds with your circle. We're in the final stretch of testing with only a handful of beta seats left, so I saved one for you.

        Jump in, post your finds, and tell me what feels off — you're part of the crew now. 🤝

        \(testFlightInvite.absoluteString)

        Stay hunting. 🔥
        """
    }

    /// Published support contact. Reviewers expect this to be reachable
    /// from inside the app — Profile → Settings → Contact support.
    static let supportEmail = "hafizizaironi@gmail.com"

    /// `mailto:` URL with a friendly, pre-filled subject + body so reaching
    /// out feels like messaging a person, not filing a ticket. The prompt
    /// nudges testers to describe what happened and attach a screenshot,
    /// which is exactly the signal that's most useful during the beta.
    /// Built with `URLComponents` so the emoji + newlines encode correctly.
    static var supportMailto: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Hey Wandery 👋"),
            URLQueryItem(name: "body", value: """
            What's on your mind? A bug, an idea, or something that just felt off — every bit of it helps us make Wandery better.

            If you hit a bug, a quick note on what you were doing (and a screenshot, if you can) goes a long way.

            We read every message. 🔥
            """)
        ]
        return components.url ?? URL(string: "mailto:\(supportEmail)")!
    }

    /// Version identifiers for the Terms of Use and Privacy Policy. Bumped
    /// whenever the hosted documents change in a material way. The signup
    /// flow records the accepted version on the user's private doc; if the
    /// version here doesn't match what the user accepted, they're re-
    /// prompted on next launch. Date-based so the "what did they accept"
    /// answer is grep-able from Firestore.
    static let termsVersion = "2026-05-23"
    // Re-bump to the analytics-disclosure date ("2026-06-08") ONLY in the
    // release that actually ships product analytics to the App Store, and after
    // the hosted privacy policy update is live — bumping re-prompts every user
    // to re-accept (via the birthdate+consent screen). Held at 2026-05-23 for
    // now so testers aren't re-prompted prematurely.
    static let privacyVersion = "2026-05-23"

    /// Minimum age required to use the app. 13 mirrors COPPA in the US and
    /// the most common floor across regions. Some EU member states require
    /// 16 — leave country-specific tightening for later.
    static let minimumAge = 13
}
