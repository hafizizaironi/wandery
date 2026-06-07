import Foundation

/// App ↔ widget bridge over the shared **App Group** container.
///
/// The `FriendsFeedWidget` extension can't run the app's live Firestore
/// listeners, so the app mirrors the minimum it needs here:
///   • `uid` / `friendIds` — so the widget's timeline provider can build the
///     same feed query the app runs (and skip a `users/{uid}/friends` read).
///   • a small post **snapshot** — so the widget's `placeholder`/`getSnapshot`
///     render instantly (and offline) without touching the network.
///
/// Add this file to BOTH the `CafeHunter` and `FriendsFeedWidgetExtension`
/// targets (synchronized-group membership exception, same as `Keychain.swift`).
/// Both targets must enable the App Group capability with `appGroup` below.
enum SharedFeedStore {

    /// Must match the App Group enabled on the app + widget targets.
    static let appGroup = "group.TechVision.CafeHunter"
    /// Team-prefixed keychain access group — mirror of `Keychain.sharedGroup`.
    /// Used for `Auth.auth().useUserAccessGroup(_:)` so the widget process sees
    /// the signed-in Firebase user.
    static let sharedKeychainGroup = "5GQ3DBXL52.TechVision.CafeHunter.shared"

    /// Lightweight, `Codable` mirror of a `FriendPost` — only the fields the
    /// widget tiles need. `displayURL` is `thumbnailURL ?? mediaURL` (video
    /// poster for videos, the image url for photos).
    struct CachedPost: Codable, Equatable {
        /// One photo within a post, in carousel order. `displayURL` is already an
        /// image url (video posters are resolved app-side before mirroring).
        struct Photo: Codable, Equatable {
            let url: String
            let thumbnailURL: String?
            var displayURL: String { thumbnailURL ?? url }
        }

        let id: String
        let authorId: String
        let username: String
        let caption: String
        let mediaURL: String
        let thumbnailURL: String?
        let createdAt: Date
        /// Tagged place name for the header chip (nil when untagged).
        let placeName: String?
        /// Author's profile photo URL (resolved by the widget's live pull from
        /// `users/{authorId}`; nil → the avatar falls back to initials).
        let authorPhotoURL: String?
        /// All photos in the post (carousel). Optional for back-compat with
        /// snapshots written before multi-photo support — `displayPhotos`
        /// falls back to the legacy single `mediaURL`.
        let photos: [Photo]?

        var displayURL: String { thumbnailURL ?? mediaURL }

        /// Always ≥1 photo. Legacy snapshots synthesize one from `mediaURL`.
        var displayPhotos: [Photo] {
            if let photos, !photos.isEmpty { return photos }
            return [Photo(url: mediaURL, thumbnailURL: thumbnailURL)]
        }

        init(id: String, authorId: String, username: String, caption: String,
             mediaURL: String, thumbnailURL: String?, createdAt: Date,
             placeName: String? = nil, photos: [Photo]? = nil,
             authorPhotoURL: String? = nil) {
            self.id = id
            self.authorId = authorId
            self.username = username
            self.caption = caption
            self.mediaURL = mediaURL
            self.thumbnailURL = thumbnailURL
            self.createdAt = createdAt
            self.placeName = placeName
            self.photos = photos
            self.authorPhotoURL = authorPhotoURL
        }
    }

    // MARK: - Backing stores

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    private enum Key {
        static let uid = "feed.uid"
        static let friendIds = "feed.friendIds"
        static let friends = "feed.friends"
        static let nearbyPlaces = "feed.nearbyPlaces"
        static let trendingPlaces = "feed.trendingPlaces"
        static let myPhotoURL = "feed.myPhotoURL"
    }

    /// Minimal friend record for the widget's "Show photos from" picker
    /// (`FriendQuery`). Mirrored by the app so the picker lists real names
    /// offline — the friends subcollection only holds ids, so the app resolves
    /// names from `users/{id}` and caches them here.
    struct FriendSummary: Codable, Equatable {
        let id: String
        let name: String
    }

    /// A nearby place for the Nearby Map widget. The app mirrors a broad
    /// candidate set (friend-tagged "recent" + saved "hunt"); the widget filters
    /// by the user's live location + radius and drops the pins.
    struct WidgetPlace: Codable, Equatable {
        let id: String
        let name: String
        let lat: Double
        let lng: Double
        let category: String        // "recent" | "hunt" | "trend"
        /// recent: who tagged it (for the avatar halo). nil otherwise.
        let friendName: String?
        let friendId: String?
        /// trend: 🔥 count. nil otherwise.
        let trendCount: Int?
    }

    /// Snapshot lives in a container file (not UserDefaults) to avoid the
    /// suite's size pressure once thumbnails-by-reference grow.
    private static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("feed_snapshot.json")
    }

    // MARK: - uid

    static func writeUID(_ uid: String?) {
        if let uid { defaults?.set(uid, forKey: Key.uid) }
        else { defaults?.removeObject(forKey: Key.uid) }
    }

    static func readUID() -> String? { defaults?.string(forKey: Key.uid) }

    // MARK: - friendIds

    static func writeFriendIds(_ ids: [String]) {
        defaults?.set(ids, forKey: Key.friendIds)
    }

    static func readFriendIds() -> [String] {
        defaults?.stringArray(forKey: Key.friendIds) ?? []
    }

    // MARK: - Friends (widget "Show photos from" picker)

    static func writeFriends(_ friends: [FriendSummary]) {
        defaults?.set(try? JSONEncoder().encode(friends), forKey: Key.friends)
    }

    static func readFriends() -> [FriendSummary] {
        guard let data = defaults?.data(forKey: Key.friends),
              let friends = try? JSONDecoder().decode([FriendSummary].self, from: data) else { return [] }
        return friends
    }

    // MARK: - Nearby places (Nearby Map widget)

    static func writeNearbyPlaces(_ places: [WidgetPlace]) {
        defaults?.set(try? JSONEncoder().encode(places), forKey: Key.nearbyPlaces)
    }

    static func readNearbyPlaces() -> [WidgetPlace] {
        guard let data = defaults?.data(forKey: Key.nearbyPlaces),
              let places = try? JSONDecoder().decode([WidgetPlace].self, from: data) else { return [] }
        return places
    }

    /// Trending places — written separately by `CircleDiscoverService` (a
    /// different owner than the recent/hunt mirror), merged in the widget.
    static func writeTrendingPlaces(_ places: [WidgetPlace]) {
        defaults?.set(try? JSONEncoder().encode(places), forKey: Key.trendingPlaces)
    }

    static func readTrendingPlaces() -> [WidgetPlace] {
        guard let data = defaults?.data(forKey: Key.trendingPlaces),
              let places = try? JSONDecoder().decode([WidgetPlace].self, from: data) else { return [] }
        return places
    }

    // MARK: - Signed-in user's profile photo (Nearby "you" marker)

    static func writeMyPhotoURL(_ url: String?) {
        if let url, !url.isEmpty { defaults?.set(url, forKey: Key.myPhotoURL) }
        else { defaults?.removeObject(forKey: Key.myPhotoURL) }
    }

    static func readMyPhotoURL() -> String? { defaults?.string(forKey: Key.myPhotoURL) }

    // MARK: - Carousel photo index (interactive tap-to-advance)

    /// Persisted per post so the displayed photo survives widget reloads. The
    /// interactive `AdvancePhotoIntent` bumps this; the provider reads it.
    static func photoIndex(for postID: String) -> Int {
        defaults?.integer(forKey: "photoIndex.\(postID)") ?? 0
    }
    static func setPhotoIndex(_ i: Int, for postID: String) {
        defaults?.set(i, forKey: "photoIndex.\(postID)")
    }

    // MARK: - snapshot

    static func writeSnapshot(_ posts: [CachedPost]) {
        guard let url = snapshotURL else { return }
        do {
            let data = try JSONEncoder().encode(posts)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("[SharedFeedStore] writeSnapshot failed: \(error.localizedDescription)")
            #endif
        }
    }

    static func readSnapshot() -> [CachedPost] {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CachedPost].self, from: data)) ?? []
    }

    // MARK: - Thumbnail byte cache (widget only)

    /// Post media URLs are immutable, so a downsampled JPEG keyed by the post id
    /// can be cached forever — the widget downloads each post's thumbnail once,
    /// then renders instantly (and offline) on subsequent timelines.
    private static var thumbsDir: URL? {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let dir = base.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func thumbURL(_ key: String) -> URL? {
        // Firestore doc ids are filename-safe; sanitize defensively anyway.
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return thumbsDir?.appendingPathComponent(safe + ".jpg")
    }

    static func readThumb(_ key: String) -> Data? {
        guard let url = thumbURL(key) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func writeThumb(_ data: Data, key: String) {
        guard let url = thumbURL(key) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drop cached thumbnails for posts no longer in the feed so the dir
    /// doesn't grow without bound.
    static func pruneThumbs(keeping ids: Set<String>) {
        guard let dir = thumbsDir,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
        let keep = Set(ids.map { $0.replacingOccurrences(of: "/", with: "_") })
        for f in files {
            let base = f.deletingPathExtension().lastPathComponent
            // Author avatars ("avatar#<id>") are bounded by friend count and
            // shared across posts — never prune them with the photo tiles.
            if base.hasPrefix("avatar#") { continue }
            // Photos are cached per-id as "<postId>#<index>" — compare on the
            // post-id prefix so a kept post keeps all of its photo tiles.
            let postKey = base.split(separator: "#").first.map(String.init) ?? base
            if !keep.contains(postKey) { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: - sign-out

    static func clear() {
        defaults?.removeObject(forKey: Key.uid)
        defaults?.removeObject(forKey: Key.friendIds)
        defaults?.removeObject(forKey: Key.friends)
        defaults?.removeObject(forKey: Key.nearbyPlaces)
        defaults?.removeObject(forKey: Key.trendingPlaces)
        defaults?.removeObject(forKey: Key.myPhotoURL)
        if let url = snapshotURL { try? FileManager.default.removeItem(at: url) }
        if let dir = thumbsDir { try? FileManager.default.removeItem(at: dir) }
    }
}
