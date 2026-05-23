import SwiftUI

/// Shared NotoEmoji picker sheet. Moved out of `HeroPageView` in
/// Phase 4 when the inline `PostReplyComposer` replaced the old
/// `FeedPostReactions` view. Both surfaces can now present the same
/// picker without duplicating the catalog grid.
///
/// `title` defaults to "Pick an emoji" so the sheet reads naturally
/// for both the reply composer and any future caller. Pass `myEmoji`
/// to highlight a previously-selected cell (used by the picker that
/// surfaces from `MessageActionsSheet` in chat threads).
struct EmojiPickerSheet: View {
    var title: String = "Pick an emoji"
    var myEmoji: String? = nil
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            grid
        }
        .background(AppTheme.surfaceCanvas)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close emoji picker")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(NotoEmojiLottie.catalog, id: \.slug) { item in
                    Button {
                        onSelect(item.emoji)
                        dismiss()
                    } label: {
                        cell(for: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func cell(for item: (emoji: String, slug: String)) -> some View {
        NotoEmojiLottieView(
            notoSlug: item.slug,
            fallbackEmoji: item.emoji,
            size: 36,
            loop: true
        )
        .frame(width: 50, height: 50)
        .background(
            myEmoji == item.emoji
                ? AppTheme.accentAction.opacity(0.22)
                : AppTheme.surfacePrimary
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    myEmoji == item.emoji
                        ? AppTheme.accentAction.opacity(0.7)
                        : Color.clear,
                    lineWidth: 1.5
                )
        }
    }
}
