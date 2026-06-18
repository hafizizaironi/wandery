import SwiftUI

/// A swipeable "wardrobe" for picking the feed-card frame. Each page is a live
/// preview of a style (rendered with a built-in sample), with a "Use this style"
/// button. Admins additionally get a Publish / Unpublish control per frame that
/// releases it to every user's wardrobe (`config/frames` via `FrameCatalogService`).
struct FrameWardrobeView: View {
    /// Pages to show — admins get every style (to preview + publish); users get
    /// only what's available to them.
    let styles: [FeedCardStyle]
    let isAdmin: Bool
    var frameCatalog: FrameCatalogService
    let onClose: () -> Void

    @AppStorage(FeedCardStyle.storageKey) private var feedCardStyle: FeedCardStyle = .plain
    @State private var page = 0

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                TabView(selection: $page) {
                    ForEach(Array(styles.enumerated()), id: \.offset) { idx, style in
                        pageView(style).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: styles.count > 1 ? .always : .never))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                footer
            }
        }
        .onAppear {
            page = styles.firstIndex(of: feedCardStyle) ?? 0
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Frame style")
                .font(.system(size: 13, weight: .bold)).tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    // MARK: One page

    @ViewBuilder
    private func pageView(_ style: FeedCardStyle) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                Spacer(minLength: 12)
                FramePreviewCard(style: style)
                    .padding(.vertical, 8)
                VStack(spacing: 4) {
                    Text(style.label)
                        .font(.system(size: 24, weight: .bold, design: .serif).italic())
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(style.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.textPrimary.opacity(0.7))
                }
                if isAdmin, !style.isReleased { adminPublishControl(style) }
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    /// Admin-only release control for an unreleased (non-base) frame.
    @ViewBuilder
    private func adminPublishControl(_ style: FeedCardStyle) -> some View {
        let live = frameCatalog.releasedFrameIDs.contains(style.rawValue)
        VStack(spacing: 8) {
            Label(live ? "Live for everyone" : "Admin only",
                  systemImage: live ? "globe" : "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(live ? AppTheme.successGreen : AppTheme.textSecondary)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    if live { await frameCatalog.unpublish(style.rawValue) }
                    else    { await frameCatalog.publish(style.rawValue) }
                }
            } label: {
                Label(live ? "Unpublish" : "Publish to everyone",
                      systemImage: live ? "eye.slash" : "megaphone.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(live ? AppTheme.errorRed : AppTheme.textOnAccent)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(live ? AppTheme.errorRed.opacity(0.10) : AppTheme.cafeAccent,
                                in: Capsule())
                    .overlay { if live { Capsule().stroke(AppTheme.errorRed.opacity(0.3), lineWidth: 1) } }
            }
            .buttonStyle(.scalePress)
        }
        .padding(.top, 4)
    }

    // MARK: Footer — "Use this style"

    @ViewBuilder
    private var footer: some View {
        if styles.indices.contains(page) {
            let style = styles[page]
            let isCurrent = feedCardStyle == style
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { feedCardStyle = style }
            } label: {
                Text(isCurrent ? "✓ Current style" : "Use this style")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isCurrent ? AppTheme.textSecondary : AppTheme.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isCurrent ? AppTheme.textPrimary.opacity(0.06) : AppTheme.cafeAccent,
                                in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isCurrent)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}

// MARK: - Preview card (a specific style with sample content)

/// Renders one feed-card style with built-in sample content, reusing the real
/// `FeedCardFrame` (via `styleOverride`) so the preview matches the feed exactly.
struct FramePreviewCard: View {
    let style: FeedCardStyle
    var photoSide: CGFloat = 220

    var body: some View {
        FeedCardFrame(
            username: "@you",
            date: Date(),
            photoSide: photoSide,
            placeName: "Sample Café",
            caption: "best brew in town ☕",
            styleOverride: style
        ) {
            SampleFramePhoto()
        } topLeading: {
            samplePill(icon: "mappin.circle.fill", "Sample Café")
        } bottomCenter: {
            samplePill(icon: nil, "best brew in town ☕")
        }
    }

    /// A frosted sample pill mirroring the feed's place/caption pills.
    private func samplePill(icon: String?, _ text: String) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.caption2).bold() }
            Text(text).font(.caption).bold().lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// The stand-in "photo" used in frame previews — a warm gradient + cup glyph
/// (the `feed-photo` asset the demos referenced doesn't exist).
struct SampleFramePhoto: View {
    var body: some View {
        ZStack {
            AppTheme.cafeGradient(0)
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
