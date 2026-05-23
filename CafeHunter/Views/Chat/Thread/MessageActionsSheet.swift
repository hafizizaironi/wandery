import SwiftUI
import UIKit

/// Long-press-on-bubble action sheet — the chat surface's equivalent of
/// iMessage's "tap-and-hold" tray. Houses:
///   1. A quick reaction row (4 fixed emojis + "+" picker — same vocab
///      as the feed reactions chrome on Hero).
///   2. Copy text (replacing the old `.contextMenu` Copy on bubbles).
///
/// Presented from `ChatThreadView` via a `.sheet(item:)` bound to a
/// `MessageActionTarget` so each long-press carries enough context for
/// the sheet to wire up its callbacks. Pending (not-yet-acked) messages
/// open with reactions disabled — there's no Firestore doc id yet to
/// stamp the reaction onto.
struct MessageActionsSheet: View {
    let message: ChatMessage
    let myUid:   String
    /// Disabled when the message is still in the optimistic queue.
    let canReact: Bool
    var onReact: (String?) -> Void
    var onCopy:  () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showFullPicker = false

    private let quickReactions = ["❤️", "🔥", "😂", "👏"]

    /// Whatever emoji I have currently stamped on this message — used to
    /// fill the matching quick-reaction cell.
    private var myReaction: String? {
        message.reactions[myUid]
    }

    var body: some View {
        VStack(spacing: 0) {
            quickRow
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider().opacity(0.4)
            actionsList
        }
        .background(AppTheme.surfaceCanvas)
        .preferredColorScheme(.light)
        .presentationDetents([.height(180)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        .sheet(isPresented: $showFullPicker) {
            EmojiPickerSheetWrapper(
                myEmoji: myReaction,
                onSelect: { emoji in
                    onReact(emoji)
                    dismiss()
                }
            )
            .presentationDetents([.fraction(0.55)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
    }

    @ViewBuilder
    private var quickRow: some View {
        HStack(spacing: 10) {
            ForEach(quickReactions, id: \.self) { e in
                Button {
                    let g = UIImpactFeedbackGenerator(style: .light)
                    g.impactOccurred()
                    // Re-tapping the same emoji toggles off — matches the
                    // feed reactions UX so users don't have to learn two
                    // different "I'm done with this" gestures.
                    if myReaction == e {
                        onReact(nil)
                    } else {
                        onReact(e)
                    }
                    dismiss()
                } label: {
                    Text(e)
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(reactionFill(for: e))
                        .clipShape(Circle())
                        .overlay {
                            Circle().stroke(
                                myReaction == e ? AppTheme.accentAction : AppTheme.borderSubtle,
                                lineWidth: myReaction == e ? 1.5 : 1
                            )
                        }
                }
                .buttonStyle(.scalePress)
                .disabled(!canReact)
                .opacity(canReact ? 1 : 0.4)
                .accessibilityLabel(myReaction == e ? "Remove \(e) reaction" : "React with \(e)")
            }
            Button {
                showFullPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.callout).bold()
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(AppTheme.surfacePrimary))
                    .overlay { Circle().stroke(AppTheme.borderSubtle, lineWidth: 1) }
            }
            .buttonStyle(.scalePress)
            .disabled(!canReact)
            .opacity(canReact ? 1 : 0.4)
            .accessibilityLabel("More reactions")
            Spacer()
        }
    }

    private func reactionFill(for emoji: String) -> Color {
        myReaction == emoji
            ? AppTheme.accentAction.opacity(0.18)
            : AppTheme.surfacePrimary
    }

    @ViewBuilder
    private var actionsList: some View {
        VStack(spacing: 0) {
            // Only show Copy for text-y messages (chat text or reply
            // text). Pure post-reaction mirror messages have no text
            // body worth copying.
            if !message.text.isEmpty {
                Button {
                    onCopy()
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.doc")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(width: 24)
                        Text("Copy")
                            .font(.body)
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy message")
            }
        }
    }
}

/// Wrapper around the existing `EmojiPickerSheet` so we can present it
/// from `MessageActionsSheet` without depending on its private scope in
/// `HeroPageView`. Keeps a small, embedded picker that doesn't need the
/// full Hero context.
private struct EmojiPickerSheetWrapper: View {
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

/// Identifier wrapper so `.sheet(item:)` keeps each long-press distinct.
struct MessageActionTarget: Identifiable, Equatable {
    let id: String   // message id
    let message: ChatMessage
    let canReact: Bool
}
