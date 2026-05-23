import SwiftUI

/// Post-birthdate gate. Collects a phone number, sends a 6-digit SMS
/// code, verifies it, and links the resulting credential to the current
/// FirebaseAuth user. On success, the verified E.164 number lands in
/// `userPrivate/{uid}` and `users/{uid}.phoneHash` — `ContentView` then
/// routes onward because `needsPhone` flips false.
struct PhoneOnboardingView: View {
    var userPrivateService: UserPrivateService
    var authService: AuthService
    /// Provide to render the screen in *soft* mode: a Cancel button
    /// replaces the Sign-out escape, suitable for presenting the flow as
    /// a dismissible sheet to a logged-in user (e.g. legacy accounts the
    /// hard gate doesn't catch). Leave nil for the routing-gate variant
    /// where the only exit is to sign out.
    var onCancel: (() -> Void)? = nil
    /// Called after successful phone verification. In hard-gate mode this
    /// is unnecessary (the router auto-routes once `needsPhone` flips),
    /// but soft-mode parents use it to dismiss their sheet.
    var onSuccess: (() -> Void)? = nil

    @State private var step: Step = .enterNumber
    @State private var phoneInput: String = "+60 "
    @State private var code: String = ""
    @State private var verificationID: String?
    @State private var isWorking = false
    @State private var errorMessage = ""
    @State private var resendSecondsLeft = 0
    @State private var resendTimerTask: Task<Void, Never>?
    @AccessibilityFocusState private var errorFocused: Bool

    private enum Step: Equatable {
        case enterNumber
        case enterCode
    }

    private var normalizedPhone: String {
        // Strip spaces, dashes, and parentheses — Firebase expects raw
        // E.164. The leading `+` is preserved.
        phoneInput
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "(" && $0 != ")" }
    }

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    switch step {
                    case .enterNumber: numberStep
                    case .enterCode:   codeStep
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.errorRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .accessibilityFocused($errorFocused)
                    }

                    if let onCancel {
                        Button("Cancel") { onCancel() }
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.top, 4)
                    } else {
                        Button("Sign out", action: signOut)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 48)
                .padding(.bottom, 32)
            }
        }
        .keyboardDismissToolbar()
        .onDisappear { resendTimerTask?.cancel() }
    }

    // MARK: - Step 1: number entry

    private var numberStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Add your phone number")
                    .font(.title2).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                Text("We use this to help friends find you on the app. Only friends can see it.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            TextField("+60 12 345 6789", text: $phoneInput)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .autocorrectionDisabled()
                .padding(14)
                .background(AppTheme.surfacePrimary.opacity(0.4))
                .clipShape(.rect(cornerRadius: 12))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 24)

            Button {
                Task { await sendCode() }
            } label: {
                Group {
                    if isWorking {
                        ProgressView().tint(AppTheme.textOnAccent)
                    } else {
                        Text("Send code")
                            .font(.callout).bold()
                            .foregroundStyle(AppTheme.textOnAccent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.accentAction)
                .clipShape(.rect(cornerRadius: 14))
            }
            .disabled(isWorking || !isLikelyValidPhone(normalizedPhone))
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Step 2: code entry

    private var codeStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Enter the code")
                    .font(.title2).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                Text("We sent a 6-digit code to \(normalizedPhone).")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .padding(14)
                .background(AppTheme.surfacePrimary.opacity(0.4))
                .clipShape(.rect(cornerRadius: 12))
                .foregroundStyle(AppTheme.textPrimary)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .onChange(of: code) { _, newValue in
                    // Strip non-digits, cap at 6.
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { code = digits }
                    // Auto-verify when the field is full.
                    if digits.count == 6 && !isWorking {
                        Task { await verifyCode() }
                    }
                }

            Button {
                Task { await verifyCode() }
            } label: {
                Group {
                    if isWorking {
                        ProgressView().tint(AppTheme.textOnAccent)
                    } else {
                        Text("Verify")
                            .font(.callout).bold()
                            .foregroundStyle(AppTheme.textOnAccent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.accentAction)
                .clipShape(.rect(cornerRadius: 14))
            }
            .disabled(isWorking || code.count != 6)
            .padding(.horizontal, 24)

            HStack(spacing: 16) {
                Button("Change number") {
                    resendTimerTask?.cancel()
                    code = ""
                    errorMessage = ""
                    verificationID = nil
                    step = .enterNumber
                }
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)

                Spacer()

                if resendSecondsLeft > 0 {
                    Text("Resend in \(resendSecondsLeft)s")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                } else {
                    Button("Resend code") {
                        Task { await sendCode(isResend: true) }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.accentAction)
                    .disabled(isWorking)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Actions

    private func sendCode(isResend: Bool = false) async {
        errorMessage = ""
        guard isLikelyValidPhone(normalizedPhone) else {
            errorMessage = PhoneAuthError.invalidPhoneNumber.errorDescription ?? ""
            errorFocused = true
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let id = try await PhoneAuthService.sendCode(to: normalizedPhone)
            verificationID = id
            step = .enterCode
            code = ""
            startResendTimer()
        } catch let e as PhoneAuthError {
            errorMessage = e.errorDescription ?? "Couldn't send the code."
            errorFocused = true
        } catch {
            errorMessage = error.localizedDescription
            errorFocused = true
        }
    }

    private func verifyCode() async {
        errorMessage = ""
        guard let id = verificationID else {
            errorMessage = PhoneAuthError.codeExpired.errorDescription ?? ""
            return
        }
        guard code.count == 6 else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await PhoneAuthService.verifyAndLink(verificationID: id, code: code)
            try await userPrivateService.setVerifiedPhone(normalizedPhone)
            resendTimerTask?.cancel()
            // Hard-gate mode: the listener on userPrivate flips
            // `needsPhone` to false and ContentView re-routes into
            // MainShellView automatically — no callback needed.
            // Soft mode (sheet): the parent uses `onSuccess` to dismiss.
            onSuccess?()
        } catch let e as PhoneAuthError {
            errorMessage = e.errorDescription ?? "Couldn't verify the code."
            errorFocused = true
        } catch {
            errorMessage = error.localizedDescription
            errorFocused = true
        }
    }

    private func startResendTimer() {
        resendTimerTask?.cancel()
        resendSecondsLeft = 30
        resendTimerTask = Task { @MainActor in
            while resendSecondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                resendSecondsLeft -= 1
            }
        }
    }

    private func signOut() {
        do {
            try authService.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Cheap client-side sanity check before we burn an SMS. Firebase will
    /// do the authoritative validation server-side — this just keeps the
    /// "Send code" button disabled until the input looks plausible.
    private func isLikelyValidPhone(_ phone: String) -> Bool {
        guard phone.first == "+" else { return false }
        let digits = phone.dropFirst().filter(\.isNumber)
        return digits.count >= 8 && digits.count <= 15
    }
}
