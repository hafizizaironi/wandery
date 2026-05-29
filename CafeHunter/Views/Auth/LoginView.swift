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

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Text("☕")
                            .font(.system(size: 42))
                            .accessibilityHidden(true)
                        Text("Cafés Around \(localityName ?? "You")")
                            .font(.title3).bold()
                            .foregroundStyle(AppTheme.cream)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.25), value: localityName)
                        Text(mode == .login ? "Welcome back! Sign in to continue." : "Create an account to get started.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.cream.opacity(0.45))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 20)
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
                .background(AppTheme.espresso)
                .clipShape(.rect(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 24)
                .padding(.horizontal, 24)

                Spacer()
            }
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
            errorMessage = "Please enter your name."
            errorFocused = true
            return
        }
        guard password.count >= 6 else {
            errorMessage = "Password must be at least 6 characters."
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
                return "Incorrect email or password."
            case .emailAlreadyInUse:
                return "An account with this email already exists."
            case .invalidEmail:
                return "Please enter a valid email address."
            case .tooManyRequests:
                return "Too many sign-in attempts. Please try again later."
            case .networkError:
                return "Network error. Please check your connection."
            case .userDisabled:
                return "This account has been disabled."
            default:
                return "Something went wrong (\(authError.code.rawValue)). Please try again."
            }
        }
        return "Something went wrong. Please try again."
    }
}

enum AuthMode { case login, signup }

#Preview {
    LoginView(authService: AuthService())
}
