import WidgetKit
import UIKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseAppCheck

/// Drives the Photo Feed widget. Two render paths:
///  • `placeholder` / `snapshot` — instant, from the App Group snapshot the app
///    mirrored. No live query.
///  • `timeline` — background-fresh: configures Firebase in this extension, runs
///    the same feed query the app runs (FRIENDS ONLY — never the signed-in
///    user's own posts), resolves each author's profile photo, and refreshes
///    the snapshot. Falls back to the cached snapshot when the query can't run
///    (offline / App Check).
///
/// The chosen post's photo + the author's avatar are downloaded + downsampled
/// here so the view renders pure bytes.
struct PhotoProvider: AppIntentTimelineProvider {
    typealias Entry = PhotoEntry
    typealias Intent = PhotoFeedConfig

    /// Longest-edge size for the full-bleed photo. Big enough for the large
    /// family, small enough to keep the widget under its ~30 MB ceiling while we
    /// hold every photo of one post in memory for the carousel.
    private static let photoMaxPixel: CGFloat = 800
    private static let avatarMaxPixel: CGFloat = 120
    private static let refresh: TimeInterval = 30 * 60

    // MARK: AppIntentTimelineProvider

    func placeholder(in context: Context) -> PhotoEntry { .empty(signedOut: false) }

    func snapshot(for configuration: PhotoFeedConfig, in context: Context) async -> PhotoEntry {
        if context.isPreview { return .empty(signedOut: false) }
        guard let post = Self.cachedPosts(onlyFriend: configuration.friendFilter).first else {
            return .empty(signedOut: SharedFeedStore.readUID() == nil)
        }
        return await Self.entry(for: post, at: SharedFeedStore.photoIndex(for: post.id),
                                date: Date(), showCaption: configuration.showCaption)
    }

    func timeline(for configuration: PhotoFeedConfig, in context: Context) async -> Timeline<PhotoEntry> {
        let showCaption = configuration.showCaption
        let interval = configuration.autoAdvance.seconds          // 0 when "Off"
        let posts = await Self.freshPosts(onlyFriend: configuration.friendFilter)
        guard let post = posts.first else {
            let signedOut = SharedFeedStore.readUID() == nil && Auth.auth().currentUser == nil
            return Timeline(entries: [.empty(signedOut: signedOut)],
                            policy: .after(Date().addingTimeInterval(Self.refresh)))
        }

        // Download every photo + the avatar once so the carousel is instant.
        var bytes: [Data?] = []
        for i in 0..<post.photoCount { bytes.append(await Self.photoData(post: post, index: i)) }
        let avatar = await Self.avatarData(post: post)
        SharedFeedStore.pruneThumbs(keeping: Set(posts.map(\.id)))

        let start = SharedFeedStore.photoIndex(for: post.id) % max(post.photoCount, 1)

        // Auto-advance: emit a frame per photo, `interval` apart (also the reload
        // cadence). Manual tap (AdvancePhotoIntent) still works in between.
        if interval > 0, post.photoCount > 1 {
            var entries: [PhotoEntry] = []
            for step in 0..<post.photoCount {
                let i = (start + step) % post.photoCount
                entries.append(PhotoEntry(date: Date().addingTimeInterval(Double(step) * interval),
                                          post: post, index: i, image: bytes[i],
                                          avatar: avatar, showCaption: showCaption, signedOut: false))
            }
            return Timeline(entries: entries, policy: .atEnd)
        }

        return Timeline(entries: [PhotoEntry(date: Date(), post: post, index: start,
                                             image: bytes[start], avatar: avatar,
                                             showCaption: showCaption, signedOut: false)],
                        policy: .after(Date().addingTimeInterval(Self.refresh)))
    }

    /// Build a single entry (snapshot path): downloads just the visible photo.
    private static func entry(for post: WidgetPost, at rawIndex: Int, date: Date,
                             showCaption: Bool) async -> PhotoEntry {
        let idx = rawIndex % max(post.photoCount, 1)
        async let img = photoData(post: post, index: idx)
        async let avatar = avatarData(post: post)
        return PhotoEntry(date: date, post: post, index: idx,
                          image: await img, avatar: await avatar,
                          showCaption: showCaption, signedOut: false)
    }

    // MARK: - Post sourcing

    /// Live Firestore pull → also refreshes the App Group snapshot. Friends only.
    /// Falls back to the cached snapshot on any failure.
    private static func freshPosts(onlyFriend: String? = nil) async -> [WidgetPost] {
        configureFirebaseIfNeeded()
        let me = Auth.auth().currentUser?.uid ?? SharedFeedStore.readUID()
        guard let me else { return cachedPosts(onlyFriend: onlyFriend) }

        let chunk: [String]
        if let onlyFriend {
            chunk = [onlyFriend]                                  // a single picked friend
        } else {
            var ids = SharedFeedStore.readFriendIds()
            if ids.isEmpty { ids = await fetchFriendIds(uid: me) }
            chunk = Array(ids.filter { $0 != me }.prefix(30))     // all friends, no self
        }
        guard !chunk.isEmpty, let posts = await fetchPosts(chunk: chunk) else {
            return cachedPosts(selfUID: me, onlyFriend: onlyFriend)
        }

        let top = Array(posts.filter { $0.authorId != me }.prefix(6))
        let photoMap = await fetchAuthorPhotos(ids: Array(Set(top.map(\.authorId))))

        // Only refresh the shared snapshot for the default (Everyone) feed — a
        // single-friend query would otherwise overwrite it with a subset.
        if onlyFriend == nil {
            let cached = top.map { p in
                SharedFeedStore.CachedPost(
                    id: p.id, authorId: p.authorId, username: p.authorUsername,
                    caption: p.primaryCaption ?? "", mediaURL: p.primaryMediaURL,
                    thumbnailURL: p.primaryThumbnailURL, createdAt: p.createdAt,
                    placeName: p.primaryPlaceName,
                    photos: p.media.map { .init(url: $0.displayURL, thumbnailURL: nil) },
                    authorPhotoURL: photoMap[p.authorId])
            }
            SharedFeedStore.writeSnapshot(cached)
        }
        return top.map { lite(fromPost: $0, photoURL: photoMap[$0.authorId]) }
    }

    private static func cachedPosts(selfUID: String? = nil, onlyFriend: String? = nil) -> [WidgetPost] {
        let me = selfUID ?? SharedFeedStore.readUID()
        return SharedFeedStore.readSnapshot()
            .filter { me == nil || $0.authorId != me }
            .filter { onlyFriend == nil || $0.authorId == onlyFriend }
            .map(lite(fromCached:))
    }

    private static func lite(fromPost p: FriendPost, photoURL: String?) -> WidgetPost {
        WidgetPost(id: p.id, authorId: p.authorId, username: p.authorUsername,
                   authorPhotoURL: photoURL, placeName: p.primaryPlaceName,
                   caption: p.primaryCaption ?? "", createdAt: p.createdAt,
                   photoURLs: p.media.map(\.displayURL))
    }
    private static func lite(fromCached c: SharedFeedStore.CachedPost) -> WidgetPost {
        WidgetPost(id: c.id, authorId: c.authorId, username: c.username,
                   authorPhotoURL: c.authorPhotoURL, placeName: c.placeName,
                   caption: c.caption, createdAt: c.createdAt,
                   photoURLs: c.displayPhotos.map(\.displayURL))
    }

    // MARK: - Image bytes (cache-first)

    private static func photoData(post: WidgetPost, index: Int) async -> Data? {
        guard index < post.photoURLs.count else { return nil }
        return await fetchJPEG(urlString: post.photoURLs[index],
                               key: "\(post.id)#\(index)", maxPixel: photoMaxPixel)
    }

    private static func avatarData(post: WidgetPost) async -> Data? {
        let key = "avatar#\(post.authorId)"
        if let cached = SharedFeedStore.readThumb(key) { return cached }
        guard let s = post.authorPhotoURL else { return nil }
        return await fetchJPEG(urlString: s, key: key, maxPixel: avatarMaxPixel)
    }

    private static func fetchJPEG(urlString: String, key: String, maxPixel: CGFloat) async -> Data? {
        if let cached = SharedFeedStore.readThumb(key) { return cached }
        guard let url = URL(string: urlString),
              let (raw, _) = try? await URLSession.shared.data(from: url),
              let ui = await ImageDecoding.prepared(from: raw, maxPixel: maxPixel),
              let jpeg = ui.jpegData(compressionQuality: 0.8) else { return nil }
        SharedFeedStore.writeThumb(jpeg, key: key)
        return jpeg
    }

    // MARK: - Firebase (mirror of the app's AppDelegate ordering)

    private static func configureFirebaseIfNeeded() {
        guard FirebaseApp.app() == nil else { return }
        AppCheck.setAppCheckProviderFactory(CafeHunterAppCheckProviderFactory())
        FirebaseApp.configure()
        try? Auth.auth().useUserAccessGroup(SharedFeedStore.sharedKeychainGroup)
    }

    private static func fetchFriendIds(uid: String) async -> [String] {
        do {
            let snap = try await Firestore.firestore()
                .collection("users").document(uid).collection("friends")
                .getDocuments(source: .server)
            return snap.documents.map(\.documentID)
        } catch { return [] }
    }

    private static func fetchPosts(chunk: [String]) async -> [FriendPost]? {
        guard !chunk.isEmpty else { return [] }
        do {
            let snap = try await Firestore.firestore().collection("posts")
                .whereField("authorId", in: chunk)
                .whereField("restricted", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 12)
                .getDocuments(source: .server)
            return snap.documents
                .compactMap { FriendPost(document: $0) }
                .filter { !$0.mediaURL.isEmpty }
        } catch { return nil }
    }

    /// Resolve authors' profile photos from `users/{id}` (≤6 distinct → one
    /// `in` query). Missing/empty photoURL just omits the key (initials fallback).
    private static func fetchAuthorPhotos(ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        do {
            let snap = try await Firestore.firestore().collection("users")
                .whereField(FieldPath.documentID(), in: Array(ids.prefix(10)))
                .getDocuments(source: .server)
            var map: [String: String] = [:]
            for doc in snap.documents {
                if let url = doc.data()["photoURL"] as? String, !url.isEmpty {
                    map[doc.documentID] = url
                }
            }
            return map
        } catch { return [:] }
    }
}
