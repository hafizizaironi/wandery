import WidgetKit
import SwiftUI
import UIKit
import AppIntents

// MARK: - Theme (Wandery design tokens)

enum WanderyTheme {
    static let espresso  = Color(red: 0.086, green: 0.059, blue: 0.035)   // #160F09
    static let ink       = Color(red: 0.122, green: 0.102, blue: 0.090)   // #1F1A17
    static let cream     = Color(red: 0.937, green: 0.902, blue: 0.824)   // #EFE6D2
    static let paper     = Color(red: 0.984, green: 0.965, blue: 0.925)   // #FBF6EC
    static let persimmon = Color(red: 0.851, green: 0.416, blue: 0.247)   // #D96A3F  recent · you-dot
    static let olive     = Color(red: 0.486, green: 0.561, blue: 0.337)   // #7C8F56  hunt
    static let honey     = Color(red: 0.788, green: 0.569, blue: 0.247)   // #C9913F  trend
}

/// Shared widget kind id — must match the `reloadTimelines(ofKind:)` calls.
let kPhotoFeedKind = "FriendsFeedWidget"

// MARK: - Auto-advance interval

enum AutoAdvance: String, AppEnum {
    case off, m15, m30, m60

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Auto-advance" }
    static var caseDisplayRepresentations: [AutoAdvance: DisplayRepresentation] {
        [.off: "Off", .m15: "Every 15 minutes", .m30: "Every 30 minutes", .m60: "Every hour"]
    }

    /// Seconds between carousel steps; 0 = off.
    var seconds: TimeInterval {
        switch self {
        case .off: return 0
        case .m15: return 15 * 60
        case .m30: return 30 * 60
        case .m60: return 60 * 60
        }
    }
}

// MARK: - Friend picker ("Show photos from")

struct FriendEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Friend" }
    static var defaultQuery = FriendQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    /// Sentinel for "Everyone" (no author filter).
    static let everyone = FriendEntity(id: "everyone", name: "Everyone")
}

struct FriendQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FriendEntity] {
        all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [FriendEntity] { all() }
    func defaultResult() -> FriendEntity? { .everyone }
    /// Reads the friend names the app mirrored into the App Group — offline, no
    /// Firestore from the picker process.
    private func all() -> [FriendEntity] {
        [.everyone] + SharedFeedStore.readFriends().map { FriendEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Configuration (long-press ▸ Edit Widget)

struct PhotoFeedConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Photo Feed"
    static var description = IntentDescription("Latest moments from your circle.")

    @Parameter(title: "Show photos from")
    var friend: FriendEntity?

    @Parameter(title: "Auto-advance photos", default: .m30)
    var autoAdvance: AutoAdvance

    @Parameter(title: "Show captions", default: true)
    var showCaption: Bool

    /// nil → Everyone (no author filter); else the picked friend's uid.
    var friendFilter: String? {
        guard let id = friend?.id, id != FriendEntity.everyone.id else { return nil }
        return id
    }
}

// MARK: - Interactive intent (tap → next photo)

struct AdvancePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Next photo"
    static var isDiscoverable = false

    @Parameter(title: "Post ID") var postID: String
    @Parameter(title: "Total")   var total: Int

    init() {}
    init(postID: String, total: Int) { self.postID = postID; self.total = total }

    func perform() async throws -> some IntentResult {
        let next = (SharedFeedStore.photoIndex(for: postID) + 1) % max(total, 1)
        SharedFeedStore.setPhotoIndex(next, for: postID)
        // The system reloads after an interactive intent, but be explicit so the
        // new index is picked up immediately.
        WidgetCenter.shared.reloadTimelines(ofKind: kPhotoFeedKind)
        return .result()
    }
}

// MARK: - Avatar (profile picture; initials + hue fallback)

struct WidgetAvatar: View {
    let initials: String
    let hue: Double
    var photo: Data? = nil
    var size: CGFloat = 30
    var body: some View {
        Group {
            if let photo, let ui = UIImage(data: photo) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(
                        colors: [Color(hue: hue / 360, saturation: 0.58, brightness: 0.62),
                                 Color(hue: (hue + 30).truncatingRemainder(dividingBy: 360) / 360,
                                       saturation: 0.52, brightness: 0.44)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
    }
}

/// The author's profile picture, used as the only identity element.
struct AuthorAvatar: View {
    let entry: PhotoEntry
    let post: WidgetPost
    var size: CGFloat = 30
    var body: some View {
        WidgetAvatar(initials: post.initials, hue: post.hue, photo: entry.avatar, size: size)
    }
}

// MARK: - Multi-photo indicators (shown ONLY when photoCount > 1)

struct PhotoDots: View {
    let total: Int, active: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(total, 1), id: \.self) { i in
                Capsule()
                    .fill(i == active ? Color.white : Color.white.opacity(0.5))
                    .frame(width: i == active ? 16 : 6, height: 6)
            }
        }
    }
}

struct MultiBadge: View {
    let index: Int, total: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.on.square").font(.system(size: 9, weight: .semibold))
            Text("\(index + 1)/\(total)").font(.system(size: 10.5, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

/// Glassy circular "next" button wired to the interactive intent.
struct NextPhotoButton: View {
    let postID: String
    let total: Int
    var size: CGFloat = 36
    var body: some View {
        Button(intent: AdvancePhotoIntent(postID: postID, total: total)) {
            Image(systemName: "chevron.right")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Family views (profile-picture only; indicators only if multi-photo)

struct PhotoSmallView: View {
    let entry: PhotoEntry
    let post: WidgetPost
    private var multi: Bool { post.photoCount > 1 }
    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) { AuthorAvatar(entry: entry, post: post, size: 30).padding(12) }
            .overlay(alignment: .topTrailing) {
                if multi { MultiBadge(index: entry.index, total: post.photoCount).padding(12) }
            }
            .overlay(alignment: .bottomLeading) {
                if multi { PhotoDots(total: post.photoCount, active: entry.index).padding(14) }
            }
    }
}

struct PhotoMediumView: View {
    let entry: PhotoEntry
    let post: WidgetPost
    private var multi: Bool { post.photoCount > 1 }
    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) { AuthorAvatar(entry: entry, post: post, size: 34).padding(14) }
            .overlay(alignment: .topTrailing) {
                if multi { MultiBadge(index: entry.index, total: post.photoCount).padding(12) }
            }
            .overlay(alignment: .bottom) {
                if multi {
                    HStack(spacing: 10) {
                        PhotoDots(total: post.photoCount, active: entry.index)
                        Spacer()
                        NextPhotoButton(postID: post.id, total: post.photoCount, size: 36)
                    }
                    .padding(14)
                }
            }
    }
}

struct PhotoLargeView: View {
    let entry: PhotoEntry
    let post: WidgetPost
    private var multi: Bool { post.photoCount > 1 }
    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) { AuthorAvatar(entry: entry, post: post, size: 40).padding(14) }
            .overlay(alignment: .topTrailing) {
                if multi { MultiBadge(index: entry.index, total: post.photoCount).padding(14) }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    if entry.showCaption, let place = post.placeName, !place.isEmpty {
                        Text(place).font(.system(size: 22, weight: .bold)).lineLimit(1)
                    }
                    if entry.showCaption, !post.caption.isEmpty {
                        Text(post.caption).font(.system(size: 13, weight: .medium)).opacity(0.88).lineLimit(2)
                    }
                    if multi {
                        HStack(spacing: 12) {
                            PhotoDots(total: post.photoCount, active: entry.index)
                            Spacer()
                            Text("Tap →").font(.system(size: 11.5, weight: .semibold)).opacity(0.8)
                            NextPhotoButton(postID: post.id, total: post.photoCount, size: 44)
                        }
                        .padding(.top, 13)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                .padding(16)
            }
    }
}

// MARK: - Empty / signed-out

struct PhotoEmptyView: View {
    let signedOut: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: signedOut ? "person.crop.circle.badge.questionmark" : "fork.knife")
                .font(.title2).foregroundStyle(WanderyTheme.cream)
            Text(signedOut ? "Open Wandery to see friends' posts" : "No friend posts yet")
                .font(.caption).multilineTextAlignment(.center)
                .foregroundStyle(WanderyTheme.cream.opacity(0.85))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Entry view + widget

struct PhotoFeedEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PhotoEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { background }
            // Tap opens the exact post the widget is showing; falls back to the
            // friends feed when there's no post (empty/signed-out states).
            .widgetURL(URL(string: entry.post.map { "wandery://post/\($0.id)" } ?? "wandery://feed"))
    }

    @ViewBuilder private var content: some View {
        if let post = entry.post {
            switch family {
            case .systemSmall: PhotoSmallView(entry: entry, post: post)
            case .systemLarge: PhotoLargeView(entry: entry, post: post)
            default:           PhotoMediumView(entry: entry, post: post)
            }
        } else {
            PhotoEmptyView(signedOut: entry.signedOut)
        }
    }

    @ViewBuilder private var background: some View {
        ZStack {
            if let data = entry.image, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                WanderyTheme.espresso
            }
            if entry.post != nil {
                LinearGradient(colors: [.black.opacity(0.46), .clear, .clear, .black.opacity(0.66)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

struct FriendsFeedWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kPhotoFeedKind, intent: PhotoFeedConfig.self, provider: PhotoProvider()) { entry in
            PhotoFeedEntryView(entry: entry)
        }
        .configurationDisplayName("Photo Feed")
        .description("A friend's latest food find — tap to flip through the photos.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // Full-bleed photo: drop WidgetKit's default content margins so the
        // avatar / dots sit at a deliberate corner inset instead of being
        // pushed inward by the system margin on top of our padding.
        .contentMarginsDisabled()
    }
}
