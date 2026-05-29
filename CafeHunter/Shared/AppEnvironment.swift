import Foundation

/// Lightweight runtime build-channel check.
enum AppEnvironment {
    /// True for TestFlight + local/dev builds, false for the App Store
    /// production build. TestFlight (and Xcode/sandbox) builds carry a
    /// `sandboxReceipt`; the production build carries `receipt`. Used to
    /// gate tester-only surfaces (e.g. the welcome message) so real users
    /// never see "you're an early tester" copy.
    ///
    /// Synchronous TestFlight / sandbox check. StoreKit 2's `AppTransaction` is
    /// async and overkill for a non-security UI gate. On iOS 18+ we construct
    /// the known sandbox receipt path directly to avoid the deprecated API.
    static var isTester: Bool {
        #if DEBUG
        return true
        #else
        if #available(iOS 18.0, *) {
            let sandboxReceiptURL = Bundle.main.bundleURL
                .appendingPathComponent("StoreKit/sandboxReceipt")
            return FileManager.default.fileExists(atPath: sandboxReceiptURL.path)
        } else {
            guard let url = Bundle.main.appStoreReceiptURL else { return false }
            return url.lastPathComponent == "sandboxReceipt"
        }
        #endif
    }
}
