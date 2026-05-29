import Combine
import CryptoKit
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

    // MARK: - E2EE

    /// Derived per-conversation AES key cache (convId → key).
    private var convKeyCache: [String: SymmetricKey] = [:]
    /// Cache of OTHER users' published public keys (uid → base64). Only
    /// present keys are cached, so a missing partner key is re-fetched on the
    /// next send (lets encryption kick in once they publish).
    private var publicKeyCache: [String: String] = [:]
    private static let lockedPlaceholder = "🔒 Message can't be decrypted"

    /// Derives the conversation key from my identity private key + the other
    /// participant's published public key. Returns nil when E2EE isn't possible
    /// (no signed-in user, malformed convId, or the partner has no published
    /// key yet) — callers then fall back to plaintext.
    private func conversationKey(convId: String) async -> SymmetricKey? {
        if let cached = convKeyCache[convId] { return cached }
        guard let me = uid else { return nil }
        // convId is the two uids sorted + joined by "_"; Firebase uids contain
        // no "_", so splitting recovers the other participant without a fetch.
        let parts = convId.split(separator: "_").map(String.init)
        guard let otherUid = parts.first(where: { $0 != me }) else { return nil }
        do {
            let myPriv = try MessageCrypto.loadOrCreateIdentityKey(uid: me)
            let theirPub: String
            if let cached = publicKeyCache[otherUid] {
                theirPub = cached
            } else {
                let snap = try await db.collection("users").document(otherUid).getDocument()
                guard let pub = snap.data()?["publicKey"] as? String, !pub.isEmpty else { return nil }
                publicKeyCache[otherUid] = pub
                theirPub = pub
            }
            let key = try MessageCrypto.conversationKey(
                myPrivateKey: myPriv, theirPublicKeyBase64: theirPub, convId: convId)
            convKeyCache[convId] = key
            return key
        } catch {
            return nil
        }
    }

    /// Returns a copy of `m` with its encrypted fields decrypted. Legacy
    /// (`encv == 0`) and deleted messages pass through untouched. A decrypt
    /// failure (e.g. the key rotated after a reinstall) renders the locked
    /// placeholder rather than raw ciphertext.
    private func decrypted(_ m: ChatMessage, key: SymmetricKey?) -> ChatMessage {
        guard m.encv >= 1, !m.deleted, let key else { return m }
        let text = (try? MessageCrypto.open(m.text, key: key)) ?? Self.lockedPlaceholder
        let reply = m.replyToText.flatMap { try? MessageCrypto.open($0, key: key) } ?? m.replyToText
        let preview = m.postPreview.flatMap { try? MessageCrypto.open($0, key: key) } ?? m.postPreview
        return ChatMessage(
            id: m.id, senderId: m.senderId, text: text, kind: m.kind,
            postId: m.postId, postPreview: preview, emoji: m.emoji,
            postMediaURL: m.postMediaURL, postIsVideo: m.postIsVideo,
            createdAt: m.createdAt, reactions: m.reactions,
            replyToId: m.replyToId, replyToText: reply,
            deleted: m.deleted, postDeleted: m.postDeleted, encv: m.encv
        )
    }

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
        convKeyCache.removeAll()
        publicKeyCache.removeAll()
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
                    var resolved: [Conversation] = []
                    resolved.reserveCapacity(convs.count)
                    for c in convs {
                        if c.lastMessageEnc, let key = await self.conversationKey(convId: c.id) {
                            let plain = (try? MessageCrypto.open(c.lastMessage, key: key)) ?? Self.lockedPlaceholder
                            resolved.append(c.withLastMessage(plain))
                        } else {
                            resolved.append(c)
                        }
                    }
                    self.inbox = resolved.sorted {
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
                    let raw = snap?.documents.compactMap { ChatMessage(document: $0) } ?? []
                    let key = await self.conversationKey(convId: convId)
                    self.activeMessages = raw.map { self.decrypted($0, key: key) }
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
        postIsVideo: Bool = false,
        replyToId: String? = nil,
        replyToText: String? = nil
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

        // E2EE: encrypt human-readable fields when we can derive the
        // conversation key. Falls back to plaintext when the partner hasn't
        // published a key yet (rollout) or sealing fails — messaging keeps
        // working either way. Metadata (senderId/kind/emoji/postMediaURL/etc.)
        // is never encrypted.
        let key = await conversationKey(convId: convId)
        var msgData: [String: Any] = [
            "senderId": me,
            "kind": kind,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        var lastMessageValue = preview
        var encrypted = false
        if let key, !trimmed.isEmpty {
            do {
                msgData["text"] = try MessageCrypto.seal(trimmed, key: key)
                if let postPreview { msgData["postPreview"] = try MessageCrypto.seal(postPreview, key: key) }
                if let replyToText { msgData["replyToText"] = try MessageCrypto.seal(replyToText, key: key) }
                lastMessageValue = try MessageCrypto.seal(preview, key: key)
                msgData["encv"] = 1
                encrypted = true
            } catch {
                encrypted = false
            }
        }
        if !encrypted {
            msgData["text"] = trimmed
            if let postPreview { msgData["postPreview"] = postPreview }
            if let replyToText { msgData["replyToText"] = replyToText }
            lastMessageValue = preview
        }
        if let postId { msgData["postId"] = postId }
        if let emoji { msgData["emoji"] = emoji }
        if let postMediaURL { msgData["postMediaURL"] = postMediaURL }
        if postIsVideo { msgData["postIsVideo"] = true }
        if let replyToId { msgData["replyToId"] = replyToId }

        let convRef = db.collection("conversations").document(convId)
        let msgRef = convRef.collection("messages").document()
        let batch = db.batch()
        batch.setData(msgData, forDocument: msgRef)
        batch.updateData([
            "lastMessage": lastMessageValue,
            "lastMessageSenderId": me,
            "lastMessageAt": FieldValue.serverTimestamp(),
            "lastMessageEnc": encrypted,
        ], forDocument: convRef)
        try await batch.commit()
    }

    /// Ensures a conv exists with `otherUid`, then writes (or quietly
    /// updates) a single reaction-mirror message for this post. No-op if
    /// `otherUid` is the caller.
    ///
    /// The message id is **deterministic** per (post, reactor) so re-reacting
    /// OVERWRITES instead of appending: the thread shows exactly one reaction
    /// bubble, and because `onNewMessage` fires on *create* only, the author
    /// is notified just once — switching emoji is a silent in-place edit. This
    /// is what keeps a tap-happy reactor from spamming the author's inbox.
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
        let convRef = db.collection("conversations").document(convId)
        let msgRef = convRef.collection("messages").document("rxn_\(postId)_\(me)")

        // Already reacted to this post → change just the emoji, in place.
        // createdAt and the conversation recency are left untouched, so the
        // bubble keeps its position and the inbox isn't re-surfaced; no push
        // goes out (the rules permit a reactor to edit `emoji` on their own
        // reaction message).
        let existing = try await msgRef.getDocument()
        if existing.exists {
            try await msgRef.updateData(["emoji": emoji])
            return
        }

        // First reaction to this post — create the bubble + bump recency so
        // the author receives exactly one notification.
        let preview = "Reacted \(emoji) to your post"
        var msgData: [String: Any] = [
            "senderId": me,
            "text": "",
            "kind": "reaction",
            "emoji": emoji,
            "postId": postId,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let postPreview { msgData["postPreview"] = postPreview }
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

    /// Soft-delete (unsend) one of MY messages. Hard deletes are disabled in
    /// the rules (message immutability), so we flip a `deleted` tombstone and
    /// blank the text; the bubble renders a "message deleted" placeholder.
    /// If it was the conversation's latest message, the inbox preview is
    /// refreshed too (without bumping recency).
    func deleteMessage(convId: String, messageId: String) async throws {
        guard uid != nil else { throw ConversationError.notSignedIn }
        let convRef = db.collection("conversations").document(convId)
        let msgRef = convRef.collection("messages").document(messageId)
        try await msgRef.updateData([
            "deleted": true,
            "text": "",
        ])
        // Keep the inbox preview honest when the unsent message was the last
        // one. Only touch `lastMessage` — leaving `lastMessageAt` alone so the
        // conversation doesn't jump to the top of the inbox.
        if activeMessages.last?.id == messageId {
            try? await convRef.updateData(["lastMessage": "Message deleted"])
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
