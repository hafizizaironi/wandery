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
    /// Long-press handler. When provided, replaces the old `.contextMenu`
    /// Copy action — ChatThreadView opens its `MessageActionsSheet`
    /// which carries Copy + reactions inside one surface.
    var onLongPress: (() -> Void)? = nil
    /// Re-tap on my reaction chip removes it. Forwarded up to
    /// ChatThreadView which calls the service.
    var onRemoveMyReaction: (() -> Void)? = nil

    private var isMe: Bool { message.senderId == myUid }

    var body: some View {
        HStack(spacing: 0) {
            if isMe { Spacer(minLength: 48) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 0) {
                bubble
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
                if hasFailed {
                    Text("Tap retry to resend")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.errorRed)
                        .padding(.top, 3)
                }
            }
            .animation(Motion.iosDrawer(duration: 0.22), value: message.reactions)

            if !isMe { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, position.trailingSpacing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var bubble: some View {
        Text(LinkifiedText.attributed(message.text))
            .font(.body)
            .foregroundStyle(AppTheme.textPrimary)
            .tint(AppTheme.accentAction)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(bubbleShape.fill(fillColor))
            .overlay {
                if hasFailed {
                    bubbleShape.stroke(AppTheme.errorRed, lineWidth: 1.5)
                }
            }
            .opacity(isPending ? 0.55 : 1)
            .onLongPressGesture(minimumDuration: 0.35) {
                guard let onLongPress else { return }
                let g = UIImpactFeedbackGenerator(style: .medium)
                g.impactOccurred()
                onLongPress()
            }
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
