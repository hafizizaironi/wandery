import CoreImage
import UIKit
import AVFoundation

/// Photo processing for upload: square center crop only (no resize, no color grade).
enum CameraCaptureProcessing {

    /// Center square crop for preview (matches live viewfinder aspect-fill; no color grade).
    /// Renders through a bitmap so `UIImage` is **.up** — avoids SwiftUI letterboxing from EXIF orientation.
    static func squareCenterUIImage(_ image: UIImage) -> UIImage {
        let upright = renderBitmapUpright(image)
        guard let cg = upright.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let side = min(w, h)
        let x = (w - side) / 2
        let y = (h - side) / 2
        let cropRect = CGRect(x: x, y: y, width: side, height: side)
        guard let cropped = cg.cropping(to: cropRect) else { return upright }
        return UIImage(cgImage: cropped, scale: upright.scale, orientation: .up)
    }

    /// Shared GPU context — allocating a `CIContext` per call is expensive
    /// (tens of ms); reuse one across uploads.
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    static func preparePhotoForUpload(_ image: UIImage) -> UIImage? {
        let upright = renderBitmapUpright(image)
        guard let ciImage = CIImage(image: upright) else { return nil }
        let cropped = squareCenterCrop(ciImage)
        guard let cg = sharedCIContext.createCGImage(cropped, from: cropped.extent.integral) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// Draws `image` into a bitmap so pixel data matches display (orientation `.up`).
    private static func renderBitmapUpright(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func squareCenterCrop(_ image: CIImage) -> CIImage {
        let e = image.extent
        let side = min(e.width, e.height)
        let x = e.midX - side / 2
        let y = e.midY - side / 2
        return image.cropped(to: CGRect(x: x, y: y, width: side, height: side))
    }

    /// Square 1080×1080 export when possible; otherwise returns original URL.
    static func exportSquareVideo(from inputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CameraExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let pref = try await track.load(.preferredTransform)
        let size = naturalSize.applying(pref)
        let w = abs(size.width)
        let h = abs(size.height)
        let side = min(w, h)
        let scale = 1080 / side
        let scaledW = w * scale
        let scaledH = h * scale
        let tx = (1080 - scaledW) / 2
        let ty = (1080 - scaledH) / 2
        let concat = pref.concatenating(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: tx / scale, y: ty / scale))

        let videoComposition = Self.makeSquareVideoComposition(track: track, duration: duration, transform: concat)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_sq.mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CameraExportError.exportFailed
        }
        export.videoComposition = videoComposition
        try await export.export(to: out, as: .mp4)
        return out
    }

    /// Square 1080² composition. iOS 26 uses the immutable `Configuration` API;
    /// iOS 18–25 uses the classic `AVMutableVideoComposition`.
    private static func makeSquareVideoComposition(
        track: AVAssetTrack,
        duration: CMTime,
        transform: CGAffineTransform
    ) -> AVVideoComposition {
        let square = CGSize(width: 1080, height: 1080)
        let frameDuration = CMTime(value: 1, timescale: 60)

        if #available(iOS 26.0, *) {
            var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            layerConfig.setTransform(transform, at: .zero)
            let layerInstruction = AVVideoCompositionLayerInstruction(configuration: layerConfig)
            let instructionConfig = AVVideoCompositionInstruction.Configuration(
                backgroundColor: nil,
                enablePostProcessing: false,
                layerInstructions: [layerInstruction],
                requiredSourceSampleDataTrackIDs: [],
                timeRange: CMTimeRange(start: .zero, duration: duration)
            )
            let instruction = AVVideoCompositionInstruction(configuration: instructionConfig)
            let compConfig = AVVideoComposition.Configuration(
                animationTool: nil,
                colorPrimaries: nil,
                colorTransferFunction: nil,
                colorYCbCrMatrix: nil,
                customVideoCompositorClass: nil,
                frameDuration: frameDuration,
                instructions: [instruction],
                outputBufferDescription: nil,
                renderScale: 1.0,
                renderSize: square,
                sourceSampleDataTrackIDs: [],
                sourceTrackIDForFrameTiming: track.trackID,
                spatialVideoConfigurations: []
            )
            return AVVideoComposition(configuration: compConfig)
        } else {
            // iOS 18–25: classic mutable composition. (`AVMutableVideoComposition`
            // is soft-deprecated on iOS 26 — one unavoidable warning to keep the
            // square crop working below 26.)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            instruction.layerInstructions = [layer]
            let comp = AVMutableVideoComposition()
            comp.renderSize = square
            comp.frameDuration = frameDuration
            comp.instructions = [instruction]
            return comp
        }
    }
}

enum CameraExportError: Error {
    case noVideoTrack
    case exportFailed
}
