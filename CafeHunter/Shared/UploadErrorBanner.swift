import SwiftUI

/// Top-pinned, dismissible banner shown when a background post upload fails.
/// Mirrors `AppUpdateBanner`'s look. "Retry" replays the saved drafts;
/// the ✕ dismisses (the drafts are still kept until the next post).
struct UploadErrorBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("⚠️").font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn't post")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: onRetry) {
                Text("Retry")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(AppTheme.accentAction))
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.surfacePrimary)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}
