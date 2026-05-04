import SwiftUI
import FirebaseCore
import GoogleSignIn
import GooglePlacesSwift

@main
struct CafeHunterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        FirebaseApp.configure()
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
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
