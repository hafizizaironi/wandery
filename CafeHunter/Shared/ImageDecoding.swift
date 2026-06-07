import UIKit
import ImageIO

/// Off-main image decoding. A plain `UIImage(data:)` is lazy — Core Animation
/// decompresses the pixels on the **main thread** at display time, which hitched
/// the feed scroll as each oversized photo slid in. These helpers force the
/// decode (and a downsample) onto a background thread up front, so the cached
/// `UIImage` is render-ready and the scroll stays smooth.
enum ImageDecoding {

    /// Decode `data` to a fully-realized `UIImage`, off the main thread. When
    /// `maxPixel` is set, ImageIO downsamples to that longest-edge size in one
    /// pass (a feed photo is ~2–3k px but only ever shown in a ~390pt card), so
    /// we decode a small bitmap instead of a huge one. Falls back to a prepared
    /// full decode if the thumbnail path fails.
    static func prepared(from data: Data, maxPixel: CGFloat?) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            if let maxPixel {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,   // apply EXIF orientation
                    kCGImageSourceShouldCacheImmediately: true,         // decode now, on this thread
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                ]
                if let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                    return UIImage(cgImage: cg)
                }
            }
            // No downsample target (or thumbnail failed): force a full decode.
            return await UIImage(data: data)?.byPreparingForDisplay()
        }.value
    }
}
