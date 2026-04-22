import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct CafeHunterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        FirebaseApp.configure()
        AppAudioSession.registerObservers()
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
