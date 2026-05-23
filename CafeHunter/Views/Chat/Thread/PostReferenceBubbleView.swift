import SwiftUI
import UIKit

/// Bubble shape for messages that mirror a feed-post interaction —
/// `kind == "reaction"` or `kind == "reply"`. Renders the post thumbnail +
/// preview text snapshot stamped at write time, then the reaction emoji
/// or reply body underneath.
///
/// Post-tap-to-jump is a Phase 2 hook; v1 leaves the thumbnail visually
/// correct but non-interactive (the post-detail route isn't wired into
/// this navigation stack yet).
struct PostReferenceBubbleView: View {
    let message:  ChatMessage
    let myUid:    String
    let position: BubblePosition
    var isPending: Bool = false
    var hasFailed: Bool = false
    /// Optional: when provided, the card becomes tappable and calls
    /// this closure (e.g. to dismiss chat + scroll the feed to the
    /// referenced post). Nil = card is visual-only.
    var onTap: (() -> Void)? = nil
    /// Long-press handler — surfaces the message-actions sheet
    /// (reactions + copy). Same pattern as MessageBubbleView.
    var onLongPress: (() -> Void)? = nil
    var onRemoveMyReaction: (() -> Void)? = nil

    private var isMe: Bool { message.senderId == myUid }

    var body: some View {
        HStack(spacing: 0) {
            if isMe { Spacer(minLength: 36) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 0) {
                tappableCard
                if !message.reactions.isEmpty {
                    MessageReactionStrip(
                        reactions: message.reactions,
                        myUid: myUid,
                        onRemoveMine: { onRemoveMyReaction?() }
                    )
                    .padding(.top, -6)
                    .padding(isMe ? .trailing : .leading, 6)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(Motion.iosDrawer(duration: 0.22), value: message.reactions)
            if !isMe { Spacer(minLength: 36) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, position.trailingSpacing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(onTap != nil ? .isButton : [])
    }

    @ViewBuilder
    private var tappableCard: some View {
        let cardView = card
            .onLongPressGesture(minimumDuration: 0.35) {
                guard let onLongPress else { return }
                let g = UIImpactFeedbackGenerator(style: .medium)
                g.impactOccurred()
                onLongPress()
            }

        if let onTap {
            Button(action: onTap) {
                cardView
            }
            .buttonStyle(.scalePress)
        } else {
            cardView
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(message.postPreview ?? "")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textPrimary.opacity(0.75))
                        .lineLimit(2)
                }
            }
            Divider().opacity(0.5)
            body(for: message)
        }
        .padding(12)
        .background(bubbleShape.fill(fillColor))
        .overlay {
            if hasFailed {
                bubbleShape.stroke(AppTheme.errorRed, lineWidth: 1.5)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .opacity(isPending ? 0.55 : 1)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let placeholder = RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppTheme.accentAction.opacity(0.18))
            .frame(width: 48, height: 48)

        if let urlString = message.postMediaURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if message.postIsVideo {
                                Image(systemName: "play.fill")
                                    .font(.caption2).bold()
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Color.black.opacity(0.55), in: Circle())
                                    .padding(3)
                            }
                        }
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private func body(for message: ChatMessage) -> some View {
        if message.isPostReaction {
            HStack(spacing: 6) {
                Text(message.emoji ?? "•")
                    .font(.title2)
                Text(isMe ? "You reacted" : "Reacted")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        } else if message.isPostReply {
            Text(LinkifiedText.attributed(message.text))
                .font(.body)
                .foregroundStyle(AppTheme.textPrimary)
                .tint(AppTheme.accentAction)
        }
    }

    private var bubbleShape: some Shape {
        let r: CGFloat = 18
        let tail: CGFloat = position.showsTail ? 4 : r
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading:     r,
                bottomLeading:  isMe ? r : tail,
                bottomTrailing: isMe ? tail : r,
                topTrailing:    r
            ),
            style: .continuous
        )
    }

    private var fillColor: Color {
        isMe ? AppTheme.surfacePrimary : AppTheme.accentAction.opacity(0.12)
    }

    private var headerText: String {
        if message.isPostReaction {
            return isMe ? "You reacted to their post" : "Reacted to your post"
        }
        if message.isPostReply {
            return isMe ? "You replied to their post" : "Replied to your post"
        }
        return ""
    }

    private var accessibilityLabel: String {
        let who = isMe ? "You" : "They"
        if message.isPostReaction {
            return "\(who) reacted with \(message.emoji ?? "an emoji") to a post"
        }
        if message.isPostReply {
            return "\(who) replied to a post: \(message.text)"
        }
        return "\(who) referenced a post"
    }
}
