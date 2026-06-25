import Foundation
import CryptoKit

/// On-disk cache for short feed videos. Feed clips are tiny (≤5s, square
/// 1080), so we download the whole file once and play it from local disk —
/// instant on replay, and (when prefetched ahead) instant on first view too.
///
/// Mirrors `DiskImageCache`: Caches directory, SHA-256 filenames, ~500 MB
/// LRU cap, all I/O on the actor's executor. `cachedFileURL(for:)` is a
/// synchronous, nonisolated existence check so the player can decide to use
/// the local file on the spot.
actor VideoCache {
    static let shared = VideoCache()

    private let fm = FileManager.default
    private let maxBytes = 500 * 1024 * 1024
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var storesSinceTrim = 0

    init() {
        // FileManager.default directly — an actor's init is nonisolated and
        // can't touch the actor-isolated `fm` property.
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
    }

    /// Synchronous, side-effect-free: the local file URL if this video is
    /// already cached, else nil. Safe to call from the main thread / a view.
    nonisolated func cachedFileURL(for remote: URL) -> URL? {
        let f = Self.path(for: remote)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Download `remote` to disk (deduped across concurrent callers) and
    /// return the local file URL, or nil on failure. No-op if already cached.
    @discardableResult
    func prefetch(_ remote: URL) async -> URL? {
        let key = Self.key(for: remote)
        let dest = Self.dir.appendingPathComponent(key)
        if fm.fileExists(atPath: dest.path) {
            touch(dest)
            return dest
        }
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task<URL?, Never> { await Self.download(remote, to: dest) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if result != nil {
            storesSinceTrim += 1
            if storesSinceTrim >= 10 {
                storesSinceTrim = 0
                trim()
            }
        }
        return result
    }

    // MARK: - Private

    nonisolated private static func download(_ remote: URL, to dest: URL) async -> URL? {
        do {
            let (tmp, response) = try await URLSession.shared.download(from: remote)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func touch(_ file: URL) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Evict least-recently-modified files until under the size cap.
    private func trim() {
        evictLeastRecentlyUsed(in: Self.dir, maxBytes: maxBytes)
    }

    nonisolated private static var dir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("VideoCache", isDirectory: true)
    }

    /// Deterministic filename (SHA-256 of the URL) + `.mp4` so AVFoundation
    /// infers the type from the extension.
    nonisolated private static func key(for remote: URL) -> String {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".mp4"
    }

    nonisolated private static func path(for remote: URL) -> URL {
        dir.appendingPathComponent(key(for: remote))
    }
}
