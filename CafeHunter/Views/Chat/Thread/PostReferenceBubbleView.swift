import SwiftUI
import UIKit

/// A mirrored feed-post interaction (`kind == "reaction"` / `"reply"`),
/// rendered as TWO stacked items so tapping and swiping never fight over a
/// single element:
///   1. an enlarged, tappable post preview — tap → jump to the post; and
///   2. a separate content bubble (the reply comment, or "Reacted 🔥") that
///      is the ONLY part carrying the long-press menu, reactions, and
///      swipe-to-reply.
struct PostReferenceBubbleView: View {
    let message:  ChatMessage
    let myUid:    String
    let position: BubblePosition
    var isPending: Bool = false
    var hasFailed: Bool = false
    /// Jump-to-post hook on the preview image. Nil = preview is non-tappable.
    var onTap: (() -> Void)? = nil
    /// Per-message action menu — attached to the CONTENT bubble only, so the
    /// big preview stays a clean tap-to-open target.
    var menu: MessageMenuModel? = nil
    var onRemoveMyReaction: (() -> Void)? = nil

    private var isMe: Bool { message.senderId == myUid }
    private let previewSide: CGFloat = 220
    /// Bumped to force a fresh image load when the user taps "retry" on a
    /// preview that failed even after the cached loader's auto-retries.
    @State private var imageRetry = 0

    var body: some View {
        HStack(spacing: 0) {
            if isMe { Spacer(minLength: 36) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 6) {
                Text(headerText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 4)

                postPreview
                contentColumn
            }
            if !isMe { Spacer(minLength: 36) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, position.trailingSpacing)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Enlarged post preview (tap → jump)

    @ViewBuilder
    private var postPreview: some View {
        if message.postDeleted {
            deletedPreview
        } else {
            standardPreview
        }
    }

    /// Compact placeholder shown once the author deleted the referenced post.
    /// Replaces the (now-gone) image and isn't tappable.
    private var deletedPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .symbolVariant(.slash)
                .font(.subheadline)
            Text("Post no longer available")
                .font(.footnote)
        }
        .foregroundStyle(AppTheme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: previewSide, alignment: .leading)
        .background(
            AppTheme.textPrimary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityLabel("The referenced post is no longer available")
    }

    @ViewBuilder
    private var standardPreview: some View {
        let image = previewImage
            .frame(width: previewSide, height: previewSide)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if message.postIsVideo {
                    Image(systemName: "play.fill")
                        .font(.callout).bold()
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(8)
                }
            }
            .opacity(isPending ? 0.55 : 1)
            .accessibilityLabel(previewAccessibilityLabel)

        if let onTap {
            image
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture { onTap() }
                .accessibilityAddTraits(.isButton)
        } else {
            image
        }
    }

    @ViewBuilder
    private var previewImage: some View {
        if let urlString = message.postMediaURL, let url = URL(string: urlString) {
            // CachedAsyncImage caches + auto-retries transient failures; the
            // tap-to-retry placeholder covers the rare case all retries fail.
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty:
                    ZStack {
                        AppTheme.accentAction.opacity(0.12)
                        ProgressView()
                    }
                case .failure:
                    retryablePlaceholder
                @unknown default:
                    previewPlaceholder
                }
            }
            .id(imageRetry)
        } else {
            previewPlaceholder
        }
    }

    private var previewPlaceholder: some View {
        ZStack {
            AppTheme.accentAction.opacity(0.15)
            Image(systemName: "photo")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AppTheme.accentAction.opacity(0.6))
        }
    }

    /// Shown when a preview fails to load even after auto-retries. Tapping it
    /// recreates the loader (via `.id`) for a fresh attempt — and this tap is
    /// consumed here, so it doesn't also trigger jump-to-post.
    private var retryablePlaceholder: some View {
        ZStack {
            AppTheme.accentAction.opacity(0.15)
            VStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 26, weight: .regular))
                Text("Tap to retry")
                    .font(.caption2)
            }
            .foregroundStyle(AppTheme.accentAction)
        }
        .contentShape(Rectangle())
        .onTapGesture { imageRetry += 1 }
        .accessibilityLabel("Preview failed to load. Tap to retry.")
    }

    // MARK: - Content bubble (comment / reaction) — menu + swipe + reactions

    private var contentColumn: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 0) {
            contentBubble
                .messageActions(menu, preview: AnyView(contentBubble))
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
        .swipeToReply(isMe: isMe, onReply: menu?.onReply)
    }

    @ViewBuilder
    private var contentBubble: some View {
        Group {
            if message.isPostReaction {
                HStack(spacing: 6) {
                    Text(message.emoji ?? "•").font(.title3)
                    Text(isMe ? "You reacted" : "Reacted")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            } else {
                Text(LinkifiedText.attributed(message.text))
                    .font(.body)
                    .foregroundStyle(AppTheme.textPrimary)
                    .tint(AppTheme.accentAction)
            }
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
        .accessibilityLabel(contentAccessibilityLabel)
    }

    // MARK: - Shape / styling

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

    // MARK: - Accessibility

    private var previewAccessibilityLabel: String {
        let who = isMe ? "You" : "They"
        let verb = message.isPostReaction ? "reacted to" : "replied to"
        let media = message.postIsVideo ? "a video post" : "a photo post"
        return onTap != nil
            ? "\(who) \(verb) \(media). Double-tap to open."
            : "\(who) \(verb) \(media)."
    }

    private var contentAccessibilityLabel: String {
        if message.isPostReaction {
            return "Reaction: \(message.emoji ?? "emoji")"
        }
        return "Reply: \(message.text)"
    }
}
