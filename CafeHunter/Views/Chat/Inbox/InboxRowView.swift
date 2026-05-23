import SwiftUI

/// One conversation row in the inbox. 44pt avatar + title + preview +
/// relative time + unread dot.
///
/// Unread state is local-only (per-device) in v1 — see
/// `InboxRowView.isUnread(...)`. Promoting to a server-side
/// `lastReadAt[uid]` map needs a rule change, deferred to Phase 2.
struct InboxRowView: View {
    let conversation: Conversation
    let myUid:        String
    let participant:  ParticipantHydrator.Participant?

    @AppStorage private var lastReadAt: Double

    init(conversation: Conversation, myUid: String, participant: ParticipantHydrator.Participant?) {
        self.conversation = conversation
        self.myUid = myUid
        self.participant = participant
        // Per-conversation @AppStorage key. Stored as a TimeIntervalSince1970
        // so we can compare directly against `lastMessageAt`.
        _lastReadAt = AppStorage(wrappedValue: 0, "chat.lastRead.\(conversation.id)")
    }

    private var otherUid: String {
        conversation.otherParticipant(of: myUid) ?? ""
    }

    private var isUnread: Bool {
        guard let last = conversation.lastMessageAt else { return false }
        // Don't show unread for messages *I* sent.
        guard conversation.lastMessageSenderId != myUid else { return false }
        // Server-side stamp wins; fall back to local @AppStorage for
        // legacy convs whose `lastReadAt` map hasn't been written yet
        // (only happens once — first thread-open writes the server
        // entry going forward).
        let serverStamp = conversation.lastReadAt[myUid]?.timeIntervalSince1970 ?? 0
        let effective = max(serverStamp, lastReadAt)
        return last.timeIntervalSince1970 > effective
    }

    private var titleText: String {
        participant?.titleText ?? "—"
    }

    private var previewText: String {
        let preview = conversation.lastMessage
        if conversation.lastMessageSenderId == myUid {
            return preview.isEmpty ? "Start a conversation" : "You: \(preview)"
        }
        return preview.isEmpty ? "Say hi" : preview
    }

    var body: some View {
        HStack(spacing: 12) {
            ParticipantAvatar(participant: participant, uid: otherUid, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(titleText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    relativeTime
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .monospacedDigit()
                }

                HStack(spacing: 6) {
                    Text(previewText)
                        .font(.footnote)
                        .foregroundStyle(isUnread ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isUnread {
                        Circle()
                            .fill(AppTheme.accentAction)
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.surfacePrimary.opacity(0.6))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var relativeTime: some View {
        if let date = conversation.lastMessageAt {
            // Auto-refreshing once per minute so "2m ago" turns into
            // "3m ago" without a manual ContentView re-render.
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                    .id(ctx.date.timeIntervalSince1970)
            }
        } else {
            Text("")
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [titleText, previewText]
        if let last = conversation.lastMessageAt {
            parts.append(last.formatted(.relative(presentation: .named)))
        }
        if isUnread { parts.append("Unread") }
        return parts.joined(separator: ", ")
    }
}
