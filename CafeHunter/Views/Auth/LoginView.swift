import AuthenticationServices
import CoreLocation
import MapKit
import SwiftUI
import FirebaseAuth

struct LoginView: View {
    var authService: AuthService

    @State private var mode: AuthMode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var errorMessage = ""
    @State private var isLoading = false
    /// Captured per-attempt; the SHA-256 of this goes to Apple, the raw
    /// value goes to Firebase. Regenerated for each authorization request.
    @State private var appleNonce: String = ""
    @AccessibilityFocusState private var errorFocused: Bool

    /// Probes the user's current locality so the headline can show their
    /// actual city instead of a hardcoded "Rawang". We never call
    /// `requestPermission()` here — that would prompt before sign-in, which
    /// reviewers and users dislike. If Location was previously authorized
    /// (returning users), `LocationManager` will start updating on its own
    /// via the `locationManagerDidChangeAuthorization` callback.
    @State private var locationManager = LocationManager()
    @State private var localityName: String?

    /// Drives the bottom-sheet slide over the entry map. Owned by the entry
    /// layer (`WanderyEntryView`) so it can raise the panel after the splash
    /// closes in, and slide it back down on a successful sign-in *before* the
    /// circular close-in into the app fires.
    @Binding var panelUp: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // The looping map fly-over behind the sheet — a live camera tour
            // over real trending spots (cached from a prior signed-in Discover
            // load), with photos popping in along the path. Falls back to a
            // demo scatter on a true first launch.
            EntryMapFlyover(pins: EntryPin.loginPins(around: EntryMapBackground.resolveCenter()))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header — app mark + serif wordmark over the map.
                VStack(spacing: 10) {
                    Image("WanderyPolaroidPin")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                        .accessibilityHidden(true)
                    Text("wandery")
                        .font(.wanderyWordmark(34))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Find where \(localityName ?? "KL") is really eating.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: localityName)
                        .multilineTextAlignment(.center)
                    Text(mode == .login ? "Welcome back! Sign in to continue." : "Create an account to get started.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 26)
                .padding(.bottom, 18)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AppTheme.borderSubtle.opacity(0.7))
                        .frame(height: 1)
                    }

                    // Body
                    VStack(spacing: 16) {
                        // Sign in with Apple — kept first so it's at least
                        // as prominent as Google (Apple Guideline 4.8).
                        SignInWithAppleButton(
                            .continue,
                            onRequest: { request in
                                appleNonce = AppleSignInNonce.random()
                                request.requestedScopes = [.fullName, .email]
                                request.nonce = AppleSignInNonce.sha256(appleNonce)
                            },
                            onCompletion: { result in
                                Task { await handleAppleAuth(result) }
                            }
                        )
                        .signInWithAppleButtonStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .clipShape(.rect(cornerRadius: 12))
                        .disabled(isLoading)

                        // Google button
                        Button {
                            Task { await signInWithGoogle() }
                        } label: {
                            HStack(spacing: 10) {
                                Image("GoogleLogo")
                                    .renderingMode(.original)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                Text("Continue with Google")
                                    .font(.subheadline).bold()
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .clipShape(.rect(cornerRadius: 12))
                        }
                        .disabled(isLoading)

                        // Divider
                        HStack {
                            Rectangle().fill(AppTheme.textPrimary.opacity(0.12)).frame(height: 1)
                            Text("or")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 8)
                            Rectangle().fill(AppTheme.textPrimary.opacity(0.12)).frame(height: 1)
                        }

                        // Form
                        VStack(spacing: 10) {
                            if mode == .signup {
                                AuthTextField(placeholder: "Your name", text: $name)
                            }
                            AuthTextField(placeholder: "Email address", text: $email)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            AuthTextField(placeholder: "Password", text: $password, isSecure: true)

                            if !errorMessage.isEmpty {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.errorRed)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityFocused($errorFocused)
                            }

                            Button {
                                Task { await handleEmailAuth() }
                            } label: {
                                Group {
                                    if isLoading {
                                        ProgressView().tint(AppTheme.textOnAccent)
                                    } else {
                                        Text(mode == .login ? "Sign in" : "Create account")
                                            .font(.subheadline).bold()
                                            .foregroundStyle(AppTheme.textOnAccent)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(AppTheme.cafeAccent)
                                .clipShape(.rect(cornerRadius: 12))
                            }
                            .disabled(isLoading)
                        }

                        // Toggle mode
                        HStack(spacing: 4) {
                            Text(mode == .login ? "Don't have an account?" : "Already have an account?")
                                .font(.caption)
                                .foregroundStyle(AppTheme.cream.opacity(0.4))
                                Button {
                                    mode = mode == .login ? .signup : .login
                                    errorMessage = ""
                                } label: {
                                    Text(mode == .login ? "Sign up" : "Sign in")
                                        .font(.caption).bold()
                                        .foregroundStyle(AppTheme.cafeAccent)
                                        .underline()
                                }
                        }

                        // App Store Guideline 1.2: EULA + Privacy Policy
                        // must be reachable from the sign-in surface so the
                        // user agrees before creating an account.
                        Text("By continuing, you accept our [Terms of Use](\(LegalURLs.termsOfUse.absoluteString)) and [Privacy Policy](\(LegalURLs.privacyPolicy.absoluteString)).")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cream.opacity(0.5))
                            .tint(AppTheme.cafeAccent)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity)
                .background(AppTheme.surfaceCanvas)
                .clipShape(.rect(topLeadingRadius: 34, topTrailingRadius: 34))
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(AppTheme.borderSubtle)
                        .frame(width: 38, height: 5)
                        .padding(.top, 9)
                }
                .shadow(color: .black.opacity(0.18), radius: 22, y: -4)
                .offset(y: panelUp ? 0 : 720)
                .opacity(panelUp ? 1 : 0)
                .ignoresSafeArea(edges: .bottom)
        }
        .keyboardDismissToolbar()
        .task { await refreshLocalityHint() }
        .onChange(of: locationManager.userLocation?.latitude) { _, _ in
            Task { await refreshLocalityHint() }
        }
    }

    // MARK: - Actions

    /// Reverse-geocodes the current user location into a city/town name.
    /// Silently no-ops if location isn't available (no permission, or
    /// updates haven't arrived yet) — the headline keeps its "You" fallback.
    private func refreshLocalityHint() async {
        guard let coord = locationManager.userLocation else { return }
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        if let resolved = await Geocoding.cityName(at: location) {
            localityName = resolved
        }
    }

    private func signInWithGoogle() async {
        isLoading = true
        errorMessage = ""
        do {
            try await authService.signInWithGoogle()
        } catch AuthServiceError.cancelled {
            // User backed out of the Google sheet — silent, no error
            // (matches the Apple .canceled handling below).
        } catch {
            errorMessage = error.localizedDescription
            errorFocused = true
        }
        isLoading = false
    }

    private func handleAppleAuth(_ result: Result<ASAuthorization, Error>) async {
        isLoading = true
        errorMessage = ""
        do {
            let authorization = try result.get()
            try await authService.signInWithApple(
                authorization: authorization,
                rawNonce: appleNonce
            )
        } catch let authError as ASAuthorizationError where authError.code == .canceled {
            // User cancelled — silent, leave isLoading off and no error.
        } catch {
            errorMessage = error.localizedDescription
            errorFocused = true
        }
        isLoading = false
    }

    private func handleEmailAuth() async {
        errorMessage = ""
        if mode == .signup, name.trimmingCharacters(in: .whitespaces).count < 2 {
            errorMessage = "Hold up — what should we call you?"
            errorFocused = true
            return
        }
        guard password.count >= 6 else {
            errorMessage = "Give your password at least 6 characters 💪"
            errorFocused = true
            return
        }
        isLoading = true
        do {
            if mode == .signup {
                try await authService.signUp(email: email, password: password, name: name)
            } else {
                try await authService.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = friendlyFirebaseError(error)
            errorFocused = true
        }
        isLoading = false
    }

    private func friendlyFirebaseError(_ error: Error) -> String {
        if let authError = error as? AuthErrorCode {
            switch authError.code {
            case .wrongPassword, .userNotFound, .invalidCredential:
                // Stays deliberately vague — never reveal whether it was the
                // email or the password that missed (don't leak which emails
                // have accounts).
                return "That email and password combo isn't clicking. Try again? ☕"
            case .emailAlreadyInUse:
                return "You've already got an account with this email — try signing in instead 👋"
            case .invalidEmail:
                return "Hmm, that email looks a little off. Mind double-checking it?"
            case .tooManyRequests:
                return "Whoa, slow down — too many tries. Grab a coffee and give it a minute ☕"
            case .networkError:
                return "Can't reach the internet right now. Check your connection and try again 📶"
            case .userDisabled:
                return "This account's been switched off. Ping us if that seems wrong."
            default:
                return "Something tripped on our end (\(authError.code.rawValue)). Give it another go 🔁"
            }
        }
        return "Welp, that didn't work. Mind trying again? 🔁"
    }
}

enum AuthMode { case login, signup }

#Preview {
    LoginView(authService: AuthService(), panelUp: .constant(true))
}
