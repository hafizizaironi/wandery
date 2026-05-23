import Combine
import CoreLocation
import Foundation
@preconcurrency import FirebaseAuth
import FirebaseFirestore

/// Closes "visit sessions" that the user has physically walked away from,
/// so the next post tag at the same place will count as a brand-new visit
/// instead of being merged into the still-open session.
///
/// How a visit session lives:
///   1. User posts at place P. Cloud Function `onPostCreatePlaceVisit`
///      writes `users/{uid}/visits/{P}` with `closed: false` and the place
///      coords as `firstPostLat/Lng`.
///   2. The client (this service) periodically — on app foreground and
///      after each fresh location fix — compares the user's current
///      coordinate to every open visit's anchor and flips `closed: true`
///      once the distance crosses `decayRadiusMeters` (~3 km).
///   3. The next post the user makes at that same place re-opens a fresh
///      session and bumps `places/{P}.globalVisitCount`.
///
/// We deliberately don't run a continuous background location stream —
/// that would burn battery for marginal benefit. The visit closes the
/// next time the app foregrounds with a fix beyond the threshold, which
/// is plenty for "did the user leave the cafe" semantics.
@MainActor
@Observable
final class VisitTrackerService {

    /// Distance the user must move from a visit's first-post location
    /// before that visit is considered "closed" and a future post can
    /// open a fresh one. 3 km matches what was discussed: well outside
    /// any single mall / neighbourhood block, comfortably inside a
    /// short city drive.
    static let decayRadiusMeters: Double = 3000

    private let db = Firestore.firestore()
    private var lastDecayAt: Date?

    /// Re-entrancy guard — the decay sweep can be triggered from several
    /// places (foreground, location update) and we don't want overlapping
    /// fetches.
    private var isSweeping = false

    /// Throttle so we don't sweep more than once every ~30 seconds when
    /// foregrounding repeatedly. Cheap to call frequently from view-tree
    /// scenePhase observers as a result.
    func sweepIfNeeded(force: Bool = false) async {
        if !force, let last = lastDecayAt, Date().timeIntervalSince(last) < 30 {
            return
        }
        await sweep()
    }

    private func sweep() async {
        guard !isSweeping else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard let coord = await LocationProvider.shared.currentCoordinate() else { return }
        isSweeping = true
        defer { isSweeping = false }
        lastDecayAt = Date()

        do {
            let snap = try await db.collection("users").document(uid)
                .collection("visits")
                .whereField("closed", isEqualTo: false)
                .getDocuments()
            let origin = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            for doc in snap.documents {
                let d = doc.data()
                guard let lat = d["firstPostLat"] as? Double,
                      let lng = d["firstPostLng"] as? Double else { continue }
                let placeLoc = CLLocation(latitude: lat, longitude: lng)
                let distance = placeLoc.distance(from: origin)
                guard distance >= Self.decayRadiusMeters else { continue }
                // Bumping `visitCount` here (not on open) means the counter
                // reflects *completed* visits — useful for "loyal" style
                // achievements that shouldn't trigger mid-session.
                try await doc.reference.setData([
                    "closed": true,
                    "closedAt": FieldValue.serverTimestamp(),
                    "visitCount": FieldValue.increment(Int64(1)),
                ], merge: true)
                #if DEBUG
                print("[VisitTracker] closed visit at \(doc.documentID) — \(Int(distance))m away")
                #endif
            }
        } catch {
            #if DEBUG
            print("[VisitTracker] sweep failed: \(error)")
            #endif
        }
    }
}
