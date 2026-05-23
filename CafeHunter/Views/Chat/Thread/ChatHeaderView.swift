import SwiftUI

/// Custom in-nav header rendered as a `.toolbar` principal item so we
/// can show avatar + name without the system-rendered title. Tap →
/// future "open friend profile" hook (Phase 2).
struct ChatHeaderView: View {
    let participant: ParticipantHydrator.Participant?
    let otherUid:    String

    private var displayName: String {
        participant?.titleText ?? "—"
    }

    var body: some View {
        HStack(spacing: 8) {
            ParticipantAvatar(participant: participant, uid: otherUid, size: 28)
            Text(displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
    }
}
