import SwiftUI
import UIKit
import FirebaseAuth

/// The 1:1 thread view — message list + composer. Reachable from the
/// inbox or directly from a friend's chat icon. Keyboard tracks for
/// free because we're inside a `NavigationStack` push (see
/// `ChatRootView` doc-comment).
struct ChatThreadView: View {
    var conversationService: ConversationService
    var socialService:       SocialService
    var hydrator:            ParticipantHydrator
    let otherUid:            String
    /// Best-effort identity seed from the caller (friend row, mirror flow)
    /// so the header renders the right name *immediately* on push, even
    /// before Firestore lookup completes.
    var seedDisplayName:     String?
    var seedPhotoURL:        String?
    /// Optional jump-to-post hook. When provided, post-reference bubbles
    /// in this thread become tappable.
    var onJumpToPost:        ((String) -> Void)?

    /// Captured once at view construction — see InboxView for rationale.
    private let myUid: String = Auth.auth().currentUser?.uid ?? ""

    @State private var convId: String? = nil
    @State private var composerText: String = ""
    @State private var sendQueue = PendingMessageQueue()
    @State private var atBottom: Bool = true
    @State private var pendingNewMessageFromOther: Bool = false
    @State private var convError: String? = nil
    @State private var lastSeenMessageId: String? = nil
    /// Set when the user picks "More reactions…" from a bubble's action
    /// menu — drives the full emoji picker sheet for that message.
    @State private var emojiPickerTarget: MessageActionTarget? = nil
    /// Set when the user picks "Report" from a bubble's action menu —
    /// drives the shared ReportSheet (`targetType: .message`).
    @State private var reportTarget: ReportTarget? = nil
    /// Drives the iMessage-style long-press overlay (lifted bubble +
    /// reaction bar + action card). Injected into the environment so each
    /// bubble's `.messageActions(_:)` can publish into it.
    @State private var actionPresenter = MessageActionPresenter()
    /// The message currently being replied to (composer shows a banner;
    /// the next send stamps `replyToId`/`replyToText`). Nil = not replying.
    @State private var replyTarget: ChatMessage? = nil
    /// Composer focus, owned here so "Reply" can focus the field.
    @FocusState private var composerFocused: Bool
    /// Message id pending an unsend confirmation (drives the Delete alert).
    @State private var deleteConfirmId: String? = nil

    /// Per-conversation last-read stamp. Bumped on appear + whenever a
    /// new message arrives while the thread is visible.
    @AppStorage private var lastReadAt: Double

    init(
        conversationService: ConversationService,
        socialService:       SocialService,
        hydrator:            ParticipantHydrator,
        otherUid:            String,
        seedDisplayName:     String?,
        seedPhotoURL:        String?,
        onJumpToPost:        ((String) -> Void)? = nil
    ) {
        self.conversationService = conversationService
        self.socialService       = socialService
        self.hydrator            = hydrator
        self.otherUid            = otherUid
        self.seedDisplayName     = seedDisplayName
        self.seedPhotoURL        = seedPhotoURL
        self.onJumpToPost        = onJumpToPost

        let convStableId = Conversation.id(for: Auth.auth().currentUser?.uid ?? "", otherUid)
        _lastReadAt = AppStorage(wrappedValue: 0, "chat.lastRead.\(convStableId)")
    }

    private var rows: [ChatRow] {
        MessageGrouping.rows(from: conversationService.activeMessages)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppTheme.surfaceCanvas.ignoresSafeArea()

            messageList
                .scrollDismissesKeyboard(.interactively)

            if pendingNewMessageFromOther {
                jumpToBottomPill
                    .padding(.bottom, 8)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Hide composer (keyboard + reply banner) while the long-press
            // action overlay is up, so the action card has room and isn't
            // covered. The overlay drives this via its own `withAnimation`,
            // so the slide-down rides that spring.
            if actionPresenter.active == nil {
                ChatComposerView(
                    text: $composerText,
                    retryBanner: sendQueue.hasFailed ? AnyView(retryBanner) : nil,
                    toast: sendQueue.toast,
                    replyPreview: replyTarget.map { replyPreviewText(for: $0) },
                    onCancelReply: { replyTarget = nil },
                    onSend: sendCurrentDraft,
                    onDismissToast: { sendQueue.toast = nil },
                    focused: $composerFocused
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatHeaderView(
                    participant: hydrator.participant(for: otherUid) ?? seededParticipant,
                    otherUid:    otherUid
                )
            }
        }
        .task(id: otherUid) {
            await openConversation()
        }
        .onChange(of: conversationService.activeMessages.last?.id) { _, newId in
            handleNewMessage(latestId: newId)
        }
        .onChange(of: actionPresenter.active != nil) { _, isShowing in
            // Drop the keyboard the moment the long-press overlay appears, so
            // it doesn't sit on top of the action card.
            if isShowing { composerFocused = false }
        }
        .onDisappear {
            // Stamp read on exit so unread state for *this* conv clears
            // even if the user navigated to the very bottom mid-thread.
            stampReadIfAhead()
            conversationService.openThread(nil)
        }
        .alert("Couldn't open chat", isPresented: Binding(
            get: { convError != nil },
            set: { if !$0 { convError = nil } }
        ), presenting: convError) { _ in
            Button("OK", role: .cancel) { convError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert("Delete message?", isPresented: Binding(
            get: { deleteConfirmId != nil },
            set: { if !$0 { deleteConfirmId = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteConfirmId = nil }
            Button("Delete", role: .destructive) {
                if let id = deleteConfirmId { performDelete(messageId: id) }
                deleteConfirmId = nil
            }
        } message: {
            Text("This removes the message for everyone in the chat. This can't be undone.")
        }
        .sheet(item: $emojiPickerTarget) { target in
            EmojiPickerSheetWrapper(
                myEmoji: target.message.reactions[myUid],
                onSelect: { emoji in
                    performReact(on: target.message, emoji: emoji)
                    emojiPickerTarget = nil
                }
            )
            .presentationDetents([.fraction(0.55)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(
                targetType: target.type,
                targetId:   target.targetId,
                socialService: socialService
            )
        }
        // The long-press menu overlay. Layered above everything (messages +
        // composer) and fed by the same presenter the bubbles publish into.
        .overlay {
            MessageActionOverlay()
        }
        .environment(actionPresenter)
    }

    // MARK: - Messages list

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                    }

                    // Pending (optimistic) messages — render in-order at the
                    // bottom so the user sees their text the instant they
                    // tap send, even if the server ack takes a moment.
                    ForEach(sendQueue.pending) { pending in
                        MessageBubbleView(
                            message: pending.asChatMessage(senderId: myUid),
                            myUid: myUid,
                            position: .single,
                            isPending: !pending.failed,
                            hasFailed: pending.failed
                        )
                        .id("pending_\(pending.id)")
                    }

                    Color.clear
                        .frame(height: 8)
                        .id(bottomAnchorID)
                }
                .padding(.top, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geom in
                // "Near the bottom" = within 80pt of the maximum offset.
                let maxY = max(0, geom.contentSize.height - geom.bounds.height)
                let distance = maxY - geom.contentOffset.y
                return distance < 80
            } action: { _, new in
                if atBottom != new {
                    atBottom = new
                    if new {
                        // Just reached the bottom — clear the pill.
                        pendingNewMessageFromOther = false
                    }
                }
            }
            .onChange(of: conversationService.activeMessages.count) { _, _ in
                // After SwiftUI commits the new row, scroll if appropriate.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    if atBottom {
                        withAnimation(Motion.iosDrawer(duration: 0.28)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: sendQueue.pending.count) { _, _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    withAnimation(Motion.iosDrawer(duration: 0.24)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .daySeparator(_, let label):
            DaySeparatorView(label: label)
        case .message(let msg, let position):
            if msg.deleted {
                // Tombstoned (unsent) — a plain placeholder with no menu,
                // swipe, or reactions.
                MessageBubbleView(message: msg, myUid: myUid, position: position)
            } else if msg.referencesPost {
                PostReferenceBubbleView(
                    message: msg,
                    myUid: myUid,
                    position: position,
                    onTap: postTapAction(for: msg),
                    menu: menuModel(for: msg, canReact: true),
                    onRemoveMyReaction: removeReactionAction(for: msg)
                )
            } else {
                MessageBubbleView(
                    message: msg,
                    myUid: myUid,
                    position: position,
                    menu: menuModel(for: msg, canReact: true),
                    onRemoveMyReaction: removeReactionAction(for: msg)
                )
            }
        }
    }

    private var bottomAnchorID: String { "chat.bottom.anchor" }

    /// Returns a tap closure for a post-reference bubble *only* when
    /// MainShellView wired us up with a jump hook AND the message
    /// actually carries a post id. Nil → the bubble stays
    /// non-interactive (matches Phase 1 behaviour as a graceful fallback).
    private func postTapAction(for msg: ChatMessage) -> (() -> Void)? {
        guard let onJumpToPost, let postId = msg.postId else { return nil }
        return {
            let g = UIImpactFeedbackGenerator(style: .light)
            g.impactOccurred()
            onJumpToPost(postId)
        }
    }

    /// Builds the per-message action menu (reactions / copy / report) for a
    /// bubble. `canReact` is false for pending bubbles (no doc id yet), which
    /// hides the reaction rows. The closures route back into this view's
    /// service calls + sheet state.
    private func menuModel(for msg: ChatMessage, canReact: Bool) -> MessageMenuModel {
        MessageMenuModel(
            message:  msg,
            myUid:    myUid,
            canReact: canReact,
            onReact:  { emoji in performReact(on: msg, emoji: emoji) },
            onMoreReactions: {
                emojiPickerTarget = MessageActionTarget(id: msg.id, message: msg, canReact: canReact)
            },
            onReply:  { beginReply(to: msg) },
            onCopy:   { UIPasteboard.general.string = msg.text },
            onDelete: { deleteConfirmId = msg.id },
            onReport: { reportTarget = ReportTarget(type: .message, targetId: msg.id) }
        )
    }

    /// Start replying to `msg`: stash it (the composer shows a banner) and
    /// focus the input so the user can type straight away.
    private func beginReply(to msg: ChatMessage) {
        replyTarget = msg
        composerFocused = true
    }

    /// Short snippet of `msg` for the reply banner + the stored
    /// `replyToText` snapshot. Falls back to a post/reaction description
    /// when the target has no plain text body.
    private func replyPreviewText(for msg: ChatMessage) -> String {
        let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        if msg.isPostReaction { return "Reacted \(msg.emoji ?? "")".trimmingCharacters(in: .whitespaces) }
        if let preview = msg.postPreview, !preview.isEmpty { return preview }
        if msg.referencesPost { return "a post" }
        return "a message"
    }

    private func removeReactionAction(for msg: ChatMessage) -> () -> Void {
        return { performReact(on: msg, emoji: nil) }
    }

    private func performDelete(messageId: String) {
        guard let convId else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        Task {
            do {
                try await conversationService.deleteMessage(convId: convId, messageId: messageId)
            } catch {
                #if DEBUG
                print("[ChatThreadView] deleteMessage failed: \(error)")
                #endif
            }
        }
    }

    private func performReact(on msg: ChatMessage, emoji: String?) {
        guard let convId else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await conversationService.reactToMessage(
                    convId:    convId,
                    messageId: msg.id,
                    emoji:     emoji
                )
            } catch {
                #if DEBUG
                print("[ChatThreadView] reactToMessage failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Floating pill + retry banner

    private var jumpToBottomPill: some View {
        Button {
            pendingNewMessageFromOther = false
            withAnimation(Motion.iosDrawer(duration: 0.3)) {
                // Programmatic-scroll trigger: bump atBottom; the next
                // message-count change handler will animate to the anchor.
                atBottom = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.caption).bold()
                Text("New message")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(AppTheme.textOnAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(AppTheme.accentAction))
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.scalePress)
    }

    private var retryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.errorRed)
            Text("Some messages didn't send")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Button("Retry all") {
                guard let id = convId else { return }
                sendQueue.retryAll(convId: id, service: conversationService)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppTheme.accentAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppTheme.errorRed.opacity(0.10))
    }

    // MARK: - Lifecycle / behaviour

    private var seededParticipant: ParticipantHydrator.Participant? {
        guard seedDisplayName != nil || seedPhotoURL != nil else { return nil }
        return ParticipantHydrator.Participant(
            uid: otherUid,
            displayName: seedDisplayName,
            username: nil,
            photoURL: seedPhotoURL
        )
    }

    private func openConversation() async {
        // Cheap: if a conv already exists between me + otherUid, the
        // peek returns it without writing anything. If not, leave convId
        // nil — the conv doc will be created on first send.
        do {
            if let existing = try await conversationService.findConversation(with: otherUid) {
                convId = existing
                conversationService.openThread(existing)
            }
        } catch {
            // Non-fatal — surface only if the user tries to send.
            #if DEBUG
            print("[ChatThreadView] findConversation failed: \(error)")
            #endif
        }
        // Make sure hydrator has a fresh fetch for the header.
        _ = hydrator.participant(for: otherUid)
        stampReadIfAhead()
    }

    private func handleNewMessage(latestId: String?) {
        guard latestId != lastSeenMessageId else { return }
        lastSeenMessageId = latestId

        guard let latest = conversationService.activeMessages.last else { return }

        // Always update the read stamp when we *are* viewing the bottom —
        // otherwise the inbox would keep this conv marked unread.
        if atBottom || latest.senderId == myUid {
            stampReadIfAhead()
        }

        if latest.senderId != myUid && !atBottom {
            withAnimation(Motion.iosDrawer(duration: 0.28)) {
                pendingNewMessageFromOther = true
            }
            // Soft haptic so the user notices even if they're glancing
            // at the input field.
            let g = UIImpactFeedbackGenerator(style: .soft)
            g.impactOccurred()
        }
    }

    private func stampReadIfAhead() {
        // Server-side stamp via ConversationService — propagates to
        // other devices through the inbox listener.
        if let convId {
            Task { @MainActor in
                await conversationService.markRead(convId: convId)
            }
        }
        // Belt-and-suspenders local stamp so the inbox row clears
        // unread state instantly even before the server write returns
        // (and so offline thread reads still mark themselves "read"
        // until the next online sync rewrites them).
        if let last = conversationService.inbox.first(where: { $0.id == convId })?.lastMessageAt {
            lastReadAt = max(lastReadAt, last.timeIntervalSince1970)
        } else if let latest = conversationService.activeMessages.last?.createdAt {
            lastReadAt = max(lastReadAt, latest.timeIntervalSince1970)
        } else {
            lastReadAt = max(lastReadAt, Date.now.timeIntervalSince1970)
        }
    }

    // MARK: - Send

    private func sendCurrentDraft() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerText = ""

        // Snapshot + clear the reply target so the banner dismisses with the send.
        let reply = replyTarget
        replyTarget = nil

        // Light haptic mirroring the rest of the app's vocabulary.
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()

        Task {
            do {
                let id = try await ensureConvId()
                sendQueue.enqueue(
                    convId:   id,
                    text:     trimmed,
                    senderId: myUid,
                    service:  conversationService,
                    replyToId:   reply?.id,
                    replyToText: reply.map { replyPreviewText(for: $0) }
                )
            } catch {
                convError = error.localizedDescription
                // Restore the draft so the user doesn't lose their typing.
                if composerText.isEmpty { composerText = trimmed }
            }
        }
    }

    private func ensureConvId() async throws -> String {
        if let convId { return convId }
        let id = try await conversationService.findOrCreateConversation(with: otherUid)
        convId = id
        conversationService.openThread(id)
        return id
    }
}
