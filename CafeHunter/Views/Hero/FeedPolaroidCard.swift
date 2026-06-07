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
    var onPlaceTap: (String) -> Void = { _ in }
    /// Static rendering (e.g. the long-press focus overlay): videos show their
    /// poster thumbnail + a play badge instead of a live player, which would
    /// otherwise sit blank until the first frame decodes.
    var staticPreview: Bool = false
    /// Brief accent glow/scale when the user was brought to this post by a
    /// notification tap (cleared by the parent after ~1.5s).
    var isHighlighted: Bool = false

    /// Display preference (Profile → "Polaroid frames"). Off = plain cards.
    @AppStorage("feed.usePolaroidFrame") private var usePolaroidFrame = false
    /// Global feed-video mute, shared across all posts (like IG/TikTok).
    /// Defaults to muted/silent; the speaker button toggles it.
    @AppStorage("feed.videoMuted") private var videoMuted = true

    @State private var topIndex = 0
    @State private var dragOffset: CGSize = .zero
    @State private var dragHappened = false
    @State private var exiting: PostMedia?
    @State private var exitTranslation: CGSize = .zero

    private let exitDistanceThreshold: CGFloat = 55
    private let exitVelocityThreshold: CGFloat = 220
    private let dragRecognitionThreshold: CGFloat = 6
    private let stackDepth = 3

    private var media: [PostMedia] { post.media }
    private var visibleDepth: Int { min(stackDepth, media.count) }

    var body: some View {
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
        // Photo stays full `side`; the cream frame bleeds past this square slot,
        // so the composer below doesn't move.
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
                .padding(.top, 12)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
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
        if usePolaroidFrame {
            PolaroidFrame(
                username: "@\(post.authorUsername)",
                date: post.createdAt,
                tilt: Self.tilt(seed: item?.url ?? post.id),
                photoSide: side
            ) {
                mediaCell(item, isActive: isVideoActive && isTop)
            } topLeading: {
                placeOverlay(for: item, isTop: isTop)
            } bottomCenter: {
                captionOverlay(for: item)
            }
        } else {
            PlainFeedFrame(
                username: "@\(post.authorUsername)",
                photoSide: side
            ) {
                mediaCell(item, isActive: isVideoActive && isTop)
            } topLeading: {
                placeOverlay(for: item, isTop: isTop)
            } bottomCenter: {
                captionOverlay(for: item)
            }
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
                SquareVideoFillView(url: u, isPlaying: isActive, muted: videoMuted)
                    .overlay(alignment: .bottomTrailing) { muteButton.padding(10) }
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
                // Only follow horizontal-dominant drags — a vertical drag is the
                // page pager's (this gesture is `.simultaneousGesture`, so it
                // also sees vertical drags; ignoring them keeps the polaroid from
                // drifting while the page slides).
                if abs(value.translation.width) >= abs(value.translation.height) {
                    dragOffset = value.translation
                }
                if !dragHappened,
                   abs(value.translation.width) > dragRecognitionThreshold ||
                   abs(value.translation.height) > dragRecognitionThreshold {
                    dragHappened = true
                }
            }
            .onEnded { value in
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
