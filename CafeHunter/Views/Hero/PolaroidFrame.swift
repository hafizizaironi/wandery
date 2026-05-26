import SwiftUI

// MARK: - PolaroidFrame
//
// Wraps a square media view (image, video, or live camera) in a cream
// paper polaroid frame: slight tilt, soft drop shadow, washi-tape
// accents at the top corners, and a slim bottom strip carrying the
// @username and a small monospaced date stamp.
//
// Caption + location are rendered as floating liquid-glass pills
// OVER the photo, not inside the cream strip. The frame takes them
// as overlay closures so the caller can reuse the project's existing
// pill views (placeTagPill, captionPillBody) without re-implementing
// the liquid-glass chrome.
//
// Layout (P3 placement):
//   ┌─────────────────────────────────┐  ← washi tape top corners
//   │ ┌─────────────────────────────┐ │
//   │ │ [📍 Place ]                 │ │  ← topLeading overlay
//   │ │                             │ │
//   │ │         (photo)             │ │
//   │ │                             │ │
//   │ │        [Its 2:44]           │ │  ← bottomCenter overlay
//   │ └─────────────────────────────┘ │
//   │ @feez            26 · 05 · 26   │  ← bottom strip
//   └─────────────────────────────────┘
//
// Used in three places:
//   1. heroFeedPostPage    — wraps FeedPostCard, passes post.placeName
//                            + post.caption as overlay pills.
//   2. captureReviewSquare — wraps the captured photo/video, passes
//                            placeTagPill + captionPillBody as overlays.
//   3. heroEmptyFeedPage   — optional, wraps the empty-state placeholder
//                            with `showTape: false, tilt: 0`.

struct PolaroidFrame<Content: View, TopLeading: View, BottomCenter: View>: View {

    // MARK: - Public configuration

    /// Username shown in the bottom strip ("@feez"). Pass nil to hide.
    let username: String?

    /// Optional date stamp shown on the right of the bottom strip.
    /// Formatted as "DD · MM · YY".
    let date: Date?

    /// Slight rotation in degrees. -1.8 is the project default; pass 0
    /// for the empty-state placeholder.
    var tilt: Double = -1.8

    /// Show washi tape strips at the top corners. Default true.
    var showTape: Bool = true

    /// The photo's side length. The cream frame is drawn OUTSIDE this, so the
    /// photo keeps its full size and the frame may bleed past the layout slot.
    var photoSide: CGFloat

    /// The square media — typically a FeedPostCard, captured image,
    /// or live preview. Sized to `photoSide`; the cream card wraps around it.
    @ViewBuilder var content: () -> Content

    /// Liquid-glass pill rendered on the photo's top-left corner.
    /// Typically the location chip ("📍 Sup Kambing Ayam"). Pass
    /// `EmptyView()` to omit.
    @ViewBuilder var topLeading: () -> TopLeading

    /// Liquid-glass pill rendered centered along the photo's bottom
    /// edge. Typically the caption pill ("Its 2:44"). Pass `EmptyView()`
    /// to omit (e.g. when caption is empty).
    @ViewBuilder var bottomCenter: () -> BottomCenter

    // MARK: - Layout constants

    private let sidePadding:   CGFloat = 14
    private let topPadding:    CGFloat = 14
    private let bottomPadding: CGFloat = 44   // slim — only carries @user + date
    private let cornerRadius:  CGFloat = 4

    private let pillEdgeInset: CGFloat = 10   // pill inset from photo edge

    private var frameColor: Color {
        // Warm cream — matches the Wandery brand palette.
        Color(red: 0.957, green: 0.925, blue: 0.864)
    }

    // MARK: - Body

    var body: some View {
        // The card is sized OUTSIDE the photo: the photo stays `photoSide`
        // (full size) and the cream border + bottom strip extend beyond it.
        // The whole view's intrinsic size is cardW × cardH; callers wrap it in
        // the original square slot so it bleeds past the edges without shifting
        // surrounding layout.
        let cardW = photoSide + sidePadding * 2
        let cardH = topPadding + photoSide + bottomPadding

        ZStack(alignment: .top) {
            // 1. Paper card
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(frameColor)
                .frame(width: cardW, height: cardH)
                .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 10)
                .shadow(color: .black.opacity(0.30), radius: 4,  x: 0, y: 2)

            // 2. Photo + overlays — full `photoSide`
            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: photoSide, height: photoSide)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                    }

                // 2a. Location pill — top-leading
                topLeading()
                    .padding(.top, pillEdgeInset)
                    .padding(.leading, pillEdgeInset)

                // 2b. Caption pill — bottom-center
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        bottomCenter()
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: photoSide, height: photoSide)
                .padding(.bottom, pillEdgeInset)
            }
            .frame(width: photoSide, height: photoSide)
            .padding(.top, topPadding)

            // 3. Bottom strip — username (left) + date (right)
            bottomStrip(width: cardW)
                .frame(width: cardW, height: bottomPadding - 14)
                .offset(y: topPadding + photoSide + 4)

            // 4. Washi tape (decorative)
            if showTape {
                washiTape
                    .accessibilityHidden(true)
            }
        }
        .frame(width: cardW, height: cardH)
        .rotationEffect(.degrees(tilt))
    }

    // MARK: - Bottom strip

    @ViewBuilder
    private func bottomStrip(width: CGFloat) -> some View {
        HStack(alignment: .center) {
            if let username {
                Text(username)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .kerning(1)
                    .foregroundStyle(Color.black.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let date {
                Text(date, format: .dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(1.5)
                    .foregroundStyle(Color.black.opacity(0.4))
                    .textCase(.uppercase)
            }
        }
        .padding(.horizontal, sidePadding + 2)
    }

    // MARK: - Washi tape

    @ViewBuilder
    private var washiTape: some View {
        ZStack(alignment: .top) {
            // Left tape — persimmon
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.85, green: 0.42, blue: 0.25).opacity(0.55),
                            Color(red: 0.85, green: 0.42, blue: 0.25).opacity(0.40),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 64, height: 22)
                .overlay {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .rotationEffect(.degrees(-8))
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                .offset(x: -90, y: -10)

            // Right tape — olive
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.37, green: 0.44, blue: 0.26).opacity(0.55),
                            Color(red: 0.37, green: 0.44, blue: 0.26).opacity(0.40),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 56, height: 20)
                .overlay {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .rotationEffect(.degrees(7))
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                .offset(x: 90, y: -8)
        }
    }
}

// MARK: - Convenience initialiser for the common case

extension PolaroidFrame where TopLeading == AnyView, BottomCenter == AnyView {

    /// Convenience for the feed-card case: pass the post's caption +
    /// place name as plain strings and the initialiser wraps them in
    /// the project's `liquidGlassChrome(in: Capsule())` pills.
    ///
    /// Use the full initialiser with `topLeading:` / `bottomCenter:`
    /// closures when you need an editable TextField (capture review)
    /// or a tappable Button (jumping to the place on the map).
    init(
        username: String?,
        date: Date?,
        placeName: String?,
        caption: String?,
        tilt: Double = -1.8,
        showTape: Bool = true,
        photoSide: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.username = username
        self.date = date
        self.tilt = tilt
        self.showTape = showTape
        self.photoSide = photoSide
        self.content = content

        self.topLeading = {
            AnyView(
                Group {
                    if let placeName {
                        HStack(spacing: 5) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 11, weight: .bold))
                            Text(placeName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(.ultraThinMaterial)
                        )
                        .overlay(
                            Capsule().fill(
                                Color(red: 0.85, green: 0.42, blue: 0.25).opacity(0.20)
                            )
                        )
                        .overlay(
                            Capsule().stroke(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.85, green: 0.42, blue: 0.25),
                                        Color(red: 0.85, green: 0.42, blue: 0.25).opacity(0.55),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.25
                            )
                        )
                        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
                    } else {
                        EmptyView()
                    }
                }
            )
        }

        self.bottomCenter = {
            AnyView(
                Group {
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(.subheadline).bold()
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(.ultraThinMaterial)
                            )
                            .overlay(
                                Capsule().fill(
                                    Color(red: 0.85, green: 0.42, blue: 0.25).opacity(0.20)
                                )
                            )
                            .overlay(
                                Capsule().stroke(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.85, green: 0.42, blue: 0.25),
                                            Color(red: 0.85, green: 0.42, blue: 0.25).opacity(0.55),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.25
                                )
                            )
                            .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
                    } else {
                        EmptyView()
                    }
                }
            )
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PolaroidFrame_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PolaroidFrame(
                username: "@feez",
                date: Date(),
                placeName: "Sup Kambing Ayam",
                caption: "Its 2:44",
                photoSide: 300
            ) {
                LinearGradient(
                    colors: [.orange, .red.opacity(0.6), .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .frame(width: 300, height: 300)
            .padding(40)
        }
        .previewDevice("iPhone 15 Pro")
    }
}
#endif
