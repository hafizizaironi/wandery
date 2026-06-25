import SwiftUI

enum NotoEmojiLottie {
    /// Maps an emoji string to its Noto CDN slug via the full catalog.
    static func notoSlug(for reactionEmoji: String) -> String? {
        catalog.first(where: { $0.emoji == reactionEmoji })?.slug
    }

    /// Full catalog of emoji–slug pairs available from the Noto animated CDN.
    static let catalog: [(emoji: String, slug: String)] = [
        // Joy & love
        ("😀", "1f600"), ("😂", "1f602"), ("🤣", "1f923"), ("🥰", "1f970"),
        ("😍", "1f60d"), ("🤩", "1f929"), ("😎", "1f60e"), ("🥳", "1f973"),
        // Sad / surprised / silly
        ("😢", "1f622"), ("😭", "1f62d"), ("🤯", "1f92f"), ("🥺", "1f97a"),
        ("😮", "1f62e"), ("😴", "1f634"), ("🤡", "1f921"), ("👻", "1f47b"),
        // Hands & gestures
        ("👍", "1f44d"), ("👎", "1f44e"), ("👏", "1f44f"), ("🙌", "1f64c"),
        ("💪", "1f4aa"), ("✊", "270a"), ("🤞", "1f91e"), ("🤙", "1f919"),
        // Hearts
        ("❤️", "2764"), ("🧡", "1f9e1"), ("💛", "1f49b"), ("💚", "1f49a"),
        ("💙", "1f499"), ("💜", "1f49c"),
        // Celebration & energy
        ("🔥", "1f525"), ("💯", "1f4af"), ("✨", "2728"), ("🎉", "1f389"),
        ("💥", "1f4a5"), ("🌟", "1f31f"),
    ]
}

struct NotoEmojiLottieView: View {
    let notoSlug: String
    let fallbackEmoji: String
    var size: CGFloat = 28
    var loop: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Renders the system emoji as plain `Text`. This previously animated the
    /// Noto emoji via Lottie, but the prebuilt `lottie-spm` binary hard-crashed
    /// inside `LottieAnimation.from(data:strategy:)` (ABI mismatch with the
    /// current Swift toolchain) — an uncatchable fault `try?` couldn't guard —
    /// so the dependency was removed and we always render the system emoji.
    var body: some View {
        Text(fallbackEmoji)
            .font(.system(size: size))
            .frame(width: size, height: size)
            .accessibilityLabel(fallbackEmoji)
    }
}
