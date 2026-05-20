import SwiftUI
import UIKit

/// Drop-in `AsyncImage` replacement that shares decoded images via a
/// process-wide NSCache. Plain `AsyncImage` ties its cache to the view
/// instance, so when SwiftUI recycles cells in a `LazyVStack` the same
/// URL re-fetches and re-decodes on every scroll. This wrapper hits the
/// shared cache by URL first and only fetches on miss.
///
/// API mirrors `AsyncImage(url:scale:content:)` with a phase-based
/// closure so existing call sites can swap with a one-word rename.
@MainActor
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let scale: CGFloat
    let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    init(
        url: URL?,
        scale: CGFloat = 1,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.scale = scale
        self.content = content
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
        // Cache hit — skip the network round-trip and the decode entirely.
        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let ui = UIImage(data: data) else {
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }
            ImageCache.shared.store(ui, for: url)
            phase = .success(Image(uiImage: ui))
        } catch is CancellationError {
            // The task was superseded (URL changed). Leave phase alone so the
            // new task can take over without flashing a stale failure state.
        } catch {
            phase = .failure(error)
        }
    }
}

/// Shared decoded-image cache. ~200 entries, capped at ~50 MB.
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
