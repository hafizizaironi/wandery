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
    /// Set when the preview image comes back 404/410 — the referenced post's
    /// media is permanently gone (owner deleted it), so we collapse to the
    /// "deleted" placeholder even if the server never stamped `postDeleted`
    /// (e.g. posts removed before the scrub function existed).
    @State private var detectedGone = false

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

    private var postPreview: some View {
        Group {
            if message.postDeleted || detectedGone {
                deletedPreview
            } else {
                standardPreview
            }
        }
        // The image may render instantly from the on-disk/memory cache and so
        // never touch the network — which means a post the friend has since
        // deleted keeps showing its (now-orphaned) cached picture. Probe the
        // live blob once; if it's gone, collapse to the deleted placeholder
        // even though the cached image would still display.
        .task(id: message.postMediaURL) { await verifyPostStillExists() }
    }

    /// Confirms the referenced post's media still exists on the server, so a
    /// cached reference doesn't outlive a deletion. Skipped when we already
    /// know it's gone (server flag or a prior probe). Transient/network
    /// failures are treated as "still there" — only a hard 404/410 collapses.
    private func verifyPostStillExists() async {
        guard !message.postDeleted, !detectedGone,
              let url = message.postMediaURL, !url.isEmpty else { return }
        let exists = await PostMediaExistence.shared.verify(url)
        if !exists { detectedGone = true }
    }

    /// Compact placeholder shown once the author deleted the referenced post.
    /// Replaces the (now-gone) image and isn't tappable.
    private var deletedPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .symbolVariant(.slash)
                .font(.subheadline)
            Text("This post was deleted")
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
        .accessibilityLabel("The author deleted this post")
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
                case .failure(let error):
                    if isNotFound(error) {
                        // Blob is gone — treat as a deleted post. Flip state so
                        // the whole preview collapses to `deletedPreview` rather
                        // than offering a retry that can never succeed.
                        Color.clear.onAppear { detectedGone = true }
                    } else {
                        retryablePlaceholder
                    }
                @unknown default:
                    previewPlaceholder
                }
            }
            .id(imageRetry)
        } else {
            previewPlaceholder
        }
    }

    /// A 404/410 surfaced by `CachedAsyncImage` as `.fileDoesNotExist` — the
    /// referenced media no longer exists, i.e. the post was deleted.
    private func isNotFound(_ error: Error) -> Bool {
        (error as? URLError)?.code == .fileDoesNotExist
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

// MARK: - Post media existence probe

/// Checks whether a referenced post's media blob still exists on the server,
/// so chat references to a deleted post collapse even when the image is still
/// in the local cache (the loader would serve the cached copy and never see
/// the 404). Results are memoised per URL and in-flight probes coalesced, so
/// many bubbles pointing at the same post cost at most one tiny request per
/// session.
actor PostMediaExistence {
    static let shared = PostMediaExistence()

    private var known: [String: Bool] = [:]
    private var inFlight: [String: Task<Bool, Never>] = [:]

    /// `true` if the blob is present (or we couldn't tell). `false` only on a
    /// definitive 404/410 — a hard "this object is gone".
    func verify(_ urlString: String) async -> Bool {
        if let cached = known[urlString] { return cached }
        if let task = inFlight[urlString] { return await task.value }

        let task = Task<Bool, Never> { await Self.probe(urlString) }
        inFlight[urlString] = task
        let result = await task.value
        known[urlString] = result
        inFlight[urlString] = nil
        return result
    }

    /// One-byte ranged GET — cheaper than fetching the object, and Firebase
    /// Storage download URLs honour Range (unlike HEAD, which they may reject).
    private static func probe(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return true }
        var req = URLRequest(url: url)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.timeoutInterval = 12
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse,
               http.statusCode == 404 || http.statusCode == 410 {
                return false
            }
            return true
        } catch {
            // Offline / transient — don't falsely declare the post deleted.
            return true
        }
    }
}
