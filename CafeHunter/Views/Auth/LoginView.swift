import SwiftUI
import FirebaseAuth

struct LoginView: View {
    @ObservedObject var authService: AuthService

    @State private var mode: AuthMode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var errorMessage = ""
    @State private var isLoading = false

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Text("☕").font(.system(size: 42))
                        Text("Cafés Around Rawang")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(AppTheme.cream)
                        Text(mode == .login ? "Welcome back! Sign in to continue." : "Create an account to get started.")
                            .font(.system(size: 13))
                            .foregroundColor(AppTheme.cream.opacity(0.45))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 20)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(AppTheme.cafeAccent.opacity(0.15))
                            .frame(height: 1)
                    }

                    // Body
                    VStack(spacing: 16) {
                        // Google button
                        Button {
                            Task { await signInWithGoogle() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "globe")
                                    .font(.system(size: 16, weight: .medium))
                                Text("Continue with Google")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(AppTheme.espresso)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.cream)
                            .cornerRadius(12)
                        }
                        .disabled(isLoading)

                        // Divider
                        HStack {
                            Rectangle().fill(AppTheme.cream.opacity(0.1)).frame(height: 1)
                            Text("or")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.cream.opacity(0.3))
                                .padding(.horizontal, 8)
                            Rectangle().fill(AppTheme.cream.opacity(0.1)).frame(height: 1)
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
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.errorRed)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                Task { await handleEmailAuth() }
                            } label: {
                                Group {
                                    if isLoading {
                                        ProgressView().tint(AppTheme.cream)
                                    } else {
                                        Text(mode == .login ? "Sign in" : "Create account")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AppTheme.cream)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(AppTheme.cafeAccent)
                                .cornerRadius(12)
                            }
                            .disabled(isLoading)
                        }

                        // Toggle mode
                        HStack(spacing: 4) {
                            Text(mode == .login ? "Don't have an account?" : "Already have an account?")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.cream.opacity(0.4))
                            Button {
                                mode = mode == .login ? .signup : .login
                                errorMessage = ""
                            } label: {
                                Text(mode == .login ? "Sign up" : "Sign in")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(AppTheme.cafeAccent)
                                    .underline()
                            }
                        }
                    }
                    .padding(24)
                }
                .background(AppTheme.espresso)
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 24)
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func signInWithGoogle() async {
        isLoading = true
        errorMessage = ""
        do {
            try await authService.signInWithGoogle()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func handleEmailAuth() async {
        errorMessage = ""
        if mode == .signup, name.trimmingCharacters(in: .whitespaces).count < 2 {
            errorMessage = "Please enter your name."
            return
        }
        guard password.count >= 6 else {
            errorMessage = "Password must be at least 6 characters."
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

struct AuthTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .focused($isFocused)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppTheme.cream.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? AppTheme.cafeAccent.opacity(0.7) : AppTheme.cafeAccent.opacity(0.25), lineWidth: 1)
        )
        .foregroundColor(AppTheme.cream)
        .font(.system(size: 14))
        .tint(AppTheme.cafeAccent)
    }
}

#Preview {
    LoginView(authService: AuthService())
}
