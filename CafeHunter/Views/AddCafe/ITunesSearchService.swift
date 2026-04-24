import Foundation

// MARK: - Vibe track

/// A single track tagged to a cafe. Backed by Apple's iTunes catalogue so we
/// get free artwork + 30s previews without API keys, but we also construct a
/// Spotify search URL so listeners can open it in their player of choice.
struct VibeTrack: Codable, Equatable, Hashable, Identifiable {
    /// iTunes trackId — stable, unique.
    let id: Int
    let title: String
    let artist: String
    /// 100×100 artwork; use `artworkURL(size:)` for a larger variant.
    let artworkURL: String
    /// 30-second m4a preview served by Apple. Plays directly in AVPlayer.
    let previewURL: String
    let genre: String

    /// Swap the `100x100bb.jpg` suffix for a larger resolution variant.
    /// iTunes serves multiple sizes from the same CDN path.
    func artworkURL(size: Int) -> String {
        artworkURL.replacingOccurrences(
            of: "100x100bb",
            with: "\(size)x\(size)bb"
        )
    }

    /// Constructed open.spotify.com search URL so users can jump over to
    /// Spotify without us needing Spotify's API.
    var spotifyOpenURL: URL? {
        let query = "\(title) \(artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://open.spotify.com/search/\(query)")
    }
}

// MARK: - Service

enum ITunesSearchService {
    /// Run one iTunes song-catalogue search. Returns an empty array on any
    /// network / decode failure — never throws to the caller.
    static func search(term: String, limit: Int = 20) async -> [VibeTrack] {
        guard
            let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string:
                "https://itunes.apple.com/search?term=\(encoded)"
                + "&media=music&entity=song&limit=\(limit)")
        else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            return decoded.results.compactMap { $0.asVibeTrack }
        } catch {
            return []
        }
    }

    /// Run multiple seeded searches in parallel and merge the results, deduped
    /// by track id. Used for "Suggested for this place".
    static func mergedSearch(terms: [String], perTerm: Int = 8) async -> [VibeTrack] {
        await withTaskGroup(of: [VibeTrack].self) { group in
            for term in terms {
                group.addTask { await search(term: term, limit: perTerm) }
            }
            var seen = Set<Int>()
            var merged: [VibeTrack] = []
            for await batch in group {
                for track in batch where !seen.contains(track.id) {
                    seen.insert(track.id)
                    merged.append(track)
                }
            }
            return merged
        }
    }
}

// MARK: - Decoding

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let trackId: Int?
    let trackName: String?
    let artistName: String?
    let artworkUrl100: String?
    let previewUrl: String?
    let primaryGenreName: String?

    var asVibeTrack: VibeTrack? {
        guard
            let id = trackId,
            let title = trackName,
            let artist = artistName,
            let art = artworkUrl100,
            let preview = previewUrl
        else { return nil }
        return VibeTrack(
            id: id,
            title: title,
            artist: artist,
            artworkURL: art,
            previewURL: preview,
            genre: primaryGenreName ?? ""
        )
    }
}
