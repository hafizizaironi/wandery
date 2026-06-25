import Foundation

/// Evicts the least-recently-modified files in `directory` until the total
/// on-disk size is back under `maxBytes`. Shared by the media caches
/// (`AudioCache`, `VideoCache`), which download whole clips to the Caches
/// directory and rely on this LRU sweep to stay bounded. No-op when already
/// under the cap or the directory can't be read.
///
/// `nonisolated` so it runs on the calling cache actor's executor (off the
/// main thread), matching the inlined `trim()` it replaced — without it,
/// default-MainActor isolation would hop this file I/O onto the main thread.
nonisolated func evictLeastRecentlyUsed(in directory: URL, maxBytes: Int) {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    guard let files = try? fm.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys
    ) else { return }

    var entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
        let v = try? url.resourceValues(forKeys: Set(keys))
        guard let date = v?.contentModificationDate, let size = v?.fileSize else { return nil }
        return (url, date, size)
    }
    var total = entries.reduce(0) { $0 + $1.size }
    guard total > maxBytes else { return }

    entries.sort { $0.date < $1.date }
    for entry in entries {
        if total <= maxBytes { break }
        try? fm.removeItem(at: entry.url)
        total -= entry.size
    }
}
