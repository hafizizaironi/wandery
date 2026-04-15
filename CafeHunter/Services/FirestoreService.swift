import Combine
import Foundation
import FirebaseFirestore
import FirebaseStorage
import UIKit

class FirestoreService: ObservableObject {
    @Published var cafes: [Cafe] = []

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    // MARK: - Real-time listener

    func subscribe() {
        listener = db.collection("places")
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let docs = snapshot?.documents else { return }
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

    private func uploadImages(_ images: [UIImage], slug: String) async throws -> [String] {
        var urls: [String] = []
        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            let filename = "\(Int(Date().timeIntervalSince1970)).jpg"
            let ref = Storage.storage().reference().child("places/\(slug)/\(filename)")
            _ = try await ref.putDataAsync(data)
            let url = try await ref.downloadURL()
            urls.append(url.absoluteString)
        }
        return urls
    }
}
