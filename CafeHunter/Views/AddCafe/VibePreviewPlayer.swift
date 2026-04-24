import AVFoundation
import Observation

/// Plays a 15-second slice of a VibeTrack's iTunes preview URL. Only one
/// track at a time — calling `toggle(_:)` starts a new track (stopping any
/// current playback) or pauses if the same track is already playing.
@Observable
final class VibePreviewPlayer {
    /// Track id currently loaded in the player. nil = no track loaded.
    private(set) var playingTrackID: Int?
    /// 0…1 progress over the 15-second cap.
    private(set) var progress: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?

    /// Maximum preview length we play before auto-stopping. Keeps the
    /// "taste test" quick — user can fully audition a song in <15s.
    private let maxSeconds: Double = 15

    /// Tap handler for a track row. Starts the track if it's not playing,
    /// stops it if it is.
    func toggle(_ track: VibeTrack) {
        if playingTrackID == track.id {
            stop()
        } else {
            play(track)
        }
    }

    func play(_ track: VibeTrack) {
        stop()

        // Allow playback through silent switch — previews are user-initiated.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let url = URL(string: track.previewURL) else { return }
        let player = AVPlayer(url: url)
        self.player = player
        self.playingTrackID = track.id
        self.progress = 0

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        self.timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.progress = min(1.0, seconds / self.maxSeconds)
            if seconds >= self.maxSeconds {
                self.stop()
            }
        }

        player.play()
    }

    func stop() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        playingTrackID = nil
        progress = 0
    }

    func isPlaying(_ track: VibeTrack) -> Bool {
        playingTrackID == track.id
    }

    deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        player?.pause()
    }
}
