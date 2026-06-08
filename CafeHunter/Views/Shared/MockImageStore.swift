import SwiftUI
import UIKit
import Observation

/// Holds admin-picked photos that fill the marketing-mockup image slots,
/// keyed by the same slot name `MockImage` uses (`mock_cafe1`, `mock_food2`, …).
///
/// Picks are persisted to Application Support so they survive relaunches and
/// reopening the mockups screen — letting the admin curate a screenshot set
/// over time. Nothing here touches live services; it's purely local imagery.
@MainActor
@Observable
final class MockImageStore {
    static let shared = MockImageStore()

    /// Slot name → picked image. `MockImage` reads this first, before the
    /// asset catalog and the branded placeholder.
    private(set) var images: [String: UIImage] = [:]

    private let dir: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("MarketingMockups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadFromDisk()
    }

    func image(for name: String) -> UIImage? { images[name] }

    /// Set (or clear, with `nil`) the picked image for a slot and persist it.
    func set(_ image: UIImage?, for name: String) {
        if let image {
            images[name] = image
        } else {
            images[name] = nil
        }
        persist(image, for: name)
    }

    func clear(_ name: String) { set(nil, for: name) }

    /// Remove every picked image (the "Clear all" action in the editor).
    func clearAll() {
        let names = Array(images.keys)
        images.removeAll()
        for name in names { persist(nil, for: name) }
    }

    // MARK: - Disk

    private func fileURL(for name: String) -> URL {
        // Slot names are simple keys, but sanitise defensively against `/`.
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).jpg")
    }

    private func persist(_ image: UIImage?, for name: String) {
        let url = fileURL(for: name)
        if let image, let data = image.jpegData(compressionQuality: 0.9) {
            Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
        } else {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func loadFromDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for url in files where url.pathExtension == "jpg" {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                images[url.deletingPathExtension().lastPathComponent] = image
            }
        }
    }
}
