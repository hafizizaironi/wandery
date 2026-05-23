import Combine
import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// 1:1 chat backend. Owns:
///  - the inbox listener (`conversations` where I'm a participant, ordered by recency)
///  - the active-thread listener (messages of one conversation)
///  - findOrCreate + sendMessage helpers
///
/// Single instance is started/stopped from the same place SocialService is
/// (typically RootView), so listeners track auth state changes.
@MainActor
@Observable
final class ConversationService {

    private(set) var inbox: [Conversation] = []
    private(set) var activeMessages: [ChatMessage] = []
    private(set) var activeConvId: String?

    private let db = Firestore.firestore()
    private var inboxListener: ListenerRegistration?
    private var threadListener: ListenerRegistration?

    private var uid: String? { Auth.auth().currentUser?.uid }

    func start(for user: FirebaseAuth.User?) {
        reset()
        guard let user else { return }
        attachInboxListener(uid: user.uid)
    }

    func reset() {
        inboxListener?.remove()
        threadListener?.remove()
        inboxListener = nil
        threadListener = nil
        inbox = []
        activeMessages = []
        activeConvId = nil
    }

    private func attachInboxListener(uid: String) {
        inboxListener?.remove()
        // Note: combining `arrayContains(participantIds)` with
        // `order(by: lastMessageAt)` requires a composite index. Until
        // that's deployed (or instead of deploying it for ~50 docs), we
        // drop the server-side sort and sort client-side after fetch.
        inboxListener = db.collection("conversations")
            .whereField("participantIds", arrayContains: uid)
            .limit(to: 50)
            .addSnapshotListener { [weak self] snap, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let err {
                        print("[ConversationService] inbox listener error: \(err)")
                        return
                    }
                    let convs = snap?.documents.compactMap { Conversation(document: $0) } ?? []
                    self.inbox = convs.sorted {
                        ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
                    }
                }
            }
    }

    /// Subscribes to messages in `convId`. Replaces any prior thread listener.
    /// Pass nil to detach.
    func openThread(_ convId: String?) {
        threadListener?.remove()
        threadListener = nil
        activeMessages = []
        activeConvId = convId
        guard let convId else { return }
        threadListener = db.collection("conversations").document(convId)
            .collection("messages")
            .order(by: "createdAt", descending: false)
            .limit(toLast: 200)
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, self.activeConvId == convId else { return }
                    self.activeMessages = snap?.documents.compactMap { ChatMessage(document: $0) } ?? []
                }
            }
    }

    /// Read-only counterpart to `findOrCreateConversation`. Returns the
    /// deterministic id if a conv already exists between me + otherUid,
    /// otherwise nil. Doesn't trigger the conversation-create rule, so
    /// it's safe to call eagerly on chat appear (no empty conversation
    /// docs get written just from peeking) — that's the call site that
    /// fixes "tap a friend's avatar but past reply messages don't show".
    func findConversation(with otherUid: String) async throws -> String? {
        guard let me = uid else { return nil }
        guard otherUid != me else { return nil }
        let id = Conversation.id(for: me, otherUid)
        let ref = db.collection("conversations").document(id)
        let snap = try await ref.getDocument()
        return snap.exists ? id : nil
    }

    /// Returns the deterministic convId, creating the parent doc if it
    /// doesn't exist yet. Idempotent — safe to call from both sides.
    func findOrCreateConversation(with otherUid: String) async throws -> String {
        guard let me = uid else { throw ConversationError.notSignedIn }
        guard otherUid != me else { throw ConversationError.cannotMessageSelf }
        let id = Conversation.id(for: me, otherUid)
        let ref = db.collection("conversations").document(id)
        // Separate the GET and CREATE so the diagnostic tells us *which*
        // step the rule engine rejected — they have different rules and
        // different fix paths.
        let snap: DocumentSnapshot
        do {
            snap = try await ref.getDocument()
        } catch let getErr as NSError {
            #if DEBUG
            print("[Conv] doc \(id) — GET failed code=\(getErr.code) desc=\(getErr.localizedDescription)")
            #endif
            throw getErr
        }
        #if DEBUG
        print("[Conv] doc \(id) — GET ok exists=\(snap.exists) participantIds=\(snap.data()?["participantIds"] ?? "nil")")
        #endif
        if !snap.exists {
            do {
                try await ref.setData([
                    "participantIds": [me, otherUid].sorted(),
                    "createdAt": FieldValue.serverTimestamp(),
                    "lastMessageAt": FieldValue.serverTimestamp(),
                    "lastMessage": "",
                    "lastMessageSenderId": "",
                ])
                #if DEBUG
                print("[Conv] doc \(id) — CREATE ok")
                #endif
            } catch let createErr as NSError {
                #if DEBUG
                print("[Conv] doc \(id) — CREATE failed code=\(createErr.code) desc=\(createErr.localizedDescription)")
                #endif
                throw createErr
            }
        }
        return id
    }

    /// Writes the message and bumps the parent conversation's recency fields
    /// in one batch. Empty/whitespace-only inputs are ignored.
    /// `kind`/`postId`/`postPreview`/`emoji` are stamped when the message is
    /// a mirror of a feed-post interaction (reaction/reply); leave them nil
    /// for ordinary chat.
    func sendMessage(
        convId: String,
        text: String,
        kind: String = "text",
        postId: String? = nil,
        postPreview: String? = nil,
        emoji: String? = nil,
        postMediaURL: String? = nil,
        postIsVideo: Bool = false
    ) async throws {
        guard let me = uid else { throw ConversationError.notSignedIn }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reactions can have empty `text` (the emoji *is* the payload); only
        // bail on empty text for plain chat.
        if kind == "text", trimmed.isEmpty { return }
        let preview: String = {
            if kind == "reaction" {
                return "Reacted \(emoji ?? "•") to your post"
            }
            if kind == "reply" {
                let snippet = String(trimmed.prefix(80))
                return "Replied: \(snippet)"
            }
            return String(trimmed.prefix(120))
        }()

        let convRef = db.collection("conversations").document(convId)
        let msgRef = convRef.collection("messages").document()
        var msgData: [String: Any] = [
            "senderId": me,
            "text": trimmed,
            "kind": kind,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let postId { msgData["postId"] = postId }
        if let postPreview { msgData["postPreview"] = postPreview }
        if let emoji { msgData["emoji"] = emoji }
        if let postMediaURL { msgData["postMediaURL"] = postMediaURL }
        if postIsVideo { msgData["postIsVideo"] = true }

        let batch = db.batch()
        batch.setData(msgData, forDocument: msgRef)
        batch.updateData([
            "lastMessage": preview,
            "lastMessageSenderId": me,
            "lastMessageAt": FieldValue.serverTimestamp(),
        ], forDocument: convRef)
        try await batch.commit()
    }

    /// Convenience: ensures a conv exists with `otherUid`, then writes a
    /// reaction-mirror message into it. No-op if `otherUid` is the caller
    /// (you can't react-to-yourself in the conv sense).
    func mirrorReaction(
        toAuthor otherUid: String,
        emoji: String,
        postId: String,
        postPreview: String?,
        postMediaURL: String?,
        postIsVideo: Bool
    ) async throws {
        guard let me = uid, me != otherUid else { return }
        let convId = try await findOrCreateConversation(with: otherUid)
        try await sendMessage(
            convId: convId,
            text: "",
            kind: "reaction",
            postId: postId,
            postPreview: postPreview,
            emoji: emoji,
            postMediaURL: postMediaURL,
            postIsVideo: postIsVideo
        )
    }

    /// Stamp `lastReadAt.<me> = now` on the conversation doc so the
    /// unread state syncs across devices. Cheap idempotent write —
    /// called when the user opens the thread and again on each new
    /// message arrival while the thread is visible.
    func markRead(convId: String) async {
        guard let me = uid else { return }
        let ref = db.collection("conversations").document(convId)
        try? await ref.updateData([
            "lastReadAt.\(me)": FieldValue.serverTimestamp(),
        ])
    }

    /// iMessage-style: stamp my emoji onto a single message. Replaces
    /// any previous reaction by me on the same message (only one
    /// reaction per participant — the rules permit any participant to
    /// update the `reactions` field, so updating my own entry is fine
    /// and updating someone else's entry is *also* technically permitted
    /// by the rules, but no UI surfaces that). Pass nil emoji to
    /// remove. Bumps only the `reactions` field; the rule's
    /// `affectedKeys().hasOnly(['reactions'])` check enforces this.
    func reactToMessage(
        convId: String,
        messageId: String,
        emoji: String?
    ) async throws {
        guard let me = uid else { throw ConversationError.notSignedIn }
        let ref = db.collection("conversations").document(convId)
            .collection("messages").document(messageId)
        if let emoji {
            try await ref.updateData([
                "reactions.\(me)": emoji,
            ])
        } else {
            try await ref.updateData([
                "reactions.\(me)": FieldValue.delete(),
            ])
        }
    }

    /// Same shape as `mirrorReaction` but for a free-text reply.
    func mirrorReply(
        toAuthor otherUid: String,
        text: String,
        postId: String,
        postPreview: String?,
        postMediaURL: String?,
        postIsVideo: Bool
    ) async throws {
        guard let me = uid, me != otherUid else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let convId = try await findOrCreateConversation(with: otherUid)
        try await sendMessage(
            convId: convId,
            text: trimmed,
            kind: "reply",
            postId: postId,
            postPreview: postPreview,
            postMediaURL: postMediaURL,
            postIsVideo: postIsVideo
        )
    }
}

enum ConversationError: LocalizedError {
    case notSignedIn
    case cannotMessageSelf

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .cannotMessageSelf: return "You can't message yourself."
        }
    }
}
