import SwiftUI
import UIKit
import CoreLocation
import FirebaseAuth

/// App root. Owns the shared services and the cold-launch entry sequence over
/// the live router. Every transition is a **circular close-in**:
///
///   loading splash (cropped polaroid, no text)
///     → close-in → the login page (its own map background), or straight onto
///       Hero for an already-signed-in user
///     → on sign-in the login **panel slides down** first (its map keeps
///       covering the app's loading state — no white splash flash), then the
///       map **circular-closes onto Hero**.
///
/// The entry owns the login layer (not `RootRouterView`) so it can choreograph
/// that panel-down → close-in sequence. See
/// `~/.claude/plans/delightful-jumping-lemur.md`.
struct WanderyEntryView: View {
    @State private var authService          = AuthService()
    @State private var firestoreService     = FirestoreService()
    @State private var statsService         = UserStatsService()
    @State private var socialService        = SocialService()
    @State private var userPrivateService   = UserPrivateService()
    @State private var visitTracker         = VisitTrackerService()
    @State private var conversationService  = ConversationService()
    /// Lightweight instance just for the close-in map's pins.
    @State private var entryPlaces          = FriendPlacesService()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false

    // Splash layer (top) — closes onto the login or Hero.
    @State private var splashActive = true
    @State private var splashScale: CGFloat = 1
    @State private var splashClose: CGFloat = 1
    @State private var splashOpacity: Double = 1

    // Login layer — the real, interactive LoginView (its own map + the panel
    // whose up/down the entry drives).
    @State private var loginActive = false
    @State private var loginPanelUp = false
    @State private var loginClose: CGFloat = 1
    @State private var loginOpacity: Double = 1

    // Logout layer — a frozen snapshot of the app, taken before the router
    // clears, that circular-CLOSES to reveal the login beneath. Without it the
    // router blanks to its base colour the instant sign-out lands (the white
    // flash), then the login animates in over white.
    @State private var logoutCoverActive = false
    @State private var logoutCoverImage: UIImage?
    @State private var logoutClose: CGFloat = 1

    // Cover layer — a bare map used for the close-in into Hero when there's no
    // login on screen (a new user finishing onboarding gates).
    @State private var coverActive = false
    @State private var coverClose: CGFloat = 1
    @State private var coverOpacity: Double = 1
    @State private var coverPins: [EntryPin] = []

    @State private var didStartIntro = false
    @State private var hasEnteredApp = false
    @State private var handledLogin = false

    private var isFullyOnboarded: Bool {
        authService.user != nil
        && !socialService.isLoadingProfile
        && !userPrivateService.isLoading
        && !socialService.needsUsername
        && !userPrivateService.needsBirthdate
        && !userPrivateService.needsConsent
        && !userPrivateService.needsPhone
    }

    var body: some View {
        ZStack {
            RootRouterView(
                authService:         authService,
                firestoreService:    firestoreService,
                statsService:        statsService,
                socialService:       socialService,
                userPrivateService:  userPrivateService,
                visitTracker:        visitTracker,
                conversationService: conversationService
            )

            if coverActive {
                EntryMapBackground(pins: coverPins)
                    .modifier(CircularClose(progress: coverClose))
                    .opacity(coverOpacity)
                    .ignoresSafeArea()
            }

            if loginActive {
                LoginView(authService: authService, panelUp: $loginPanelUp)
                    .modifier(CircularClose(progress: loginClose))
                    .opacity(loginOpacity)
                    .ignoresSafeArea()
            }

            // Drawn above the login so it hides the router blanking beneath;
            // closing it in reveals the freshly-presented login.
            if logoutCoverActive, let img = logoutCoverImage {
                Image(uiImage: img)
                    .resizable()
                    .ignoresSafeArea()
                    .modifier(CircularClose(progress: logoutClose))
                    .allowsHitTesting(false)
            }

            if splashActive {
                splashLayer
                    .modifier(CircularClose(progress: splashClose))
                    .opacity(splashOpacity)
                    .ignoresSafeArea()
            }
        }
        .task { await startIfNeeded() }
        .task(id: socialService.feedPosts.count) {
            guard authService.user != nil, !socialService.feedPosts.isEmpty else { return }
            await entryPlaces.refresh(from: socialService.feedPosts)
        }
        .onChange(of: authService.user?.uid) { _, uid in
            if uid != nil {
                // Signed in from the entry login.
                if loginActive, !handledLogin {
                    handledLogin = true
                    Task { await handlePostLogin() }
                }
            } else {
                // Signed out mid-session → iris the login open over the canvas
                // the app left behind (the inverse of the sign-in close-in).
                guard didStartIntro, !splashActive, hasSeenWelcome else { return }
                hasEnteredApp = false
                handledLogin = false
                presentLoginCloseIn()
            }
        }
        .onChange(of: hasSeenWelcome) { _, seen in
            // New user finished the welcome carousel → present the login.
            guard seen, authService.user == nil, didStartIntro,
                  !splashActive, !loginActive else { return }
            presentLoginRaised()
        }
        .onChange(of: isFullyOnboarded) { _, onboarded in
            // A new user finished onboarding gates (no login on screen) → cover
            // with the map and close in on Hero.
            guard onboarded, !hasEnteredApp, didStartIntro,
                  !splashActive, !loginActive else { return }
            hasEnteredApp = true
            Task { await runCoverCloseIn() }
        }
    }

    // MARK: - Splash (cropped polaroid only — no text, no square)

    private var splashLayer: some View {
        ZStack {
            EntryPalette.splashBackground.ignoresSafeArea()

            Image("WanderyPolaroidPin")
                .resizable()
                .scaledToFit()
                .frame(width: 150, height: 150)
                .scaleEffect(splashScale)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wandery, loading")
    }

    // MARK: - Sequence

    private func startIfNeeded() async {
        guard !didStartIntro else { return }
        didStartIntro = true

        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) {
                splashScale = 1.03
            }
        }

        // Minimum dwell (the deliberate beat), then hold the breathing splash
        // until auth + profile have settled so we land on the right screen and
        // never close in on a half-loaded shell.
        try? await Task.sleep(for: .seconds(reduceMotion ? EntryTiming.reducedHold : EntryTiming.loadingHold))
        while authService.isLoading { try? await Task.sleep(for: .seconds(0.05)) }
        if authService.user != nil { await waitForProfileSettled() }

        if authService.user == nil {
            if hasSeenWelcome {
                // Present the login *under* the splash, then close the splash
                // while the panel rises — splash gives way to the login page.
                loginActive = true
                loginPanelUp = false
                loginClose = 1; loginOpacity = 1
                try? await Task.sleep(for: .seconds(0.05))
                if !reduceMotion {
                    withAnimation(.entryPanel) { loginPanelUp = true }
                } else {
                    loginPanelUp = true
                }
                await closeSplash()
            } else {
                // Reveal the welcome carousel (RootRouter); login comes after.
                await closeSplash()
            }
        } else if isFullyOnboarded {
            // Returning user — splash closes straight onto Hero.
            hasEnteredApp = true
            await closeSplash()
        } else {
            // Signed in but mid-onboarding at launch — reveal the gate.
            await closeSplash()
        }
    }

    /// Sign-in from the entry login: slide the panel down, keep the login's map
    /// covering the app's loading state, then close in on Hero (or, for a new
    /// user, give way to the onboarding gate).
    private func handlePostLogin() async {
        withAnimation(.entryPanel) { loginPanelUp = false }
        try? await Task.sleep(for: .seconds(0.45))

        await waitForProfileSettled()

        if isFullyOnboarded {
            hasEnteredApp = true
            coverPins = resolveEntryPins()   // (login already has a matching map)
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.5)) { loginOpacity = 0 }
                try? await Task.sleep(for: .seconds(0.5))
            } else {
                withAnimation(.entryClose) { loginClose = 0 }
                try? await Task.sleep(for: .seconds(EntryTiming.closeIn))
            }
            loginActive = false
        } else {
            // New user → onboarding gate. Fade the login away to reveal it; the
            // close-in fires later when the gates clear.
            withAnimation(.easeInOut(duration: 0.4)) { loginOpacity = 0 }
            try? await Task.sleep(for: .seconds(0.4))
            loginActive = false
            loginOpacity = 1
        }
    }

    /// Close-in into Hero from a bare map cover (used when no login is on
    /// screen — a new user finishing onboarding).
    private func runCoverCloseIn() async {
        coverPins = resolveEntryPins()
        coverClose = 1; coverOpacity = 1
        coverActive = true
        try? await Task.sleep(for: .seconds(0.05))

        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.5)) { coverOpacity = 0 }
            try? await Task.sleep(for: .seconds(0.5))
        } else {
            withAnimation(.entryClose) { coverClose = 0 }
            try? await Task.sleep(for: .seconds(EntryTiming.closeIn))
        }
        coverActive = false
    }

    private func closeSplash() async {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.4)) { splashOpacity = 0 }
            try? await Task.sleep(for: .seconds(0.4))
        } else {
            withAnimation(.entryClose) { splashClose = 0 }
            try? await Task.sleep(for: .seconds(EntryTiming.closeIn))
        }
        splashActive = false
    }

    private func presentLoginRaised() {
        loginActive = true
        loginClose = 1; loginOpacity = 1
        loginPanelUp = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if reduceMotion {
                loginPanelUp = true
            } else {
                withAnimation(.entryPanel) { loginPanelUp = true }
            }
        }
    }

    /// Logout: **circular close-in**. Freeze the app as it still looks, present
    /// the finished login beneath, then collapse the frozen snapshot into a
    /// point to reveal the login — so the router clearing to its base colour
    /// never flashes (the inverse of the sign-in close-in).
    private func presentLoginCloseIn() {
        // Capture BEFORE touching any state, while the app is still on screen.
        let snapshot = Self.captureScreen()

        // Login waits, fully formed (sheet up), beneath the cover.
        loginActive = true
        loginOpacity = 1
        loginClose = 1
        loginPanelUp = true

        guard !reduceMotion, let snapshot else {
            // Reduce Motion or capture failed → just present the login.
            return
        }

        logoutCoverImage = snapshot
        logoutClose = 1
        logoutCoverActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.entryClose) { logoutClose = 0 }   // app closes in
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + EntryTiming.closeIn + 0.1) {
            logoutCoverActive = false
            logoutCoverImage = nil
        }
    }

    /// A still image of the current screen — used to circular-close the app on
    /// logout. `afterScreenUpdates: false` grabs the pixels already on screen
    /// (the app), not the router's pending blank frame.
    private static func captureScreen() -> UIImage? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
        guard let window else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    // MARK: - Helpers

    /// Bounded wait so the splash never hangs forever on a flaky network.
    private func waitForProfileSettled() async {
        let deadline = Date().addingTimeInterval(6)
        while (socialService.isLoadingProfile || userPrivateService.isLoading),
              Date() < deadline {
            try? await Task.sleep(for: .seconds(0.05))
        }
    }

    /// Real places from the feed when available; otherwise a curated demo
    /// scatter so the close-in map always has life.
    private func resolveEntryPins() -> [EntryPin] {
        let places = entryPlaces.places
        if !places.isEmpty {
            return places.prefix(7).map { place in
                let post = place.mostRecent
                let urlString = post?.primaryThumbnailURL ?? post?.primaryMediaURL
                let letter = String((post?.authorUsername ?? place.name).prefix(1)).uppercased()
                return EntryPin(
                    id: place.id,
                    coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng),
                    photoURL: urlString.flatMap(URL.init(string:)),
                    photoName: nil,
                    profileLetter: letter.isEmpty ? "•" : letter,
                    hue: Double(abs(place.id.hashValue) % 100) / 100.0,
                    isStall: place.type == .stall
                )
            }
        }
        return EntryPin.demoPins(around: EntryMapBackground.resolveCenter())
    }
}

#Preview {
    WanderyEntryView()
}
