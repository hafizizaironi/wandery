import SwiftUI

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
    @State private var flyingPost: FriendPost?
    @State private var flyingOffset: CGSize = .zero
    @State private var flyingRotation: Double = 0

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
        .background(AppTheme.surfaceCanvas.ignoresSafeArea())
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
            Text(place.type.emoji).font(.system(size: 28))
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(visitsLine)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
            }
            .buttonStyle(.plain)
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
        HStack(spacing: 10) {
            navButton(
                title: "Google Maps",
                systemImage: "map.fill",
                appURL: URL(string: "comgooglemaps://?q=\(place.lat),\(place.lng)&center=\(place.lat),\(place.lng)&zoom=16"),
                webURL: URL(string: "https://www.google.com/maps/search/?api=1&query=\(place.lat),\(place.lng)")
            )
            navButton(
                title: "Waze",
                systemImage: "car.fill",
                appURL: URL(string: "waze://?ll=\(place.lat),\(place.lng)&navigate=yes"),
                webURL: URL(string: "https://waze.com/ul?ll=\(place.lat),\(place.lng)&navigate=yes")
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func navButton(title: String, systemImage: String,
                           appURL: URL?, webURL: URL?) -> some View {
        Button {
            openMapsURL(appURL: appURL, webURL: webURL)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(AppTheme.surfacePrimary, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.borderSubtle, lineWidth: 1))
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
        if friendCount == 1 { return "\(n) visits by 1 friend" }
        return "\(n) visits by \(friendCount) friends"
    }

    private var stack: some View {
        GeometryReader { geo in
            let cardSide = min(geo.size.width - 64, 360)
            // 0 → 1 progress used to advance back cards toward the front as
            // the user drags. 140pt feels like a natural "halfway committed"
            // point on iPhone.
            let dragMagnitude = max(abs(dragOffset.width), abs(dragOffset.height))
            let progress = min(dragMagnitude / 140, 1)
            ZStack {
                // Resident stack — keyed by post.id so each card retains its
                // identity (and loaded image) across topIndex changes.
                ForEach(visiblePosts, id: \.post.id) { entry in
                    cardView(post: entry.post,
                             stackPos: entry.stackPos,
                             side: cardSide,
                             progress: progress)
                }
                // Departing card during a swipe-off, rendered above the stack.
                if let flying = flyingPost {
                    PostStackCard(post: flying)
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
        .task { await runHintIfNeeded() }
    }

    private struct StackEntry {
        let post: FriendPost
        let stackPos: Int
    }

    /// Up to 3 cards (front + 2 peeks), starting at `topIndex` and wrapping.
    private var visiblePosts: [StackEntry] {
        let n = place.posts.count
        guard n > 0 else { return [] }
        let depth = min(3, n)
        return (0..<depth).map { i in
            let idx = (topIndex + i) % n
            return StackEntry(post: place.posts[idx], stackPos: i)
        }
    }

    private func cardView(post: FriendPost, stackPos: Int,
                          side: CGFloat, progress: CGFloat) -> some View {
        // While a fly-off is mid-flight, no resident card claims `isFront` —
        // the new top card sits flush at scale=1, y=0 thanks to its baseline
        // values, and the lifted card on top owns the drag/rotation state.
        let isFront = stackPos == 0 && flyingPost == nil
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
        return PostStackCard(post: post)
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
            .gesture(cardGesture(post: post, stackPos: stackPos))
    }

    /// Single gesture attached to every card. Drag-to-swipe when `stackPos`
    /// is 0; tap-to-front when it's a back card. Kept as one gesture so the
    /// modifier chain doesn't restructure when `stackPos` changes.
    private func cardGesture(post: FriendPost, stackPos: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard stackPos == 0, flyingPost == nil else { return }
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
                    guard flyingPost == nil else { return }
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
                    guard let target = place.posts.firstIndex(where: { $0.id == post.id }) else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        topIndex = target
                        dragOffset = .zero
                    }
                }
            }
    }

    private func completeSwipe(direction: CGSize) {
        let n = place.posts.count
        guard n > 0 else { return }
        let frontPost = place.posts[topIndex]
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
        flyingPost = frontPost
        // Advance the resident stack instantly. The next card was already
        // mounted as a back card with progress≈1 → scale=1, y=0; it now
        // simply becomes stackPos=0. Its AsyncImage is untouched.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            topIndex = (topIndex + 1) % n
            dragOffset = .zero
        }
        // Now animate only the lifted card off-screen.
        withAnimation(.easeOut(duration: 0.28)) {
            flyingOffset = CGSize(width: flyX, height: flyY)
            // Add a final tilt as the card flies away.
            flyingRotation = useHorizontal ? signX * 18 : flyingRotation
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            flyingPost = nil
            flyingOffset = .zero
            flyingRotation = 0
        }
    }

    /// Subtle one-shot wiggle of the front card on first appearance, so the
    /// user knows it's swipeable. Skipped if there's only one card or if the
    /// user has already touched the stack.
    private func runHintIfNeeded() async {
        guard !didHint, place.posts.count > 1 else { return }
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !didHint else { return }
        withAnimation(.easeInOut(duration: 0.45)) { hintOffset = 14 }
        try? await Task.sleep(nanoseconds: 480_000_000)
        guard !didHint else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.5)) { hintOffset = 0 }
        try? await Task.sleep(nanoseconds: 600_000_000)
        didHint = true
    }
}

/// Single post card inside the place-detail stack.
private struct PostStackCard: View {
    let post: FriendPost

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            mediaLayer
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            metaOverlay
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    private var mediaLayer: some View {
        Group {
            if let urlString = post.thumbnailURL ?? .some(post.mediaURL),
               let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
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
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            AppTheme.surfacePrimary
            Image(systemName: "photo")
                .font(.system(size: 32))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var metaOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text("@\(post.authorUsername)")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            if !post.caption.isEmpty {
                Text(post.caption)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
            }
            Text(relativeTime)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
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

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: post.createdAt, relativeTo: Date())
    }
}
