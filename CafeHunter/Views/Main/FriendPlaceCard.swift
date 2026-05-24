import SwiftUI

/// Tinder-style hero card for one `FriendPlace`. Used inside the visited-
/// places sheet carousel — photo fills the card, name + social proof
/// overlay the lower third, whole card is the tap target.
struct FriendPlaceCard: View {
    let place: FriendPlace
    let onTap: () -> Void

    private var heroURL: URL? {
        guard let post = place.mostRecent else { return nil }
        let urlString = post.isVideo ? (post.thumbnailURL ?? post.mediaURL) : post.mediaURL
        return URL(string: urlString)
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
        // `Color.clear` flexes to fill the ZStack frame; the image is
        // placed as `.overlay` so its reported size matches the clear
        // anchor instead of the image's intrinsic .fill expansion.
        Color.clear
            .overlay {
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

/// Tinder-style card stack of `FriendPlaceCard`s. The top card responds to
/// a horizontal `DragGesture` with rotation; the next two cards peek behind
/// with reduced scale + downward offset, rising forward as the drag
/// progresses. Past `exitThreshold`, the top card flies off and the deck
/// advances by one (modulo for free wrap-around). Tap on the top card →
/// `onTap(place)`.
struct FriendPlaceCarousel: View {
    let places: [FriendPlace]
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

    var body: some View {
        VStack(spacing: 10) {
            cardStack
            indicator
        }
        .onChange(of: places.map(\.id)) { _, _ in
            // Filter switched — reset to the top of the new list.
            topIndex = 0
            dragOffset = .zero
        }
    }

    private var cardStack: some View {
        ZStack {
            // Reversed so back cards are laid down first; zIndex still
            // explicitly set in case ZStack ordering inverts.
            ForEach((0..<visibleDepth).reversed(), id: \.self) { rel in
                let idx = (topIndex + rel) % max(places.count, 1)
                FriendPlaceCard(place: places[idx]) {
                    // Only the top card opens place-detail on tap — back
                    // cards are non-interactive. Also bail if a drag
                    // happened: a Button inside a parent
                    // `.simultaneousGesture` fires its tap on touch-up
                    // even after meaningful drag motion, which would
                    // misfire place-detail every time the user swiped.
                    guard rel == 0, !dragHappened else { return }
                    onTap(places[idx])
                }
                .modifier(StackTransform(rel: rel, dragOffset: dragOffset))
                .zIndex(Double(visibleDepth - rel))
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
                }
            }
            .onEnded { value in
                let absDistance = abs(value.translation.width)
                let absPredicted = abs(value.predictedEndTranslation.width)
                let velocityDominates = absPredicted > absDistance
                let shouldExit =
                    (absDistance > exitDistanceThreshold ||
                     absPredicted > exitVelocityThreshold) &&
                    places.count > 1

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
        let leaving = places[topIndex]
        // Atomic instant: move the leaving card into the exiting overlay
        // (starting at the current drag translation, so the hand-off is
        // seamless), advance the stack, and reset the drag. No animation
        // context wraps this — the deck snaps into its new state.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            exitingPlace = leaving
            exitTranslation = translation
            topIndex = (topIndex + 1) % max(places.count, 1)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            var clearT = Transaction()
            clearT.disablesAnimations = true
            withTransaction(clearT) {
                exitingPlace = nil
                exitTranslation = .zero
            }
        }
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            Text("\(topIndex + 1)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.primary)
                .monospacedDigit()
            Text("of \(places.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.bottom, 4)
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
