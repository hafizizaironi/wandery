import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Fills a square frame like `resizeAspectFill` (SwiftUI `VideoPlayer` often letterboxes).
struct SquareVideoFillView: UIViewRepresentable {

    let url: URL
    /// When `false`, the player is paused (e.g. feed video off-screen in a pager). Defaults to `true` for capture preview.
    var isPlaying: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
    }

    func makeUIView(context: Context) -> VideoFillContainerView {
        let v = VideoFillContainerView()
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
    }
}

final class VideoFillContainerView: UIView {

    private let playerLayer = AVPlayerLayer()
    /// Strong reference so looping keeps working (`AVPlayerLooper` does not retain the template item forever in all cases).
    private var looper: AVPlayerLooper?

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
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
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

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
