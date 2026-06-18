import Foundation
import CryptoKit

/// On-disk cache for the 30-second song previews attached to posts. Mirrors
/// `VideoCache`: the clips are tiny (~0.5–1 MB), so we download the whole file
/// once and play it from local disk — instant on replay, and (when prefetched
/// ahead of the scroll) instant on first play too, so settling on a music post
/// never hitches the pager.
///
/// `cachedFileURL(for:)` is a synchronous, nonisolated existence check so
/// `PostMusicPlayer` can decide to play the local file from its off-main build.
actor AudioCache {
    static let shared = AudioCache()

    private let fm = FileManager.default
    private let maxBytes = 150 * 1024 * 1024   // ~150 MB; clips are tiny
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var storesSinceTrim = 0

    init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
    }

    /// Synchronous, side-effect-free: the local file URL if this preview is
    /// already cached, else nil. Safe to call from any thread.
    nonisolated func cachedFileURL(for remote: URL) -> URL? {
        let f = Self.path(for: remote)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Download `remote` to disk (deduped across concurrent callers) and return
    /// the local file URL, or nil on failure. No-op if already cached.
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
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(
            at: Self.dir, includingPropertiesForKeys: keys
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

    nonisolated private static var dir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("AudioCache", isDirectory: true)
    }

    /// Deterministic filename (SHA-256 of the URL) keeping the remote file's
    /// extension (iTunes previews are `.m4a`) so AVFoundation infers the type.
    nonisolated private static func key(for remote: URL) -> String {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = remote.pathExtension.isEmpty ? "m4a" : remote.pathExtension
        return hex + "." + ext
    }

    nonisolated private static func path(for remote: URL) -> URL {
        dir.appendingPathComponent(key(for: remote))
    }
}
