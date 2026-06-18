import SwiftUI

// MARK: - PlainFeedFrame
//
// The "original" (non-polaroid) feed/review card. Drop-in sibling of
// `PolaroidFrame`: identical `content` / `topLeading` / `bottomCenter`
// closure slots, so call sites can switch between the two with a single
// `if` and no other change.
//
// Renders just the square photo (rounded corners + a hairline stroke) with
// the location + caption liquid-glass pills floating over it, and a small
// leading "@username" label above the photo (no date — the polaroid's
// bottom strip is what carries the date, and this mode drops it).
//
// Layout parity with PolaroidFrame: the photo stays a full `photoSide`
// square and the username header bleeds past the layout slot, so wrapping
// this in the caller's `.frame(width: side, height: side)` keeps the
// composer below from shifting when the user toggles styles.

struct PlainFeedFrame<Content: View, TopLeading: View, BottomCenter: View>: View {

    /// Author handle shown above the photo ("@feez"). Pass nil to hide.
    let username: String?

    /// The photo's side length. Matches `PolaroidFrame.photoSide` so the
    /// image is the same size in both styles.
    var photoSide: CGFloat

    /// Optional pill on the photo's bottom-left corner (the music sticker).
    /// Same inset convention as the location/caption pills. Default = omit.
    var bottomLeading: () -> AnyView = { AnyView(EmptyView()) }

    /// Optional control on the photo's top-right corner (mirrors `topLeading`).
    /// Same inset, same level as the location pill. Default = omit.
    var topTrailing: () -> AnyView = { AnyView(EmptyView()) }

    /// The square media (image, video, or live preview), sized to `photoSide`.
    @ViewBuilder var content: () -> Content

    /// Liquid-glass pill on the photo's top-left (location chip).
    @ViewBuilder var topLeading: () -> TopLeading

    /// Liquid-glass pill centered on the photo's bottom edge (caption).
    @ViewBuilder var bottomCenter: () -> BottomCenter

    private let cornerRadius:  CGFloat = 14
    private let pillEdgeInset: CGFloat = 10
    private let captionBottomInset: CGFloat = 10  // caption sits higher off the bottom edge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let username {
                Text(username)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }

            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: photoSide, height: photoSide)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(AppTheme.borderSubtle, lineWidth: 1)
                    }

                // Location pill — top-leading.
                topLeading()
                    .padding(.top, pillEdgeInset)
                    .padding(.leading, pillEdgeInset)

                // Caption pill — bottom-center. The bottom inset lives INSIDE the
                // photoSide frame (on the HStack) so it lifts the caption off the
                // photo's bottom edge — applying it outside the frame would only
                // add empty space below the box and never move the pill.
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        bottomCenter()
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, captionBottomInset)
                }
                .frame(width: photoSide, height: photoSide)

                // Bottom-leading pill (the music sticker) — mirrors the
                // location pill's inset on the opposite (bottom-left) corner.
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        bottomLeading()
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, pillEdgeInset)
                    .padding(.bottom, captionBottomInset)
                }
                .frame(width: photoSide, height: photoSide)

                // Top-trailing control (the music button) — mirrors the
                // location pill's inset on the opposite (top-right) corner.
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        topTrailing()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, pillEdgeInset)
                .padding(.trailing, pillEdgeInset)
                .frame(width: photoSide, height: photoSide)
            }
        }
        .frame(width: photoSide)
    }
}
