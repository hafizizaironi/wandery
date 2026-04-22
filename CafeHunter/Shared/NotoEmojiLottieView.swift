import Lottie
import SwiftUI

enum NotoEmojiLottie {
    private static let cdnBase = URL(string: "https://fonts.gstatic.com/s/e/notoemoji/latest/")!

    static func lottieURL(notoCodepointHex: String) -> URL {
        cdnBase.appendingPathComponent(notoCodepointHex).appendingPathComponent("lottie.json")
    }

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

    var body: some View {
        Group {
            if reduceMotion {
                Text(fallbackEmoji)
                    .font(.system(size: size))
            } else {
                lottie
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(fallbackEmoji)
    }

    @ViewBuilder
    private var lottie: some View {
        LottieView {
            // URLSession + explicit decoding strategy: required for lottie-spm binary (avoids default-arg symbols).
            let url = NotoEmojiLottie.lottieURL(notoCodepointHex: notoSlug)
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                return nil
            }
            return try LottieAnimation.from(data: data, strategy: .dictionaryBased)
        } placeholder: {
            Text(fallbackEmoji)
                .font(.system(size: size))
        }
        .playbackMode(
            .playing(
                .fromProgress(0, toProgress: 1, loopMode: loop ? .loop : .playOnce)
            )
        )
        .resizable()
        .frame(width: size, height: size)
    }
}
