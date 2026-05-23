import Combine
import Foundation
import FirebaseFirestore
import FirebaseStorage
import UIKit

@MainActor
@Observable
final class FirestoreService {
    var cafes: [Cafe] = []

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    // MARK: - Real-time listener

    func subscribe() {
        listener = db.collection("places")
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                // Firebase fires this on its own queue; hop to MainActor
                // before touching @Published state.
                Task { @MainActor [weak self] in
                    self?.cafes = docs.compactMap { try? $0.data(as: Cafe.self) }
                }
            }
    }

    func unsubscribe() {
        listener?.remove()
        listener = nil
    }

    // MARK: - Add place

    func addPlace(data: CafeFormData, photoImages: [UIImage]) async throws {
        let photoUrls = try await uploadImages(photoImages, slug: data.slug)
        try await db.collection("places").addDocument(data: [
            "slug":         data.slug,
            "name":         data.name,
            "type":         data.type.rawValue,
            "tagline":      data.tagline,
            "neighborhood": data.neighborhood,
            "hours":        data.hours,
            "description":  data.description,
            "vibeTags":     data.vibeTags,
            "lat":          data.lat,
            "lng":          data.lng,
            "photos":       photoUrls,
            "createdAt":    FieldValue.serverTimestamp(),
        ])
    }

    // MARK: - Update place

    func updatePlace(id: String, data: CafeFormData, existingPhotos: [String], newImages: [UIImage]) async throws {
        let newUrls = try await uploadImages(newImages, slug: data.slug)
        let allPhotos = existingPhotos + newUrls
        try await db.collection("places").document(id).updateData([
            "name":         data.name,
            "type":         data.type.rawValue,
            "tagline":      data.tagline,
            "neighborhood": data.neighborhood,
            "hours":        data.hours,
            "description":  data.description,
            "vibeTags":     data.vibeTags,
            "lat":          data.lat,
            "lng":          data.lng,
            "photos":       allPhotos,
        ])
    }

    // MARK: - Delete place

    func deletePlace(id: String) async throws {
        try await db.collection("places").document(id).delete()
    }

    // MARK: - Storage upload

    /// Uploads each image in parallel via a throwing task group and returns
    /// the resulting download URLs in the same order as the input.
    /// UUID filenames remove the second-resolution collision risk of the
    /// previous timestamp-based scheme.
    private func uploadImages(_ images: [UIImage], slug: String) async throws -> [String] {
        try await withThrowingTaskGroup(of: (Int, String)?.self) { group in
            for (idx, image) in images.enumerated() {
                guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
                group.addTask {
                    let filename = "\(UUID().uuidString).jpg"
                    let ref = Storage.storage().reference().child("places/\(slug)/\(filename)")
                    _ = try await ref.putDataAsync(data)
                    let url = try await ref.downloadURL()
                    return (idx, url.absoluteString)
                }
            }
            var pairs: [(Int, String)] = []
            for try await result in group {
                if let result { pairs.append(result) }
            }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
