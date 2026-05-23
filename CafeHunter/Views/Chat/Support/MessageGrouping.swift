import Foundation

/// Pure transformation: `[ChatMessage]` → `[ChatRow]` ready for the LazyVStack.
/// No SwiftUI here, no @State — easy to reason about, easy to unit-test.
///
/// Rendering rules (iMessage/WhatsApp-style):
///   1. A day-separator row precedes the first message of each calendar day.
///   2. Consecutive same-sender messages within 2 minutes form a "group":
///      they share tight 2pt spacing and only the *last* in the group shows
///      a tail. Across senders or after a ≥2-minute gap, spacing opens up
///      to 10pt and every message gets a tail.
enum ChatRow: Identifiable, Equatable {
    case daySeparator(id: String, label: String)
    case message(ChatMessage, position: BubblePosition)

    var id: String {
        switch self {
        case .daySeparator(let id, _): return "sep_\(id)"
        case .message(let m, _):       return m.id
        }
    }
}

/// Where a bubble sits inside a sender-group. Drives spacing + tail.
enum BubblePosition: Equatable {
    /// First in a group (top corners rounded, no tail).
    case top
    /// Middle of a group (tighter corners on the sender's side).
    case middle
    /// Last in a group (gets the tail).
    case bottom
    /// Standalone — neighbours are too far away or from another sender.
    case single

    var showsTail: Bool {
        self == .bottom || self == .single
    }

    /// Tight 2pt between group members; open 10pt at group boundaries.
    /// Used for the *trailing* spacing of this bubble.
    var trailingSpacing: CGFloat {
        switch self {
        case .top, .middle: return 2
        case .bottom, .single: return 10
        }
    }
}

enum MessageGrouping {
    /// Anything tighter than this and we treat the two messages as one
    /// "thought" from the sender — iMessage's grouping rule.
    static let groupGapSeconds: TimeInterval = 120

    static func rows(
        from messages: [ChatMessage],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [ChatRow] {
        guard !messages.isEmpty else { return [] }

        // Messages arrive ordered ascending by createdAt from the listener.
        var out: [ChatRow] = []
        var previous: ChatMessage?

        // First pass: emit day separators + raw .message rows with .single
        // positions. Second pass adjusts positions based on neighbours so
        // we can use both lookbehind (prev sender / prev createdAt) and
        // lookahead (next sender / next createdAt) cleanly.
        for msg in messages {
            if previous == nil || !calendar.isDate(previous!.createdAt, inSameDayAs: msg.createdAt) {
                let label = daySeparatorLabel(for: msg.createdAt, now: now, calendar: calendar)
                out.append(.daySeparator(id: msg.id, label: label))
            }
            out.append(.message(msg, position: .single))
            previous = msg
        }

        // Second pass: resolve positions.
        for i in out.indices {
            guard case .message(let msg, _) = out[i] else { continue }

            let prevMsg: ChatMessage? = lookback(out, before: i)
            let nextMsg: ChatMessage? = lookahead(out, after: i)

            let groupsWithPrev = groups(prevMsg, msg)
            let groupsWithNext = groups(msg, nextMsg)

            let position: BubblePosition
            switch (groupsWithPrev, groupsWithNext) {
            case (false, false): position = .single
            case (false, true):  position = .top
            case (true,  true):  position = .middle
            case (true,  false): position = .bottom
            }
            out[i] = .message(msg, position: position)
        }

        return out
    }

    /// Two messages "group" when same sender AND within `groupGapSeconds`.
    /// Day-separator presence breaks grouping implicitly — if a separator
    /// row sits between them, `lookback`/`lookahead` skips past it but the
    /// time gap also forces a break.
    private static func groups(_ a: ChatMessage?, _ b: ChatMessage?) -> Bool {
        guard let a, let b else { return false }
        guard a.senderId == b.senderId else { return false }
        return abs(b.createdAt.timeIntervalSince(a.createdAt)) <= groupGapSeconds
    }

    private static func lookback(_ rows: [ChatRow], before index: Int) -> ChatMessage? {
        var i = index - 1
        while i >= 0 {
            if case .message(let m, _) = rows[i] { return m }
            i -= 1
        }
        return nil
    }

    private static func lookahead(_ rows: [ChatRow], after index: Int) -> ChatMessage? {
        var i = index + 1
        while i < rows.count {
            if case .message(let m, _) = rows[i] { return m }
            i += 1
        }
        return nil
    }

    static func daySeparatorLabel(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = sameYear ? "EEE, MMM d" : "MMM d, yyyy"
        return df.string(from: date)
    }
}
