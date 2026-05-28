import SwiftUI
import GoogleSignIn
import GooglePlacesSwift
import FirebaseAuth

@main
struct CafeHunterApp: App {
    // FirebaseApp.configure() lives in `AppDelegate.didFinishLaunching`
    // instead of here — required for the swizzling-disabled Phone Auth
    // setup (see AppDelegate.swift comment for the why).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppAudioSession.registerObservers()
        Self.configureGooglePlaces()
        // Touch the LocationProvider singleton so it starts asking for / caching
        // a location before the user ever opens the place picker.
        _ = LocationProvider.shared
    }

    private static func configureGooglePlaces() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GMSPlacesAPIKey") as? String,
              !key.isEmpty else {
            assertionFailure("Missing GMSPlacesAPIKey in Info.plist")
            return
        }
        _ = PlacesClient.provideAPIKey(key)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Scene-aware URL handling (iOS 26 deprecated the
                // AppDelegate `application(_:open:options:)` path). Both
                // Firebase Auth's reCAPTCHA return AND Google Sign-In's
                // callback land here.
                .onOpenURL { url in
                    if Auth.auth().canHandle(url) { return }
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
