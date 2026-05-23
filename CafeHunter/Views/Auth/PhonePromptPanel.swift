import SwiftUI

/// Soft prompt presented to *existing* users who onboarded before the
/// phone-required gate shipped. Shown as a medium-detent sheet once per
/// cold launch from MainShellView. Tapping "Add phone" hands off to the
/// full `PhoneOnboardingView`; "Maybe later" just dismisses — the prompt
/// reappears on the next launch.
struct PhonePromptPanel: View {
    var onAddPhone: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(AppTheme.accentAction)
                    .padding(.top, 8)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Add your phone number")
                        .font(.title3).bold()
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Friends who already have you in their contacts can find you instantly. Your number stays private — only friends see it.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 24)

            VStack(spacing: 10) {
                Button(action: onAddPhone) {
                    Text("Add phone")
                        .font(.callout).bold()
                        .foregroundStyle(AppTheme.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.accentAction)
                        .clipShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Maybe later")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.surfaceCanvas.ignoresSafeArea())
    }
}
