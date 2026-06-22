import SwiftUI
import CoreLocation

/// Bottom sheet shown when a friend pin on the map is tapped.
/// Header = place metadata. Body = card stack of every friend post at the
/// place; most recent is the front-most card. Cards lazy-load media URLs
/// (no thumbnail prefetch — these are typically <50 entries per place).
struct PlaceDetailSheet: View {
    let place: FriendPlace
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    /// Topmost visible card in the stack. Tap a back card to bring it forward;
    /// swipe the front card to reveal the next.
    @State private var topIndex: Int = 0
    /// Live drag translation of the front card. Drives the card itself plus
    /// the "advance" interpolation of the back cards.
    @State private var dragOffset: CGSize = .zero
    /// Synthetic offset used by the first-appearance wiggle. Set to non-zero
    /// once briefly to telegraph that the front card is swipeable, then reset.
    @State private var hintOffset: CGFloat = 0
    /// Latches once the user touches the card or the wiggle finishes, so the
    /// hint never replays and never fights a real drag.
    @State private var didHint = false
    /// While a swipe-off is animating, the departing post is rendered in a
    /// separate overlay layer keyed by its own id. This lets us advance
    /// `topIndex` instantly so the next card (which was already mounted as a
    /// back card with its AsyncImage loaded) becomes the front WITHOUT
    /// SwiftUI swapping the URL on the front-slot view — that swap is what
    /// was producing the mid-swipe image flicker.
    @State private var flyingCard: PlaceCard?
    /// True while we resolve a Google `place_id` for an app-created place
    /// before opening Google Maps (shows a spinner on that button).
    @State private var resolvingMaps = false

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng)
    }
    @State private var flyingOffset: CGSize = .zero
    @State private var flyingRotation: Double = 0
    /// Shared hydrator for post-author avatars. Prefetched on appear so the
    /// avatar corner never renders empty even for one frame.
    @State private var hydrator = ParticipantHydrator()

    /// Card ids the user has already swiped away. Once this covers the whole
    /// deck (or the card now on top is one they've already seen), we surface a
    /// gentle "you've looped" toast — the stack itself wraps forever, so this
    /// is the only signal that there's nothing new left.
    @State private var swipedIds: Set<String> = []
    @State private var showLoopHint = false
    @State private var loopHintTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            navButtons
            Divider().opacity(0.2)
            stack
                .padding(.vertical, 16)
            Spacer(minLength: 0)
        }
        .task {
            hydrator.prefetch(place.posts.map(\.authorId))
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 38, height: 4)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(place.type.emoji)
                .font(.title)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                Text(visitsLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Two-button row: open the place in Google Maps or Waze. Tries the
    /// app-scheme URL first; if the target app isn't installed iOS reports
    /// `success == false` and we fall back to the universal-link web URL,
    /// which both Google and Waze redirect to their app via universal links
    /// when present (or open in the browser otherwise).
    private var navButtons: some View {
        let waze = MapsNavigation.waze(name: place.name, coordinate: coordinate)
        return HStack(spacing: 10) {
            // Google Maps: route to the exact POI by Google place_id. For an
            // app-created place (no stored id) we first resolve one by
            // name+coordinate — hence the async tap + spinner — and fall back
            // to the coordinate if there's no confident match.
            navButtonLabel(title: "Google Maps", systemImage: "map.fill", loading: resolvingMaps) {
                Task { await openGoogleMaps() }
            }
            .disabled(resolvingMaps)

            // Waze has no place-id concept: search the name centered on the
            // coordinate; Waze matches the named POI near there or routes to
            // the coordinate when there's no distinct match.
            navButton(title: "Waze", systemImage: "car.fill", appURL: waze.app, webURL: waze.web)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Google Maps: use the stored `googlePlaceId` when present, otherwise
    /// resolve one by name+coordinate; `MapsNavigation` falls back to the
    /// coordinate when there's still no id.
    private func openGoogleMaps() async {
        AnalyticsService.shared.log(.openGoogleMaps, area: .placeDetail)
        var placeId = place.googlePlaceId
        if placeId?.isEmpty ?? true {
            resolvingMaps = true
            placeId = await PlacePickerService.shared.resolveGooglePlaceId(name: place.name, near: coordinate)
            resolvingMaps = false
        }
        let urls = MapsNavigation.googleMaps(name: place.name, coordinate: coordinate, googlePlaceId: placeId)
        openMapsURL(appURL: urls.app, webURL: urls.web)
    }

    private func navButton(title: String, systemImage: String,
                           appURL: URL?, webURL: URL?) -> some View {
        Button {
            openMapsURL(appURL: appURL, webURL: webURL)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.footnote).bold()
                Text(title)
                    .font(.footnote).bold()
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            // Project-wide Liquid Glass chrome — matches the sheet
            // panel + every other floating button in the app.
            .liquidGlassChrome(in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Same chrome as `navButton`, but driven by an action closure and able to
    /// show a spinner (used by the Google Maps button while it resolves a
    /// place_id).
    private func navButtonLabel(title: String, systemImage: String, loading: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.footnote).bold()
                }
                Text(title)
                    .font(.footnote).bold()
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .liquidGlassChrome(in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func openMapsURL(appURL: URL?, webURL: URL?) {
        if let appURL {
            openURL(appURL) { success in
                if !success, let webURL { openURL(webURL) }
            }
        } else if let webURL {
            openURL(webURL)
        }
    }

    private var visitsLine: String {
        // Use the server-side visit counter so multiple posts in one
        // sitting count as a single visit, matching the rest of the UI.
        // Posts.count fallback covers the moments before the place doc
        // hydrates with its real counter.
        let visits = max(place.globalVisitCount, 0)
        let n = visits > 0 ? visits : place.posts.count
        let friendCount = Set(place.posts.map(\.authorId)).count
        if n == 1 { return "1 visit" }
        // No friend posts here (came in from Trending or a synthesized fallback)
        // — drop the "by N friends" tail rather than reporting "by 0 friends".
        if friendCount == 0 { return "\(n) visits" }
        if friendCount == 1 { return "\(n) visits by 1 friend" }
        return "\(n) visits by \(friendCount) friends"
    }

    @ViewBuilder
    private var stack: some View {
        if cards.isEmpty {
            emptyStack
        } else {
            populatedStack
        }
    }

    private var populatedStack: some View {
        GeometryReader { geo in
            let cardSide = min(geo.size.width - 64, 360)
            // 0 → 1 progress used to advance back cards toward the front as
            // the user drags. 140pt feels like a natural "halfway committed"
            // point on iPhone.
            let dragMagnitude = max(abs(dragOffset.width), abs(dragOffset.height))
            let progress = min(dragMagnitude / 140, 1)
            ZStack {
                // Resident stack — keyed by the (post, media) card id so each
                // card retains its identity (and loaded image) across topIndex
                // changes, even when several cards come from the same post.
                ForEach(visibleCards, id: \.card.id) { entry in
                    cardView(card: entry.card,
                             stackPos: entry.stackPos,
                             side: cardSide,
                             progress: progress)
                }
                // Departing card during a swipe-off, rendered above the stack.
                if let flying = flyingCard {
                    PostStackCard(
                        post: flying.post,
                        media: flying.media,
                        hydrator: hydrator,
                        shouldBlur: place.postsAreFallback && !flying.post.discoverable,
                        // The departing card flies off in 0.28s — its thumbnail
                        // is fine; don't spin a player just to throw it away.
                        isActive: false
                    )
                        .frame(width: cardSide, height: cardSide)
                        .offset(flyingOffset)
                        .rotationEffect(.degrees(flyingRotation))
                        .zIndex(100)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(height: 360)
        .overlay(alignment: .top) {
            if showLoopHint { loopHintPill }
        }
        .task {
            prefetchUpcomingVideos()
            await runHintIfNeeded()
        }
    }

    /// Warm the front + next couple of tagged videos into `VideoCache` so the
    /// player builds from a local file (no network hitch) the instant a card
    /// becomes the front card. Off-drag, `.utility` priority, dedup handled by
    /// the cache — mirrors `HeroPageView.prefetchFeedVideos`.
    private func prefetchUpcomingVideos() {
        let deck = cards
        guard !deck.isEmpty else { return }
        for offset in 0..<min(3, deck.count) {
            let media = deck[(topIndex + offset) % deck.count].media
            guard media.isVideo, let url = URL(string: media.url) else { continue }
            Task.detached(priority: .utility) { _ = await VideoCache.shared.prefetch(url) }
        }
    }

    /// Friendly "you've seen them all" toast. Wording adapts to a single-photo
    /// place ("the only photo here") vs a looped multi-card deck.
    private var loopHintPill: some View {
        HStack(spacing: 6) {
            Image(systemName: cards.count <= 1 ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.bold))
            Text(loopHintText)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var loopHintText: String {
        cards.count <= 1
            ? "That's the only photo here"
            : "You've seen all \(cards.count) — back to the start"
    }

    /// Fades the loop toast in, then out after a beat. Re-triggering resets the
    /// timer so rapid repeat-swipes keep it visible without stacking timers.
    private func showLoopHintBriefly() {
        loopHintTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showLoopHint = true }
        loopHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) { showLoopHint = false }
        }
    }

    /// Shown when there's nothing left to display — either no one has posted
    /// here, or every author chose to keep their visits private. Calm
    /// "nothing to see" copy rather than a hard error.
    private var emptyStack: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.55))
            Text("No photos to show here yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Friends of yours haven't posted here, and visitors at this place chose to keep their photos private.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }

    /// One card in the stack = a single tagged photo at this place. A post
    /// with several photos tagged here fans out into several cards.
    private struct PlaceCard: Identifiable, Equatable {
        let post: FriendPost
        let media: PostMedia
        // post.id is unique per post; media.url is unique within a post →
        // the composite is globally unique AND stable, so the AsyncImage
        // identity is retained across topIndex changes (no mid-swipe flicker).
        var id: String { "\(post.id)|\(media.url)" }
    }

    private struct StackEntry {
        let card: PlaceCard
        let stackPos: Int
    }

    /// Flattened deck for this place: one card per photo tagged here, in
    /// post-recency then display order. `place.posts` stays the source for the
    /// visit/friend counts (`visitsLine`) — a post is one visit, not one per
    /// photo — so we only fan out for the card stack.
    private var cards: [PlaceCard] {
        place.posts.flatMap { post -> [PlaceCard] in
            let tagged = post.media.filter { $0.placeId == place.id }
            // Legacy / untagged-media posts reach this place only via the
            // top-level placeId fallback in `distinctPlaceIds` → show their
            // single primary item.
            let items = tagged.isEmpty ? Array(post.media.prefix(1)) : tagged
            return items.map { PlaceCard(post: post, media: $0) }
        }
    }

    /// Up to 3 cards (front + 2 peeks), starting at `topIndex` and wrapping.
    private var visibleCards: [StackEntry] {
        let deck = cards
        let n = deck.count
        guard n > 0 else { return [] }
        let depth = min(3, n)
        return (0..<depth).map { i in
            let idx = (topIndex + i) % n
            return StackEntry(card: deck[idx], stackPos: i)
        }
    }

    private func cardView(card: PlaceCard, stackPos: Int,
                          side: CGFloat, progress: CGFloat) -> some View {
        // While a fly-off is mid-flight, no resident card claims `isFront` —
        // the new top card sits flush at scale=1, y=0 thanks to its baseline
        // values, and the lifted card on top owns the drag/rotation state.
        let isFront = stackPos == 0 && flyingCard == nil
        let baseScale = 1.0 - CGFloat(stackPos) * 0.04
        let baseOffsetY = CGFloat(stackPos) * 12
        // Back cards lerp toward (scale=1, y=0) as the front is dragged away,
        // so the next card appears to "rise" into place rather than pop.
        let advancedScale = baseScale + (1 - baseScale) * progress
        let advancedY = baseOffsetY * (1 - progress)
        let frontX = dragOffset.width + hintOffset
        let frontY = dragOffset.height
        // CRITICAL: a single unbranched modifier chain. An `if/else` that
        // attaches different gestures per branch counts as two structural
        // subtrees in SwiftUI — flipping branches destroys the loaded
        // AsyncImage and reloads it, which is what produced the post-swipe
        // spinner. Always attach the same DragGesture and gate behavior
        // inside its handlers.
        return PostStackCard(
            post: card.post,
            media: card.media,
            hydrator: hydrator,
            shouldBlur: place.postsAreFallback && !card.post.discoverable,
            // Playback follows stack POSITION, not `isFront` — `isFront` is gated
            // on `flyingCard == nil`, which stays non-nil for ~300ms after a
            // swipe, so gating playback on it would stall the incoming front
            // card's video. Position-only means it plays the instant topIndex
            // advances. The departing overlay card is passed isActive:false, so
            // there's still only one player.
            isActive: stackPos == 0
        )
            .frame(width: side, height: side)
            .scaleEffect(isFront ? 1.0 : advancedScale)
            .offset(
                x: isFront ? frontX : 0,
                y: isFront ? frontY : advancedY
            )
            // Tilt the front card a few degrees in the drag direction for a
            // more tactile, deck-of-cards feel.
            .rotationEffect(isFront ? .degrees(Double(frontX) / 22) : .zero)
            .opacity(isFront ? 1 : (0.85 + 0.15 * progress))
            .zIndex(Double(3 - stackPos))
            .gesture(cardGesture(card: card, stackPos: stackPos))
    }

    /// Single gesture attached to every card. Drag-to-swipe when `stackPos`
    /// is 0; tap-to-front when it's a back card. Kept as one gesture so the
    /// modifier chain doesn't restructure when `stackPos` changes.
    private func cardGesture(card: PlaceCard, stackPos: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard stackPos == 0, flyingCard == nil else { return }
                if !didHint {
                    didHint = true
                    hintOffset = 0
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                let dragMag = max(abs(value.translation.width),
                                  abs(value.translation.height))
                if stackPos == 0 {
                    guard flyingCard == nil else { return }
                    let throwMag = max(abs(value.predictedEndTranslation.width),
                                       abs(value.predictedEndTranslation.height))
                    if dragMag > 90 || throwMag > 220 {
                        completeSwipe(direction: value.translation)
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                            dragOffset = .zero
                        }
                    }
                } else if dragMag <= 4 {
                    // Treat near-stationary drag as a tap on a back card.
                    guard let target = cards.firstIndex(where: { $0.id == card.id }) else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        topIndex = target
                        dragOffset = .zero
                    }
                }
            }
    }

    private func completeSwipe(direction: CGSize) {
        let deck = cards
        let n = deck.count
        guard n > 0 else { return }
        let frontCard = deck[topIndex]
        let dx = direction.width
        let dy = direction.height
        let useHorizontal = abs(dx) >= abs(dy)
        let signX: CGFloat = dx >= 0 ? 1 : -1
        let signY: CGFloat = dy >= 0 ? 1 : -1
        let flyX = useHorizontal ? signX * 720 : dx * 2.5
        let flyY = useHorizontal ? dy * 2.5 : signY * 720
        // Hand the in-progress drag state off to the lifted overlay BEFORE
        // touching topIndex/dragOffset, so the user sees no positional jump.
        flyingOffset = dragOffset
        flyingRotation = Double(dragOffset.width) / 22
        flyingCard = frontCard
        // Advance the resident stack instantly. The next card was already
        // mounted as a back card with progress≈1 → scale=1, y=0; it now
        // simply becomes stackPos=0. Its AsyncImage is untouched.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            topIndex = (topIndex + 1) % n
            dragOffset = .zero
        }
        // Warm the next window now that the deck advanced.
        prefetchUpcomingVideos()
        // Track what's been seen. If the deck has now fully cycled (or the card
        // that just rose to the front is one we've already swiped), nudge the
        // user that there's nothing new — the stack itself just loops silently.
        swipedIds.insert(frontCard.id)
        let nowFront = deck[topIndex]
        if n == 1 || swipedIds.count >= n || swipedIds.contains(nowFront.id) {
            showLoopHintBriefly()
        }
        // Now animate only the lifted card off-screen.
        withAnimation(.easeOut(duration: 0.28)) {
            flyingOffset = CGSize(width: flyX, height: flyY)
            // Add a final tilt as the card flies away.
            flyingRotation = useHorizontal ? signX * 18 : flyingRotation
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            flyingCard = nil
            flyingOffset = .zero
            flyingRotation = 0
        }
    }

    /// Subtle one-shot wiggle of the front card on first appearance, so the
    /// user knows it's swipeable. Skipped if there's only one card or if the
    /// user has already touched the stack.
    private func runHintIfNeeded() async {
        guard !didHint, cards.count > 1 else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !didHint else { return }
        withAnimation(.easeInOut(duration: 0.45)) { hintOffset = 14 }
        try? await Task.sleep(for: .milliseconds(480))
        guard !didHint else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.5)) { hintOffset = 0 }
        try? await Task.sleep(for: .milliseconds(600))
        didHint = true
    }
}

/// Single photo card inside the place-detail stack. `media` is the specific
/// item tagged to this place (a post can contribute several), so the card
/// shows that photo rather than always the post's primary one.
private struct PostStackCard: View {
    let post: FriendPost
    let media: PostMedia
    let hydrator: ParticipantHydrator
    /// True when the parent stack came from the public-discoverable fallback
    /// AND this specific post wasn't approved by the classifier. Renders the
    /// media layer blurred so the card still appears (the new-user flow
    /// would otherwise see an empty stack) while preserving the privacy
    /// signal the trending grid already shows.
    var shouldBlur: Bool = false
    /// True only for the front card. Only the active card builds a video
    /// player; back/peek cards render the cheap poster thumbnail, so at most
    /// one AVPlayer is ever alive in the stack (see prefetchUpcomingVideos).
    var isActive: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            mediaLayer
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            metaOverlay
        }
        // Author avatar pinned to the top-right corner — replaces the
        // `@username` text that used to live in the bottom overlay.
        .overlay(alignment: .topTrailing) {
            ParticipantAvatar(
                participant: hydrator.participant(for: post.authorId),
                uid: post.authorId,
                size: 38
            )
            .overlay {
                Circle().stroke(Color.white.opacity(0.55), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 2)
            .padding(12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    private var mediaLayer: some View {
        // Resident poster/thumbnail base + (only for the active video card) a
        // clear-backed player ON TOP. Keeping the thumbnail always mounted means
        // its loaded image is never torn down when the card toggles active, and
        // it shows THROUGH the player while it builds — no thumbnail→black→video
        // pop on swipe. The player's `.clear` background reveals the poster until
        // the first frame decodes; once playing, resizeAspectFill covers it.
        // Peek/back cards (isActive == false) and gated (`shouldBlur`) posts have
        // no player at all, so at most one AVPlayer is alive in the stack.
        ZStack {
            thumbnailLayer
            if media.isVideo, isActive, !shouldBlur, let u = URL(string: media.url) {
                SquareVideoFillView(url: u, isPlaying: scenePhase == .active,
                                    muted: true, backgroundColor: .clear)
            }
        }
    }

    /// `displayURL` resolves to the video thumbnail for videos and the image url
    /// otherwise — the specific photo tagged to this place. Always mounted (see
    /// `mediaLayer`); privacy-gated posts render it blurred with a lock chip.
    private var thumbnailLayer: some View {
        Group {
            if let url = URL(string: media.displayURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    @unknown default:
                        placeholder
                    }
                }
                .blur(radius: shouldBlur ? 22 : 0)
                .overlay {
                    if shouldBlur {
                        // Slight dim so the blur reads as intentional, plus a
                        // lock chip with truthful copy: blur lifts when the
                        // viewer is friends with the author, not when "some
                        // friend visits this place" (the old wording was
                        // misleading — see Hafiz 2026-05-28).
                        ZStack {
                            Color.black.opacity(0.10)
                            VStack(spacing: 6) {
                                Image(systemName: "lock.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.85))
                                Text("Only visible to the author's circle")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.78))
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            AppTheme.surfacePrimary
            Image(systemName: "photo")
                .font(.title)
                .foregroundStyle(AppTheme.textSecondary)
                .accessibilityHidden(true)
        }
    }

    private var metaOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            // Prefer this photo's own caption; fall back to the post caption.
            if let caption = media.caption ?? (post.caption.isEmpty ? nil : post.caption),
               !caption.isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            }
            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
    }

    /// Reused across rows so each card doesn't pay for formatter setup.
    /// `RelativeDateTimeFormatter` instantiation is non-trivial; this
    /// shaves a few ms off body-eval when the place sheet renders a
    /// stack of post cards.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var relativeTime: String {
        Self.relativeFormatter.localizedString(for: post.createdAt, relativeTo: .now)
    }
}
