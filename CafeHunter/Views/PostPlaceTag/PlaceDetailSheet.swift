import SwiftUI

/// Bottom sheet shown when a friend pin on the map is tapped.
/// Header = place metadata. Body = card stack of every friend post at the
/// place; most recent is the front-most card. Cards lazy-load media URLs
/// (no thumbnail prefetch — these are typically <50 entries per place).
struct PlaceDetailSheet: View {
    let place: FriendPlace
    let onDismiss: () -> Void

    /// Topmost visible card in the stack. Tap a back card to bring it forward;
    /// swipe the front card to reveal the next.
    @State private var topIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
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

    private var visitsLine: String {
        let n = place.posts.count
        let friendCount = Set(place.posts.map(\.authorId)).count
        if n == 1 { return "1 visit" }
        if friendCount == 1 { return "\(n) visits by 1 friend" }
        return "\(n) visits by \(friendCount) friends"
    }

    private var stack: some View {
        GeometryReader { geo in
            let cardSide = min(geo.size.width - 64, 360)
            ZStack {
                ForEach(visibleSlice.indices, id: \.self) { offsetIdx in
                    let actualIdx = topIndex + offsetIdx
                    let post = place.posts[actualIdx]
                    PostStackCard(post: post)
                        .frame(width: cardSide, height: cardSide)
                        .scaleEffect(1.0 - CGFloat(offsetIdx) * 0.04)
                        .offset(y: CGFloat(offsetIdx) * 12)
                        .zIndex(Double(visibleSlice.count - offsetIdx))
                        .opacity(offsetIdx == 0 ? 1 : 0.92)
                        .onTapGesture {
                            if offsetIdx > 0 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    topIndex = actualIdx
                                }
                            }
                        }
                        .gesture(swipeGesture(for: offsetIdx))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(height: 360)
    }

    /// Up to 3 cards rendered at once — front + 2 peeks.
    private var visibleSlice: [Int] {
        let end = min(place.posts.count, topIndex + 3)
        return Array(topIndex..<end)
    }

    private func swipeGesture(for offsetIdx: Int) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard offsetIdx == 0 else { return }
                if abs(value.translation.height) > 40 || abs(value.translation.width) > 60 {
                    advance()
                }
            }
    }

    private func advance() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            topIndex = (topIndex + 1) % max(place.posts.count, 1)
        }
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
