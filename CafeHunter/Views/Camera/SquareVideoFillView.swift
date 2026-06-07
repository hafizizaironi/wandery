import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Fills a square frame like `resizeAspectFill` (SwiftUI `VideoPlayer` often letterboxes).
struct SquareVideoFillView: UIViewRepresentable {

    let url: URL
    /// When `false`, the player is paused (e.g. feed video off-screen in a pager). Defaults to `true` for capture preview.
    var isPlaying: Bool = true
    /// Mutes the audio track. Defaults to `false` so the capture-review
    /// preview keeps sound; the feed passes the user's global mute preference.
    var muted: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
    }

    func makeUIView(context: Context) -> VideoFillContainerView {
        let v = VideoFillContainerView()
        v.setMuted(muted)
        context.coordinator.lastURL = url
        v.setLoopingVideo(url: url, shouldPlay: isPlaying)
        return v
    }

    func updateUIView(_ uiView: VideoFillContainerView, context: Context) {
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            uiView.setLoopingVideo(url: url, shouldPlay: isPlaying)
        } else {
            uiView.setPlayback(shouldPlay: isPlaying)
        }
        uiView.setMuted(muted)
    }
}

final class VideoFillContainerView: UIView {

    private let playerLayer = AVPlayerLayer()
    /// Strong reference so looping keeps working (`AVPlayerLooper` does not retain the template item forever in all cases).
    private var looper: AVPlayerLooper?
    private var muted = false
    /// Identifies the latest load request so a slow async build for a now-stale
    /// URL can't clobber a newer one when the user scrolls quickly.
    private var buildToken = UUID()
    /// Latest desired play state — applied when the async-built player attaches.
    private var desiredPlaying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspectFill
        layer.insertSublayer(playerLayer, at: 0)
    }

    required init?(coder: NSCoder) { nil }

    /// Builds the player **off the main thread** so swapping a feed card's video
    /// never blocks the scroll. Constructing the `AVPlayerItem` parses the clip
    /// header (disk or network I/O) — doing that synchronously inside
    /// `makeUIView` froze the slide mid-page as the paging window shifted. The
    /// previous player stays attached (showing its last frame) until the new one
    /// is ready, so the swap has no black gap.
    func setLoopingVideo(url: URL, shouldPlay: Bool) {
        desiredPlaying = shouldPlay
        let token = UUID()
        buildToken = token
        let isMuted = muted
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Play the locally-cached file when we have it (instant, no network);
            // otherwise stream the remote URL. `cachedFileURL` is a synchronous
            // existence check — now off-main, so it's free of the scroll.
            let playURL = VideoCache.shared.cachedFileURL(for: url) ?? url
            let item = AVPlayerItem(asset: AVURLAsset(url: playURL))
            DispatchQueue.main.async {
                guard let self, self.buildToken == token else { return }
                (self.playerLayer.player as? AVQueuePlayer)?.pause()
                let queuePlayer = AVQueuePlayer()
                queuePlayer.isMuted = isMuted
                // Start as soon as there's anything to show rather than waiting
                // to build a large buffer — these clips are short and loop.
                queuePlayer.automaticallyWaitsToMinimizeStalling = false
                self.looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
                self.playerLayer.player = queuePlayer
                if self.desiredPlaying { queuePlayer.play() } else { queuePlayer.pause() }
            }
        }
    }

    func setPlayback(shouldPlay: Bool) {
        desiredPlaying = shouldPlay
        guard let q = playerLayer.player as? AVQueuePlayer else { return }
        if shouldPlay {
            q.play()
        } else {
            q.pause()
        }
    }

    func setMuted(_ m: Bool) {
        muted = m
        (playerLayer.player as? AVQueuePlayer)?.isMuted = m
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
