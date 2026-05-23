import SwiftUI

/// Tiny chip strip rendered just below a chat bubble when one or more
/// participants have reacted to it. iMessage-style: my reaction gets a
/// terracotta-tinted background, theirs is neutral. Tapping my own
/// reaction removes it; tapping someone else's is a no-op (you'd react
/// from the long-press tray, not by tapping their chip).
struct MessageReactionStrip: View {
    let reactions: [String: String]   // uid → emoji
    let myUid:     String
    var onRemoveMine: () -> Void

    private var entries: [(uid: String, emoji: String)] {
        // Render my reaction first so it sits closest to the bubble.
        // Sorted-by-uid afterwards for stability across re-renders.
        let mine = reactions[myUid].map { (uid: myUid, emoji: $0) }
        let others = reactions
            .filter { $0.key != myUid }
            .sorted(by: { $0.key < $1.key })
            .map { (uid: $0.key, emoji: $0.value) }
        return (mine.map { [$0] } ?? []) + others
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(entries, id: \.uid) { entry in
                chip(emoji: entry.emoji, isMine: entry.uid == myUid)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func chip(emoji: String, isMine: Bool) -> some View {
        let content = Text(emoji)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isMine
                               ? AppTheme.accentAction.opacity(0.20)
                               : AppTheme.surfacePrimary)
            )
            .overlay {
                Capsule().stroke(
                    isMine ? AppTheme.accentAction.opacity(0.45) : AppTheme.borderSubtle,
                    lineWidth: 0.75
                )
            }

        if isMine {
            Button(action: onRemoveMine) { content }
                .buttonStyle(.scalePress)
                .accessibilityLabel("Remove \(emoji) reaction")
        } else {
            content
        }
    }

    private var accessibilityLabel: String {
        let mine = reactions[myUid]
        let others = reactions.filter { $0.key != myUid }.values.joined(separator: ", ")
        switch (mine, others.isEmpty) {
        case (.some(let m), true):  return "You reacted \(m)"
        case (.some(let m), false): return "You reacted \(m); they reacted \(others)"
        case (.none, false):        return "They reacted \(others)"
        case (.none, true):         return ""
        }
    }
}
