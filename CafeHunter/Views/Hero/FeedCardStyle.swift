import SwiftUI

/// The available feed-card layouts — the single registry of post-card styles.
///
/// **This is the one place to register a style.** To add a new one:
///   1. add a `case` here (with its `label` / `subtitle` / `icon`),
///   2. add the matching `case` to `FeedCardFrame`'s `switch` below,
///   3. create the new frame view.
/// The settings picker (`ForEach(FeedCardStyle.allCases)`) and every feed call
/// site pick it up automatically — nothing else to touch.
enum FeedCardStyle: String, CaseIterable, Identifiable {
    case plain
    case polaroid

    var id: String { rawValue }

    /// Shown in the settings picker.
    var label: String {
        switch self {
        case .plain:    "Classic"
        case .polaroid: "Polaroid"
        }
    }

    /// One-liner under the settings row.
    var subtitle: String {
        switch self {
        case .plain:    "Clean square cards"
        case .polaroid: "Framed like printed prints"
        }
    }

    /// SF Symbol for the settings row.
    var icon: String {
        switch self {
        case .plain:    "square"
        case .polaroid: "photo.on.rectangle.angled"
        }
    }

    // MARK: - Release gating (the team's switch)

    /// Whether this style is released to regular users. A style is a "skin" the
    /// user can pick — but the team decides which skins are available. Keep an
    /// in-development style `false` so it's hidden from the user picker until
    /// it's ready; admins can still preview it (see `ProfileHomeView`).
    var isReleased: Bool {
        switch self {
        case .plain:    true
        case .polaroid: true
        }
    }

    /// The styles a regular user can choose from (released only). Admins get the
    /// full `allCases` so they can preview unreleased skins before shipping them.
    static var released: [FeedCardStyle] { allCases.filter(\.isReleased) }

    // MARK: - Persistence

    /// The `@AppStorage` key — single source of truth for the stored style.
    static let storageKey = "feed.cardStyle"

    /// One-time migration from the old boolean key (`feed.usePolaroidFrame`).
    /// Call once at launch. Carries an existing polaroid preference over to the
    /// new key instead of silently resetting users to the `.plain` default.
    static func migrateLegacyKeyIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyKey = "feed.usePolaroidFrame"
        guard defaults.object(forKey: storageKey) == nil,
              defaults.object(forKey: legacyKey) != nil else { return }
        let style: FeedCardStyle = defaults.bool(forKey: legacyKey) ? .polaroid : .plain
        defaults.set(style.rawValue, forKey: storageKey)
    }
}

/// The single style dispatcher: wraps the media `content` (plus the location /
/// caption overlay slots) in whichever frame the user's selected `FeedCardStyle`
/// maps to. Every feed surface — live feed, empty-state, capture review — routes
/// through this, so the style is read in ONE place and there are no scattered
/// `if/else` branches.
///
/// `date` / `tilt` / `showTape` are only consumed by styles that need them
/// (`.polaroid`); `.plain` ignores them.
struct FeedCardFrame<Content: View, TopLeading: View, BottomCenter: View>: View {
    var username: String?
    var date: Date?
    var tilt: Double = -1.8
    var showTape: Bool = true
    var photoSide: CGFloat
    /// Optional bottom-left pill (the music sticker). Routed into each frame's
    /// matching slot so it's positioned like the location/caption pills.
    var bottomLeading: () -> AnyView = { AnyView(EmptyView()) }
    /// Optional top-right control (the composer music button). Routed into each
    /// frame's top-trailing slot — same level/inset as the top-left location pill.
    var topTrailing: () -> AnyView = { AnyView(EmptyView()) }
    @ViewBuilder var content: () -> Content
    @ViewBuilder var topLeading: () -> TopLeading
    @ViewBuilder var bottomCenter: () -> BottomCenter

    @AppStorage(FeedCardStyle.storageKey) private var style: FeedCardStyle = .plain

    var body: some View {
        switch style {
        case .plain:
            PlainFeedFrame(username: username, photoSide: photoSide,
                           bottomLeading: bottomLeading, topTrailing: topTrailing) {
                content()
            } topLeading: {
                topLeading()
            } bottomCenter: {
                bottomCenter()
            }
        case .polaroid:
            PolaroidFrame(
                username: username,
                date: date,
                tilt: tilt,
                showTape: showTape,
                photoSide: photoSide,
                bottomLeading: bottomLeading,
                topTrailing: topTrailing
            ) {
                content()
            } topLeading: {
                topLeading()
            } bottomCenter: {
                bottomCenter()
            }
        }
    }
}
