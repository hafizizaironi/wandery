import SwiftUI

struct UsernameOnboardingView: View {
    var socialService: SocialService
    var authService: AuthService

    @State private var username = ""
    @State private var isSaving = false
    @State private var errorMessage = ""
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Choose a username")
                    .font(.title2).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Friends add you with this name. Letters, numbers, and underscore only (3–20).")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                TextField("username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(AppTheme.surfacePrimary.opacity(0.4))
                    .clipShape(.rect(cornerRadius: 12))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 24)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.errorRed)
                        .accessibilityFocused($errorFocused)
                }

                Button {
                    Task { await save() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().tint(AppTheme.textOnAccent)
                        } else {
                            Text("Continue")
                                .font(.callout).bold()
                                .foregroundStyle(AppTheme.textOnAccent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.accentAction)
                    .clipShape(.rect(cornerRadius: 14))
                }
                .disabled(isSaving)
                .padding(.horizontal, 24)

                Button("Sign out", action: signOut)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.top, 8)
            }
            .padding(.top, 48)
        }
        .keyboardDismissToolbar()
    }

    private func signOut() {
        Task { @MainActor in
            do {
                try await authService.signOut()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() async {
        errorMessage = ""
        isSaving = true
        defer { isSaving = false }
        do {
            try await socialService.reserveUsername(username)
        } catch let e as SocialError {
            errorMessage = e.localizedDescription
            errorFocused = true
        } catch {
            errorMessage = error.localizedDescription
            errorFocused = true
        }
    }
}
