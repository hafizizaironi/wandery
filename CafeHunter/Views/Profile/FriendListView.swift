import SwiftUI
import FirebaseFirestore

/// Hydrated friend row used by FriendListView. Pulled from `users/{uid}` once
/// per friend; stale-tolerant since usernames rarely change.
struct FriendRow: Identifiable, Equatable {
    let id: String          // = uid
    var username: String?
    var displayName: String?
    var photoURL: String?

    var titleText: String {
        if let n = displayName, !n.isEmpty { return n }
        if let u = username, !u.isEmpty { return u }
        return "Friend"
    }
    var subtitleText: String? {
        guard let u = username, !u.isEmpty else { return nil }
        return "@\(u)"
    }
}

@MainActor
@Observable
final class FriendListLoader {
    enum LoadStatus { case idle, loading, loaded }

    private(set) var rows: [FriendRow] = []
    private(set) var status: LoadStatus = .idle
    private var cache: [String: FriendRow] = [:]
    private let db = Firestore.firestore()

    /// Hydrate any new uids and prune ones that have been removed. Cheap when
    /// nothing changed (cache hit on every uid).
    func sync(with friendIds: [String]) async {
        status = .loading
        let missing = friendIds.filter { cache[$0] == nil }
        if !missing.isEmpty {
            await withTaskGroup(of: FriendRow?.self) { group in
                for uid in missing {
                    group.addTask { [db] in
                        do {
                            let snap = try await db.collection("users").document(uid).getDocument()
                            let d = snap.data() ?? [:]
                            return FriendRow(
                                id: uid,
                                username: d["username"] as? String,
                                displayName: d["displayName"] as? String,
                                photoURL: d["photoURL"] as? String
                            )
                        } catch {
                            // Missing/unreadable profile — keep a placeholder
                            // so we don't re-fetch on every friend list render.
                            return FriendRow(id: uid, username: nil, displayName: nil, photoURL: nil)
                        }
                    }
                }
                for await row in group {
                    if let row { cache[row.id] = row }
                }
            }
        }
        rows = friendIds.compactMap { cache[$0] }
        status = .loaded
    }

    /// Force-clear the cache and re-hydrate. Used by the Retry button when
    /// the initial sync left rows empty despite having friend ids.
    func retry(with friendIds: [String]) async {
        cache.removeAll()
        await sync(with: friendIds)
    }
}

struct FriendListView: View {
    @ObservedObject var socialService: SocialService
    /// Injected by the host (e.g. ProfileHomeView) so friend profiles can be
    /// pre-fetched before the panel opens — the panel then appears with rows
    /// already populated instead of a loading spinner. Host owns the loader
    /// via @State and is responsible for calling sync() as friend ids change.
    let loader: FriendListLoader
    /// Called when the user taps "Message" on a row. Host wires this to the
    /// conversation flow. Optional so the list view can still render before
    /// chat is plumbed.
    var onMessage: ((FriendRow) -> Void)?
    var onClose: () -> Void

    @State private var pendingRemoval: FriendRow?
    @State private var removingUid: String?

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()
            content
        }
        .alert(
            "Remove \(pendingRemoval?.titleText ?? "friend")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { row in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                Task { await performRemoval(row) }
            }
        } message: { row in
            Text("They'll no longer see your posts and you won't see theirs.")
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            header

            if socialService.friendIds.isEmpty {
                emptyState
            } else if loader.status != .loaded {
                loadingState
            } else if loader.rows.isEmpty {
                // friendIds is non-empty but the hydration produced zero rows.
                // Most likely cause: Firestore rules deny reading the friend's
                // user doc, or the doc was deleted. Surface a Retry so it's
                // recoverable rather than silently blank.
                couldNotLoadState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(loader.rows) { row in
                            friendRowCell(row)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 40)
            ProgressView()
                .tint(AppTheme.cafeAccent)
            Text("Loading friends…")
                .font(.footnote)
                .contrastAware(AppTheme.cream, opacity: 0.5)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var couldNotLoadState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 40)
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .contrastAware(AppTheme.cream, opacity: 0.3)
                .accessibilityHidden(true)
            Text("Couldn't load your friends")
                .font(.subheadline).bold()
                .contrastAware(AppTheme.cream, opacity: 0.7)
            Text("\(socialService.friendIds.count) friend id(s) on your account but their profiles didn't load.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .contrastAware(AppTheme.cream, opacity: 0.4)
                .padding(.horizontal, 32)
            Button {
                Task { await loader.retry(with: socialService.friendIds) }
            } label: {
                Text("Retry")
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(AppTheme.cafeAccent)
                    .clipShape(.rect(cornerRadius: 12))
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack {
            Text("Friends")
                .font(.title3).bold()
                .foregroundStyle(AppTheme.cream)
            Text("\(socialService.friendIds.count)")
                .font(.caption).bold()
                .foregroundStyle(AppTheme.cafeAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppTheme.cafeAccent.opacity(0.15)))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote).bold()
                    .contrastAware(AppTheme.cream, opacity: 0.7)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.cream.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "person.2")
                .font(.largeTitle)
                .contrastAware(AppTheme.cream, opacity: 0.25)
                .accessibilityHidden(true)
            Text("No friends yet")
                .font(.subheadline).bold()
                .contrastAware(AppTheme.cream, opacity: 0.65)
            Text("Add friends from the profile page to see them here.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .contrastAware(AppTheme.cream, opacity: 0.4)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func friendRowCell(_ row: FriendRow) -> some View {
        HStack(spacing: 12) {
            avatar(for: row)
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.titleText)
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)
                    .lineLimit(1)
                if let sub = row.subtitleText {
                    Text(sub)
                        .font(.caption2)
                        .contrastAware(AppTheme.cream, opacity: 0.4)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)

            if let onMessage {
                Button {
                    onMessage(row)
                } label: {
                    Image(systemName: "message.fill")
                        .font(.caption).bold()
                        .foregroundStyle(AppTheme.cafeAccent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(AppTheme.cafeAccent.opacity(0.14)))
                        .overlay {
                            Circle().stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Message \(row.titleText)")
            }

            Button {
                pendingRemoval = row
            } label: {
                Group {
                    if removingUid == row.id {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "person.fill.xmark")
                            .font(.caption).bold()
                            .foregroundStyle(AppTheme.errorRed.opacity(0.85))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(AppTheme.errorRed.opacity(0.10)))
                            .overlay {
                                Circle().stroke(AppTheme.errorRed.opacity(0.3), lineWidth: 1)
                            }
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(removingUid != nil)
            .accessibilityLabel("Remove \(row.titleText)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(AppTheme.cream.opacity(0.05)))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cafeAccent.opacity(0.16), lineWidth: 1)
        }
        // Group the whole row for VoiceOver: one swipe = friend identity,
        // Actions rotor exposes Message / Remove. Inner Buttons remain
        // tappable for sighted users and discoverable via Voice Control's
        // "Show actions" command.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowLabel(for: row))
        .accessibilityActions {
            if onMessage != nil {
                Button("Message") { onMessage?(row) }
            }
            Button("Remove") { pendingRemoval = row }
        }
    }

    private func rowLabel(for row: FriendRow) -> String {
        if let sub = row.subtitleText {
            return "\(row.titleText), \(sub)"
        }
        return row.titleText
    }

    @ViewBuilder
    private func avatar(for row: FriendRow) -> some View {
        if let urlString = row.photoURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: initialsFallback(for: row)
                }
            }
        } else {
            initialsFallback(for: row)
        }
    }

    private func initialsFallback(for row: FriendRow) -> some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials(for: row))
                .font(.footnote).bold()
                .foregroundStyle(AppTheme.cream)
        }
    }

    private func initials(for row: FriendRow) -> String {
        let source = row.displayName?.isEmpty == false
            ? row.displayName!
            : (row.username ?? "?")
        return source.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    private func performRemoval(_ row: FriendRow) async {
        pendingRemoval = nil
        removingUid = row.id
        defer { removingUid = nil }
        do {
            try await socialService.removeFriend(uid: row.id)
        } catch {
            // The friend listener won't update on failure, so the row stays
            // in place — the user can retry. Surfacing a toast here would
            // be nice but isn't critical for v1.
        }
    }
}
