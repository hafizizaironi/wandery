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
    case thermalReceipt
    case filmStrip
    case holo
    case starPass
    case parAvion

    var id: String { rawValue }

    /// Shown in the settings picker.
    var label: String {
        switch self {
        case .plain:          "Classic"
        case .polaroid:       "Polaroid"
        case .thermalReceipt: "Thermal Receipt"
        case .filmStrip:      "Film Strip"
        case .holo:           "Holo Card"
        case .starPass:       "Star Pass"
        case .parAvion:       "Par Avion"
        }
    }

    /// One-liner under the settings row.
    var subtitle: String {
        switch self {
        case .plain:          "Clean square cards"
        case .polaroid:       "Framed like printed prints"
        case .thermalReceipt: "Printed café receipt"
        case .filmStrip:      "35mm celluloid strip"
        case .holo:           "Iridescent trading card"
        case .starPass:       "Celestial admit-one ticket"
        case .parAvion:       "Airmail love postcard"
        }
    }

    /// SF Symbol for the settings row.
    var icon: String {
        switch self {
        case .plain:          "square"
        case .polaroid:       "photo.on.rectangle.angled"
        case .thermalReceipt: "scroll"
        case .filmStrip:      "film"
        case .holo:           "sparkles"
        case .starPass:       "ticket"
        case .parAvion:       "envelope"
        }
    }

    // MARK: - Release gating (the team's switch)

    /// Whether this style is released to regular users. A style is a "skin" the
    /// user can pick — but the team decides which skins are available. Keep an
    /// in-development style `false` so it's hidden from the user picker until
    /// it's ready; admins can still preview it (see `ProfileHomeView`).
    var isReleased: Bool {
        switch self {
        case .plain:          true
        case .polaroid:       true
        // Not released at the BASE — exposed to admins (preview) + allow-listed
        // testers (thermal), and to everyone once the admin PUBLISHES them via
        // the wardrobe (`config/frames` → `FrameCatalogService`). See `ProfileHomeView`.
        case .thermalReceipt: false
        case .filmStrip:      false
        case .holo:           false
        case .starPass:       false
        case .parAvion:       false
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
    /// Raw place name / caption strings. Most styles render location + caption
    /// as the `topLeading` / `bottomCenter` pill *views*, but `.thermalReceipt`
    /// prints them as receipt text rows, so it needs the plain strings. Defaulted
    /// nil — the non-feed call sites (empty state) don't pass them.
    var placeName: String? = nil
    var caption: String? = nil
    /// Feed post's attached song — used only by `.thermalReceipt`, which prints a
    /// `♪ track — artist` row and reacts the barcode to `musicPlaying` (tap =
    /// `onMusicTap`, the mute toggle). Other styles show the cover via `topTrailing`.
    var music: PostMusic? = nil
    var musicPlaying: Bool = false
    var onMusicTap: (() -> Void)? = nil
    /// True in the post composer (capture-review). The `.thermalReceipt` style
    /// uses this to overlay the SAME interactive top pills as the other frames
    /// (place top-left, music top-right) instead of its receipt-native rows.
    var isComposer: Bool = false
    /// Render a SPECIFIC style regardless of the stored preference — used by the
    /// wardrobe preview to show each frame. Nil → use the user's selected style.
    var styleOverride: FeedCardStyle? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var topLeading: () -> TopLeading
    @ViewBuilder var bottomCenter: () -> BottomCenter

    @AppStorage(FeedCardStyle.storageKey) private var storedStyle: FeedCardStyle = .plain
    private var style: FeedCardStyle { styleOverride ?? storedStyle }

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
        case .thermalReceipt:
            // In the FEED the receipt prints location / caption / song as text
            // rows (ignoring the pill slots). In the COMPOSER it overlays the
            // interactive place + music pills on the photo, like the other styles.
            ThermalReceiptFeedFrame(
                username: username,
                date: date,
                placeName: placeName,
                caption: caption,
                photoSide: photoSide,
                topLeading: { AnyView(topLeading()) },
                topTrailing: topTrailing,
                bottomCenter: { AnyView(bottomCenter()) },
                isComposer: isComposer,
                music: music,
                musicPlaying: musicPlaying,
                onMusicTap: onMusicTap
            ) {
                content()
            }
        case .filmStrip:
            // Uses the pill slots like Plain/Polaroid; adds the celluloid chrome.
            FilmStripFeedFrame(
                username: username,
                placeName: placeName,
                photoSide: photoSide,
                topTrailing: topTrailing
            ) {
                content()
            } topLeading: {
                topLeading()
            } bottomCenter: {
                bottomCenter()
            }
        case .holo:
            HoloCardFeedFrame(
                username: username,
                placeName: placeName,
                photoSide: photoSide,
                topTrailing: topTrailing
            ) {
                content()
            } topLeading: {
                topLeading()
            } bottomCenter: {
                bottomCenter()
            }
        case .starPass:
            // Text-native (caption/place print in the stub); composer overlays
            // the interactive pills on the photo — same shape as the receipt.
            StarPassTicketFeedFrame(
                username: username,
                placeName: placeName,
                caption: caption,
                photoSide: photoSide,
                topLeading: { AnyView(topLeading()) },
                topTrailing: topTrailing,
                bottomCenter: { AnyView(bottomCenter()) },
                isComposer: isComposer
            ) {
                content()
            }
        case .parAvion:
            ParAvionPostcardFeedFrame(
                username: username,
                placeName: placeName,
                caption: caption,
                date: date,
                photoSide: photoSide,
                topLeading: { AnyView(topLeading()) },
                topTrailing: topTrailing,
                bottomCenter: { AnyView(bottomCenter()) },
                isComposer: isComposer
            ) {
                content()
            }
        }
    }
}
