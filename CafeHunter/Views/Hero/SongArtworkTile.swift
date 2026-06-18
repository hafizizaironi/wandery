import SwiftUI

extension Color {
    /// The music feature's neon-green accent (green-on-black set). Shared by the
    /// composer music control, the feed cover tile, and the artwork tile.
    static let musicNeon = Color(red: 0.27, green: 1.0, blue: 0.44)
}

/// The album-cover tile for a post's attached song. Shared by the composer
/// (top-right "selected song" control) and the feed (top-right of the photo)
/// so the two can't drift. Neon-green edge + soft glow to read as the music
/// accent; falls back to a `music.note` tile when the track has no artwork.
struct SongArtworkTile: View {
    let artworkURL: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let s = artworkURL, let u = URL(string: s) {
                CachedAsyncImage(url: u) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFill() }
                    else { Color.black.opacity(0.65) }
                }
            } else {
                ZStack {
                    Color.black.opacity(0.65)
                    Image(systemName: "music.note").foregroundStyle(Color.musicNeon)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.musicNeon.opacity(0.9), lineWidth: 1))
        .shadow(color: Color.musicNeon.opacity(0.6), radius: 6)
    }
}
