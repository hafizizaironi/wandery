import SwiftUI

/// Medium-detent sheet shown once per user after phone verification.
/// Asks for permission to surface the FriendFind flow — tapping "Find
/// friends" leads into iOS's contacts permission prompt and then the
/// full FriendFindView. "Maybe later" dismisses without ever requesting
/// contacts access. Either choice flips the `contactsPromptShown` flag
/// so this panel doesn't reappear.
struct ContactsSuggestionPanel: View {
    var onAllow: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(AppTheme.accentAction)
                    .padding(.top, 8)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Find friends already here")
                        .font(.title3).bold()
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("See which of your contacts are on Wandery. Your contacts stay on this device — only hashed numbers are checked, and only your matches are shown.")
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
                Button(action: onAllow) {
                    Text("Find friends")
                        .font(.callout).bold()
                        .foregroundStyle(AppTheme.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.accentAction)
                        .clipShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button(action: onSkip) {
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
