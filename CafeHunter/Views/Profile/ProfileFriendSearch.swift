import SwiftUI
import FirebaseFirestore
import FirebaseAuth

// MARK: - Friend search (autocomplete dropdown)

/// One row in the username-autocomplete dropdown under the "Add friend"
/// input. Hydrated from `users/{uid}` after a prefix match on the
/// lowercased `usernames` collection.
struct FriendSearchHit: Identifiable, Equatable {
    let id: String   // = uid
    let username: String?
    let displayName: String?
    let photoURL: String?
}

@MainActor
@Observable
final class FriendSearchModel {
    private(set) var suggestions: [FriendSearchHit] = []
    private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?
    private let db = Firestore.firestore()

    /// Debounce + fan-out search. `usernames/{lowercase}` doc IDs are the
    /// canonical case-insensitive index — a doc-ID prefix range there
    /// gives us matching uids in one query, then we fetch each user's
    /// public profile in parallel. Excludes self + existing friends so
    /// the dropdown only ever shows actionable add-targets.
    func queryChanged(_ text: String, excludeUids: Set<String>) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        searchTask?.cancel()
        guard trimmed.count >= 2 else {
            suggestions = []
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            // Debounce — keystrokes within 220ms collapse to one query so
            // typing a 6-char name doesn't trigger six round-trips.
            try? await Task.sleep(for: .milliseconds(220))
            if Task.isCancelled { return }
            await self?.run(trimmed, excludeUids: excludeUids)
        }
    }

    func clear() {
        searchTask?.cancel()
        suggestions = []
        isSearching = false
    }

    private func run(_ q: String, excludeUids: Set<String>) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let upper = q + "\u{f8ff}"
            let snap = try await db.collection("usernames")
                .whereField(FieldPath.documentID(), isGreaterThanOrEqualTo: q)
                .whereField(FieldPath.documentID(), isLessThan: upper)
                .limit(to: 10)
                .getDocuments()
            if Task.isCancelled { return }
            let uids = snap.documents.compactMap { ($0.data()["uid"] as? String) }
                .filter { !excludeUids.contains($0) }
            let hits = await fetchProfiles(uids: uids)
            if Task.isCancelled { return }
            suggestions = hits.sorted { ($0.username ?? "") < ($1.username ?? "") }
        } catch {
            #if DEBUG
            print("[FriendSearch] query '\(q)' failed: \(error.localizedDescription)")
            #endif
            suggestions = []
        }
    }

    private func fetchProfiles(uids: [String]) async -> [FriendSearchHit] {
        await withTaskGroup(of: FriendSearchHit?.self) { group in
            for uid in uids {
                group.addTask { [db] in
                    guard let doc = try? await db.collection("users").document(uid).getDocument(),
                          let data = doc.data() else { return nil }
                    return FriendSearchHit(
                        id: uid,
                        username: data["username"] as? String,
                        displayName: data["displayName"] as? String,
                        photoURL: data["photoURL"] as? String
                    )
                }
            }
            var arr: [FriendSearchHit] = []
            for await item in group { if let item { arr.append(item) } }
            return arr
        }
    }
}

// MARK: - Friend avatar chip (horizontal strip on profile)

/// One circle in the profile's friend strip. Renders the friend's photo if
/// available, falls back to gradient initials. Username text under the
/// avatar so the user recognises faces *and* handles at a glance.
struct FriendAvatarChip: View {
    let row: FriendRow

    var body: some View {
        VStack(spacing: 6) {
            avatar
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(AppTheme.cafeAccent.opacity(0.35), lineWidth: 2)
                }

            Text(labelText)
                .font(.caption2)
                .foregroundStyle(AppTheme.cream)
                .lineLimit(1)
                .frame(maxWidth: 72)
        }
        .frame(width: 72)
    }

    private var avatar: some View {
        AvatarView(urlString: row.photoURL, name: row.displayName ?? row.username, size: 60)
    }

    private var labelText: String {
        if let u = row.username, !u.isEmpty { return "@\(u)" }
        if let n = row.displayName, !n.isEmpty { return n }
        return "Friend"
    }

}

