import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// Lightweight row used by `CreatorPicksAdminView` — covers both
/// currently-featured picks and add-candidate places. Sortable by
/// `creatorPickOrder` when set.
struct CreatorPickRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: PlaceType
    let neighborhood: String
    let lat: Double
    let lng: Double
    let photoURL: String
    /// Nil = not currently a pick.
    var creatorPickOrder: Int?

    var isPick: Bool { creatorPickOrder != nil }
}

/// Admin-only CRUD for the Creator's Pick curation surface. Writes the
/// `creatorPickOrder` field directly on `places/{id}` — no separate
/// collection, no callable. Caller must already be admin (gated at the
/// view level via `AuthService.isAdmin`); Firestore rules are the
/// authoritative gate.
@MainActor
@Observable
final class CreatorPicksAdminService {
    /// Currently-featured places, sorted by `creatorPickOrder asc`.
    private(set) var picks: [CreatorPickRow] = []
    /// All photo-bearing places that *could* be added as picks (excludes
    /// places that are already picks).
    private(set) var candidates: [CreatorPickRow] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    private let db = Firestore.firestore()

    // MARK: - Load

    /// Fetches both currently-featured picks and add-candidates in parallel.
    func reload() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        async let picksTask = fetchPicks()
        async let placesTask = fetchAllPhotoPlaces()
        let loadedPicks = await picksTask
        let allPlaces = await placesTask

        let pickIds = Set(loadedPicks.map(\.id))
        picks = loadedPicks
        candidates = allPlaces
            .filter { !pickIds.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Mutations

    /// Adds a place to the picks list at the end. Order = current highest + 1.
    func add(_ candidate: CreatorPickRow) async {
        let nextOrder = (picks.last?.creatorPickOrder ?? 0) + 1
        do {
            try await db.collection("places").document(candidate.id).updateData([
                "creatorPickOrder": nextOrder
            ])
            var added = candidate
            added.creatorPickOrder = nextOrder
            picks.append(added)
            candidates.removeAll { $0.id == candidate.id }
        } catch {
            lastError = "Couldn't add: \(error.localizedDescription)"
        }
    }

    /// Removes a place from the picks list (clears the field, doesn't
    /// delete the place doc).
    func remove(_ pick: CreatorPickRow) async {
        do {
            try await db.collection("places").document(pick.id).updateData([
                "creatorPickOrder": FieldValue.delete()
            ])
            picks.removeAll { $0.id == pick.id }
            var freed = pick
            freed.creatorPickOrder = nil
            candidates.append(freed)
            candidates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            // Renumber to keep order contiguous after a removal.
            await renumberAll()
        } catch {
            lastError = "Couldn't remove: \(error.localizedDescription)"
        }
    }

    /// Applies a new order (by id) and persists it. Caller is expected
    /// to have already computed the reorder — typically the SwiftUI view
    /// running `Array.move(fromOffsets:toOffset:)` on a local copy of
    /// `picks`. Keeping the SwiftUI move out of this service avoids a
    /// SwiftUI import in the service layer.
    func reorder(byIds newOrder: [String]) async {
        let dict = Dictionary(uniqueKeysWithValues: picks.map { ($0.id, $0) })
        let rebuilt = newOrder.compactMap { dict[$0] }
        guard rebuilt.count == picks.count else { return }
        picks = rebuilt
        await renumberAll()
    }

    // MARK: - Internal

    /// Rewrites `creatorPickOrder` on every pick to match its current
    /// index in `picks`. Uses a single batched write so partial failure
    /// can't leave the list with duplicate or skipped orders.
    private func renumberAll() async {
        let batch = db.batch()
        for (idx, pick) in picks.enumerated() {
            let newOrder = idx + 1
            picks[idx].creatorPickOrder = newOrder
            batch.updateData(
                ["creatorPickOrder": newOrder],
                forDocument: db.collection("places").document(pick.id)
            )
        }
        do {
            try await batch.commit()
        } catch {
            lastError = "Couldn't reorder: \(error.localizedDescription)"
        }
    }

    private func fetchPicks() async -> [CreatorPickRow] {
        do {
            let snap = try await db.collection("places")
                .whereField("creatorPickOrder", isGreaterThan: 0)
                .order(by: "creatorPickOrder")
                .getDocuments()
            return snap.documents.compactMap(Self.row(from:))
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    private func fetchAllPhotoPlaces() async -> [CreatorPickRow] {
        do {
            // Capped at 200 — admin curation surface, not a paginated
            // list. If the catalogue grows past that we should add
            // search instead.
            let snap = try await db.collection("places")
                .limit(to: 200)
                .getDocuments()
            return snap.documents.compactMap(Self.row(from:))
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    private static func row(from doc: QueryDocumentSnapshot) -> CreatorPickRow? {
        let data = doc.data()
        guard let name = data["name"] as? String,
              let lat = data["lat"] as? Double,
              let lng = data["lng"] as? Double else { return nil }
        let photos = (data["photos"] as? [String]) ?? []
        guard let first = photos.first, !first.isEmpty else { return nil }
        let typeStr = (data["type"] as? String) ?? "restaurant"
        let neighborhood = (data["neighborhood"] as? String) ?? ""
        return CreatorPickRow(
            id: doc.documentID,
            name: name,
            type: PlaceType(rawValue: typeStr) ?? .restaurant,
            neighborhood: neighborhood,
            lat: lat,
            lng: lng,
            photoURL: first,
            creatorPickOrder: data["creatorPickOrder"] as? Int
        )
    }
}
