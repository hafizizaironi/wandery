import AVFoundation
import SwiftUI
import UIKit

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
            if let connection = previewLayer.connection {
                let angle = Self.rotationAngleForInterface()
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                // Front camera defaults to mirrored; turn off so preview matches saved photo/video.
                // Must disable automatic mirroring before setting `isVideoMirrored` or the runtime throws.
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
        }

        /// Align preview with the active window orientation (fixed **90** often caused letterboxing on some devices).
        private static func rotationAngleForInterface() -> CGFloat {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                return 90
            }
            let orientation: UIInterfaceOrientation
            if #available(iOS 26.0, *) {
                orientation = scene.effectiveGeometry.interfaceOrientation
            } else {
                orientation = scene.interfaceOrientation
            }
            switch orientation {
            case .portrait: return 90
            case .portraitUpsideDown: return 270
            case .landscapeLeft: return 0
            case .landscapeRight: return 180
            default: return 90
            }
        }
    }
}
