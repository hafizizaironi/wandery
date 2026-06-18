import Foundation
import FirebaseFirestore

/// The app-wide released-frames catalog. Reads `config/frames = { released:
/// [styleId] }` so a feed-card skin the admin publishes appears in every user's
/// wardrobe live. Mirrors `UserStatsService`'s snapshot-listener shape. Admin
/// writes go through `publish`/`unpublish` — allowed by the existing
/// `config/{docId}` admin-write Firestore rule (no rules change needed).
@Observable
final class FrameCatalogService {
    /// `FeedCardStyle.rawValue`s currently released to all users.
    private(set) var releasedFrameIDs: Set<String> = []

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    // MARK: - Subscribe / unsubscribe

    func subscribe() {
        guard listener == nil else { return }
        listener = db.collection("config").document("frames")
            .addSnapshotListener { [weak self] snap, _ in
                let ids = (snap?.data()?["released"] as? [String]) ?? []
                Task { @MainActor [weak self] in
                    self?.releasedFrameIDs = Set(ids)
                }
            }
    }

    func unsubscribe() {
        listener?.remove()
        listener = nil
    }

    deinit { unsubscribe() }

    // MARK: - Admin writes (gated by the `config/{docId}` admin-write rule)

    /// Release a frame to everyone's wardrobe.
    func publish(_ id: String) async {
        try? await db.collection("config").document("frames")
            .setData(["released": FieldValue.arrayUnion([id])], merge: true)
    }

    /// Pull a frame back to admin-only.
    func unpublish(_ id: String) async {
        try? await db.collection("config").document("frames")
            .setData(["released": FieldValue.arrayRemove([id])], merge: true)
    }
}
