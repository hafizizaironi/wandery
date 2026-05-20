import SwiftUI
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// 1:1 chat thread. Reads `conversationService.activeMessages` (live) and
/// writes via `sendMessage`. The host wires `openThread(convId)` before
/// presenting and clears it on dismiss.
struct ChatView: View {
    @ObservedObject var conversationService: ConversationService
    /// Required for the Block button to work end-to-end. Tagged as
    /// @ObservedObject so the chat closes itself when `blockedUserIds`
    /// updates to include `otherUid`.
    @ObservedObject var socialService: SocialService
    /// Optional. When nil, this is a fresh chat with a friend the user has
    /// never messaged. The conversation document is *lazy-created* on the
    /// first send — the composer stays interactive and `send()` calls
    /// `findOrCreateConversation` before writing the message. Existing
    /// conversations (from the inbox or from a Hero reaction reply) pass
    /// the id in directly and skip the lazy path.
    let convId: String?
    let otherUid: String
    let otherTitle: String
    var onClose: () -> Void
    /// Optional jump-to-post handler. When set, reaction/reply bubbles
    /// expose a tappable thumbnail that calls this with the referenced
    /// post id — host typically dismisses the chat and scrolls the Hero
    /// feed to that post.
    var onJumpToPost: ((String) -> Void)?

    @State private var draft: String = ""
    @State private var isSending = false
    @State private var sendError: String?
    /// Set on first send for the lazy-create path. Once set, `effectiveConvId`
    /// returns this instead of the (still-nil) `convId` prop. ChatView's
    /// @State survives the parent's view-tree re-renders since `PendingChat.id`
    /// doesn't change when convId resolves.
    @State private var resolvedConvId: String?
    @FocusState private var inputFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
    @State private var pendingBlock = false
    @State private var reportTarget: ReportTarget?
    @State private var moderationError: String?

    /// Either the convId the host passed (existing conversation) or the one
    /// we lazy-created on first send. Drives both the messages listener
    /// gate and the empty-state UI.
    private var effectiveConvId: String? { resolvedConvId ?? convId }

    /// Captured at struct init so `messageBubble(_:)` doesn't hit
    /// Auth.auth().currentUser on every body re-render. The signed-in
    /// user can't change while this view is alive — if it did, the
    /// surrounding view tree would unmount.
    private let myUid: String = Auth.auth().currentUser?.uid ?? ""

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                messagesScroll
                Divider().background(AppTheme.cream.opacity(0.05))
                composer
            }
            .padding(.bottom, keyboardHeight)
        }
        // SwiftUI's built-in keyboard avoidance doesn't reliably propagate
        // into views presented via .overlay { } — both .ignoresSafeArea(.container)
        // and .safeAreaInset(edge: .bottom) failed to lift the composer in
        // testing. Observe the keyboard directly and apply the height as
        // bottom padding ourselves. .ignoresSafeArea(.keyboard) below tells
        // SwiftUI to stay out of it so we get clean single-source behaviour.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = 0
            }
        }
        .onDisappear { conversationService.openThread(nil) }
        .alert(
            "Block \(otherTitle)?",
            isPresented: $pendingBlock
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                Task { await performBlock() }
            }
        } message: {
            Text("They'll be removed from your friends, can't message you, and won't appear in your feed.")
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(
                targetType: target.type,
                targetId: target.targetId,
                socialService: socialService
            )
            .presentationDetents([.medium, .large])
        }
        // Auto-close once the block takes effect — the blocked-users
        // listener flips this set, and the user shouldn't be staring at a
        // chat with someone they just blocked.
        .onChange(of: socialService.blockedUserIds.contains(otherUid)) { _, isBlocked in
            if isBlocked { onClose() }
        }
    }

    private func performBlock() async {
        do {
            try await socialService.blockUser(uid: otherUid)
        } catch {
            moderationError = error.localizedDescription
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.subheadline).bold()
                    .contrastAware(AppTheme.cream, opacity: 0.7)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.cream.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text(otherTitle)
                .font(.subheadline).bold()
                .foregroundStyle(AppTheme.cream)
                .lineLimit(1)

            Spacer()

            // Overflow menu — App Store Guideline 1.2 requires both a
            // block-user and a report-content path. Surface both here
            // since the chat is the most likely place a user encounters
            // harassment.
            Menu {
                Button {
                    reportTarget = ReportTarget(type: .user, targetId: otherUid)
                } label: {
                    Label("Report user", systemImage: "exclamationmark.triangle")
                }
                Button(role: .destructive) {
                    pendingBlock = true
                } label: {
                    Label("Block user", systemImage: "hand.raised")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.cream.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 14)
        // ChatView is full-screen + ignoresSafeArea, so the back button
        // needs a fixed top padding to clear the status bar / dynamic
        // island. Same value as the inbox header for consistency.
        .padding(.top, 56)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var messagesScroll: some View {
        if effectiveConvId == nil {
            // Brand-new conversation — no listener attached yet (we lazy-
            // create the doc on first send). Show a friendly prompt instead
            // of an empty scroll view or a spinner that suggests the app is
            // waiting on something. The composer below is fully interactive.
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32, weight: .light))
                    .contrastAware(AppTheme.cream, opacity: 0.35)
                    .accessibilityHidden(true)
                Text("Say hi to start the conversation")
                    .font(.footnote)
                    .contrastAware(AppTheme.cream, opacity: 0.5)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(conversationService.activeMessages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                        }
                        Color.clear.frame(height: 1).id("__bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .onChange(of: conversationService.activeMessages.count) { _, _ in
                    // Always scroll to the newest message — the user is either
                    // typing in the composer (and expects to see what they
                    // just sent) or watching the thread live.
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("__bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("__bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        let mine = msg.senderId == myUid
        let bubbleContent = bubbleContentView(msg: msg, mine: mine)
        // Only allow reporting messages from the other user (you can't
        // report your own). Long-press surfaces the Report option.
        if mine {
            bubbleContent
        } else {
            bubbleContent
                .contextMenu {
                    Button {
                        reportTarget = ReportTarget(type: .message, targetId: msg.id)
                    } label: {
                        Label("Report message", systemImage: "exclamationmark.triangle")
                    }
                }
        }
    }

    @ViewBuilder
    private func bubbleContentView(msg: ChatMessage, mine: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if msg.referencesPost {
                postReferenceBanner(msg, mine: mine)
            }
            // For post-anchored messages we line up the bubble next to a
            // thumbnail of the referenced post. The thumb sits on the
            // *opposite* side from the bubble's tail so it visually reads
            // as "this message is about that picture".
            if msg.referencesPost, let mediaURL = msg.postMediaURL.flatMap(URL.init(string:)) {
                HStack(alignment: .bottom, spacing: 8) {
                    if mine {
                        mainBubble(msg, mine: mine)
                        postThumbnail(mediaURL, postId: msg.postId)
                    } else {
                        postThumbnail(mediaURL, postId: msg.postId)
                        mainBubble(msg, mine: mine)
                    }
                }
            } else {
                mainBubble(msg, mine: mine)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    /// Tappable post snapshot. AsyncImage + a tiny play badge for videos.
    /// Tap calls `onJumpToPost` so the host can dismiss the chat and scroll
    /// the feed to that post; falls back to a static look when the host
    /// hasn't wired the callback.
    @ViewBuilder
    private func postThumbnail(_ url: URL, postId: String?) -> some View {
        let inner = ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    Color.black.opacity(0.4)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.subheadline)
                                .contrastAware(AppTheme.cream, opacity: 0.5)
                        }
                default:
                    AppTheme.cream.opacity(0.08)
                        .overlay { ProgressView().scaleEffect(0.6) }
                }
            }
            .frame(width: 225, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppTheme.cream.opacity(0.20), lineWidth: 1)
            }

            // "Tap to jump" affordance — the corner arrow signals that
            // tapping the thumb leaves the chat for the post itself.
            Image(systemName: "arrow.up.right.square.fill")
                .font(.title2).bold()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 2)
                .padding(8)
        }

        if let postId, let onJumpToPost {
            Button { onJumpToPost(postId) } label: { inner }
                .buttonStyle(.plain)
                .accessibilityLabel("Open post")
        } else {
            inner
        }
    }

    /// Compact pill that captions reaction/reply messages with the post they
    /// were sent against. Tapping is intentionally inert for v1 — this is a
    /// context label, not navigation.
    private func postReferenceBanner(_ msg: ChatMessage, mine: Bool) -> some View {
        let preview = msg.postPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snippet = preview.isEmpty ? "their post" : "\"\(preview)\""
        let label: String = {
            if msg.isPostReaction {
                let who = mine ? "You reacted to" : "Reacted to"
                return "\(who) \(snippet)"
            }
            // reply
            let who = mine ? "You replied to" : "Replied to"
            return "\(who) \(snippet)"
        }()
        return HStack(spacing: 6) {
            Image(systemName: msg.isPostReaction ? "heart.fill" : "arrowshape.turn.up.left.fill")
                .font(.caption2).bold()
            Text(label)
                .font(.caption2)
                .lineLimit(1)
        }
        .contrastAware(AppTheme.cream, opacity: 0.55)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(AppTheme.cream.opacity(0.05))
        )
        .overlay(Capsule().stroke(AppTheme.cream.opacity(0.10), lineWidth: 1))
        .padding(mine ? .trailing : .leading, 6)
    }

    private func mainBubble(_ msg: ChatMessage, mine: Bool) -> some View {
        Group {
            if msg.isPostReaction {
                // Reactions render as a big emoji on a transparent background
                // — same vibe as Locket/IG "reaction" surfaces.
                Text(msg.emoji ?? "•")
                    .font(.largeTitle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            } else {
                Text(msg.text)
                    .font(.subheadline)
                    .foregroundStyle(mine ? AppTheme.cream : AppTheme.cream.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(mine ? AppTheme.cafeAccent.opacity(0.85) : AppTheme.cream.opacity(0.08))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                mine ? AppTheme.cafeAccent.opacity(0.35) : AppTheme.cream.opacity(0.08),
                                lineWidth: 1
                            )
                    }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let err = sendError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(AppTheme.errorRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
            HStack(spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.cream)
                    .tint(AppTheme.cafeAccent)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.cream.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(AppTheme.cafeAccent.opacity(0.2), lineWidth: 1)
                    }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline).bold()
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(canSend ? AppTheme.cafeAccent : AppTheme.cafeAccent.opacity(0.35))
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend || isSending)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(AppTheme.espresso)
    }

    private var canSend: Bool {
        // Empty drafts can't send, but a nil convId is fine — we'll
        // lazy-create the conversation when the user taps Send.
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        guard canSend, !isSending else { return }
        let text = draft
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            // Resolve the convId first if this is a brand-new conversation.
            // findOrCreateConversation is idempotent — if a doc already
            // exists for this pair (e.g. the friend messaged us first), it
            // returns the existing id without creating.
            let id: String
            if let existing = effectiveConvId {
                id = existing
            } else {
                id = try await conversationService.findOrCreateConversation(with: otherUid)
                resolvedConvId = id
                conversationService.openThread(id)
            }
            try await conversationService.sendMessage(convId: id, text: text)
            draft = ""
        } catch {
            sendError = error.localizedDescription
        }
    }
}
