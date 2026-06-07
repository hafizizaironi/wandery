import SwiftUI
import UIKit
import CryptoKit

/// Drop-in `AsyncImage` replacement backed by a two-tier cache:
///   • L1 — a process-wide in-memory `NSCache` of decoded images (instant), and
///   • L2 — an on-disk cache of the raw bytes (survives app restarts).
/// Lookup order is memory → disk → network. Plain `AsyncImage` ties its cache
/// to the view instance, so a recycled `LazyVStack` cell re-fetches and
/// re-decodes the same URL on every scroll; this hits the shared caches first.
///
/// API mirrors `AsyncImage(url:scale:content:)` with a phase-based closure so
/// existing call sites can swap with a one-word rename.
@MainActor
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let scale: CGFloat
    /// Longest-edge pixel cap for the decoded bitmap. `nil` (default) decodes at
    /// full size — still **off the main thread** (the point is to keep the slide
    /// from stalling on a lazy main-thread decode), just without downsampling.
    let maxPixelSize: CGFloat?
    let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase

    init(
        url: URL?,
        scale: CGFloat = 1,
        maxPixelSize: CGFloat? = nil,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.scale = scale
        self.maxPixelSize = maxPixelSize
        self.content = content
        // Seed from the in-memory cache so an already-cached image renders on
        // the FIRST frame instead of flashing `.empty`. Without this, a
        // freshly-mounted view shows its transparent loading state for a frame
        // — and anything behind it (e.g. the focus overlay's blur) bleeds
        // through the image region until the async `.task` resolves the cache.
        if let url, let cached = ImageCache.shared.image(for: url) {
            _phase = State(initialValue: .success(Image(uiImage: cached)))
        } else {
            _phase = State(initialValue: .empty)
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        // L1 — in-memory hit: no network, no decode.
        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }
        // L2 — on-disk hit: decode + promote into memory. Survives restarts,
        // so a previously-seen image never re-downloads.
        if let data = await DiskImageCache.shared.data(for: url),
           let ui = await ImageDecoding.prepared(from: data, maxPixel: maxPixelSize) {
            ImageCache.shared.store(ui, for: url)
            phase = .success(Image(uiImage: ui))
            return
        }
        // If this is a retry after a prior failure, show the loading state again.
        if case .failure = phase { phase = .empty }

        // Bounded retry with backoff. Stock AsyncImage gives up after one
        // failed attempt and never retries while the view stays on screen, so
        // a momentary blip (waking from background, switching networks) left
        // previews permanently blank. Retries only run on failure, so a
        // successful load costs exactly one request as before.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    // 404/410 = the object is permanently gone (e.g. a deleted
                    // post's media). Retrying can't help, and callers want to
                    // distinguish "deleted" from a transient blip — so fail
                    // fast with a recognisable error instead of looping.
                    if http.statusCode == 404 || http.statusCode == 410 {
                        phase = .failure(URLError(.fileDoesNotExist))
                        return
                    }
                    throw URLError(.badServerResponse)
                }
                guard let ui = await ImageDecoding.prepared(from: data, maxPixel: maxPixelSize) else {
                    throw URLError(.cannotDecodeContentData)
                }
                ImageCache.shared.store(ui, for: url)
                // Persist the original bytes to disk for future launches
                // (fire-and-forget so the success path isn't delayed).
                Task { await DiskImageCache.shared.store(data, for: url) }
                phase = .success(Image(uiImage: ui))
                return
            } catch is CancellationError {
                // Superseded (URL changed) — let the new task take over without
                // flashing a stale failure state.
                return
            } catch {
                guard attempt < maxAttempts else {
                    phase = .failure(error)
                    return
                }
                // 0.6s, then 1.2s.
                try? await Task.sleep(for: .seconds(0.6 * Double(attempt)))
                if Task.isCancelled { return }
            }
        }
    }
}

/// L1: shared decoded-image cache. ~200 entries, capped at ~50 MB.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 50 * 1024 * 1024
        return c
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { Int($0.bytesPerRow * $0.height) } ?? 0
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// L2: persistent on-disk byte cache in the app's Caches directory (the OS may
/// evict it under storage pressure — appropriate for a cache). All file I/O
/// runs on this actor's own executor, off the main thread. Capped at ~200 MB
/// and trimmed least-recently-modified-first.
actor DiskImageCache {
    static let shared = DiskImageCache()

    private let dir: URL
    private let fm = FileManager.default
    private let maxBytes = 200 * 1024 * 1024
    private var storesSinceTrim = 0

    init() {
        // Use FileManager.default directly — an actor's init is nonisolated
        // and can't touch the actor-isolated `fm` property.
        let manager = FileManager.default
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        dir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func data(for url: URL) -> Data? {
        let file = path(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Touch the modification date so frequently-read files survive trims.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func store(_ data: Data, for url: URL) {
        try? data.write(to: path(for: url), options: .atomic)
        storesSinceTrim += 1
        if storesSinceTrim >= 30 {
            storesSinceTrim = 0
            trim()
        }
    }

    private func path(for url: URL) -> URL {
        dir.appendingPathComponent(Self.key(for: url))
    }

    /// Deterministic filename from the URL (SHA-256 — `String.hashValue` is
    /// randomised per launch and would never hit across sessions).
    private static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Evict least-recently-modified files until under the size cap.
    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys
        ) else { return }

        var entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard let date = v?.contentModificationDate, let size = v?.fileSize else { return nil }
            return (url, date, size)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        entries.sort { $0.date < $1.date }   // oldest first
        for entry in entries {
            if total <= maxBytes { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
