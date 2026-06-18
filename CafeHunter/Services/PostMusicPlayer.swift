import AVFoundation
import Foundation

/// Plays a post's attached Spotify preview clip as background music while the
/// post is the active card in the feed, and previews a track in the picker.
///
/// This is intentionally small: a single looping `AVQueuePlayer`. It is NOT a
/// global now-playing controller — no lock-screen, no background-audio mode.
/// Music only plays while a music post is on-screen and the feed is unmuted.
///
/// Owned by `HeroPageView` (a sibling of `camera`) and shared with the picker
/// so previewing and feed playback never run at once.
@MainActor
@Observable
final class PostMusicPlayer {

    private(set) var isPlaying = false
    /// The preview URL currently loaded — used by the picker to show which row
    /// is playing and by the feed to avoid restarting the same clip.
    private(set) var currentURL: String?

    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    /// Identifies the latest build request so a slow off-main build for a
    /// now-stale clip (fast scroll) can't attach over a newer one.
    private var buildToken = UUID()

    // MARK: Feed-driven

    /// Called by `HeroPageView` whenever the active card, mute state, or scene
    /// phase changes. Plays the active post's song when one exists and the feed
    /// is audible; otherwise stops.
    func update(activePost: FriendPost?, muted: Bool, scenePhaseActive: Bool) {
        guard let music = activePost?.music, !muted, scenePhaseActive else {
            stop()
            return
        }
        play(urlString: music.previewURL)
    }

    // MARK: Picker preview

    /// Toggle preview of a track in the picker (tap again to stop).
    func togglePreview(urlString: String) {
        if currentURL == urlString, isPlaying {
            stop()
        } else {
            play(urlString: urlString)
        }
    }

    func isPreviewing(_ urlString: String) -> Bool {
        currentURL == urlString && isPlaying
    }

    // MARK: Core

    /// Builds the player **off the main thread** (mirrors `SquareVideoFillView`)
    /// so settling on a music post never blocks the pager. The 30s clip is read
    /// from `AudioCache` when present (instant, no network), the audio session
    /// is activated off-main, and only the lightweight `AVQueuePlayer` swap
    /// happens on main. `currentURL` stays the ORIGINAL preview URL (identity)
    /// even when we play the cached local file.
    private func play(urlString: String) {
        if currentURL == urlString, isPlaying { return }
        teardownPlayer()
        guard let remote = URL(string: urlString) else { return }

        // Optimistic state on main → the vinyl disc starts spinning immediately.
        currentURL = urlString
        isPlaying = true
        let token = UUID()
        buildToken = token

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let playURL = AudioCache.shared.cachedFileURL(for: remote) ?? remote
            Self.activateSession()
            let item = AVPlayerItem(asset: AVURLAsset(url: playURL))
            DispatchQueue.main.async {
                guard let self, self.buildToken == token else { return }
                let player = AVQueuePlayer()
                // Start as soon as there's anything to play; these clips are
                // short and loop. Seamless loop without per-end notifications.
                player.automaticallyWaitsToMinimizeStalling = false
                self.looper = AVPlayerLooper(player: player, templateItem: item)
                self.queuePlayer = player
                player.play()
            }
        }
    }

    /// Pause + drop the current player WITHOUT touching the audio session — used
    /// when switching clips so we don't churn `setActive` on every scroll.
    private func teardownPlayer() {
        queuePlayer?.pause()
        looper?.disableLooping()
        looper = nil
        queuePlayer = nil
    }

    func stop() {
        let wasActive = queuePlayer != nil || isPlaying
        teardownPlayer()
        buildToken = UUID()        // invalidate any in-flight build
        currentURL = nil
        isPlaying = false
        guard wasActive else { return }
        // Deactivate off the main thread so stopping during a scroll never hitches.
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    /// `.playback` so the song is audible past the silent switch (TikTok /
    /// Instagram behavior). No `.mixWithOthers`: the song is THE audio while a
    /// music post is on-screen. Safe to call off the main thread.
    nonisolated private static func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}
