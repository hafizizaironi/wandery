import SwiftUI

/// Empty state for a fresh user with no conversations yet. Big enough to
/// fill the vertical space gracefully, soft enough not to feel like an
/// error.
struct InboxEmptyState: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(AppTheme.textPrimary.opacity(0.14))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("No conversations yet")
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Tap a friend's chat icon to start one — they'll see your message instantly.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .onAppear {
            withAnimation(Motion.cozyReveal.delay(0.05)) {
                appeared = true
            }
        }
    }
}
