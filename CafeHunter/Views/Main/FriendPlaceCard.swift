import SwiftUI
import UIKit

/// Direction the user committed on a card. `.save` = swiped right (save the
/// place), `.skip` = swiped left ("less likely to visit").
enum SwipeDirection {
    case save
    case skip
}

/// Tinder-style hero card for one `FriendPlace`. Used inside the visited-
/// places sheet carousel — photo fills the card, name + social proof
/// overlay the lower third, whole card is the tap target.
struct FriendPlaceCard: View {
    let place: FriendPlace
    /// Only the front card plays video; back/exiting cards render the thumbnail,
    /// so the deck never holds more than one live AVPlayer. Declared before
    /// `onTap` so the trailing-closure call sites keep working.
    var isActive: Bool = false
    let onTap: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    private var heroURL: URL? {
        guard let post = place.mostRecent else { return nil }
        let urlString = post.isVideo ? (post.thumbnailURL ?? post.mediaURL) : post.mediaURL
        return URL(string: urlString)
    }

    /// Full video URL for the most-recent post when this is the active (front)
    /// card and that post is a video; otherwise nil → fall back to the thumbnail.
    private var heroVideoURL: URL? {
        guard isActive, let post = place.mostRecent, post.isVideo,
              let s = post.media.first?.url, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private var visitsLabel: String {
        let visits = max(place.globalVisitCount, 0)
        let displayed = visits > 0 ? visits : place.posts.count
        let friendCount = Set(place.posts.map(\.authorId)).count
        if displayed == 1 { return "1 visit" }
        if friendCount <= 1 { return "\(displayed) visits" }
        return "\(displayed) visits · \(friendCount) friends"
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                heroLayer
                gradientOverlay
                typeChip
                bottomContent
            }
            // Anchor the ZStack to the proposed size so the image's
            // .aspectRatio(.fill) can't propagate its oversized intrinsic
            // size back up and push the bottom-leading text past the
            // sheet's left edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.espresso)
            .clipShape(.rect(cornerRadius: 22))
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    // MARK: - Layers

    private var heroLayer: some View {
        // `Color.clear` flexes to fill the ZStack frame; the media is placed as
        // `.overlay` so its reported size matches the clear anchor instead of the
        // media's intrinsic .fill expansion. The thumbnail stays resident UNDER
        // the (clear-backed) player, so a video card shows its poster while the
        // player builds — no thumbnail→black→video pop as the deck advances — and
        // the image is never torn down when the front card toggles active.
        Color.clear
            .overlay {
                ZStack {
                    CachedAsyncImage(url: heroURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure, .empty:
                            fallbackHero
                        @unknown default:
                            fallbackHero
                        }
                    }
                    if let u = heroVideoURL {
                        // Front card + video → full looping muted player over the
                        // resident poster. `.clear` reveals the poster until the
                        // first frame decodes; once playing it fills the card.
                        SquareVideoFillView(url: u, isPlaying: scenePhase == .active,
                                            muted: true, backgroundColor: .clear)
                    }
                }
            }
            .clipped()
    }

    private var fallbackHero: some View {
        // Use the panel color so a missing/loading photo blends into the
        // sheet instead of flashing a colored gradient. The emoji still
        // gives a hint of the place type.
        ZStack {
            AppTheme.espresso
            Text(place.type.emoji)
                .font(.system(size: 72))
                .opacity(0.45)
        }
    }

    private var gradientOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.0),  location: 0.35),
                .init(color: .black.opacity(0.20), location: 0.65),
                .init(color: .black.opacity(0.70), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var typeChip: some View {
        HStack(spacing: 5) {
            Text(place.type.emoji).font(.system(size: 12))
            Text(place.type.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .environment(\.colorScheme, .dark)
        .overlay(
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var bottomContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            // Allow up to 3 lines, then auto-shrink down to 55% before
            // truncating — long mall-style names ("Ramen Honolu Premier -
            // The Exchange TRX") fit gracefully instead of running off
            // the card edge.
            Text(place.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(visitsLabel)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// One mounted card in the deck: the place plus its current depth (`rel`,
/// 0 = front). Identified by place id so SwiftUI keeps a card's view — and its
/// loaded image — stable as it rises from the back to the front.
private struct DeckCard: Identifiable {
    let place: FriendPlace
    let rel: Int
    var id: String { place.id }
}

/// Tinder-style swipe deck of `FriendPlaceCard`s. The top card responds to a
/// horizontal `DragGesture` with rotation; the next two cards peek behind with
/// reduced scale + downward offset, rising forward as the drag progresses. Past
/// `exitThreshold`, the top card flies off and `onSwipe` fires with the
/// committed direction — RIGHT = save, LEFT = "less likely". The deck is owned
/// by the parent: each committed swipe is persisted, which removes the place
/// from `places`, so the deck depletes until empty (→ `SwipeDeckEmptyState`).
/// Tap on the top card → `onTap(place)`.
struct FriendPlaceCarousel: View {
    let places: [FriendPlace]
    /// Fired when the top card is flung past threshold. The parent persists the
    /// decision and removes the place from `places`.
    let onSwipe: (FriendPlace, SwipeDirection) -> Void
    let onTap: (FriendPlace) -> Void

    @State private var topIndex: Int = 0
    @State private var dragOffset: CGSize = .zero
    /// Set true once a drag exceeds the motion threshold; gated against by
    /// the card's tap closure so lifting your thumb after a swipe doesn't
    /// also fire the Button's tap recognizer. Reset async in onEnded so
    /// the (synchronous) tap-up sees this still true and bails.
    @State private var dragHappened: Bool = false
    /// Card currently animating off-screen. Plucked out of the stack when
    /// the user drags past `exitThreshold` so the stack itself can update
    /// `topIndex` atomically without the new top card inheriting the
    /// in-flight spring on `dragOffset`.
    @State private var exitingPlace: FriendPlace?
    /// Translation of the exiting card. Starts at the user's last drag
    /// translation (so the hand-off from the dragged top card is seamless)
    /// and springs to off-screen.
    @State private var exitTranslation: CGSize = .zero

    /// One-time swipe tutorial. Mirrors `ShutterControl`'s `hasSeenGuide` gate:
    /// shown on first use, auto-retires after a few seconds, and clears the
    /// instant the user starts a real drag.
    @AppStorage("swipeDeck.hasSeenGuide") private var hasSeenGuide = false
    @State private var coachPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Horizontal drag distance at which we commit to flying the top card
    /// off-screen instead of snapping back. Slow drags must reach this.
    private let exitDistanceThreshold: CGFloat = 55
    /// `predictedEndTranslation.width` — factors in velocity. A quick flick
    /// has a small instantaneous translation but a large predicted one, so
    /// crossing this threshold lets a flick commit to exit even when the
    /// finger only travelled a short distance.
    private let exitVelocityThreshold: CGFloat = 220
    /// Motion threshold (in either axis) above which we consider the touch
    /// a drag rather than a tap.
    private let dragRecognitionThreshold: CGFloat = 6

    /// How many cards to keep mounted at once. 3 = top + 2 peeking behind.
    private let stackDepth: Int = 3

    private var visibleDepth: Int { min(stackDepth, places.count) }
    private var showCoach: Bool { !hasSeenGuide && !places.isEmpty && exitingPlace == nil }

    /// The mounted cards, ordered back-to-front, each tagged with its depth and
    /// identified by place id (see `DeckCard`) so a rising card keeps its
    /// already-loaded image instead of being recycled by stack position.
    private var visibleCards: [DeckCard] {
        guard !places.isEmpty else { return [] }
        var cards: [DeckCard] = []
        for rel in 0..<visibleDepth {
            let idx = topIndex + rel
            guard idx < places.count else { break }
            cards.append(DeckCard(place: places[idx], rel: rel))
        }
        // Back-to-front so the ZStack lays deeper cards down first; zIndex is
        // still set explicitly as a backstop.
        return cards.reversed()
    }

    /// Warm the front + next places' most-recent video into `VideoCache` so the
    /// front card's player builds from a local file (no network hitch) as the
    /// deck advances. Off-drag, `.utility` priority, dedup handled by the cache.
    private func prefetchUpcomingVideos() {
        guard !places.isEmpty else { return }
        let end = min(topIndex + stackDepth, places.count)
        guard topIndex < end else { return }
        for i in topIndex..<end {
            guard let post = places[i].mostRecent, post.isVideo,
                  let s = post.media.first?.url, let url = URL(string: s) else { continue }
            Task.detached(priority: .utility) { _ = await VideoCache.shared.prefetch(url) }
        }
    }

    var body: some View {
        Group {
            // Keep the deck mounted while a card is still flying off, even once
            // `places` has emptied, so the last swipe animates out before the
            // empty state takes over.
            if places.isEmpty && exitingPlace == nil {
                SwipeDeckEmptyState()
            } else {
                VStack(spacing: 10) {
                    cardStack
                    if !places.isEmpty { indicator }
                }
            }
        }
        .onChange(of: places.map(\.id)) { _, _ in
            // Deck shrank (a swipe persisted) or the filter switched — keep the
            // front card pinned at index 0 so the next card slides forward.
            topIndex = 0
            dragOffset = .zero
            prefetchUpcomingVideos()
        }
        .onAppear {
            prefetchUpcomingVideos()
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                coachPulse = true
            }
        }
        // Auto-retire the coachmark after a few seconds if the user hasn't
        // swiped yet (mirrors ShutterControl). Re-armed whenever it reappears.
        .task(id: showCoach) {
            guard showCoach else { return }
            try? await Task.sleep(for: .seconds(6))
            hasSeenGuide = true
        }
    }

    private var cardStack: some View {
        ZStack {
            // Keyed by place id (not stack position) so a card keeps its
            // identity — and its loaded image — as it rises to the front.
            // Position-based identity recycled the view when the deck advanced,
            // which let the name update a frame ahead of the async image.
            ForEach(visibleCards) { card in
                FriendPlaceCard(place: card.place, isActive: card.rel == 0) {
                    // Only the top card opens place-detail on tap — back
                    // cards are non-interactive. Also bail if a drag
                    // happened: a Button inside a parent
                    // `.simultaneousGesture` fires its tap on touch-up
                    // even after meaningful drag motion, which would
                    // misfire place-detail every time the user swiped.
                    guard card.rel == 0, !dragHappened else { return }
                    onTap(card.place)
                }
                .overlay { if card.rel == 0 { swipeStamp } }
                .modifier(StackTransform(rel: card.rel, dragOffset: dragOffset))
                .zIndex(Double(visibleDepth - card.rel))
            }
            // Card flying off-screen lives outside the stack so the deck
            // can advance instantly without inheriting the spring.
            if let exitingPlace {
                FriendPlaceCard(place: exitingPlace) { }
                    .modifier(ExitTransform(translation: exitTranslation))
                    .allowsHitTesting(false)
                    .zIndex(1000)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .overlay { if showCoach { coachOverlay } }
        .animation(.easeOut(duration: 0.2), value: showCoach)
        // simultaneousGesture so the top card's Button tap still fires
        // when the user taps without dragging more than `minimumDistance`.
        .simultaneousGesture(swipeGesture)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragOffset = value.translation
                if !dragHappened &&
                    (abs(value.translation.width) > dragRecognitionThreshold ||
                     abs(value.translation.height) > dragRecognitionThreshold) {
                    dragHappened = true
                    // First real interaction retires the tutorial.
                    if !hasSeenGuide { hasSeenGuide = true }
                }
            }
            .onEnded { value in
                let absDistance = abs(value.translation.width)
                let absPredicted = abs(value.predictedEndTranslation.width)
                let velocityDominates = absPredicted > absDistance
                let shouldExit =
                    (absDistance > exitDistanceThreshold ||
                     absPredicted > exitVelocityThreshold) &&
                    topIndex < places.count

                if shouldExit {
                    // Use the predicted translation to decide direction
                    // when velocity outpaces distance — a leftward flick
                    // that barely moves the finger past center should
                    // still exit leftward.
                    let directionSource = velocityDominates
                        ? value.predictedEndTranslation.width
                        : value.translation.width
                    let direction: CGFloat = directionSource > 0 ? 1 : -1
                    flyOff(translation: value.translation, direction: direction)
                } else {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.74)) {
                        dragOffset = .zero
                    }
                }
                // Reset on the next runloop tick — the Button's tap-up
                // recognizer fires synchronously after this `onEnded`,
                // and we need `dragHappened` to still be true when that
                // tap closure runs so it bails. Async reset clears it
                // before the next touch.
                DispatchQueue.main.async {
                    dragHappened = false
                }
            }
    }

    private func flyOff(translation: CGSize, direction: CGFloat) {
        guard topIndex < places.count else { return }
        let leaving = places[topIndex]
        let swipe: SwipeDirection = direction > 0 ? .save : .skip
        // Atomic instant: move the leaving card into the exiting overlay
        // (starting at the current drag translation, so the hand-off is
        // seamless), advance the visible stack by one so the next card is
        // already in front (no one-frame double-render), and reset the drag.
        // We do NOT wrap — `onSwipe` persists the decision, which removes this
        // place from `places`; the resulting `onChange` resets `topIndex` to 0
        // and the indices realign on the same front card.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            exitingPlace = leaving
            exitTranslation = translation
            topIndex += 1
            dragOffset = .zero
        }
        // Glide the exiting card off-screen with a snappy curve so light
        // flicks feel decisive. 850pt target ensures even on iPad widths
        // the card is fully gone before the cleanup fires.
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
            exitTranslation = CGSize(
                width: direction * 850,
                height: translation.height + translation.height * 0.2
            )
        }
        Self.swipeHaptic(swipe)
        onSwipe(leaving, swipe)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            var clearT = Transaction()
            clearT.disablesAnimations = true
            withTransaction(clearT) {
                exitingPlace = nil
                exitTranslation = .zero
            }
        }
    }

    private static func swipeHaptic(_ direction: SwipeDirection) {
        switch direction {
        case .save:
            let g = UINotificationFeedbackGenerator()
            g.notificationOccurred(.success)
        case .skip:
            let g = UIImpactFeedbackGenerator(style: .light)
            g.impactOccurred()
        }
    }

    /// Heart (save) / skip stamp that fades in on the top card as it's
    /// dragged, signalling what releasing now will do.
    @ViewBuilder
    private var swipeStamp: some View {
        let w = dragOffset.width
        let mag = Double(min(abs(w) / 90, 1))
        ZStack {
            if w > 6 {
                stampBadge("heart.fill", color: AppTheme.successGreen)
                    .rotationEffect(.degrees(-12))
                    .opacity(mag)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if w < -6 {
                stampBadge("forward.fill", color: AppTheme.accentAction)
                    .rotationEffect(.degrees(12))
                    .opacity(mag)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .padding(22)
        .allowsHitTesting(false)
    }

    private func stampBadge(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .heavy))
            .foregroundColor(color)
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(color, lineWidth: 3)
            )
    }

    /// First-run swipe tutorial overlaid on the deck.
    private var coachOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                coachChip("forward.fill", "Skip", fill: AppTheme.accentAction)
                coachChip("heart.fill", "Save", fill: AppTheme.successGreen)
            }
            Text("Swipe right to save, left to skip. 🔥")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.top, 8)
            Spacer().frame(height: 30)
        }
        .scaleEffect(coachPulse && !reduceMotion ? 1.04 : 1.0)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func coachChip(_ systemName: String, _ text: String, fill: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(fill.opacity(0.92)))
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            Text("\(places.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.primary)
                .monospacedDigit()
            Text(places.count == 1 ? "place left" : "places left")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 4)
    }
}

/// Shown in the card-stack slot once every visited place has been swiped.
/// Mirrors `emptyFeedPlaceholder`'s styling so it reads as part of the app.
struct SwipeDeckEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("🔥").font(.system(size: 40))
            Text("You're all caught up")
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Text("Sorry man, we're running out of new places — keep hunting! 🔥")
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// Positions the card that's flying off-screen. Tracks the same translation
/// + rotation rules as a top-card drag, but lives outside the stack so it
/// can animate without disturbing the deck behind it.
private struct ExitTransform: ViewModifier {
    let translation: CGSize

    func body(content: Content) -> some View {
        content
            .offset(x: translation.width, y: translation.height)
            .rotationEffect(.degrees(Double(translation.width / 18)))
    }
}

/// Positions a card within the swipe deck. Top card (rel = 0) follows the
/// drag offset + rotates. Back cards sit smaller and lower; as the top card
/// drags, they interpolate toward the front to give the "next one rises"
/// feel that makes the deck feel alive.
private struct StackTransform: ViewModifier {
    let rel: Int
    let dragOffset: CGSize

    func body(content: Content) -> some View {
        let dragMag = min(abs(dragOffset.width) / 110, 1)
        let baseScale = 1.0 - CGFloat(rel) * 0.06
        let baseY = CGFloat(rel) * 14
        let scale = baseScale + CGFloat(rel) * 0.06 * dragMag
        let yOffset = baseY - CGFloat(rel) * 14 * dragMag

        let isTop = rel == 0
        let xT = isTop ? dragOffset.width : 0
        let yT = isTop ? dragOffset.height : yOffset
        let rotation = isTop ? Double(dragOffset.width / 18) : 0
        let opacity = isTop ? 1.0 : max(0.45, 0.88 - Double(rel) * 0.14)

        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .offset(x: xT, y: yT)
            .opacity(opacity)
            .allowsHitTesting(isTop)
    }
}
