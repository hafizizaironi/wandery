import FirebaseAuth
import SwiftUI

/// The app's state router: picks the destination from auth + onboarding-gate
/// state. Extracted from the old `ContentView` so `WanderyEntryView` can own
/// the shared services and host this router *beneath* the cold-launch entry
/// chrome (splash → iris → map → dive). The routing ladder + lifecycle wiring
/// here is unchanged from before; only ownership of the services moved up.
struct RootRouterView: View {
    var authService:          AuthService
    var firestoreService:     FirestoreService
    var statsService:         UserStatsService
    var socialService:        SocialService
    var userPrivateService:   UserPrivateService
    var visitTracker:         VisitTrackerService
    var conversationService:  ConversationService
    var permissionsManager:   PermissionsManager
    var spotifyAuth:          SpotifyAuthService
    var postMusicPlayer:      PostMusicPlayer
    var frameCatalog:         FrameCatalogService

    @Environment(\.scenePhase) private var scenePhase

    /// Persists across launches — set true after a user finishes (or skips)
    /// the welcome carousel. Returning users skip straight to LoginView.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false

    /// Per-install latch for the queued permission-priming flow. Wiped on
    /// re-download (so the flow re-shows), persists across logout (so it never
    /// re-fires on a same-device account switch). The flag — not the live
    /// status — is the latch, so a user tapping "Maybe later" can't loop it.
    @AppStorage("hasSeenPermissionPriming") private var hasSeenPermissionPriming: Bool = false

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            if authService.isLoading {
                SplashView()
            } else if authService.user == nil {
                if hasSeenWelcome {
                    // The login screen is presented by the entry layer
                    // (`WanderyEntryView`) over the live map, so it can own the
                    // panel slide-down + circular close-in. Nothing to draw
                    // here — the entry chrome covers this canvas.
                    Color.clear
                } else {
                    WelcomeView(onComplete: {
                        // The carousel's "Get started" / "Maybe later" route
                        // here. The entry layer then presents the login.
                        withAnimation(Motion.modal) {
                            hasSeenWelcome = true
                        }
                    })
                    .transition(.opacity)
                }
            } else if socialService.isLoadingProfile || userPrivateService.isLoading {
                SplashView()
            } else if socialService.needsUsername {
                UsernameOnboardingView(socialService: socialService, authService: authService)
            } else if userPrivateService.needsBirthdate || userPrivateService.needsConsent {
                BirthdateOnboardingView(
                    userPrivateService: userPrivateService,
                    authService:        authService
                )
            } else if userPrivateService.needsPhone {
                PhoneOnboardingView(
                    userPrivateService: userPrivateService,
                    authService:        authService
                )
            } else if !hasSeenPermissionPriming && permissionsManager.hasUndeterminedCorePermission {
                // Queued, one-at-a-time permission priming — runs once after
                // onboarding, before the main app, so the OS prompts never burst.
                PermissionPrimingView(permissions: permissionsManager) {
                    withAnimation(Motion.modal) { hasSeenPermissionPriming = true }
                }
                .transition(.opacity)
                .task { await permissionsManager.refreshAllStatuses() }
            } else {
                MainShellView(
                    authService:         authService,
                    firestoreService:    firestoreService,
                    statsService:        statsService,
                    socialService:       socialService,
                    conversationService: conversationService,
                    userPrivateService:  userPrivateService,
                    spotifyAuth:         spotifyAuth,
                    postMusicPlayer:     postMusicPlayer,
                    frameCatalog:        frameCatalog
                )
                // Fresh identity per signed-in user so a re-login always
                // rebuilds the shell from its defaults — i.e. lands on the
                // Hero tab — instead of restoring the tab the previous session
                // signed out from.
                .id(authService.user?.uid)
                .onAppear  { firestoreService.subscribe() }
                .onDisappear { firestoreService.unsubscribe() }
            }
        }
        .animation(Motion.modal, value: authService.isLoading)
        .animation(Motion.modal, value: authService.user?.uid)
        .animation(Motion.modal, value: hasSeenWelcome)
        .animation(Motion.modal, value: hasSeenPermissionPriming)
        // Subscribe / unsubscribe stats listener when auth state changes
        .onChange(of: authService.user?.uid) { _, uid in
            if let uid {
                statsService.subscribe(uid: uid)
            } else {
                statsService.unsubscribe()
                // Sign-out: drop in-memory Spotify state and silence any feed
                // music. Tokens stay in the keychain so a re-login reconnects.
                spotifyAuth.reset()
                postMusicPlayer.stop()
            }
        }
        .onAppear {
            if let uid = authService.user?.uid {
                statsService.subscribe(uid: uid)
            }
        }
        .task(id: authService.user?.uid) {
            socialService.start(for: authService.user)
            userPrivateService.start(for: authService.user)
            conversationService.start(for: authService.user)
            spotifyAuth.start(for: authService.user)
            // Catch up on any visit sessions that need to close after a
            // cold start. Cheap no-op when nothing's open.
            if authService.user != nil {
                await visitTracker.sweepIfNeeded(force: true)
                // First foreground after sign-in / cold launch counts as
                // a presence event. The service throttles internally so
                // repeated calls within ~5 min collapse to one write.
                userPrivateService.touchLastSeen()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-check when the user comes back to the app — if they've
            // walked or driven > 3 km from where they last posted, the
            // session closes so the next post counts as a fresh visit.
            guard phase == .active, authService.user != nil else { return }
            Task { await visitTracker.sweepIfNeeded() }
            userPrivateService.touchLastSeen()
        }
    }
}

struct SplashView: View {
    /// Drives the continuous rotation. Goes 0 → 360, then resets to 0
    /// (instantly, no animation) so each subsequent revolution starts
    /// from the same angle without snapping back through 360→0.
    @State private var rotation: Double = 0
    /// Subtle scale pulse layered on top of the rotation — gives the
    /// spinner a tiny "breath" so it doesn't feel mechanical.
    @State private var pulsing = false

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            Image("WanderyPolaroidPin")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(rotation))
                .scaleEffect(pulsing ? 1.05 : 0.97)
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
                .onAppear {
                    // Continuous rotation: 1.6s per revolution, linear so
                    // the spin reads as a steady buffer-style loader.
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                    // Independent slow pulse for the gentle breathing.
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                }
        }
    }
}

#Preview {
    WanderyEntryView()
}
