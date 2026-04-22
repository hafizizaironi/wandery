import Foundation
import FirebaseFirestore
import Combine

// MARK: - User stats model

struct UserStats {
    var cafesVisited:        Int = 0
    var stallsVisited:       Int = 0
    var photosShared:        Int = 0
    var placesAdded:         Int = 0
    var friendsHunted:       Int = 0
    var nightCheckIns:       Int = 0
    var favoritePlaceVisits: Int = 0

    /// achievementID → date it was first unlocked (persisted in Firestore)
    var unlockedAchievements: [String: Date] = [:]
}

// MARK: - Service

class UserStatsService: ObservableObject {
    @Published var stats = UserStats()

    private let db       = Firestore.firestore()
    private var listener: ListenerRegistration?

    // MARK: - Subscribe / unsubscribe

    func subscribe(uid: String) {
        listener = db.collection("users").document(uid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self else { return }
                let data = snap?.data() ?? [:]
                Task { @MainActor in
                    var s = UserStats()
                    s.cafesVisited        = data["cafesVisited"]        as? Int ?? 0
                    s.stallsVisited       = data["stallsVisited"]       as? Int ?? 0
                    s.photosShared        = data["photosShared"]        as? Int ?? 0
                    s.placesAdded         = data["placesAdded"]         as? Int ?? 0
                    s.friendsHunted       = data["friendsHunted"]       as? Int ?? 0
                    s.nightCheckIns       = data["nightCheckIns"]       as? Int ?? 0
                    s.favoritePlaceVisits = data["favoritePlaceVisits"]  as? Int ?? 0
                    if let map = data["unlockedAchievements"] as? [String: Timestamp] {
                        s.unlockedAchievements = map.mapValues { $0.dateValue() }
                    }
                    self.stats = s
                    // Auto-persist any newly earned achievements
                    await self.persistNewlyUnlocked(uid: uid, stats: s)
                }
            }
    }

    func unsubscribe() {
        listener?.remove()
        listener = nil
    }

    deinit { unsubscribe() }

    // MARK: - Auto-persist achievement unlocks

    @MainActor
    private func persistNewlyUnlocked(uid: String, stats: UserStats) async {
        var updates: [String: Any] = [:]
        for a in Achievement.definitions {
            guard stats.unlockedAchievements[a.id] == nil,
                  a.condition(stats) else { continue }
            updates["unlockedAchievements.\(a.id)"] = Timestamp(date: Date())
        }
        guard !updates.isEmpty else { return }
        try? await db.collection("users").document(uid).setData(updates, merge: true)
    }

    // MARK: - Increment helpers

    /// Generic increment — field names match Firestore document keys.
    func increment(_ field: String, uid: String) {
        db.collection("users").document(uid)
            .setData([field: FieldValue.increment(Int64(1))], merge: true)
    }

    func recordCafeVisit(uid: String)        { increment("cafesVisited",        uid: uid) }
    func recordStallVisit(uid: String)       { increment("stallsVisited",       uid: uid) }
    func recordPhotoShared(uid: String)      { increment("photosShared",        uid: uid) }
    func recordPlaceAdded(uid: String)       { increment("placesAdded",         uid: uid) }
    func recordFriendHunt(uid: String)       { increment("friendsHunted",       uid: uid) }
    func recordNightCheckIn(uid: String)     { increment("nightCheckIns",       uid: uid) }
    func recordFavoritePlaceVisit(uid: String){ increment("favoritePlaceVisits", uid: uid) }
}
