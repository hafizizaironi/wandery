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

    /// Per-conversation content key (CEK) cache (convId → key). The CEK is
    /// **stable for the life of the thread** (encv 2): a participant rotating
    /// identity keys re-wraps the same CEK rather than changing the message key,
    /// so history survives reinstalls / new devices.
    private var cekCache: [String: SymmetricKey] = [:]
    /// Legacy static-ECDH conversation key cache (encv 1 messages only).
    private var legacyKeyCache: [String: SymmetricKey] = [:]
    /// Cache of OTHER users' published public keys (uid → base64).
    private var publicKeyCache: [String: String] = [:]
    private static let lockedPlaceholder = "🔒 Can't decrypt — a device was reinstalled"

    /// convId is the two uids sorted + joined by "_"; Firebase uids contain no
    /// "_", so splitting recovers the other participant without a fetch.
    private func otherUid(in convId: String, me: String) -> String? {
        convId.split(separator: "_").map(String.init).first { $0 != me }
    }

    /// A peer's published identity public key (base64). Cached; `fresh` forces a
    /// server read (used when re-wrapping after a suspected key rotation).
    private func peerPublicKey(_ other: String, fresh: Bool = false) async -> String? {
        if !fresh, let cached = publicKeyCache[other] { return cached }
        let snap = try? await db.collection("users").document(other)
            .getDocument(source: fresh ? .server : .default)
        guard let pub = snap?.data()?["publicKey"] as? String, !pub.isEmpty else { return nil }
        publicKeyCache[other] = pub
        return pub
    }

    /// The conversation's content key (encv 2), establishing it if absent and
    /// `establish` is true. Returns nil when the CEK can't be obtained yet — the
    /// peer hasn't published an identity key, or my wrapped entry is stale after
    /// I rotated (the peer re-wraps it on their next open). On success, keeps the
    /// peer's wrapped entry fresh so a peer who rotated regains access.
    private func contentKey(convId: String, establish: Bool,
                            rewrapPeerIfStale: Bool = false) async -> SymmetricKey? {
        if let cached = cekCache[convId] { return cached }
        guard let me = uid else { return nil }
        guard let myPriv = try? MessageCrypto.loadOrCreateIdentityKey(uid: me) else { return nil }

        let convRef = db.collection("conversations").document(convId)
        let cekMap = (try? await convRef.getDocument())?.data()?["cek"] as? [String: [String: String]]

        // 1. I have a usable wrapped entry → unwrap, cache. On thread open, also
        //    keep the peer's wrapped entry fresh so a peer who reinstalled
        //    regains access (skipped on the inbox path to avoid N server reads).
        if let mine = cekMap?[me], let ek = mine["ek"], let ct = mine["ct"],
           let cek = try? MessageCrypto.unwrap(ek: ek, ct: ct, myPrivateKey: myPriv) {
            cekCache[convId] = cek
            if rewrapPeerIfStale {
                await ensurePeerWrap(convId: convId, convRef: convRef, cekMap: cekMap, cek: cek, me: me)
            }
            return cek
        }

        // 2. No CEK exists yet → establish one (needs the peer's published key).
        if cekMap == nil, establish {
            return await establishContentKey(convId: convId, convRef: convRef, me: me, myPriv: myPriv)
        }

        // 3. A CEK exists but my entry is missing/stale (I rotated). The peer
        //    re-wraps it to my new key on their next open — locked until then.
        return nil
    }

    /// Generate a CEK and wrap it to both participants. Transaction-guarded so a
    /// simultaneous first message from the other side can't split the key.
    private func establishContentKey(
        convId: String, convRef: DocumentReference,
        me: String, myPriv: Curve25519.KeyAgreement.PrivateKey
    ) async -> SymmetricKey? {
        guard let other = otherUid(in: convId, me: me),
              let theirPub = await peerPublicKey(other) else { return nil }
        let myPub = MessageCrypto.publicKeyBase64(for: myPriv)
        let cek = MessageCrypto.newContentKey()
        guard let mineW = try? MessageCrypto.wrap(cek, toPublicKeyBase64: myPub),
              let theirsW = try? MessageCrypto.wrap(cek, toPublicKeyBase64: theirPub) else { return nil }
        let myEntry = ["ek": mineW.ek, "ct": mineW.ct, "forPub": myPub]
        let theirEntry = ["ek": theirsW.ek, "ct": theirsW.ct, "forPub": theirPub]

        // Atomic create-if-absent; if the peer won the race, adopt their map.
        let result = try? await db.runTransaction { (txn, _) -> Any? in
            let doc = try? txn.getDocument(convRef)
            if let existing = doc?.data()?["cek"] as? [String: [String: String]] { return existing }
            let map = [me: myEntry, other: theirEntry]
            txn.setData(["cek": map], forDocument: convRef, merge: true)
            return map
        }
        let authMap = result as? [String: [String: String]]
        guard let mine = authMap?[me], let ek = mine["ek"], let ct = mine["ct"],
              let key = try? MessageCrypto.unwrap(ek: ek, ct: ct, myPrivateKey: myPriv) else { return nil }
        cekCache[convId] = key
        return key
    }

    /// If I hold the CEK and the peer's wrapped entry is missing or was wrapped
    /// to a now-stale identity key (they reinstalled), re-wrap the CEK to their
    /// current key so they regain access to history. Logged for observability —
    /// this key-change point is also where a future safety-number / MITM warning
    /// would hook in (see plan V5).
    private func ensurePeerWrap(
        convId: String, convRef: DocumentReference,
        cekMap: [String: [String: String]]?, cek: SymmetricKey, me: String
    ) async {
        guard let other = otherUid(in: convId, me: me),
              let theirCurrentPub = await peerPublicKey(other, fresh: true) else { return }
        if cekMap?[other]?["forPub"] == theirCurrentPub { return }   // already fresh
        guard let w = try? MessageCrypto.wrap(cek, toPublicKeyBase64: theirCurrentPub) else { return }
        dlog("[ConversationService] re-wrapping CEK for \(other) (identity key changed) in \(convId)")
        try? await convRef.updateData([
            "cek.\(other)": ["ek": w.ek, "ct": w.ct, "forPub": theirCurrentPub],
        ])
    }

    /// Legacy encv-1 key (static ECDH of both identity keys) — read-only path
    /// for messages sealed before the CEK migration.
    private func legacyKey(convId: String, forceRefresh: Bool = false) async -> SymmetricKey? {
        if !forceRefresh, let cached = legacyKeyCache[convId] { return cached }
        guard let me = uid, let other = otherUid(in: convId, me: me),
              let myPriv = try? MessageCrypto.loadOrCreateIdentityKey(uid: me),
              let theirPub = await peerPublicKey(other, fresh: forceRefresh),
              let key = try? MessageCrypto.conversationKey(
                myPrivateKey: myPriv, theirPublicKeyBase64: theirPub, convId: convId) else { return nil }
        legacyKeyCache[convId] = key
        return key
    }

    /// Returns a copy of `m` with its encrypted fields decrypted, choosing the
    /// key by version (encv 2 → CEK, encv 1 → legacy). Plaintext (`encv == 0`)
    /// and deleted messages pass through. Empty `text` (e.g. a reaction mirror
    /// whose only encrypted payload is `postPreview`) is left as-is. A decrypt
    /// failure renders the locked placeholder rather than raw ciphertext.
    private func decrypted(_ m: ChatMessage, cek: SymmetricKey?, legacy: SymmetricKey?) -> ChatMessage {
        guard m.encv >= 1, !m.deleted else { return m }
        let key = m.encv >= 2 ? cek : legacy
        func open(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return s }
            guard let key else { return Self.lockedPlaceholder }
            return (try? MessageCrypto.open(s, key: key)) ?? Self.lockedPlaceholder
        }
        return ChatMessage(
            id: m.id, senderId: m.senderId, text: open(m.text) ?? m.text, kind: m.kind,
            postId: m.postId, postPreview: open(m.postPreview) ?? m.postPreview, emoji: m.emoji,
            postMediaURL: m.postMediaURL, postIsVideo: m.postIsVideo,
            createdAt: m.createdAt, reactions: m.reactions,
            replyToId: m.replyToId, replyToText: open(m.replyToText) ?? m.replyToText,
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
        cekCache.removeAll()
        legacyKeyCache.removeAll()
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
                        dlog("[ConversationService] inbox listener error: \(err)")
                        return
                    }
                    let convs = snap?.documents.compactMap { Conversation(document: $0) } ?? []
                    var resolved: [Conversation] = []
                    resolved.reserveCapacity(convs.count)
                    for c in convs {
                        if c.lastMessageEnc {
                            // Preview may be encv 2 (CEK) or legacy encv 1 — try both.
                            let cek = await self.contentKey(convId: c.id, establish: false)
                            var plain = cek.flatMap { try? MessageCrypto.open(c.lastMessage, key: $0) }
                            if plain == nil, let legacy = await self.legacyKey(convId: c.id) {
                                plain = try? MessageCrypto.open(c.lastMessage, key: legacy)
                            }
                            resolved.append(c.withLastMessage(plain ?? Self.lockedPlaceholder))
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
                    let cek = await self.contentKey(convId: convId, establish: false, rewrapPeerIfStale: true)
                    var legacy = await self.legacyKey(convId: convId)
                    var decoded = raw.map { self.decrypted($0, cek: cek, legacy: legacy) }
                    // A locked encv-1 message can mean the peer rotated their
                    // legacy key — force a one-shot server refresh and retry.
                    // (encv-2 recovery is peer-driven: the other side re-wraps the
                    // CEK to my new key on their next open.)
                    if decoded.contains(where: { $0.encv == 1 && !$0.deleted && $0.text == Self.lockedPlaceholder }),
                       let freshLegacy = await self.legacyKey(convId: convId, forceRefresh: true) {
                        legacy = freshLegacy
                        decoded = raw.map { self.decrypted($0, cek: cek, legacy: legacy) }
                    }
                    self.activeMessages = decoded
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
            dlog("[Conv] doc \(id) — GET failed code=\(getErr.code) desc=\(getErr.localizedDescription)")
            #endif
            throw getErr
        }
        #if DEBUG
        dlog("[Conv] doc \(id) — GET ok exists=\(snap.exists) participantIds=\(snap.data()?["participantIds"] ?? "nil")")
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
                dlog("[Conv] doc \(id) — CREATE ok")
                #endif
            } catch let createErr as NSError {
                #if DEBUG
                dlog("[Conv] doc \(id) — CREATE failed code=\(createErr.code) desc=\(createErr.localizedDescription)")
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
        // E2EE: encrypt all human-readable fields with the conversation's stable
        // content key (encv 2). If a CEK can't be established yet — the peer
        // hasn't published an identity key — THROW so the caller's
        // PendingMessageQueue retries; we NEVER store plaintext. Metadata
        // (senderId/kind/emoji/postMediaURL/postId/replyToId) is not encrypted.
        guard let key = await contentKey(convId: convId, establish: true) else {
            throw ConversationError.notEncryptable
        }
        var msgData: [String: Any] = [
            "senderId": me,
            "kind": kind,
            "createdAt": FieldValue.serverTimestamp(),
            "encv": 2,
        ]
        msgData["text"] = trimmed.isEmpty ? "" : (try MessageCrypto.seal(trimmed, key: key))
        if let postPreview { msgData["postPreview"] = try MessageCrypto.seal(postPreview, key: key) }
        if let replyToText { msgData["replyToText"] = try MessageCrypto.seal(replyToText, key: key) }
        let lastMessageValue = try MessageCrypto.seal(preview, key: key)
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
            "lastMessageEnc": true,
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

        // First reaction to this post — create the bubble + bump recency so the
        // author receives exactly one notification. The post-caption snapshot
        // (`postPreview`) is user content: encrypt it with the CEK, or OMIT it
        // entirely when no key is available (never store it plaintext). The
        // inbox preview ("Reacted X to your post") is derived from the `emoji`
        // metadata, so it stays plaintext / `lastMessageEnc` false.
        let preview = "Reacted \(emoji) to your post"
        let cek = await contentKey(convId: convId, establish: true)
        var msgData: [String: Any] = [
            "senderId": me,
            "text": "",
            "kind": "reaction",
            "emoji": emoji,
            "postId": postId,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let postPreview, let cek {
            msgData["postPreview"] = try MessageCrypto.seal(postPreview, key: cek)
            msgData["encv"] = 2
        }
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
    case notEncryptable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .cannotMessageSelf: return "You can't message yourself."
        case .notEncryptable:
            return "Waiting for your friend's encryption key — the message will send once it's available."
        }
    }
}
