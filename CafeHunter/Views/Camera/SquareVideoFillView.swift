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

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspectFill
        layer.insertSublayer(playerLayer, at: 0)
    }

    required init?(coder: NSCoder) { nil }

    func setLoopingVideo(url: URL, shouldPlay: Bool) {
        (playerLayer.player as? AVQueuePlayer)?.pause()
        looper = nil
        // Play the locally-cached file when we have it (instant, no network);
        // otherwise stream the remote URL. `VideoCache.cachedFileURL` is a
        // synchronous existence check, safe to call here.
        let playURL = VideoCache.shared.cachedFileURL(for: url) ?? url
        let item = AVPlayerItem(url: playURL)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = muted
        // Start as soon as there's anything to show rather than waiting to
        // build a large buffer — these clips are short and loop.
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        playerLayer.player = queuePlayer
        if shouldPlay {
            queuePlayer.play()
        } else {
            queuePlayer.pause()
        }
    }

    func setPlayback(shouldPlay: Bool) {
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
