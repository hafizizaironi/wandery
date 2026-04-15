import AVFoundation
import SwiftUI

/// Live camera feed using `AVCaptureVideoPreviewLayer` as a **sublayer** (more reliable than replacing `layerClass`).
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    var isRunning: Bool
    /// Increment before a physical lens swap; triggers a `CATransition` fade to cover the blank frame.
    var lensSwitchToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastLensSwitchToken: Int = 0
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Apply a crossfade before a physical lens swap to hide the blank frame between inputs.
        if lensSwitchToken != context.coordinator.lastLensSwitchToken {
            context.coordinator.lastLensSwitchToken = lensSwitchToken
            let transition = CATransition()
            transition.duration = 0.35
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            transition.type = .fade
            uiView.previewLayer.add(transition, forKey: "lensSwitch")
        }
        _ = isRunning
        uiView.previewLayer.session = session
        uiView.previewLayer.videoGravity = .resizeAspectFill
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    final class PreviewUIView: UIView {

        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            backgroundColor = .black
            layer.insertSublayer(previewLayer, at: 0)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            let r = bounds
            guard r.width.isFinite, r.height.isFinite, r.width > 1, r.height > 1 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = r
            CATransaction.commit()
            if let connection = previewLayer.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}
