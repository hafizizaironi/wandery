import SwiftUI

// MARK: - Feed moderation modifier

/// Hosts the report-content sheet + block-user confirmation alert for the
/// Hero feed. Extracted from HeroPageView.body because attaching both
/// modifiers inline tipped the SwiftUI type-checker over its complexity
/// limit ("the compiler is unable to type-check this expression in
/// reasonable time"). Same behaviour, different attachment surface.
struct FeedModerationModifier: ViewModifier {
    @Binding var reportTarget: ReportTarget?
    @Binding var pendingBlockUid: String?
    @Binding var pendingBlockTitle: String
    @Binding var postFocus: PostFocus?
    @Binding var pendingDeletePost: FriendPost?
    var socialService: SocialService

    func body(content: Content) -> some View {
        content
            .overlay {
                if let focus = postFocus {
                    PostFocusOverlay(
                        focus: focus,
                        onDismiss: dismissFocus,
                        onReportPost: { withFocusedPost { reportTarget = ReportTarget(type: .post, targetId: $0.id) } },
                        onReportUser: { withFocusedPost { reportTarget = ReportTarget(type: .user, targetId: $0.authorId) } },
                        onBlock: { withFocusedPost { pendingBlockUid = $0.authorId; pendingBlockTitle = $0.authorUsername } },
                        onDelete: { withFocusedPost { pendingDeletePost = $0 } },
                        onHideDiscover: { withFocusedPost { p in
                            Task { try? await socialService.setDiscoverable(postId: p.id, false) }
                        } }
                    )
                }
            }
            .alert(
                "Block \(pendingBlockTitle)?",
                isPresented: Binding(
                    get: { pendingBlockUid != nil },
                    set: { if !$0 { pendingBlockUid = nil } }
                ),
                presenting: pendingBlockUid
            ) { uid in
                Button("Cancel", role: .cancel) { pendingBlockUid = nil }
                Button("Block", role: .destructive) {
                    Task {
                        try? await socialService.blockUser(uid: uid)
                        pendingBlockUid = nil
                    }
                }
            } message: { _ in
                Text("They'll be removed from your friends, can't message you, and won't appear in your feed.")
            }
            .alert(
                "Delete post?",
                isPresented: Binding(
                    get: { pendingDeletePost != nil },
                    set: { if !$0 { pendingDeletePost = nil } }
                ),
                presenting: pendingDeletePost
            ) { post in
                Button("Cancel", role: .cancel) { pendingDeletePost = nil }
                Button("Delete", role: .destructive) {
                    Task { try? await socialService.deletePost(post) }
                    pendingDeletePost = nil
                }
            } message: { _ in
                Text("This permanently deletes the post and its photo or video. This can't be undone.")
            }
            .sheet(item: $reportTarget) { target in
                ReportSheet(
                    targetType: target.type,
                    targetId: target.targetId,
                    socialService: socialService
                )
                .presentationDetents([.medium, .large])
            }
    }

    /// Runs `action` with the focused post, then closes the focus overlay.
    /// Centralizes the "act + dismiss" pattern every menu row needs.
    private func withFocusedPost(_ action: (FriendPost) -> Void) {
        guard let post = postFocus?.post else { return }
        action(post)
        dismissFocus()
    }

    private func dismissFocus() {
        withAnimation(.easeOut(duration: 0.18)) { postFocus = nil }
    }
}

// MARK: - Post focus (long-press) menu

/// Captured state for the long-press focus overlay on a feed post.
struct PostFocus: Identifiable {
    let id = UUID()
    let post:   FriendPost
    let index:  Int
    let side:   CGFloat
    let anchor: CGRect   // the post card's frame in global coordinates
    let isMine: Bool
}

extension View {
    /// Long-press a feed post to open the focus menu. Tracks the card's
    /// global frame so the overlay can lift it in place, then fires
    /// `onActivate(frame)` on a long hold. Simultaneous so it coexists with
    /// the card's multi-media swipe and vertical paging.
    func postFocusLongPress(onActivate: @escaping (CGRect) -> Void) -> some View {
        modifier(PostFocusLongPressModifier(onActivate: onActivate))
    }
}

private struct PostFocusLongPressModifier: ViewModifier {
    var onActivate: (CGRect) -> Void
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    onActivate(frame)
                }
            )
    }
}

/// Full-screen focus overlay: blurs the feed, lifts the pressed post in
/// place (crisp, over the blur), and shows the action card below it. Mirrors
/// the chat long-press menu. Hosted by `FeedModerationModifier`.
private struct PostFocusOverlay: View {
    let focus: PostFocus
    var onDismiss:      () -> Void
    var onReportPost:   () -> Void
    var onReportUser:   () -> Void
    var onBlock:        () -> Void
    var onDelete:       () -> Void
    var onHideDiscover: () -> Void

    @State private var cardSize: CGSize = .zero
    /// Drives the lift "pop": 1.0 → overshoot → settle, so the post bounces
    /// when it appears (staying ≥ 1.0 the whole time, so it never shrinks
    /// below the original and lets the blur peek around the edges).
    @State private var pop: CGFloat = 1.0
    private let gap: CGFloat = 14
    private let bottomSafe: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.1))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .transition(.opacity)

                // The pressed post, kept crisp over the blur. Cache-seeded so
                // it's opaque from frame 1, and inserted with `.identity` (no
                // fade) so it covers the original instantly — the blur can't
                // bleed through. `onAppear` then springs a visible pop via
                // `scaleEffect`, kept ≥ 1.0 so the post never shrinks below the
                // original. Removal fades as the blur clears.
                FeedPolaroidCard(post: focus.post, index: focus.index, isVideoActive: false, side: focus.side, staticPreview: true)
                    .frame(width: focus.side, height: focus.side)
                    .scaleEffect(pop)
                    .position(x: focus.anchor.midX, y: focus.anchor.midY)
                    .allowsHitTesting(false)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    .onAppear {
                        withAnimation(.spring(response: 0.16, dampingFraction: 0.6)) { pop = 1.06 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.45)) { pop = 1.0 }
                        }
                    }

                actionCard
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                    .position(cardPosition(in: geo.size))
                    .opacity(cardSize == .zero ? 0 : 1)
                    .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
    }

    /// Centered horizontally, just below the post; clamped above the bottom.
    private func cardPosition(in screen: CGSize) -> CGPoint {
        let y = focus.anchor.maxY + gap + cardSize.height / 2
        let maxY = screen.height - bottomSafe - cardSize.height / 2
        return CGPoint(x: screen.width / 2, y: min(y, maxY))
    }

    private var actionCard: some View {
        VStack(spacing: 0) {
            if focus.isMine {
                cardRow("Delete post", "trash", destructive: true, action: onDelete)
                if focus.post.discoverable {
                    Divider().opacity(0.5)
                    cardRow("Hide from Discover", "eye.slash", destructive: false, action: onHideDiscover)
                }
            } else {
                cardRow("Report post", "exclamationmark.triangle", destructive: false, action: onReportPost)
                Divider().opacity(0.5)
                cardRow("Report user", "person.crop.circle.badge.exclamationmark", destructive: false, action: onReportUser)
                Divider().opacity(0.5)
                cardRow("Block @\(focus.post.authorUsername)", "hand.raised", destructive: true, action: onBlock)
            }
        }
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private func cardRow(_ label: String, _ icon: String, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label).font(.body).lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: icon).font(.body)
            }
            .foregroundStyle(destructive ? AppTheme.errorRed : AppTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
