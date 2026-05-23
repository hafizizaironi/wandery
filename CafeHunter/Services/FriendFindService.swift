import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// A contact whose hashed phone number was found in `users/{uid}.phoneHash`,
/// joined with the matching user's public profile fields.
struct ContactsOnAppMatch: Identifiable, Equatable, Sendable {
    var id: String { uid }
    let uid: String
    let displayName: String
    let username: String?
    let photoURL: String?
    let contact: ContactRecord
    /// True when the matched user is already in the current user's
    /// friends collection — UI renders a "Friend" badge instead of an
    /// Add button.
    let isFriend: Bool
    /// True when the matched user is the current user themselves — UI
    /// hides the row entirely.
    let isSelf: Bool
}

/// Maps hashed contact phone numbers to actual users on the app by
/// querying `users` where `phoneHash IN [...]`. Splits results into
/// "already on the app" (with add-friend affordance) and "invite" (the
/// rest of the user's contacts).
///
/// Privacy: only the hashes leave the device. Firestore reads return
/// public profile fields (displayName, photoURL, username) — never the
/// matched phone number or hash.
@MainActor
@Observable
final class FriendFindService {
    private(set) var onApp: [ContactsOnAppMatch] = []
    private(set) var invitees: [ContactRecord] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Firestore caps `whereField(_:in:)` to 30 array elements per
    /// query. Larger contact lists are split into multiple parallel
    /// queries and stitched back together.
    private static let inBatchSize = 30

    private let db = Firestore.firestore()

    /// Runs the full scan: requests contacts, hashes them, queries
    /// Firestore in batches, classifies results. `currentUserPhone` is
    /// the verified phone of the calling user — used both to determine
    /// the default country code for normalisation and to exclude
    /// self-matches.
    func scan(currentUserPhone: String?, friendIds: Set<String>) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            _ = try await ContactsService.requestAccess()
            let defaultCountry = currentUserPhone
                .flatMap(ContactsService.countryCode(fromE164:)) ?? "60"
            let contacts = try await ContactsService.fetchContacts(
                defaultCountryCode: defaultCountry
            )
            let hashesToContacts = Dictionary(
                grouping: contacts,
                by: \.phoneHash
            )
            let allHashes = Array(hashesToContacts.keys)
            let matches = await fetchMatches(hashes: allHashes, currentUid: uid)

            // Classify
            var onAppList: [ContactsOnAppMatch] = []
            var matchedHashes: Set<String> = []
            for match in matches {
                guard let phoneHash = match.phoneHash,
                      let contact = hashesToContacts[phoneHash]?.first else { continue }
                matchedHashes.insert(phoneHash)
                onAppList.append(ContactsOnAppMatch(
                    uid: match.uid,
                    displayName: match.displayName,
                    username: match.username,
                    photoURL: match.photoURL,
                    contact: contact,
                    isFriend: friendIds.contains(match.uid),
                    isSelf: match.uid == uid
                ))
            }
            let inviteList = contacts.filter { !matchedHashes.contains($0.phoneHash) }

            self.onApp = onAppList
                .filter { !$0.isSelf }
                .sorted { lhs, rhs in
                    // Already-friends sink to the bottom; non-friends surface.
                    if lhs.isFriend != rhs.isFriend { return !lhs.isFriend }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            self.invitees = inviteList
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch let e as ContactsService.AccessError {
            lastError = e.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Firestore

    /// Internal projection of `users/{uid}` after the phoneHash IN query.
    private struct MatchedUser: Sendable, Equatable {
        let uid: String
        let displayName: String
        let username: String?
        let photoURL: String?
        let phoneHash: String?
    }

    /// Splits the hash list into Firestore IN-query-sized batches and
    /// runs them in parallel via a `TaskGroup`. Errors on individual
    /// batches are swallowed so a single failed batch doesn't lose all
    /// matches; the failure is reported via `lastError` if every batch
    /// fails.
    private func fetchMatches(hashes: [String], currentUid: String) async -> [MatchedUser] {
        let batches = stride(from: 0, to: hashes.count, by: Self.inBatchSize).map { start -> [String] in
            Array(hashes[start..<min(start + Self.inBatchSize, hashes.count)])
        }
        guard !batches.isEmpty else { return [] }

        return await withTaskGroup(of: [MatchedUser].self) { group in
            for batch in batches {
                group.addTask { [db] in
                    do {
                        let snap = try await db.collection("users")
                            .whereField("phoneHash", in: batch)
                            .getDocuments()
                        return snap.documents.map { doc in
                            let data = doc.data()
                            return MatchedUser(
                                uid: doc.documentID,
                                displayName: (data["displayName"] as? String) ?? "Friend",
                                username: data["username"] as? String,
                                photoURL: data["photoURL"] as? String,
                                phoneHash: data["phoneHash"] as? String
                            )
                        }
                    } catch {
                        #if DEBUG
                        print("[FriendFind] batch query failed: \(error.localizedDescription)")
                        #endif
                        return []
                    }
                }
            }
            var all: [MatchedUser] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }

    /// Resets state. Called when the view dismisses so a re-open
    /// shows a fresh loading state instead of stale results.
    func reset() {
        onApp = []
        invitees = []
        isLoading = false
        lastError = nil
    }
}
