import Foundation
import SwiftUI

/// Owns optimistic-send state for a single thread. Each enqueued message:
///   1. Renders as a faded bubble at the bottom of the chat *immediately*
///      (the listener feed doesn't know about it yet).
///   2. Posts to `ConversationService.sendMessage` with up to 3 attempts
///      using exponential backoff (1s, 2s).
///   3. On success: removed from `pending` — the listener will append the
///      server-stamped version a beat later.
///   4. On final failure (3 attempts exhausted): stays in `pending` with
///      `failed = true`, draws a red stroke + "Tap retry" caption, and
///      sets the `hasFailed` flag so the thread view can surface its
///      sticky "Tap to retry all unsent" banner.
///   5. A non-blocking `toast` field is set on the first failure of any
///      message ("Couldn't send — retrying") so the user sees what's
///      happening even before the final-failure banner appears.
///
/// Why a queue instead of inline state per bubble: retries happen
/// asynchronously; the user can keep typing and queue more messages
/// while previous ones are still resolving. Keeping pending state in
/// one place keeps the view simple.
@MainActor
@Observable
final class PendingMessageQueue {
    struct Pending: Identifiable, Equatable {
        let id: String
        let text: String
        let kind: String
        let createdAt: Date
        let senderId: String
        var attempts: Int = 0
        var failed: Bool = false
        /// Mirrored references for reaction/reply pending messages so
        /// the optimistic bubble can render correctly. Empty for plain
        /// text sends.
        var postId: String?
        var postPreview: String?
        var emoji: String?
        var postMediaURL: String?
        var postIsVideo: Bool = false
        /// In-thread reply snapshot (see ChatMessage.replyToId/replyToText).
        var replyToId: String?
        var replyToText: String?

        /// Convert into a `ChatMessage` for rendering. The id is a UUID
        /// (not a Firestore doc id) so it doesn't collide with anything
        /// in `conversationService.activeMessages`.
        func asChatMessage(senderId: String) -> ChatMessage {
            ChatMessage(
                id: id,
                senderId: senderId,
                text: text,
                kind: kind,
                postId: postId,
                postPreview: postPreview,
                emoji: emoji,
                postMediaURL: postMediaURL,
                postIsVideo: postIsVideo,
                createdAt: createdAt,
                replyToId: replyToId,
                replyToText: replyToText
            )
        }
    }

    private(set) var pending: [Pending] = []
    /// Transient banner shown when *any* send fails its first attempt.
    /// Auto-clears on next successful send.
    var toast: String?

    var hasFailed: Bool {
        pending.contains(where: { $0.failed })
    }

    // MARK: - Enqueue

    func enqueue(
        convId:   String,
        text:     String,
        senderId: String,
        service:  ConversationService,
        kind:     String = "text",
        postId:   String? = nil,
        postPreview: String? = nil,
        emoji:    String? = nil,
        postMediaURL: String? = nil,
        postIsVideo: Bool = false,
        replyToId: String? = nil,
        replyToText: String? = nil
    ) {
        let p = Pending(
            id: UUID().uuidString,
            text: text,
            kind: kind,
            createdAt: .now,
            senderId: senderId,
            postId: postId,
            postPreview: postPreview,
            emoji: emoji,
            postMediaURL: postMediaURL,
            postIsVideo: postIsVideo,
            replyToId: replyToId,
            replyToText: replyToText
        )
        pending.append(p)
        Task { await sendWithRetries(pendingId: p.id, convId: convId, service: service) }
    }

    // MARK: - Retry

    /// Re-queue every previously-failed message for another 3-attempt run.
    /// Called from the sticky banner.
    func retryAll(convId: String, service: ConversationService) {
        let failed = pending.filter { $0.failed }
        for p in failed {
            guard let idx = pending.firstIndex(where: { $0.id == p.id }) else { continue }
            pending[idx].failed = false
            pending[idx].attempts = 0
            Task { await sendWithRetries(pendingId: p.id, convId: convId, service: service) }
        }
        toast = nil
    }

    // MARK: - Internal

    private func sendWithRetries(
        pendingId: String,
        convId:    String,
        service:   ConversationService
    ) async {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            guard let idx = pending.firstIndex(where: { $0.id == pendingId }) else { return }
            pending[idx].attempts = attempt
            let snapshot = pending[idx]
            do {
                try await service.sendMessage(
                    convId:       convId,
                    text:         snapshot.text,
                    kind:         snapshot.kind,
                    postId:       snapshot.postId,
                    postPreview:  snapshot.postPreview,
                    emoji:        snapshot.emoji,
                    postMediaURL: snapshot.postMediaURL,
                    postIsVideo:  snapshot.postIsVideo,
                    replyToId:    snapshot.replyToId,
                    replyToText:  snapshot.replyToText
                )
                pending.removeAll(where: { $0.id == pendingId })
                // Clear the toast on first success after a failure.
                toast = nil
                return
            } catch {
                if attempt == 1 {
                    toast = "Couldn't send — retrying…"
                }
                if attempt < maxAttempts {
                    let delaySeconds = pow(2.0, Double(attempt - 1)) // 1s, 2s
                    try? await Task.sleep(for: .seconds(delaySeconds))
                }
            }
        }
        // All attempts failed. Flip the bubble's failed flag; the thread
        // view will surface the sticky retry banner via `hasFailed`.
        if let idx = pending.firstIndex(where: { $0.id == pendingId }) {
            pending[idx].failed = true
        }
        toast = "Message didn't send. Tap retry."
    }
}

/// `ChatMessage`'s only init takes a Firestore document. For optimistic
/// rendering we need a memberwise init — exposed in this extension so
/// the chat surfaces can construct a faded bubble before the server
/// has stamped the real doc.
extension ChatMessage {
    init(
        id: String,
        senderId: String,
        text: String,
        kind: String,
        postId: String?,
        postPreview: String?,
        emoji: String?,
        postMediaURL: String?,
        postIsVideo: Bool,
        createdAt: Date,
        reactions: [String: String] = [:],
        replyToId: String? = nil,
        replyToText: String? = nil,
        deleted: Bool = false,
        postDeleted: Bool = false
    ) {
        self.id = id
        self.senderId = senderId
        self.text = text
        self.kind = kind
        self.postId = postId
        self.postPreview = postPreview
        self.emoji = emoji
        self.postMediaURL = postMediaURL
        self.postIsVideo = postIsVideo
        self.createdAt = createdAt
        self.reactions = reactions
        self.replyToId = replyToId
        self.replyToText = replyToText
        self.deleted = deleted
        self.postDeleted = postDeleted
    }
}
