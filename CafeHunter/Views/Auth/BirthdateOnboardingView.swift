import SwiftUI
import SafariServices

/// Post-username gate. Collects birthdate and records consent for the
/// current Terms / Privacy versions. Presented by `ContentView` whenever
/// `UserPrivateService.needsBirthdate || .needsConsent` is true — so the
/// same screen handles both first-time signup and re-prompting existing
/// users after a legal-doc version bump.
struct BirthdateOnboardingView: View {
    var userPrivateService: UserPrivateService
    var authService: AuthService

    @State private var birthdate: Date
    @State private var isSaving = false
    @State private var errorMessage = ""
    @State private var presentedLegalURL: IdentifiedURL?
    @AccessibilityFocusState private var errorFocused: Bool

    private let maxBirthdate: Date
    private let minBirthdate: Date

    init(userPrivateService: UserPrivateService, authService: AuthService) {
        self.userPrivateService = userPrivateService
        self.authService = authService

        // Anyone born after this date is <13 today — the DatePicker won't
        // let them go past it, so the age check is enforced at the input
        // layer rather than as a post-submit error.
        let cal = Calendar.current
        let now = Date()
        let max = cal.date(byAdding: .year, value: -LegalURLs.minimumAge, to: now) ?? now
        let min = cal.date(byAdding: .year, value: -120, to: now) ?? now
        self.maxBirthdate = max
        self.minBirthdate = min
        // Default to the max so the wheel starts on the latest legal date
        // rather than today — fewer scrolls for the typical young user.
        _birthdate = State(initialValue: max)
    }

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    header

                    DatePicker(
                        "Birthdate",
                        selection: $birthdate,
                        in: minBirthdate...maxBirthdate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    // Force the wheel into light mode so its text colour
                    // stays dark against the cream `surfaceCanvas`. The
                    // underlying UIDatePicker inherits the trait
                    // collection's interface style — without this, dark
                    // mode (or the system picking the wrong default)
                    // renders nearly-invisible white text.
                    .colorScheme(.light)
                    .tint(AppTheme.accentAction)
                    .padding(.horizontal, 12)

                    consentCopy

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.errorRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .accessibilityFocused($errorFocused)
                    }

                    continueButton
                        .padding(.horizontal, 24)

                    Button("Sign out", action: signOut)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.top, 4)
                }
                .padding(.top, 36)
                .padding(.bottom, 32)
            }
        }
        .keyboardDismissToolbar()
        .sheet(item: $presentedLegalURL) { wrapper in
            SafariView(url: wrapper.url)
                .ignoresSafeArea()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Text("Almost there")
                .font(.title2).bold()
                .foregroundStyle(AppTheme.textPrimary)
            Text("Tell us when you were born and review our terms. You must be at least \(LegalURLs.minimumAge) to use the app.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var consentCopy: some View {
        VStack(spacing: 6) {
            Text("By continuing, you accept our")
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
            HStack(spacing: 4) {
                Button("Terms of Use") {
                    presentedLegalURL = IdentifiedURL(url: LegalURLs.termsOfUse)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.accentAction)

                Text("and")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)

                Button("Privacy Policy") {
                    presentedLegalURL = IdentifiedURL(url: LegalURLs.privacyPolicy)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.accentAction)
            }
        }
        .padding(.horizontal, 24)
    }

    private var continueButton: some View {
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
    }

    // MARK: - Actions

    private func save() async {
        errorMessage = ""
        guard birthdate <= maxBirthdate else {
            errorMessage = "Aw, you've gotta be at least \(LegalURLs.minimumAge) to hunt with us."
            errorFocused = true
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await userPrivateService.acceptOnboarding(birthdate: birthdate)
        } catch {
            errorMessage = error.localizedDescription
            errorFocused = true
        }
    }

    private func signOut() {
        do {
            try authService.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Helpers

/// Wrapper so the sheet's `item:` binding can present arbitrary URLs.
private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Thin UIViewControllerRepresentable around SFSafariViewController so the
/// legal docs open in-app rather than punting to Safari (reviewers prefer
/// the in-app surface — the user stays inside the onboarding flow).
private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
