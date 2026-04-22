import SwiftUI

struct UsernameOnboardingView: View {
    @ObservedObject var socialService: SocialService
    @ObservedObject var authService: AuthService

    @State private var username = ""
    @State private var isSaving = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Choose a username")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("Friends add you with this name. Letters, numbers, and underscore only (3–20).")
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                TextField("username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(AppTheme.surfacePrimary.opacity(0.4))
                    .cornerRadius(12)
                    .foregroundColor(AppTheme.textPrimary)
                    .padding(.horizontal, 24)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.errorRed)
                }

                Button {
                    Task { await save() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().tint(AppTheme.textOnAccent)
                        } else {
                            Text("Continue")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppTheme.textOnAccent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.accentAction)
                    .cornerRadius(14)
                }
                .disabled(isSaving)
                .padding(.horizontal, 24)

                Button("Sign out") {
                    try? authService.signOut()
                }
                .font(.system(size: 14))
                .foregroundColor(AppTheme.textSecondary)
                .padding(.top, 8)
            }
            .padding(.top, 48)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
