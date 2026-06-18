import Foundation

/// A normalized track row for the music picker, independent of source. Spotify
/// supplies the user's library/metadata; the playable 30s `previewURL` comes
/// from whichever source has one (Spotify rarely does anymore — see below).
struct PickerTrack: Identifiable, Equatable {
    let id: String
    let name: String
    let artist: String
    let artworkURL: String?
    /// nil until resolved. Spotify's `preview_url` is null for most tracks on
    /// newer apps, so this is usually filled lazily from `MusicPreviewResolver`.
    var previewURL: String?

    func toPostMusic(trackId: String? = nil) -> PostMusic? {
        guard let preview = previewURL, !preview.isEmpty else { return nil }
        return PostMusic(trackId: trackId ?? id, trackName: name,
                         artistName: artist, artworkURL: artworkURL, previewURL: preview)
    }
}

extension SpotifyTrack {
    var asPickerTrack: PickerTrack {
        PickerTrack(id: id, name: name, artist: artistNames,
                    artworkURL: artworkURL,
                    previewURL: (preview_url?.isEmpty == false) ? preview_url : nil)
    }
}

/// Resolves playable 30-second preview clips via Apple's **iTunes Search API**
/// (public, no auth, HTTPS — ATS-clean). This is the fallback for Spotify's
/// `preview_url` deprecation: Spotify still gives us the user's library + search
/// metadata, and we match each track to an iTunes `previewUrl` for the audio.
/// It also powers the picker's Search tab directly (reliable + always playable).
enum MusicPreviewResolver {

    private struct ITunesResponse: Decodable { let results: [ITunesSong] }
    private struct ITunesSong: Decodable {
        let trackId: Int?
        let trackName: String?
        let artistName: String?
        let previewUrl: String?
        let artworkUrl100: String?
    }

    private static func endpoint(term: String, limit: Int) -> URL? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            .init(name: "term", value: term),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: String(limit)),
        ]
        return comps?.url
    }

    private static func fetch(_ url: URL) async -> [ITunesSong] {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let resp = try? JSONDecoder().decode(ITunesResponse.self, from: data)
        else { return [] }
        return resp.results
    }

    // MARK: - Trending (Apple "most-played" chart)

    private struct AppleRSSResponse: Decodable {
        struct Feed: Decodable { let results: [Song] }
        struct Song: Decodable {
            let id: String?
            let name: String?
            let artistName: String?
            let artworkUrl100: String?
        }
        let feed: Feed
    }

    /// Currently-trending songs from Apple's public "most-played" chart (no auth,
    /// no subscription, daily-updated). Spotify's trending/charts endpoints were
    /// deprecated for new third-party apps, so this powers the picker's default
    /// page. Rows carry no preview URL — it's resolved from iTunes Search on tap
    /// (same on-demand path the Liked/Playlists rows use).
    static func topCharts(limit: Int = 50) async -> [PickerTrack] {
        // Try the device's storefront first; fall back to US if that region has
        // no chart (or the request fails).
        let primary = storefront()
        var rows = await chart(storefront: primary, limit: limit)
        if rows.isEmpty && primary != "us" {
            rows = await chart(storefront: "us", limit: limit)
        }
        return rows
    }

    private static func chart(storefront: String, limit: Int) async -> [PickerTrack] {
        guard let url = URL(string:
            "https://rss.applemarketingtools.com/api/v2/\(storefront)/music/most-played/\(limit)/songs.json")
        else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let resp = try? JSONDecoder().decode(AppleRSSResponse.self, from: data)
        else { return [] }
        return resp.feed.results.compactMap { song in
            guard let name = song.name, let artist = song.artistName else { return nil }
            return PickerTrack(
                id: song.id ?? "\(name)|\(artist)",
                name: name, artist: artist,
                artworkURL: song.artworkUrl100,
                previewURL: nil   // resolved on tap via iTunes Search
            )
        }
    }

    /// Lowercased ISO region for the Apple RSS storefront (e.g. `my`, `us`).
    private static func storefront() -> String {
        let region = Locale.current.region?.identifier.lowercased()
        return (region?.isEmpty == false) ? region! : "us"
    }

    /// Search the iTunes catalog for songs. Every returned row is playable
    /// (carries a `previewURL`) — this backs the picker's Search tab.
    static func search(term: String, limit: Int = 25) async -> [PickerTrack] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let url = endpoint(term: q, limit: limit) else { return [] }
        return await fetch(url).compactMap { song in
            guard let name = song.trackName, let artist = song.artistName,
                  let preview = song.previewUrl, !preview.isEmpty else { return nil }
            return PickerTrack(
                id: song.trackId.map(String.init) ?? "\(name)|\(artist)",
                name: name, artist: artist,
                artworkURL: song.artworkUrl100, previewURL: preview
            )
        }
    }

    /// Resolve a 30s preview (+ artwork) for a known Spotify track by matching
    /// name + artist against iTunes. Returns nil if no match has a preview.
    static func resolvePreview(name: String, artist: String) async -> (previewURL: String, artworkURL: String?)? {
        let primaryArtist = artist.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? artist
        guard let url = endpoint(term: "\(name) \(primaryArtist)", limit: 8) else { return nil }
        let results = await fetch(url).filter { $0.previewUrl?.isEmpty == false }
        let lowerName = name.lowercased()
        let lowerArtist = primaryArtist.lowercased()
        // Prefer a row whose name AND artist match; fall back to first playable.
        let best = results.first(where: {
            ($0.trackName?.lowercased().contains(lowerName) ?? false) &&
            ($0.artistName?.lowercased().contains(lowerArtist) ?? false)
        }) ?? results.first(where: { $0.trackName?.lowercased().contains(lowerName) ?? false })
            ?? results.first
        guard let song = best, let preview = song.previewUrl else { return nil }
        return (preview, song.artworkUrl100)
    }
}
