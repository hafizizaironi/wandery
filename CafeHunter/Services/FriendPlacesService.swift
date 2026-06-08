import Foundation
import FirebaseFirestore
import CoreLocation
import MapKit
import WidgetKit

/// Aggregated representation of one tagged place + all the friend posts at it.
/// Drives both the map annotation layer and the place-detail card stack.
struct FriendPlace: Identifiable, Equatable {
    let id: String   // = places/{id}
    var name: String
    var type: PlaceType
    var lat: Double
    var lng: Double
    /// Posts at this place, most recent first.
    var posts: [FriendPost]
    /// Real visit count from the place doc — bumped server-side once per
    /// "session" (multiple posts in one sitting count as one visit). Use
    /// this for any "X visits" UI label, NOT `posts.count`.
    var globalVisitCount: Int = 0
    /// Per-user visit count derived from `users/{uid}/visits/{placeId}`:
    /// closed sessions + 1 if there's a still-open one. Same session
    /// semantics as `globalVisitCount` but scoped to the current user.
    /// Zero until the visits listener catches up.
    var myVisitCount: Int = 0
    /// Total engagement (reactions + replies) on tagged posts at this place.
    var globalEngagementCount: Int = 0
    /// Formatted address snapshot (newer places store this at creation); nil
    /// for older places, which get a reverse-geocoded `cityName` instead.
    var address: String? = nil
    /// City/locality for the My Hunt legend, counts, and place rows. Derived
    /// from `address` when present, otherwise reverse-geocoded from lat/lng
    /// and filled in progressively (see `resolveMissingCities`).
    var cityName: String? = nil
    /// `true` when `posts` were fetched via the public discoverable-fallback
    /// path (trending tap on a place the user has no friend posts at).
    /// Drives per-card blur in `PlaceDetailSheet` — non-discoverable posts
    /// in this stack are rendered blurred. Friend-feed posts never set
    /// this flag, so a friend's legacy `discoverable=false` post stays clear.
    var postsAreFallback: Bool = false
    /// Google Places `place_id` for places imported from Google, when stored.
    /// Lets navigation route to the exact POI by id instead of a coordinate.
    /// Nil for app-created places (and synthesized ones) → navigation resolves
    /// a match by name+coordinate, or falls back to the coordinate.
    var googlePlaceId: String? = nil

    var mostRecent: FriendPost? { posts.first }
}

/// Sendable snapshot of the raw fields parsed from a `places/{id}` Firestore
/// doc. Used to ferry data out of a nonisolated task group back to the
/// MainActor consumer, which then constructs the MainActor-isolated `Place`.
private struct FetchedPlaceFields: Sendable {
    let name: String
    let type: PlaceType
    let lat: Double
    let lng: Double
    let geohash: String
    let source: String
    let googlePlaceId: String?
    let address: String?
    let globalVisitCount: Int
    let globalEngagementCount: Int
    let lastVisitedAt: Date?
    let createdAt: Date?
}

/// Derives `[FriendPlace]` from a stream of feed posts.
/// Caches place docs so we don't re-fetch on every feed snapshot. Hydration
/// errors silently skip the place (the post still exists in the feed).
@MainActor
@Observable
final class FriendPlacesService {
    private(set) var places: [FriendPlace] = []
    private var placeCache: [String: Place] = [:]
    private var inflight: Set<String> = []
    /// Tracks the most recent post id we've seen per place — used to decide
    /// whether to refetch the place doc to pick up updated counters
    /// (`globalVisitCount`, `globalEngagementCount`) without re-fetching
    /// every place on every call.
    private var lastSeenPostByPlace: [String: String] = [:]
    /// Reverse-geocoded city per place id, so we geocode each place at most
    /// once per session. Places whose doc carries an `address` skip this.
    private var cityCache: [String: String] = [:]
    private var cityResolveTask: Task<Void, Never>?
    /// `placeId → my visit count`. Populated by the live visits listener
    /// (`subscribeToMyVisits`) reading `users/{uid}/visits`. Formula:
    /// `visitCount + (closed ? 0 : 1)` — closed sessions plus one for any
    /// currently-open session. Survives refreshes so a re-emit doesn't
    /// flash back to zero.
    private var myVisitsByPlace: [String: Int] = [:]
    private var myVisitsListener: ListenerRegistration?
    private var myVisitsListenerUid: String?

    /// Place ids the user swiped RIGHT on (saved) — backs the "Saved" filter
    /// tab. Place ids swiped LEFT on ("less likely") — filtered out of the
    /// card deck only, never the list/map. Both are live-synced from
    /// `users/{uid}/savedPlaces` + `users/{uid}/hiddenPlaces`. Mutated
    /// optimistically by the swipe handlers; the listeners reconcile.
    private(set) var savedPlaceIds: Set<String> = []
    private(set) var hiddenPlaceIds: Set<String> = []
    private var savedListener: ListenerRegistration?
    private var hiddenListener: ListenerRegistration?
    private var prefsListenerUid: String?

    private let db = Firestore.firestore()

    /// Recompute `places` from the latest feed snapshot. Fetches uncached
    /// place docs and re-fetches places that have a new "most-recent" post
    /// since last call (so counters refresh after activity). Cheap when
    /// nothing's changed.
    func refresh(from posts: [FriendPost]) async {
        // A post can carry several photos tagged at different places; surface
        // it under EACH distinct tagged place (not just the primary), so every
        // café a post touches shows it. Legacy single-place posts contribute
        // exactly one entry via `distinctPlaceIds`.
        var byPlace: [String: [FriendPost]] = [:]
        for post in posts {
            for placeId in post.distinctPlaceIds {
                byPlace[placeId, default: []].append(post)
            }
        }

        // Refetch criteria:
        //   1. Place is uncached (first time we've seen it), OR
        //   2. The most-recent post at the place changed since last run
        //      (i.e. a new tag landed → visit/engagement counters might
        //       have moved on the server).
        let toFetch = byPlace.compactMap { placeId, postsAtPlace -> String? in
            if inflight.contains(placeId) { return nil }
            let mostRecentId = postsAtPlace
                .max(by: { $0.createdAt < $1.createdAt })?.id
            let needsFresh = placeCache[placeId] == nil ||
                lastSeenPostByPlace[placeId] != mostRecentId
            return needsFresh ? placeId : nil
        }
        #if DEBUG
        print("[FriendPlaces] refresh — feedPosts=\(posts.count) byPlace=\(byPlace.count) toFetch=\(toFetch.count) cached=\(placeCache.count)")
        #endif
        if !toFetch.isEmpty {
            for id in toFetch { inflight.insert(id) }
            // Identify which fetches need fresh server data vs which can come
            // from the local Firestore cache. A first-time-this-session load
            // (placeCache miss) is happy with cached counters. A refetch
            // driven by a newly-landed post wants the server's authoritative
            // visit/engagement counts, which are bumped server-side by the
            // post-create Cloud Function.
            let firstTimeIds: Set<String> = Set(toFetch.filter { placeCache[$0] == nil })
            await withTaskGroup(of: (String, FetchedPlaceFields?, Error?).self) { group in
                for id in toFetch {
                    let preferCache = firstTimeIds.contains(id)
                    group.addTask { [db] in
                        do {
                            let snap: DocumentSnapshot
                            if preferCache {
                                // Cache hit = zero billed reads. On miss the
                                // SDK throws; we fall back to server.
                                do {
                                    snap = try await db.collection("places")
                                        .document(id)
                                        .getDocument(source: .cache)
                                } catch {
                                    snap = try await db.collection("places")
                                        .document(id)
                                        .getDocument(source: .server)
                                }
                            } else {
                                snap = try await db.collection("places")
                                    .document(id)
                                    .getDocument(source: .server)
                            }
                            // Manual dict decode rather than Codable — the
                            // FirestoreDecoder fails opaquely when a field's
                            // type drifts (e.g. a new field was added but
                            // an older doc has it missing in some odd shape).
                            // Dict access reads what's there and falls
                            // through to defaults for anything missing.
                            guard let data = snap.data(),
                                  let name = data["name"] as? String,
                                  let lat = data["lat"] as? Double,
                                  let lng = data["lng"] as? Double else {
                                return (id, nil, NSError(
                                    domain: "FriendPlaces",
                                    code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "missing required fields"]
                                ))
                            }
                            let typeStr = (data["type"] as? String) ?? "restaurant"
                            let fields = FetchedPlaceFields(
                                name: name,
                                type: PlaceType(rawValue: typeStr) ?? .restaurant,
                                lat: lat,
                                lng: lng,
                                geohash: (data["geohash"] as? String) ?? "",
                                source: (data["source"] as? String) ?? "google",
                                googlePlaceId: data["googlePlaceId"] as? String,
                                address: data["address"] as? String,
                                globalVisitCount: (data["globalVisitCount"] as? Int) ?? 0,
                                globalEngagementCount: (data["globalEngagementCount"] as? Int) ?? 0,
                                lastVisitedAt: (data["lastVisitedAt"] as? Timestamp)?.dateValue(),
                                createdAt: (data["createdAt"] as? Timestamp)?.dateValue()
                            )
                            return (id, fields, nil)
                        } catch {
                            return (id, nil, error)
                        }
                    }
                }
                // `Place()` and its `@DocumentID`-wrapped `id` setter are
                // MainActor-isolated, so the struct is constructed here in
                // the consumer loop rather than inside the nonisolated task.
                for await (id, fields, err) in group {
                    inflight.remove(id)
                    if let fields {
                        var place = Place()
                        place.id = id
                        place.name = fields.name
                        place.type = fields.type
                        place.lat = fields.lat
                        place.lng = fields.lng
                        place.geohash = fields.geohash
                        place.source = fields.source
                        place.googlePlaceId = fields.googlePlaceId
                        place.address = fields.address
                        place.globalVisitCount = fields.globalVisitCount
                        place.globalEngagementCount = fields.globalEngagementCount
                        place.lastVisitedAt = fields.lastVisitedAt
                        place.createdAt = fields.createdAt
                        placeCache[id] = place
                    } else {
                        #if DEBUG
                        print("[FriendPlaces] FAILED to load place \(id): \(err?.localizedDescription ?? "nil")")
                        #endif
                    }
                }
            }
        }
        // Refresh the "last seen" pointer for each place so subsequent
        // calls only re-fetch when a new post lands.
        for (placeId, postsAtPlace) in byPlace {
            lastSeenPostByPlace[placeId] = postsAtPlace
                .max(by: { $0.createdAt < $1.createdAt })?.id
        }

        let assembled: [FriendPlace] = byPlace.compactMap { placeId, postsAtPlace in
            guard let p = placeCache[placeId] else {
                #if DEBUG
                print("[FriendPlaces] dropping \(placeId) — not in cache after fetch")
                #endif
                return nil
            }
            let sorted = postsAtPlace.sorted { $0.createdAt > $1.createdAt }
            // City: parse the stored address when present (no network),
            // else use a previously reverse-geocoded result if we have one.
            let city = p.address.flatMap { Self.city(fromAddress: $0) } ?? cityCache[placeId]
            return FriendPlace(
                id: placeId,
                name: p.name,
                type: p.type,
                lat: p.lat,
                lng: p.lng,
                posts: sorted,
                globalVisitCount: p.globalVisitCount,
                myVisitCount: myVisitsByPlace[placeId] ?? 0,
                globalEngagementCount: p.globalEngagementCount,
                address: p.address,
                cityName: city,
                googlePlaceId: p.googlePlaceId
            )
        }
        #if DEBUG
        print("[FriendPlaces] assembled=\(assembled.count) of byPlace=\(byPlace.count)")
        #endif

        // Most-recently-active place first — useful when many pins overlap.
        // (The map's visited-places LIST re-sorts by visit count in the view;
        // keeping recency here preserves My Hunt / map-pin ordering.)
        places = assembled.sorted {
            ($0.mostRecent?.createdAt ?? .distantPast) > ($1.mostRecent?.createdAt ?? .distantPast)
        }

        // Fill in any still-missing city labels by reverse-geocoding lat/lng.
        resolveMissingCities()

        // Hand nearby places (coords + category) to the Nearby Map widget.
        mirrorNearbyPlacesToWidget()
    }

    // MARK: - Nearby Map widget mirror

    private var lastNearbyMirror: Date?
    /// Cache of place name+coords for saved-only places (not in `places`), so
    /// the saved-place doc reads happen at most once per place per session.
    private var savedPlaceCoords: [String: (name: String, lat: Double, lng: Double)] = [:]

    /// Mirror a candidate set of nearby places (recent friend-tagged + saved
    /// hunt) to the App Group for the Nearby Map widget. Debounced — the widget
    /// then filters by the user's live location + radius.
    func mirrorNearbyPlacesToWidget() {
        let now = Date()
        if let last = lastNearbyMirror, now.timeIntervalSince(last) < 20 { return }
        lastNearbyMirror = now
        Task { await buildAndMirrorNearby() }
    }

    private func buildAndMirrorNearby() async {
        var out: [SharedFeedStore.WidgetPlace] = []
        var seen = Set<String>()

        // Recent — friend-tagged places (carry the tagging friend for the halo).
        for p in places {
            out.append(.init(id: p.id, name: p.name, lat: p.lat, lng: p.lng,
                             category: "recent",
                             friendName: p.mostRecent?.authorUsername,
                             friendId: p.mostRecent?.authorId, trendCount: nil))
            seen.insert(p.id)
            savedPlaceCoords[p.id] = (p.name, p.lat, p.lng)
        }

        // Hunt — saved places not already shown as recent. Resolve coords from
        // the cache, else read the place docs once (batched).
        let savedOnly = savedPlaceIds.subtracting(seen)
        let needFetch = savedOnly.filter { savedPlaceCoords[$0] == nil }
        if !needFetch.isEmpty {
            let ids = Array(needFetch)
            for start in stride(from: 0, to: ids.count, by: 30) {
                let chunk = Array(ids[start..<min(start + 30, ids.count)])
                guard let snap = try? await db.collection("places")
                    .whereField(FieldPath.documentID(), in: chunk).getDocuments() else { continue }
                for doc in snap.documents {
                    let d = doc.data()
                    if let name = d["name"] as? String,
                       let lat = d["lat"] as? Double, let lng = d["lng"] as? Double {
                        savedPlaceCoords[doc.documentID] = (name, lat, lng)
                    }
                }
            }
        }
        for id in savedOnly {
            guard let c = savedPlaceCoords[id] else { continue }
            out.append(.init(id: id, name: c.name, lat: c.lat, lng: c.lng,
                             category: "hunt", friendName: nil, friendId: nil, trendCount: nil))
        }

        SharedFeedStore.writeNearbyPlaces(out)
        WidgetCenter.shared.reloadTimelines(ofKind: "WanderyNearbyMap")
    }

    // MARK: - My visits

    /// Subscribe to the user's `users/{uid}/visits` collection so each
    /// `FriendPlace.myVisitCount` reflects the same session-deduped semantics
    /// as `globalVisitCount`, scoped to this user. Re-applies values to any
    /// places already loaded so the UI updates without waiting for a refresh.
    ///
    /// Safe to call repeatedly; switching uid swaps the listener.
    func subscribeToMyVisits(uid: String) {
        guard !uid.isEmpty else { return }
        if myVisitsListenerUid == uid, myVisitsListener != nil { return }
        myVisitsListener?.remove()
        myVisitsListenerUid = uid
        myVisitsListener = db.collection("users").document(uid)
            .collection("visits")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let docs = snap?.documents else { return }
                Task { @MainActor in
                    var next: [String: Int] = [:]
                    for doc in docs {
                        let d = doc.data()
                        let closed = (d["closed"] as? Bool) ?? false
                        let closedCount = (d["visitCount"] as? Int) ?? 0
                        // Cloud function bumps `visitCount` only when a session
                        // closes; add 1 while one is still open so the displayed
                        // count includes the visit currently in progress.
                        let total = closedCount + (closed ? 0 : 1)
                        if total > 0 { next[doc.documentID] = total }
                    }
                    self.myVisitsByPlace = next
                    self.applyMyVisitsToPlaces()
                }
            }
    }

    func unsubscribeMyVisits() {
        myVisitsListener?.remove()
        myVisitsListener = nil
        myVisitsListenerUid = nil
        myVisitsByPlace.removeAll()
        applyMyVisitsToPlaces()
    }

    /// Patch `myVisitCount` into the already-assembled `places` so the UI
    /// reflects a freshly-arrived visits snapshot without waiting for the
    /// next `refresh(from:)` call.
    private func applyMyVisitsToPlaces() {
        guard !places.isEmpty else { return }
        for i in places.indices {
            let count = myVisitsByPlace[places[i].id] ?? 0
            if places[i].myVisitCount != count {
                places[i].myVisitCount = count
            }
        }
    }

    // MARK: - Swipe-deck preferences (saved / hidden)

    /// Live-sync the user's saved + "less likely" place ids from
    /// `users/{uid}/savedPlaces` and `users/{uid}/hiddenPlaces`. Mirrors
    /// `subscribeToMyVisits`. Safe to call repeatedly; switching uid swaps the
    /// listeners. NOTE: must be wired on the SAME service instance the map +
    /// card stack read from (MainMapView owns its own instance).
    func subscribeToPlacePrefs(uid: String) {
        guard !uid.isEmpty else { return }
        if prefsListenerUid == uid, savedListener != nil { return }
        savedListener?.remove()
        hiddenListener?.remove()
        prefsListenerUid = uid

        savedListener = db.collection("users").document(uid)
            .collection("savedPlaces")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let docs = snap?.documents else { return }
                Task { @MainActor in
                    self.savedPlaceIds = Set(docs.map(\.documentID))
                    self.mirrorNearbyPlacesToWidget()
                }
            }

        hiddenListener = db.collection("users").document(uid)
            .collection("hiddenPlaces")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let docs = snap?.documents else { return }
                Task { @MainActor in self.hiddenPlaceIds = Set(docs.map(\.documentID)) }
            }
    }

    func unsubscribePlacePrefs() {
        savedListener?.remove();  savedListener = nil
        hiddenListener?.remove(); hiddenListener = nil
        prefsListenerUid = nil
        savedPlaceIds.removeAll()
        hiddenPlaceIds.removeAll()
    }

    /// Swipe RIGHT → save. Optimistically updates local state (so the card
    /// vanishes instantly), clears any prior "hidden" mark, then persists.
    /// Doc id = placeId, so re-saving is idempotent.
    func savePlace(_ id: String, uid: String) {
        guard !uid.isEmpty else { return }
        savedPlaceIds.insert(id)
        hiddenPlaceIds.remove(id)
        let userDoc = db.collection("users").document(uid)
        userDoc.collection("savedPlaces").document(id)
            .setData(["createdAt": FieldValue.serverTimestamp()])
        userDoc.collection("hiddenPlaces").document(id).delete()
    }

    /// Swipe LEFT → "less likely to visit". Removes the card from the deck
    /// only; the place stays in the list and on the map.
    func hidePlace(_ id: String, uid: String) {
        guard !uid.isEmpty else { return }
        hiddenPlaceIds.insert(id)
        db.collection("users").document(uid)
            .collection("hiddenPlaces").document(id)
            .setData(["createdAt": FieldValue.serverTimestamp()])
    }

    /// Un-save from the "Saved" tab — the place re-enters the deck unless it's
    /// also hidden.
    func unsavePlace(_ id: String, uid: String) {
        guard !uid.isEmpty else { return }
        savedPlaceIds.remove(id)
        db.collection("users").document(uid)
            .collection("savedPlaces").document(id).delete()
    }

    // MARK: - City resolution

    /// Reverse-geocode places that still have no `cityName` (older places with
    /// no stored address), one at a time and cached, then patch them into
    /// `places` so the UI updates progressively. Reuses the same
    /// `MKReverseGeocodingRequest` path as `LoginView.refreshLocalityHint`.
    private func resolveMissingCities() {
        let pending = places.compactMap { place -> (id: String, lat: Double, lng: Double)? in
            guard place.cityName == nil, cityCache[place.id] == nil else { return nil }
            return (place.id, place.lat, place.lng)
        }
        guard !pending.isEmpty else { return }

        cityResolveTask?.cancel()
        cityResolveTask = Task { @MainActor [weak self] in
            for item in pending {
                if Task.isCancelled { return }
                guard let city = await Self.reverseGeocodeCity(lat: item.lat, lng: item.lng) else {
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                }
                guard let self, !Task.isCancelled else { return }
                self.cityCache[item.id] = city
                if let i = self.places.firstIndex(where: { $0.id == item.id }) {
                    self.places[i].cityName = city
                }
                // Gentle throttle to stay under MapKit's geocoding rate limit.
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    // MARK: - Place-detail jump (deep-link / Trending → place sheet)

    /// Fetches a place doc and synthesizes a `FriendPlace` for the detail sheet
    /// when the place isn't already in `places` (a deep-link / Trending jump to
    /// a place the friend feed doesn't cover). `friendFeedPosts` is the caller's
    /// already-loaded feed, used first; when it has nothing at this place we
    /// fall back to public discoverable posts so the card stack isn't empty.
    /// Returns nil if the place doc is gone or unreadable (caller no-ops).
    func placeForJump(placeId: String, friendFeedPosts: [FriendPost]) async -> FriendPlace? {
        do {
            let doc = try await db.collection("places")
                .document(placeId)
                .getDocument(as: Place.self)
            let friendPosts = friendFeedPosts.filter { $0.distinctPlaceIds.contains(placeId) }
            // Trending-place / new-user path: the friend graph has no posts
            // at this place, so the card stack would render empty. Fall back
            // to public posts (clear AND blurred) so the sheet has content.
            // PostStackCard renders non-discoverable ones with a blur based
            // on `postsAreFallback` below.
            let postsAtPlace: [FriendPost]
            let postsAreFallback: Bool
            if friendPosts.isEmpty {
                postsAtPlace = await fetchDiscoverablePostsAtPlace(placeId)
                postsAreFallback = true
            } else {
                postsAtPlace = friendPosts.sorted { $0.createdAt > $1.createdAt }
                postsAreFallback = false
            }
            return FriendPlace(
                id: placeId,
                name: doc.name,
                type: doc.type,
                lat: doc.lat,
                lng: doc.lng,
                posts: postsAtPlace,
                // Pass through the global counters so the detail sheet shows
                // "N visits" instead of "0 visits by 0 friends" when the user
                // landed here from a non-friend surface (e.g. Trending).
                globalVisitCount: doc.globalVisitCount,
                globalEngagementCount: doc.globalEngagementCount,
                address: doc.address,
                postsAreFallback: postsAreFallback
            )
        } catch {
            // Place was deleted or unreadable — return nil so the caller can
            // silently no-op rather than strand the user with an error.
            return nil
        }
    }

    /// Pulls public posts at a place when the friend feed has none. Used by
    /// the Trending → place-detail flow so the sheet never renders an empty
    /// card stack. Includes BOTH discoverable=true (rendered clear) AND
    /// discoverable=false (rendered blurred via PostStackCard's blur
    /// modifier). Posts authored by users who toggled "Help your circle
    /// discover" OFF are dropped entirely — we respect that opt-out by
    /// hiding the card, not blurring it. The `containsFaces == false` and
    /// `restricted == false` filters are required to match the Firestore rule
    /// (a restricted/audience-limited post must never surface in this public
    /// place-detail fallback).
    ///
    /// We run TWO queries and union them: the top-level `placeId ==` (every
    /// post carries it — it's the original, always-deployed index) and
    /// `mediaPlaceIds array-contains` (so a post tagged to this place only in a
    /// SECONDARY photo also matches). Querying `mediaPlaceIds` ALONE was a
    /// regression: posts created before the `mediaPlaceIds` denormalization
    /// (or before its backfill/index were deployed) carry only `placeId`, so
    /// the panel came up empty for them — which is exactly the trending posts
    /// that put the place on the map. Both branches are permitted by the
    /// public-read rule (it accepts placeId OR mediaPlaceIds).
    private func fetchDiscoverablePostsAtPlace(_ placeId: String) async -> [FriendPost] {
        // Independent fetches so one failing (e.g. the mediaPlaceIds composite
        // index isn't deployed yet) doesn't void the other.
        async let byPlaceId = postsAtPlace(placeId, by: .placeId)
        async let byMediaPlaceIds = postsAtPlace(placeId, by: .mediaPlaceIds)
        let merged = await byPlaceId + (await byMediaPlaceIds)

        // Dedupe by post id (a primary-photo tag matches BOTH queries), newest
        // first, then drop opted-out authors and cap at 20.
        var seen = Set<String>()
        let unique = merged
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert($0.id).inserted }
        let optedOut = await fetchOptedOutAuthorSet(
            authorIds: Array(Set(unique.map(\.authorId)))
        )
        return Array(unique.filter { !optedOut.contains($0.authorId) }.prefix(20))
    }

    private enum PlaceMatch { case placeId, mediaPlaceIds }

    /// One leg of the place-detail public fallback. Shares the
    /// `restricted == false` + `containsFaces == false` filters (required by
    /// the Firestore rule) and differs only in how it matches the place.
    private func postsAtPlace(_ placeId: String, by match: PlaceMatch) async -> [FriendPost] {
        do {
            let base = db.collection("posts")
            let matched: Query
            switch match {
            case .placeId:       matched = base.whereField("placeId", isEqualTo: placeId)
            case .mediaPlaceIds: matched = base.whereField("mediaPlaceIds", arrayContains: placeId)
            }
            let snap = try await matched
                .whereField("restricted", isEqualTo: false)
                .whereField("containsFaces", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 20)
                .getDocuments()
            return snap.documents.compactMap(FriendPost.init(document:))
        } catch {
            #if DEBUG
            print("[FriendPlacesService] place-posts \(match) fetch failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    /// Bulk-fetches `users/{uid}.optedOutOfDiscovery` for the given authors
    /// and returns the set of UIDs that have the toggle OFF (= opted out).
    /// Used to hide opted-out authors' cards in the place-detail panel —
    /// mirrors how the Trending Cloud Function drops them. Splits into
    /// chunks of 30 because that's Firestore's `in:` query cap.
    private func fetchOptedOutAuthorSet(authorIds: [String]) async -> Set<String> {
        guard !authorIds.isEmpty else { return [] }
        var result: Set<String> = []
        let chunks = stride(from: 0, to: authorIds.count, by: 30).map {
            Array(authorIds[$0..<min($0 + 30, authorIds.count)])
        }
        for chunk in chunks {
            do {
                let snap = try await db.collection("users")
                    .whereField(FieldPath.documentID(), in: chunk)
                    .getDocuments()
                for doc in snap.documents {
                    if (doc.data()["optedOutOfDiscovery"] as? Bool) == true {
                        result.insert(doc.documentID)
                    }
                }
            } catch {
                #if DEBUG
                print("[FriendPlacesService] opt-out batch read failed: \(error.localizedDescription)")
                #endif
            }
        }
        return result
    }

    private static func reverseGeocodeCity(lat: Double, lng: Double) async -> String? {
        await Geocoding.cityName(at: CLLocation(latitude: lat, longitude: lng))
    }

    /// Locality from a comma-separated address. Tuned for the common
    /// "…, <postal> <City>, <State>, <Country>" shape: take the
    /// third-from-last component and strip a leading postal code. Returns nil
    /// for short/ambiguous addresses so the caller reverse-geocodes instead.
    static func city(fromAddress address: String) -> String? {
        let parts = address
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }
        let candidate = parts[parts.count - 3]
        let city = candidate.drop(while: { $0.isNumber || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
        return city.isEmpty ? nil : city
    }
}
