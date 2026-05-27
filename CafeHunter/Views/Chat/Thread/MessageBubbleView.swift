import SwiftUI
import UIKit

/// One chat bubble. Aligned right for the current user, left for the
/// other participant. Colour split chosen 2026-05-22: incoming bubbles
/// get the terracotta wash (accentAction @ 12%) so the accent stays
/// reserved for "someone is talking to you", and my outgoing bubbles
/// use `surfacePrimary` — quieter, lets the partner's voice lead.
struct MessageBubbleView: View {
    let message:  ChatMessage
    let myUid:    String
    let position: BubblePosition
    /// If true, render at reduced opacity (still-being-sent) and skip
    /// any haptic-tied affordances.
    var isPending: Bool = false
    /// If true, draw a red stroke and add the "Tap to retry" caption.
    /// Used by `PendingMessageQueue`'s failed-bubble state.
    var hasFailed: Bool = false
    /// Per-message action menu (reactions / copy / report). Nil for
    /// optimistic bubbles — no Firestore doc id to act on yet. Presented
    /// via `.messageActions(_:)` — today a native context menu.
    var menu: MessageMenuModel? = nil
    /// Re-tap on my reaction chip removes it. Forwarded up to
    /// ChatThreadView which calls the service.
    var onRemoveMyReaction: (() -> Void)? = nil

    private var isMe: Bool { message.senderId == myUid }

    var body: some View {
        HStack(spacing: 0) {
            if isMe { Spacer(minLength: 48) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 0) {
                bubble
                if !message.deleted, !message.reactions.isEmpty {
                    MessageReactionStrip(
                        reactions: message.reactions,
                        myUid: myUid,
                        onRemoveMine: { onRemoveMyReaction?() }
                    )
                    .padding(.top, -6)
                    .padding(isMe ? .trailing : .leading, 6)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                if hasFailed {
                    Text("Tap retry to resend")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.errorRed)
                        .padding(.top, 3)
                }
            }
            .animation(Motion.iosDrawer(duration: 0.22), value: message.reactions)
            .swipeToReply(isMe: isMe, onReply: menu?.onReply)

            if !isMe { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, position.trailingSpacing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var bubble: some View {
        bubbleContent
            .messageActions(menu, preview: AnyView(bubbleContent))
    }

    /// The bubble's visual, split out so a fresh copy can be lifted in the
    /// long-press overlay (a real view re-hosts crisply; the modifier's
    /// `content` proxy would render blank).
    @ViewBuilder
    private var bubbleContent: some View {
        if message.deleted {
            deletedContent
        } else {
            normalContent
        }
    }

    private var normalContent: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 5) {
            if message.isMessageReply, let quote = message.replyToText {
                replyQuote(quote)
            }
            Text(LinkifiedText.attributed(message.text))
                .font(.body)
                .foregroundStyle(AppTheme.textPrimary)
                .tint(AppTheme.accentAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(bubbleShape.fill(fillColor))
        .overlay {
            if hasFailed {
                bubbleShape.stroke(AppTheme.errorRed, lineWidth: 1.5)
            }
        }
        .opacity(isPending ? 0.55 : 1)
    }

    /// Tombstone placeholder for an unsent message — muted italic text in a
    /// faint outlined bubble. No actions attach (the row passes no menu).
    private var deletedContent: some View {
        HStack(spacing: 5) {
            Image(systemName: "slash.circle")
                .font(.caption)
            Text(isMe ? "You deleted this message" : "This message was deleted")
                .font(.subheadline.italic())
        }
        .foregroundStyle(AppTheme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(bubbleShape.fill(AppTheme.textPrimary.opacity(0.05)))
        .overlay {
            bubbleShape.stroke(AppTheme.borderSubtle, lineWidth: 1)
        }
    }

    /// The quoted snippet of the message this bubble is replying to,
    /// rendered as a muted header inside the bubble (accent bar + text).
    private func replyQuote(_ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppTheme.accentAction.opacity(0.8))
                .frame(width: 2.5)
            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            AppTheme.textPrimary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    /// iMessage-style bubble shape: the corner closest to the sender's
    /// alignment edge is sharper (4pt) on the *last* bubble in a sender
    /// group, mimicking a tail without drawing a custom Shape path.
    /// Middle / top bubbles in a group get fully-rounded corners on
    /// both sides so the group reads as one continuous block.
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

    private var accessibilityLabel: String {
        let speaker = isMe ? "You said" : "They said"
        let time = message.createdAt.formatted(date: .omitted, time: .shortened)
        return "\(speaker): \(message.text), \(time)"
    }
}
