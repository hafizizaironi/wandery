import Foundation

// Decodable DTOs for the Spotify Web API responses the poster's picker needs.
// Field names are kept snake_case to match the API verbatim (no key-decoding
// strategy), so `preview_url` / `display_name` read exactly as returned.

struct SpotifyImage: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

struct SpotifyTrack: Decodable, Identifiable {
    let id: String
    let name: String
    let preview_url: String?
    let artists: [Artist]
    let album: Album

    struct Artist: Decodable { let name: String }
    struct Album: Decodable { let name: String; let images: [SpotifyImage] }

    var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    /// Smallest-acceptable artwork (last image is typically 64px) falling back
    /// to the first; nil if the album carries no images.
    var artworkURL: String? { album.images.last?.url ?? album.images.first?.url }
    /// Only tracks with a non-empty preview can be used as post music.
    var isPlayable: Bool { (preview_url?.isEmpty == false) }

    /// Convert to the model stored on the post. nil when no playable preview.
    func toPostMusic() -> PostMusic? {
        guard let preview = preview_url, !preview.isEmpty else { return nil }
        return PostMusic(trackId: id, trackName: name, artistName: artistNames,
                         artworkURL: album.images.first?.url, previewURL: preview)
    }
}

struct SpotifyPlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let images: [SpotifyImage]
    var artworkURL: String? { images.first?.url }
}

struct SpotifyPaging<T: Decodable>: Decodable {
    let items: [T]
    let next: String?
}

struct SpotifySearchResponse: Decodable {
    let tracks: SpotifyPaging<SpotifyTrack>?
}

/// A playlist's track entries — `track` is nullable (removed/unavailable items).
struct SpotifyPlaylistItem: Decodable { let track: SpotifyTrack? }

/// A "Liked Songs" entry — wraps the track under `track`.
struct SpotifySavedTrackItem: Decodable { let track: SpotifyTrack? }

struct SpotifyUser: Decodable {
    let id: String
    let display_name: String?
}

struct SpotifyTokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let refresh_token: String?
    let scope: String?
}
