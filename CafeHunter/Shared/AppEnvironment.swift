import Foundation

/// Lightweight runtime build-channel check.
enum AppEnvironment {
    /// True for TestFlight + local/dev builds, false for the App Store
    /// production build. TestFlight (and Xcode/sandbox) builds carry a
    /// `sandboxReceipt`; the production build carries `receipt`. Used to
    /// gate tester-only surfaces (e.g. the welcome message) so real users
    /// never see "you're an early tester" copy.
    ///
    /// `appStoreReceiptURL` is deprecated in favour of StoreKit 2's async
    /// `AppTransaction`, but that's overkill for a synchronous, non-security
    /// UI gate — the worst case here is a welcome banner showing (or not) to
    /// the wrong build channel. Deliberately keeping the simple sync check.
    static var isTester: Bool {
        #if DEBUG
        return true
        #else
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.lastPathComponent == "sandboxReceipt"
        #endif
    }
}
