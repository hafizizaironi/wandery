import FirebaseAuth
import SwiftUI

struct ContentView: View {
    @State private var authService          = AuthService()
    @State private var firestoreService     = FirestoreService()
    @State private var statsService         = UserStatsService()
    @State private var socialService        = SocialService()
    @State private var userPrivateService   = UserPrivateService()
    @State private var visitTracker         = VisitTrackerService()
    @State private var conversationService  = ConversationService()
    @Environment(\.scenePhase) private var scenePhase

    /// Persists across launches — set true after a user finishes (or skips)
    /// the welcome carousel. Returning users skip straight to LoginView.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            if authService.isLoading {
                SplashView()
            } else if authService.user == nil {
                if hasSeenWelcome {
                    LoginView(authService: authService)
                        .transition(.opacity)
                } else {
                    WelcomeView(onComplete: {
                        // The carousel's "Get started" / "Maybe later"
                        // route here. Fade — not slide — into LoginView
                        // so the auth surface feels like a continuation
                        // of the same canvas, not a new screen.
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
            } else {
                MainShellView(
                    authService:         authService,
                    firestoreService:    firestoreService,
                    statsService:        statsService,
                    socialService:       socialService,
                    conversationService: conversationService,
                    userPrivateService:  userPrivateService
                )
                .onAppear  { firestoreService.subscribe() }
                .onDisappear { firestoreService.unsubscribe() }
            }
        }
        .animation(Motion.modal, value: authService.isLoading)
        .animation(Motion.modal, value: authService.user?.uid)
        .animation(Motion.modal, value: hasSeenWelcome)
        // Subscribe / unsubscribe stats listener when auth state changes
        .onChange(of: authService.user?.uid) { _, uid in
            if let uid {
                statsService.subscribe(uid: uid)
            } else {
                statsService.unsubscribe()
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
    @State private var pulsing = false

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()
            Text("☕")
                .font(.system(size: 60))
                .foregroundColor(AppTheme.cream.opacity(0.85))
                .scaleEffect(pulsing ? 1.1 : 0.95)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
        }
    }
}

#Preview {
    ContentView()
}
