import SwiftUI

extension Color {
    /// Shared neon green for the music feature (composer button + picker panel).
    static let musicNeon = Color(red: 0.27, green: 1.0, blue: 0.44)
    /// Matte dark backdrop for the music picker panel.
    static let musicPanelDark = Color(red: 0.05, green: 0.06, blue: 0.05)
}

/// The poster's song picker, opened from the composer's music button.
///
/// Source split (because Spotify nulls `preview_url` for most tracks now):
/// - **Search** queries Apple's iTunes catalog directly → every result is
///   instantly playable.
/// - **Liked / Playlists** browse the user's own Spotify library; the playable
///   30s clip is resolved on demand from iTunes (`MusicPreviewResolver`) when a
///   row is previewed or chosen.
struct SpotifyMusicPickerView: View {
    let spotifyAuth: SpotifyAuthService
    let player: PostMusicPlayer
    var onPick: (PostMusic) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Tab: Hashable { case trending, search, liked, playlists }
    @State private var tab: Tab = .trending
    @State private var query = ""
    @State private var tracks: [PickerTrack] = []
    @State private var playlists: [SpotifyPlaylist] = []
    @State private var loading = false
    @State private var resolvingID: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Trending").tag(Tab.trending)
                    Text("Search").tag(Tab.search)
                    Text("Liked").tag(Tab.liked)
                    Text("Playlists").tag(Tab.playlists)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if tab == .search { searchField }

                content
            }
            .navigationTitle("Add music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { player.stop(); dismiss() }
                        .tint(Color.musicNeon)
                }
            }
        }
        // Matte dark sheet with a green outline (no glow) — inherits the music
        // button's dark + green look, panel-scale.
        .environment(\.colorScheme, .dark)
        .presentationBackground {
            Color.musicPanelDark.overlay(
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 10,
                                       style: .continuous)
                    .strokeBorder(Color.musicNeon.opacity(0.5), lineWidth: 1)
            )
        }
        // Live iTunes search debounce.
        .task(id: query) {
            guard tab == .search else { return }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { tracks = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await runSearch(q)
        }
        // Load the browse tabs (and reset state) when the tab changes.
        .task(id: tab) {
            tracks = []; playlists = []; errorText = nil
            switch tab {
            case .trending:  await loadTrending()
            case .search:
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty { await runSearch(q) }
            case .liked:     await loadLiked()
            case .playlists: await loadPlaylists()
            }
        }
        .onDisappear { player.stop() }
    }

    // MARK: Subviews

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.musicNeon.opacity(0.8))
            TextField("Songs, artists…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Matte dark capsule + green outline — mirrors the composer button.
        .background(Color.black.opacity(0.4), in: Capsule())
        .overlay(Capsule().stroke(Color.musicNeon.opacity(0.55), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().tint(Color.musicNeon)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            messageState(icon: "exclamationmark.triangle", text: errorText)
        } else if tab == .playlists {
            playlistList
        } else if tracks.isEmpty {
            emptyTracksState
        } else {
            trackList
        }
    }

    @ViewBuilder
    private var emptyTracksState: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab == .trending {
            messageState(icon: "chart.line.uptrend.xyaxis", text: "Couldn't load trending songs. Pull to retry or search instead.")
        } else if tab == .search && q.isEmpty {
            messageState(icon: "magnifyingglass", text: "Search for a song to add.")
        } else if tab == .search {
            messageState(icon: "magnifyingglass", text: "No songs found for “\(q)”.")
        } else {
            messageState(icon: "music.note", text: "No songs here yet.")
        }
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(tracks) { track in
                    MusicTrackRow(
                        track: track,
                        isPreviewing: track.previewURL.map { player.isPreviewing($0) } ?? false,
                        isResolving: resolvingID == track.id,
                        onPreview: { Task { await preview(track) } },
                        onUse: { Task { await use(track) } }
                    )
                    Divider().overlay(Color.musicNeon.opacity(0.15))
                }
            }
            .padding(.top, 4)
        }
    }

    private var playlistList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(playlists) { pl in
                    NavigationLink {
                        SpotifyPlaylistTracksView(
                            spotifyAuth: spotifyAuth, player: player, playlist: pl,
                            onPick: { music in player.stop(); onPick(music); dismiss() }
                        )
                    } label: {
                        HStack(spacing: 12) {
                            TrackArtwork(urlString: pl.artworkURL)
                            Text(pl.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.musicNeon.opacity(0.15))
                }
            }
            .padding(.top, 4)
        }
    }

    private func messageState(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AppTheme.textSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: Loads

    private func runSearch(_ q: String) async {
        loading = true; errorText = nil
        defer { loading = false }
        tracks = await MusicPreviewResolver.search(term: q)
    }

    private func loadLiked() async {
        loading = true; errorText = nil
        defer { loading = false }
        do { tracks = try await spotifyAuth.savedTracks().map(\.asPickerTrack) }
        catch { errorText = friendly(error) }
    }

    private func loadPlaylists() async {
        loading = true; errorText = nil
        defer { loading = false }
        do { playlists = try await spotifyAuth.myPlaylists() }
        catch { errorText = friendly(error) }
    }

    private func loadTrending() async {
        loading = true; errorText = nil
        defer { loading = false }
        tracks = await MusicPreviewResolver.topCharts()
    }

    // MARK: Preview / pick (resolve iTunes audio on demand)

    private func preview(_ track: PickerTrack) async {
        if let url = track.previewURL { player.togglePreview(urlString: url); return }
        guard let resolved = await resolve(track), let url = resolved.previewURL else {
            errorText = "Couldn't find a preview for “\(track.name)”."
            return
        }
        player.togglePreview(urlString: url)
    }

    private func use(_ track: PickerTrack) async {
        let final: PickerTrack
        if track.previewURL != nil { final = track }
        else if let r = await resolve(track) { final = r }
        else { errorText = "Couldn't find a playable preview for “\(track.name)”."; return }
        guard let music = final.toPostMusic() else { return }
        player.stop()
        onPick(music)
        dismiss()
    }

    /// Resolve the iTunes preview, cache it into `tracks`, and return the
    /// updated track (so a second tap doesn't re-resolve).
    private func resolve(_ track: PickerTrack) async -> PickerTrack? {
        resolvingID = track.id
        defer { resolvingID = nil }
        guard let (preview, _) = await MusicPreviewResolver.resolvePreview(name: track.name, artist: track.artist)
        else { return nil }
        var updated = track
        updated.previewURL = preview
        if let idx = tracks.firstIndex(where: { $0.id == track.id }) { tracks[idx] = updated }
        return updated
    }

    private func friendly(_ error: Error) -> String {
        (error as? SpotifyError)?.errorDescription ?? "Couldn't reach Spotify. Try again."
    }
}

/// Tracks of a chosen Spotify playlist — same on-demand iTunes preview resolution.
private struct SpotifyPlaylistTracksView: View {
    let spotifyAuth: SpotifyAuthService
    let player: PostMusicPlayer
    let playlist: SpotifyPlaylist
    var onPick: (PostMusic) -> Void

    @State private var tracks: [PickerTrack] = []
    @State private var loading = true
    @State private var resolvingID: String?
    @State private var errorText: String?

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(Color.musicNeon)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                Text(errorText)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tracks) { track in
                            MusicTrackRow(
                                track: track,
                                isPreviewing: track.previewURL.map { player.isPreviewing($0) } ?? false,
                                isResolving: resolvingID == track.id,
                                onPreview: { Task { await preview(track) } },
                                onUse: { Task { await use(track) } }
                            )
                            Divider().overlay(Color.musicNeon.opacity(0.15))
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { tracks = try await spotifyAuth.playlistTracks(id: playlist.id).map(\.asPickerTrack) }
            catch { errorText = (error as? SpotifyError)?.errorDescription ?? "Couldn't load this playlist." }
            loading = false
        }
        .onDisappear { player.stop() }
    }

    private func preview(_ track: PickerTrack) async {
        if let url = track.previewURL { player.togglePreview(urlString: url); return }
        guard let resolved = await resolve(track), let url = resolved.previewURL else { return }
        player.togglePreview(urlString: url)
    }

    private func use(_ track: PickerTrack) async {
        let final: PickerTrack
        if track.previewURL != nil { final = track }
        else if let r = await resolve(track) { final = r }
        else { return }
        guard let music = final.toPostMusic() else { return }
        onPick(music)
    }

    private func resolve(_ track: PickerTrack) async -> PickerTrack? {
        resolvingID = track.id
        defer { resolvingID = nil }
        guard let (preview, _) = await MusicPreviewResolver.resolvePreview(name: track.name, artist: track.artist)
        else { return nil }
        var updated = track
        updated.previewURL = preview
        if let idx = tracks.firstIndex(where: { $0.id == track.id }) { tracks[idx] = updated }
        return updated
    }
}

// MARK: - Shared row + artwork

private struct MusicTrackRow: View {
    let track: PickerTrack
    let isPreviewing: Bool
    let isResolving: Bool
    let onPreview: () -> Void
    let onUse: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TrackArtwork(urlString: track.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onPreview) {
                if isResolving {
                    ProgressView().tint(Color.musicNeon)
                } else {
                    Image(systemName: isPreviewing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.musicNeon)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 30)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onUse() }
    }
}

private struct TrackArtwork: View {
    let urlString: String?
    var body: some View {
        Group {
            if let s = urlString, let u = URL(string: s) {
                CachedAsyncImage(url: u) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.07)
                    }
                }
            } else {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "music.note").foregroundStyle(Color.musicNeon.opacity(0.7))
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
