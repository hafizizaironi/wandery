import SwiftUI
import AVFoundation
import UIKit

/// Lightweight camera surface for scanning a Wandery Code. Owns its OWN
/// `AVCaptureSession` + `AVCaptureVideoDataOutput` (independent of the app's
/// main `CameraService` capture pipeline), feeds the luma plane to
/// `WanderyCodeDetector` on a serial queue, and reports a confident decode.
///
/// The analyzed buffer stays in its native landscape orientation — the code is
/// rotation-invariant (the north pin resolves rotation), so only the *preview*
/// is rotated for display.
struct WanderyCodeScannerView: UIViewControllerRepresentable {
    var onDecode: (WanderyCodeDetector.Result) -> Void
    var onFrame: ((WanderyCodeDetector.Frame) -> Void)?

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onDecode = onDecode
        vc.onFrame = onFrame
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {
        vc.onDecode = onDecode
        vc.onFrame = onFrame
    }
}

final class ScannerViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onDecode: ((WanderyCodeDetector.Result) -> Void)?
    var onFrame: ((WanderyCodeDetector.Frame) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "wandery.scanner.session")
    private let videoQueue = DispatchQueue(label: "wandery.scanner.video")

    /// Created lazily on `videoQueue` so its JSContext lives on that queue.
    private var detector: WanderyCodeDetector?
    private var frameCounter = 0
    private var fired = false

    private var previewView: PreviewView { view as! PreviewView }
    override func loadView() { view = PreviewView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        previewView.previewLayer.session = session
        previewView.previewLayer.videoGravity = .resizeAspectFill
        configureIfAuthorized()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        fired = false
        sessionQueue.async { [session] in if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Rotate the preview to portrait (cosmetic only; analysis uses the raw buffer).
        if let c = previewView.previewLayer.connection, c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
    }

    private func configureIfAuthorized() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.configureSession() }
            }
        default:
            break
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings =
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCounter &+= 1
        guard frameCounter % 3 == 0, !fired else { return }            // ~analyze every 3rd frame
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if detector == nil { detector = WanderyCodeDetector() }        // first frame: build JSContext here

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let baseRaw = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let base = baseRaw.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)

        let result = detector?.analyze(base: base, width: w, height: h, bytesPerRow: bpr)
        let frame = detector?.lastFrame

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let frame { self.onFrame?(frame) }
            if let result, !self.fired {
                self.fired = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.onDecode?(result)
            }
        }
    }
}

/// A `UIView` whose backing layer IS the capture preview layer.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
