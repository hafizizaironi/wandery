import SwiftUI
import UIKit

// Per-message actions moved from a bottom `.sheet` to an in-place native
// context menu (see `MessageActionMenu.swift`). What remains here is the
// full emoji picker — presented as its own focused sheet when the user
// taps "More reactions…" — plus the small Identifiable target wrapper that
// drives it via `.sheet(item:)`.

/// Full emoji picker presented from a bubble's "More reactions…" action.
/// A compact grid that doesn't need the full Hero context (kept separate
/// from `HeroPageView`'s private picker on purpose).
struct EmojiPickerSheetWrapper: View {
    let myEmoji: String?
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("React")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close emoji picker")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().opacity(0.4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(NotoEmojiLottie.catalog, id: \.slug) { item in
                        Button {
                            onSelect(item.emoji)
                        } label: {
                            NotoEmojiLottieView(
                                notoSlug: item.slug,
                                fallbackEmoji: item.emoji,
                                size: 36,
                                loop: true
                            )
                            .frame(width: 50, height: 50)
                            .background(
                                myEmoji == item.emoji
                                    ? AppTheme.accentAction.opacity(0.28)
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(AppTheme.surfaceCanvas)
        .preferredColorScheme(.light)
    }
}

/// Identifiable wrapper so `.sheet(item:)` keeps each picker presentation
/// distinct (one per message the user opened "More reactions…" on).
struct MessageActionTarget: Identifiable, Equatable {
    let id: String   // message id
    let message: ChatMessage
    let canReact: Bool
}
