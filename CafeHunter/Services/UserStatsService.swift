import Foundation
import FirebaseFirestore
import Combine

// MARK: - User stats model

struct UserStats: Equatable {
    var cafesVisited:        Int = 0
    var stallsVisited:       Int = 0
    var photosShared:        Int = 0
    var friendsHunted:       Int = 0
    var nightCheckIns:       Int = 0

    // Phase 5 — discovery achievement counters. All bumped server-side.
    /// Number of brand-new places this user was the first to create
    /// (drives Pioneer).
    var pioneerCount:         Int = 0
    /// Distinct places the user has tagged at least once
    /// (drives Wanderer).
    var uniquePlacesVisited:  Int = 0
    /// Highest number of distinct places ever tagged in any single
    /// geohash5 cell (≈5 km area). Drives Local Guide.
    var topAreaPlaceCount:    Int = 0
    /// Total reactions other users have left on this user's posts
    /// (drives Tastemaker).
    var reactionsReceived:    Int = 0
    /// Highest per-place visit-session count on this user's record
    /// (drives Loyal — same place 3+ separate trips).
    var topPlaceVisitCount:   Int = 0
    /// Distinct restaurants visited (server already writes this; surfaced here
    /// for the restaurant achievements).
    var restaurantsVisited:   Int = 0

    // Expansion counters — all bumped server-side (see functions/index.js),
    // locked against client writes by `touchesServerOwnedStats()` in firestore.rules.
    /// Posts with a song attached (drives the music ladder).
    var musicPostsCount:      Int = 0
    /// Posts that include a video (drives the video ladder).
    var videoPostsCount:      Int = 0
    /// Posts made before 8 AM device-local (drives Early Bird).
    var earlyBirdCount:       Int = 0
    /// Friends added (drives the social ladder).
    var friendsCount:         Int = 0
    /// Consecutive-day posting streak — current run and personal best.
    var currentStreak:        Int = 0
    var longestStreak:        Int = 0
    /// Device-local day (yyyy-MM-dd) of the last post — lets the UI tell whether
    /// today's post is already in (streak secured) or still needed (at risk).
    var lastPostDay:          String = ""

    /// achievementID → date it was first unlocked (persisted in Firestore)
    var unlockedAchievements: [String: Date] = [:]
}

// MARK: - Service

@Observable
final class UserStatsService {
    var stats = UserStats()
    /// Achievements unlocked DURING this session (not retroactively on first
    /// load) — the UI drains this to play an unlock celebration. Append-only
    /// queue; the presenter removes items as it shows them.
    var justUnlocked: [Achievement] = []

    private let db       = Firestore.firestore()
    private var listener: ListenerRegistration?
    /// True once the first snapshot for this uid has been processed — used to
    /// suppress celebrations for already-met conditions on initial load.
    @ObservationIgnored private var establishedBaseline = false

    // MARK: - Subscribe / unsubscribe

    func subscribe(uid: String) {
        listener = db.collection("users").document(uid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self else { return }
                let data = snap?.data() ?? [:]
                // Skip snapshots that are echoes of our own pending writes.
                // The auto-persist below issues writes that bounce back as
                // listener fires; without this gate, every unlock would
                // re-trigger persistNewlyUnlocked while the server hadn't
                // confirmed yet, which previously combined with a parse
                // bug to produce a per-second write storm.
                let hasPendingWrites = snap?.metadata.hasPendingWrites ?? false
                Task { @MainActor in
                    var s = UserStats()
                    s.cafesVisited        = data["cafesVisited"]        as? Int ?? 0
                    s.stallsVisited       = data["stallsVisited"]       as? Int ?? 0
                    s.photosShared        = data["photosShared"]        as? Int ?? 0
                    s.friendsHunted       = data["friendsHunted"]       as? Int ?? 0
                    s.nightCheckIns       = data["nightCheckIns"]       as? Int ?? 0
                    s.pioneerCount        = data["pioneerCount"]        as? Int ?? 0
                    s.uniquePlacesVisited = data["uniquePlacesVisited"] as? Int ?? 0
                    s.topAreaPlaceCount   = data["topAreaPlaceCount"]   as? Int ?? 0
                    s.reactionsReceived   = data["reactionsReceived"]   as? Int ?? 0
                    s.topPlaceVisitCount  = data["topPlaceVisitCount"]  as? Int ?? 0
                    s.restaurantsVisited  = data["restaurantsVisited"]  as? Int ?? 0
                    s.musicPostsCount     = data["musicPostsCount"]     as? Int ?? 0
                    s.videoPostsCount     = data["videoPostsCount"]     as? Int ?? 0
                    s.earlyBirdCount      = data["earlyBirdCount"]      as? Int ?? 0
                    s.friendsCount        = data["friendsCount"]        as? Int ?? 0
                    s.currentStreak       = data["currentStreak"]       as? Int ?? 0
                    s.longestStreak       = data["longestStreak"]       as? Int ?? 0
                    s.lastPostDay         = data["lastPostDay"]         as? String ?? ""
                    // Defensive value-by-value parse. The previous strict
                    // `as? [String: Timestamp]` cast failed *entirely* if a
                    // single nested value wasn't exactly a Timestamp (e.g. an
                    // old test write that stamped a Date or null), wiping
                    // the parsed unlock set to `[:]`. That tricked
                    // `persistNewlyUnlocked` into re-writing every met
                    // condition every snapshot — a Firestore write storm.
                    if let raw = data["unlockedAchievements"] as? [String: Any] {
                        s.unlockedAchievements = raw.reduce(into: [:]) { acc, kv in
                            if let ts = kv.value as? Timestamp {
                                acc[kv.key] = ts.dateValue()
                            }
                        }
                    }
                    let previous = self.stats
                    self.stats = s
                    // First snapshot establishes the baseline — already-met
                    // conditions get their timestamp written but DON'T fire a
                    // celebration (otherwise an existing user floods on launch).
                    let isBaseline = !self.establishedBaseline
                    self.establishedBaseline = true
                    // Three guards on the auto-persist write:
                    //  1. Don't react to our own pending-write echoes.
                    //  2. Don't run if nothing observable changed (e.g. a
                    //     no-op metadata refresh).
                    //  3. (inside persistNewlyUnlocked) only write when
                    //     there's a genuinely new unlock.
                    guard !hasPendingWrites, s != previous else { return }
                    await self.persistNewlyUnlocked(uid: uid, stats: s, celebrate: !isBaseline)
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
    private func persistNewlyUnlocked(uid: String, stats: UserStats, celebrate: Bool) async {
        var updates: [String: Any] = [:]
        var newly: [Achievement] = []
        for a in Achievement.definitions {
            guard stats.unlockedAchievements[a.id] == nil,
                  a.condition(stats) else { continue }
            updates["unlockedAchievements.\(a.id)"] = Timestamp(date: Date())
            newly.append(a)
        }
        guard !updates.isEmpty else { return }
        if celebrate { justUnlocked.append(contentsOf: newly) }
        try? await db.collection("users").document(uid).setData(updates, merge: true)
    }

    // NOTE: the former `increment` / `record*` helpers were removed — they were
    // dead code (no callers) and these counters are written exclusively
    // server-side by Cloud Function triggers (onPostCreatePlaceVisit etc.) and
    // are now locked against client writes in firestore.rules. See
    // SECURITY_REVIEW.md (H2). The subscribe listener above remains the only
    // reader; persistNewlyUnlocked still writes `unlockedAchievements` (allowed).
}
