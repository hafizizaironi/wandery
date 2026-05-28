import Foundation
import FirebaseFirestore

/// One placed-tagged post's classifier output, used by the admin tuning view.
/// Mirrors the fields the `discoverFeed` Cloud Function consults when
/// deciding clear vs blur vs exclude.
struct ClassifierTuningRow: Identifiable, Equatable {
    let id: String                  // postId
    let authorId: String
    let placeId: String
    let placeName: String
    let createdAt: Date
    let thumbnailURL: String?       // prefers thumbnailURL → mediaURL
    let mediaURL: String
    let isVideo: Bool
    /// Server-stamped by `PostClassifier`. Missing on unclassified or
    /// pre-classifier posts.
    let aestheticScore: Double?
    let containsFaces: Bool?
    /// The classifier's final say. Missing = never classified.
    let discoverable: Bool?

    /// Was the classifier verdict ever written for this post?
    var isClassified: Bool {
        aestheticScore != nil && containsFaces != nil && discoverable != nil
    }
}

/// Paginated admin-only feed of recent placed-tagged posts with their
/// classifier verdicts. Lets the admin compare photos to their on-device
/// aesthetic score so they can pick a sensible discoverability threshold.
///
/// Caller must already be admin — gated at the view level via
/// `AuthService.isAdmin`. Firestore rules add a second `isAdmin()` clause
/// to `/posts/{postId}` read so this query can see posts the admin
/// otherwise wouldn't (non-friend, non-discoverable).
@MainActor
@Observable
final class AdminClassifierTuningService {
    private(set) var rows: [ClassifierTuningRow] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = true
    private(set) var lastError: String?

    /// Page size — kept modest so the initial render is snappy and the
    /// admin can pull more on demand.
    private let pageSize = 60
    private var lastDoc: DocumentSnapshot?
    private let db = Firestore.firestore()

    // MARK: - Load

    /// Initial fetch — resets pagination and reloads the first page.
    func reload() async {
        rows = []
        lastDoc = nil
        hasMore = true
        await loadNextPage(initial: true)
    }

    /// Fetch the next page. No-op when already loading or exhausted.
    func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        await loadNextPage(initial: false)
    }

    private func loadNextPage(initial: Bool) async {
        if initial {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        lastError = nil
        defer {
            isLoading = false
            isLoadingMore = false
        }

        var q: Query = db.collection("posts")
            // Server-side filter on placeId presence — only posts with a
            // location tag are useful for the "place trending" gate.
            .whereField("placeId", isNotEqualTo: "")
            .order(by: "placeId")     // required by Firestore for `!=` filter
            .order(by: "createdAt", descending: true)
            .limit(to: pageSize)
        if let lastDoc {
            q = q.start(afterDocument: lastDoc)
        }

        do {
            let snap = try await q.getDocuments()
            let newRows = snap.documents.compactMap(Self.parse)
            rows.append(contentsOf: newRows)
            lastDoc = snap.documents.last
            hasMore = snap.documents.count == pageSize
        } catch {
            lastError = error.localizedDescription
            hasMore = false
        }
    }

    // MARK: - Parse

    private static func parse(_ doc: QueryDocumentSnapshot) -> ClassifierTuningRow? {
        let d = doc.data()
        guard
            let authorId = d["authorId"] as? String,
            let placeId  = d["placeId"]  as? String, !placeId.isEmpty,
            let mediaURL = d["mediaURL"] as? String,
            let createdAt = (d["createdAt"] as? Timestamp)?.dateValue()
        else { return nil }

        let mediaType = (d["mediaType"] as? String) ?? "image"
        return ClassifierTuningRow(
            id: doc.documentID,
            authorId: authorId,
            placeId: placeId,
            placeName: (d["placeName"] as? String) ?? "",
            createdAt: createdAt,
            thumbnailURL: d["thumbnailURL"] as? String,
            mediaURL: mediaURL,
            isVideo: mediaType == "video",
            aestheticScore: d["aestheticScore"] as? Double,
            containsFaces: d["containsFaces"] as? Bool,
            discoverable: d["discoverable"] as? Bool
        )
    }
}
