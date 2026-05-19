import SwiftUI
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// Inbox of recent 1:1 conversations. Driven by `ConversationService.inbox`,
/// which is a live snapshot ordered by `lastMessageAt`. Tap a row → push a
/// chat thread for that conversation.
struct ConversationsListView: View {
    @ObservedObject var conversationService: ConversationService
    @ObservedObject var socialService: SocialService
    var onClose: () -> Void
    /// Forwarded into the inner ChatView so a thumbnail tap there lets the
    /// host scroll the feed to the referenced post.
    var onJumpToPost: ((String) -> Void)?

    @State private var profileLoader = FriendListLoader()
    @State private var openConvId: String?
    @State private var openOtherUid: String?
    @State private var openOtherTitle: String = ""

    private var myUid: String { Auth.auth().currentUser?.uid ?? "" }

    /// Other-participant uids referenced by the current inbox — driver for the
    /// profile-hydration pass. Recomputed cheaply when the inbox changes.
    private var otherUids: [String] {
        conversationService.inbox.compactMap { $0.otherParticipant(of: myUid) }
    }

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()
            VStack(spacing: 0) {
                header

                if conversationService.inbox.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(conversationService.inbox) { conv in
                                conversationRow(conv)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .task(id: otherUids) {
            await profileLoader.sync(with: otherUids)
        }
        // Full-screen chat layered on top of the inbox (which is itself
        // full-screen, presented by the host). Slides in from the trailing
        // edge so it reads as "drilling into" the conversation.
        .overlay {
            if let convId = openConvId, let otherUid = openOtherUid {
                ChatView(
                    conversationService: conversationService,
                    convId: convId,
                    otherUid: otherUid,
                    otherTitle: openOtherTitle,
                    onClose: { closeThread() },
                    onJumpToPost: onJumpToPost.map { jump in
                        { postId in
                            closeThread()
                            onClose()
                            jump(postId)
                        }
                    }
                )
                .background(AppTheme.espresso.ignoresSafeArea())
                .ignoresSafeArea()
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: openConvId)
    }

    private var header: some View {
        HStack {
            Text("Messages")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppTheme.cream)
            Text("\(conversationService.inbox.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.cafeAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppTheme.cafeAccent.opacity(0.15)))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.cream.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.cream.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        // The inbox is full-screen + ignoresSafeArea, so this top padding
        // is what clears the status bar / dynamic island. Hardcoded to a
        // value that works on every iPhone — large enough for the island
        // and small enough not to look like a header gap on smaller
        // devices.
        .padding(.top, 56)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundColor(AppTheme.cream.opacity(0.25))
            Text("No conversations yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.cream.opacity(0.65))
            Text("Open a friend's profile and tap Message to start a chat.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundColor(AppTheme.cream.opacity(0.4))
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func conversationRow(_ conv: Conversation) -> some View {
        let otherUid = conv.otherParticipant(of: myUid) ?? ""
        let other = profileLoader.rows.first(where: { $0.id == otherUid })
        let title = other?.titleText ?? "Friend"
        let preview = previewText(for: conv)

        return Button {
            openConvId = conv.id
            openOtherUid = otherUid
            openOtherTitle = title
            conversationService.openThread(conv.id)
        } label: {
            HStack(spacing: 12) {
                ConversationAvatar(row: other)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.cream)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let date = conv.lastMessageAt {
                            Text(Self.relativeTime(date))
                                .font(.system(size: 10))
                                .foregroundColor(AppTheme.cream.opacity(0.4))
                        }
                    }
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.cream.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppTheme.cream.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cafeAccent.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func previewText(for conv: Conversation) -> String {
        if conv.lastMessage.isEmpty { return "Say hi 👋" }
        let prefix = conv.lastMessageSenderId == myUid ? "You: " : ""
        return prefix + conv.lastMessage
    }

    private func closeThread() {
        openConvId = nil
        openOtherUid = nil
        openOtherTitle = ""
        conversationService.openThread(nil)
    }

    private static func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Avatar reused by inbox + chat header. Falls back to initials if no
/// `photoURL` or it fails to load.
struct ConversationAvatar: View {
    let row: FriendRow?

    var body: some View {
        ZStack {
            if let urlString = row?.photoURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: initialsBackground
                    }
                }
            } else {
                initialsBackground
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1))
    }

    private var initialsBackground: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(AppTheme.cream)
        }
    }

    private var initials: String {
        let title = row?.titleText ?? "?"
        return title.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}
