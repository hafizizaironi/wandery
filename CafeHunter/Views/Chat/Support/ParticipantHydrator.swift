import FirebaseFirestore
import Foundation
import SwiftUI

/// Looks up display name + avatar for arbitrary uids and memoizes the
/// result for the session. Used by InboxRowView (one row per conversation,
/// each needs the *other* participant's profile) and ChatHeaderView
/// (single uid lookup).
///
/// Without this cache, every inbox render would refetch every participant's
/// profile, the rows would flicker through "—" → name on each frame, and
/// scrolling would hammer Firestore. Mirrors the pattern of
/// `FriendListLoader` but optimised for lazy per-uid lookups instead of
/// batch hydration.
@MainActor
@Observable
final class ParticipantHydrator {
    struct Participant: Equatable {
        let uid: String
        let displayName: String?
        let username: String?
        let photoURL: String?
        /// Base64 X25519 public key for E2EE (nil if the user hasn't published one).
        let publicKey: String?

        var titleText: String {
            if let n = displayName, !n.isEmpty { return n }
            if let u = username, !u.isEmpty { return u }
            return "Friend"
        }

        var initials: String {
            let source = displayName?.isEmpty == false
                ? displayName!
                : (username ?? "?")
            return source.split(separator: " ")
                .prefix(2)
                .compactMap { $0.first.map(String.init) }
                .joined()
                .uppercased()
        }
    }

    private(set) var cache: [String: Participant] = [:]
    private var inFlight: Set<String> = []
    private let db = Firestore.firestore()

    /// Returns the cached row if available; otherwise kicks off a fetch
    /// and returns nil. Caller (the row view) re-renders when the cache
    /// is updated because this class is @Observable.
    func participant(for uid: String) -> Participant? {
        if let hit = cache[uid] { return hit }
        if !inFlight.contains(uid) {
            inFlight.insert(uid)
            Task { await fetch(uid: uid) }
        }
        return nil
    }

    /// Eager pre-fetch — used by InboxView when a row first appears so the
    /// row never renders empty even for a single frame.
    func prefetch(_ uids: [String]) {
        for uid in uids where cache[uid] == nil && !inFlight.contains(uid) {
            inFlight.insert(uid)
            Task { await fetch(uid: uid) }
        }
    }

    private func fetch(uid: String) async {
        defer { inFlight.remove(uid) }
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            let d = snap.data() ?? [:]
            cache[uid] = Participant(
                uid: uid,
                displayName: d["displayName"] as? String,
                username: d["username"] as? String,
                photoURL: d["photoURL"] as? String,
                publicKey: d["publicKey"] as? String
            )
        } catch {
            // Cache a placeholder so we don't retry on every render. The
            // user can still see the (uid-derived) initials fallback.
            cache[uid] = Participant(uid: uid, displayName: nil, username: nil, photoURL: nil, publicKey: nil)
        }
    }

    func reset() {
        cache.removeAll()
        inFlight.removeAll()
    }
}

/// Shared circular avatar used by inbox + thread header. Reuses the
/// terracotta→sage gradient that `FriendListView`'s initials fallback
/// uses so chat surfaces don't feel visually disconnected.
struct ParticipantAvatar: View {
    let participant: ParticipantHydrator.Participant?
    /// `uid` is here so the gradient can be deterministic when participant
    /// data hasn't loaded yet — same initial-less avatar across renders.
    let uid: String
    var size: CGFloat = 44

    var body: some View {
        AvatarView(urlString: participant?.photoURL, initials: initialsText, size: size, stroke: .subtle)
    }

    private var initialsText: String {
        if let init1 = participant?.initials, !init1.isEmpty { return init1 }
        // Fall back to first letter of the uid so empty placeholders
        // aren't all identical-looking circles.
        return String(uid.prefix(1)).uppercased()
    }
}
