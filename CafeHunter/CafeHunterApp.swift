import SwiftUI
import GoogleSignIn
import GooglePlacesSwift
import FirebaseAuth
import WidgetKit

@main
struct CafeHunterApp: App {
    // FirebaseApp.configure() lives in `AppDelegate.didFinishLaunching`
    // instead of here — required for the swizzling-disabled Phone Auth
    // setup (see AppDelegate.swift comment for the why).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppAudioSession.registerObservers()
        Self.configureGooglePlaces()
        // Carry an existing feed-style preference from the old boolean key
        // (`feed.usePolaroidFrame`) to the new enum key, once, on first launch
        // after the update — so polaroid users aren't reset to Classic.
        FeedCardStyle.migrateLegacyKeyIfNeeded()
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
            WanderyEntryView()
                // Scene-aware URL handling (iOS 26 deprecated the
                // AppDelegate `application(_:open:options:)` path). Both
                // Firebase Auth's reCAPTCHA return AND Google Sign-In's
                // callback land here.
                .onOpenURL { url in
                    if url.scheme == "wandery" {
                        // Widget tap → open the exact post it was showing
                        // (`wandery://post/<id>`), falling back to the friends
                        // feed (`wandery://feed`).
                        if url.host == "post", let id = url.pathComponents.last(where: { $0 != "/" }) {
                            NotificationRouter.shared.pending = .post(postId: id)
                            return
                        }
                        if url.host == "place", let id = url.pathComponents.last(where: { $0 != "/" }) {
                            NotificationRouter.shared.pending = .place(placeId: id)
                            return
                        }
                        if url.host == "nearby" {
                            NotificationRouter.shared.pending = .nearby
                            return
                        }
                        if url.host == "feed" {
                            NotificationRouter.shared.pending = .feed
                            return
                        }
                    }
                    // Spotify PKCE callback. ASWebAuthenticationSession normally
                    // consumes this via its own completion handler, so this
                    // branch is a fallback — and it stops the redirect falling
                    // through to the Firebase/Google handlers below.
                    if url.scheme == "cafehunter-spotify" {
                        SpotifyRedirectInbox.shared.consume(url)
                        return
                    }
                    if Auth.auth().canHandle(url) { return }
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Refresh the widget with whatever the app last cached when it
            // backgrounds, so the Home Screen reflects the latest feed.
            if phase == .background { WidgetCenter.shared.reloadAllTimelines() }
        }
    }
}
