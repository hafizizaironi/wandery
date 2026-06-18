import SwiftUI
import UIKit
@preconcurrency import FirebaseAuth

/// One post in the feed: the polaroid frame wrapping a paged media carousel.
/// Owns the carousel's `page` so the place + caption pills (polaroid overlay
/// slots) reflect the currently-visible photo.
/// One post in the feed. A single-media post is one polaroid; a multi-media
/// post is a swipeable STACK of polaroids — each photo its own tilted frame
/// with its own place/caption pills — flipped like a physical pile of prints.
struct FeedPolaroidCard: View {
    let post: FriendPost
    let index: Int
    let isVideoActive: Bool
    let side: CGFloat
    /// Shared feed music player — observed so the thermal-receipt barcode can
    /// react while THIS post's song is the one actively playing. Nil in static
    /// contexts (e.g. the long-press focus snapshot), where the barcode is flat.
    var postMusicPlayer: PostMusicPlayer? = nil
    var onPlaceTap: (String) -> Void = { _ in }
    /// Static rendering (e.g. the long-press focus overlay): videos show their
    /// poster thumbnail + a play badge instead of a live player, which would
    /// otherwise sit blank until the first frame decodes.
    var staticPreview: Bool = false
    /// Brief accent glow/scale when the user was brought to this post by a
    /// notification tap (cleared by the parent after ~1.5s).
    var isHighlighted: Bool = false

    /// Global feed-video mute, shared across all posts (like IG/TikTok).
    /// Defaults to muted/silent; the speaker button toggles it.
    @AppStorage("feed.videoMuted") private var videoMuted = true

    @State private var topIndex = 0
    @State private var dragOffset: CGSize = .zero
    @State private var dragHappened = false
    @State private var exiting: PostMedia?
    @State private var exitTranslation: CGSize = .zero
    /// The axis this drag committed to (nil until decided). A drag judged
    /// `.vertical` belongs to the page pager, so this gesture goes inert for it —
    /// otherwise the soft "width ≥ height" nudge made vertical paging on
    /// multi-photo cards feel stuck (it fought the pager every diagonal frame).
    @State private var swipeAxis: SwipeAxis? = nil

    private enum SwipeAxis { case horizontal, vertical }

    private let exitDistanceThreshold: CGFloat = 55
    private let exitVelocityThreshold: CGFloat = 220
    private let dragRecognitionThreshold: CGFloat = 6
    private let stackDepth = 3

    private var media: [PostMedia] { post.media }
    private var visibleDepth: Int { min(stackDepth, media.count) }

    var body: some View {
        cardStack
            // Photo stays full `side`; the cream frame bleeds past this square
            // slot, so the composer below doesn't move. (The vinyl record that
            // peeks below a music post is hosted by `heroFeedPostPage` so its
            // peeking part stays inside a hit-testable container.)
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
            .scaleEffect(isHighlighted ? 1.03 : 1)
            .shadow(color: AppTheme.cafeAccent.opacity(isHighlighted ? 0.55 : 0), radius: 18)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
        // Audience badge for restricted (private) posts.
        .overlay(alignment: .topTrailing) {
            if let text = restrictedBadgeText {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                    Text(text).font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(AppTheme.accentAction.opacity(0.92)))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                // Drop below the song cover (44pt tile at a 10pt inset) when the
                // post has music, so the two top-right badges don't overlap.
                .padding(.top, post.music != nil ? 62 : 12)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
            }
        }
    }

    /// The single polaroid or the swipeable multi-photo stack (unchanged from
    /// before — just extracted so the body can layer the vinyl record behind it).
    private var cardStack: some View {
        Group {
            if media.count <= 1 {
                polaroid(for: media.first, rel: 0)
            } else {
                ZStack {
                    // Back cards laid down first; explicit zIndex keeps order.
                    ForEach((0..<visibleDepth).reversed(), id: \.self) { rel in
                        polaroid(for: media[(topIndex + rel) % media.count], rel: rel)
                            .modifier(PolaroidStackTransform(rel: rel, dragOffset: dragOffset))
                            .zIndex(Double(visibleDepth - rel))
                    }
                    if let exiting {
                        polaroid(for: exiting, rel: 0)
                            .modifier(PolaroidExitTransform(translation: exitTranslation))
                            .allowsHitTesting(false)
                            .zIndex(1000)
                    }
                }
                .simultaneousGesture(swipeGesture)
            }
        }
    }

    private var myUid: String { Auth.auth().currentUser?.uid ?? "" }

    /// Badge copy for a restricted post: the recipient sees "Shared with you";
    /// the author sees who it went to. Nil for normal (everyone) posts.
    private var restrictedBadgeText: String? {
        guard post.restricted else { return nil }
        if post.authorId == myUid {
            let others = post.recipientUids.filter { $0 != myUid }.count
            return others <= 1 ? "Shared privately" : "Shared with \(others)"
        }
        return "Shared with you"
    }

    @ViewBuilder
    private func polaroid(for item: PostMedia?, rel: Int) -> some View {
        let isTop = rel == 0
        FeedCardFrame(
            username: "@\(post.authorUsername)",
            date: post.createdAt,
            tilt: Self.tilt(seed: item?.url ?? post.id),
            photoSide: side,
            topTrailing: { AnyView(musicOverlay(isTop: isTop)) },
            // Raw strings for the thermal-receipt style's text rows; the pill
            // styles render these via the topLeading / bottomCenter slots instead.
            placeName: item?.placeName,
            caption: item?.caption,
            // Thermal-receipt music: prints a song row + a barcode that reacts
            // while this post's song is the one playing; tap the barcode to mute.
            // (Only the top card reacts / is tappable.)
            music: post.music,
            musicPlaying: isTop && isThisPostPlaying,
            onMusicTap: isTop ? { videoMuted.toggle(); UIImpactFeedbackGenerator(style: .light).impactOccurred() } : nil
        ) {
            mediaCell(item, isActive: isVideoActive && isTop)
        } topLeading: {
            placeOverlay(for: item, isTop: isTop)
        } bottomCenter: {
            captionOverlay(for: item)
        }
    }

    /// True while THIS post's song is the one actively playing (active card,
    /// unmuted, scene active). Drives the thermal-receipt barcode equalizer;
    /// false → the barcode lies flat.
    private var isThisPostPlaying: Bool {
        guard let m = post.music, let player = postMusicPlayer else { return false }
        return player.isPlaying && player.currentURL == m.previewURL
    }

    /// The post's song cover, top-right of the photo (mirrors the composer).
    /// Tapping toggles the shared feed mute — the song auto-plays for the
    /// active post, so this tile is its mute control. Only the top card in a
    /// multi-photo stack is hittable.
    @ViewBuilder
    private func musicOverlay(isTop: Bool) -> some View {
        if let m = post.music {
            Button {
                if isTop {
                    videoMuted.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } label: {
                SongArtworkTile(artworkURL: m.artworkURL)
                    // Mute badge — shown only while the song is muted.
                    .overlay(alignment: .bottomTrailing) {
                        if videoMuted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                                .padding(3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(isTop)
            .accessibilityLabel("Song: \(m.trackName) by \(m.artistName). Tap to \(videoMuted ? "unmute" : "mute").")
        }
    }

    /// Tappable location pill — shared by both card styles. Only the top
    /// card in a multi-media stack accepts the tap (jump-to-place).
    @ViewBuilder
    private func placeOverlay(for item: PostMedia?, isTop: Bool) -> some View {
        if let name = item?.placeName, let pid = item?.placeId {
            Button {
                if isTop, !dragHappened { onPlaceTap(pid) }
            } label: {
                placePill(name: name)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(isTop)
        }
    }

    /// Caption pill — shared by both card styles.
    @ViewBuilder
    private func captionOverlay(for item: PostMedia?) -> some View {
        if let cap = item?.caption, !cap.isEmpty {
            captionPill(text: cap)
        }
    }

    @ViewBuilder
    private func mediaCell(_ item: PostMedia?, isActive: Bool) -> some View {
        Group {
            if let item, !item.url.isEmpty, item.isVideo, !staticPreview, let u = URL(string: item.url) {
                // A song replaces the video's own audio, so force the player
                // muted when the post has music (the song is the post's audio).
                SquareVideoFillView(url: u, isPlaying: isActive, muted: videoMuted || post.music != nil)
                    .overlay(alignment: .bottomTrailing) {
                        // For music posts the chip is the audio control, so hide
                        // the per-video speaker to avoid two competing toggles.
                        if post.music == nil { muteButton.padding(10) }
                    }
            } else if let item, !item.displayURL.isEmpty, let u = URL(string: item.displayURL) {
                // `displayURL` is the image URL for photos and the poster
                // thumbnail for videos — so static video previews show a frame.
                CachedAsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .failure: placeholder
                    case .empty: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    @unknown default: Color.gray.opacity(0.2)
                    }
                }
                .overlay {
                    if staticPreview, item.isVideo { videoBadge }
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque backing in preview mode so a not-yet-loaded poster can't let
        // the focus blur show through the photo area.
        .background(staticPreview ? AppTheme.surfacePrimary : Color.clear)
        .clipped()
    }

    private var videoBadge: some View {
        Image(systemName: "play.fill")
            .font(.title2).bold()
            .foregroundStyle(.white)
            .padding(12)
            .background(Color.black.opacity(0.5), in: Circle())
    }

    /// Mute/unmute toggle for feed videos. Flips the shared `videoMuted`
    /// preference, so all videos follow it. A Button so its tap is consumed
    /// and doesn't trip the card's swipe / long-press gestures.
    private var muteButton: some View {
        Button {
            videoMuted.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: videoMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(videoMuted ? "Unmute video" : "Mute video")
    }

    private var placeholder: some View {
        ZStack {
            AppTheme.gradient(for: .cafe, index: index)
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .symbolVariant(.slash)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityHidden(true)
                Text("Media unavailable")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func placePill(name: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "mappin.circle.fill")
                .font(.caption2).bold()
            Text(name)
                .font(.caption).bold()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // Thin frosted glass — sizes to the content at its frame, so it stays
        // uniform across posts. (`.glassEffect` renders inconsistently inside
        // the polaroid's per-post tilt, which is what made some pills balloon.)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func captionPill(text: String) -> some View {
        Text(text)
            .font(.footnote).fontWeight(.semibold)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // Commit to one axis per drag, then latch. This gesture is a
                // `.simultaneousGesture` peer of the pager's vertical drag, so a
                // drag we judge vertical is the pager's — go fully inert for it
                // (don't touch `dragOffset`) so the page slide isn't fought.
                // Bias toward the pager: claim the drag only on *clear* horizontal
                // dominance, which keeps vertical paging on multi-photo cards as
                // easy as on single-photo ones.
                if swipeAxis == nil {
                    let w = abs(value.translation.width), h = abs(value.translation.height)
                    swipeAxis = (w > h * 1.2) ? .horizontal : .vertical
                }
                // Mark that a real drag happened (either axis) so a place-pill
                // tap-up fired right after this still bails — same guard as before.
                if !dragHappened,
                   abs(value.translation.width) > dragRecognitionThreshold ||
                   abs(value.translation.height) > dragRecognitionThreshold {
                    dragHappened = true
                }
                guard swipeAxis == .horizontal else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                defer { swipeAxis = nil }
                // Only act on a drag we owned (horizontal). Vertical/undecided
                // drags belonged to the pager — `dragOffset` was never moved, so
                // there's nothing to settle.
                guard swipeAxis == .horizontal else {
                    DispatchQueue.main.async { dragHappened = false }
                    return
                }
                let absDistance = abs(value.translation.width)
                let absPredicted = abs(value.predictedEndTranslation.width)
                let shouldExit = (absDistance > exitDistanceThreshold ||
                                  absPredicted > exitVelocityThreshold) && media.count > 1
                if shouldExit {
                    let dirSource = absPredicted > absDistance
                        ? value.predictedEndTranslation.width : value.translation.width
                    flyOff(translation: value.translation, direction: dirSource > 0 ? 1 : -1)
                } else {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.74)) {
                        dragOffset = .zero
                    }
                }
                // Reset next tick so the place-pill tap-up (which fires
                // synchronously after onEnded) still sees the drag and bails.
                DispatchQueue.main.async { dragHappened = false }
            }
    }

    /// Flip the top polaroid off-screen and advance the stack (cyclic), so the
    /// user can keep flipping through the pile.
    private func flyOff(translation: CGSize, direction: CGFloat) {
        let leaving = media[topIndex % media.count]
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            exiting = leaving
            exitTranslation = translation
            topIndex = (topIndex + 1) % media.count
            dragOffset = .zero
        }
        withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
            exitTranslation = CGSize(width: direction * 850,
                                     height: translation.height + translation.height * 0.2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            var c = Transaction(); c.disablesAnimations = true
            withTransaction(c) { exiting = nil; exitTranslation = .zero }
        }
    }

    /// Stable per-photo tilt (FNV-1a over the media URL) so the stack looks
    /// like scattered prints and never jitters on scroll.
    static func tilt(seed: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(Int(h % 121)) / 20.0 - 3.0   // -3.0 … +3.0 degrees
    }
}

/// Positions a polaroid within the swipe stack. Top card follows the drag +
/// rotates; back cards sit smaller/lower and rise as the top card drags.
private struct PolaroidStackTransform: ViewModifier {
    let rel: Int
    let dragOffset: CGSize

    func body(content: Content) -> some View {
        let dragMag = min(abs(dragOffset.width) / 110, 1)
        let baseScale = 1.0 - CGFloat(rel) * 0.05
        let baseY = CGFloat(rel) * 12
        let scale = baseScale + CGFloat(rel) * 0.05 * dragMag
        let yOffset = baseY - CGFloat(rel) * 12 * dragMag
        let isTop = rel == 0
        return content
            .scaleEffect(scale)
            // Adds to each polaroid's own tilt; back cards only get scale/offset.
            .rotationEffect(.degrees(isTop ? Double(dragOffset.width / 18) : 0))
            .offset(x: isTop ? dragOffset.width : 0, y: isTop ? dragOffset.height : yOffset)
            .opacity(isTop ? 1.0 : max(0.5, 0.9 - Double(rel) * 0.13))
            .allowsHitTesting(isTop)
    }
}

/// Positions the polaroid flying off-screen — same translation+rotation feel
/// as a top-card drag, but lives outside the stack so the deck can advance.
private struct PolaroidExitTransform: ViewModifier {
    let translation: CGSize

    func body(content: Content) -> some View {
        content
            .offset(x: translation.width, y: translation.height)
            .rotationEffect(.degrees(Double(translation.width / 18)))
    }
}
