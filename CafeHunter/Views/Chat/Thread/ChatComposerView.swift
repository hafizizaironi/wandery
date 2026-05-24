import SwiftUI

/// Bottom-anchored composer. Sits in `.safeAreaInset(edge: .bottom)`
/// on `ChatThreadView` so the keyboard tracks 1:1 via SwiftUI's
/// automatic safe-area insets — no `inputAccessoryView` bridge needed.
struct ChatComposerView: View {
    @Binding var text: String
    /// Sticky red strip rendered above the input when there are
    /// failed-after-retries messages. Owner provides — view just slots
    /// it in so the layout/animation stays cohesive.
    var retryBanner: AnyView?
    /// Transient one-liner ("Couldn't send — retrying…") shown above
    /// the input. Nil to hide.
    var toast: String?
    var onSend: () -> Void
    var onDismissToast: () -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            retryBanner

            if let toast {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(AppTheme.errorRed)
                    Text(toast)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Button {
                        onDismissToast()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(AppTheme.errorRed.opacity(0.08))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Divider().opacity(0.5)

            HStack(alignment: .bottom, spacing: 10) {
                inputField
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        // Don't use `.regularMaterial` here — it adapts to system color
        // scheme and goes dark when the user is in dark mode, which
        // fights the AppTheme's fixed-light palette and makes inverted
        // text float over a brown-grey blur. Explicit canvas color
        // keeps the composer cohesive with the rest of the thread.
        .background(AppTheme.surfaceCanvas)
        .animation(Motion.iosDrawer(duration: 0.22), value: toast)
        .animation(Motion.iosDrawer(duration: 0.22), value: retryBanner != nil)
    }

    private var inputField: some View {
        TextField("Message…", text: $text, axis: .vertical)
            .font(.body)
            // Explicit foreground so the text stays readable on the
            // light input pill regardless of system color scheme.
            .foregroundStyle(AppTheme.textPrimary)
            .tint(AppTheme.accentAction)
            .lineLimit(1...5)
            .textInputAutocapitalization(.sentences)
            .focused($focused)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            // Project-wide Liquid Glass chrome — matches the navbar, sheet
            // panels, and floating buttons. Replaces the previous solid
            // `surfacePrimary` fill so the composer reads as the same
            // material as the rest of the floating chrome.
            .liquidGlassChrome(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .submitLabel(.send)
            .onSubmit {
                guard canSend else { return }
                onSend()
            }
    }

    private var sendButton: some View {
        Button {
            onSend()
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textOnAccent)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(AppTheme.accentAction.opacity(canSend ? 1 : 0.35))
                )
        }
        .buttonStyle(.scalePress)
        .disabled(!canSend)
        .accessibilityLabel("Send message")
    }
}
