import FirebaseAppCheck
import FirebaseCore
import Foundation

/// Picks the right AppCheck provider per build configuration.
///
/// - **RELEASE** builds use `AppAttestProvider` — Apple's hardware-backed
///   device-attestation API. Firebase Auth uses the resulting token to
///   verify Phone Auth requests *without* needing APNs silent push or
///   reCAPTCHA, which sidesteps the SwiftUI `@UIApplicationDelegateAdaptor`
///   swizzling issue entirely.
/// - **DEBUG** builds use `AppCheckDebugProvider`, which prints a debug
///   token to the Xcode console on first launch. That token must be
///   registered in Firebase Console → AppCheck → CafeHunter → Manage
///   debug tokens before AppCheck-protected calls will succeed in dev.
///
/// Must be installed via `AppCheck.setAppCheckProviderFactory(_:)` BEFORE
/// `FirebaseApp.configure()` runs — otherwise the default (no-op) factory
/// is locked in for the rest of the process lifetime.
final class CafeHunterAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if DEBUG
        return AppCheckDebugProvider(app: app)
        #else
        // App Attest is iOS 14+; CafeHunter's deployment target is iOS 18.0
        // so the availability check is satisfied without a fallback.
        // NOTE: App Attest is unavailable on the Simulator and on
        // "Designed for iPad"/Apple-Silicon-Mac runs — Phone Auth on those
        // environments must rely on a registered debug token instead.
        return AppAttestProvider(app: app)
        #endif
    }
}
