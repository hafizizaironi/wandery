import Foundation
import FirebaseFunctions

/// Client bridge to the Wandery Code identity callables (`ensureWanderyCode`,
/// `beginPresenting`, `resolveWanderyCode`). Uses the same `httpsCallable`
/// pattern as `SocialService` (see `acceptRequest`).
@MainActor
@Observable
final class WanderyCodeService {

    /// Outcome of resolving a scanned code, mapped from the callable's `status`
    /// (or its `HttpsError` code).
    enum ResolveOutcome: Equatable {
        case added             // instant mutual add (in person, or accepted a pending)
        case requested         // friend request sent (to approve)
        case alreadyFriends
        case isSelf
        case notFound          // code not active
        case blocked
        case failed(String)
    }

    /// Public profile of the scanned user (nil on error outcomes).
    struct ScannedProfile: Equatable {
        let username: String?
        let displayName: String?
        let photoURL: String?
        let cafes: Int
        let stalls: Int
        let restaurants: Int
    }

    struct ResolveResult: Equatable {
        let outcome: ResolveOutcome
        let profile: ScannedProfile?
    }

    private let functions = Functions.functions()
    private(set) var cachedAccountId: UInt64?

    /// This user's permanent 44-bit account id (minted on first call), cached
    /// for the session. The id is server-owned — the client only ever learns
    /// its own via this call.
    func ensureCode() async throws -> UInt64 {
        if let cachedAccountId { return cachedAccountId }
        let result = try await functions.httpsCallable("ensureWanderyCode").call()
        guard let dict = result.data as? [String: Any],
              let id = (dict["accountId"] as? NSNumber)?.uint64Value else {
            throw NSError(domain: "WanderyCode", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't load your code."])
        }
        cachedAccountId = id
        return id
    }

    /// Mark myself as actively presenting my code (~60s server window). Call
    /// when My Code is shown and refresh periodically while it's visible.
    func beginPresenting() async {
        _ = try? await functions.httpsCallable("beginPresenting").call()
    }

    /// Resolve a scanned account id into a connection. Never throws — returns a
    /// `ResolveResult` (outcome + scanned profile) the UI can show directly.
    func resolve(accountId: UInt64) async -> ResolveResult {
        do {
            let result = try await functions.httpsCallable("resolveWanderyCode")
                .call(["accountId": NSNumber(value: accountId)])
            let data = result.data as? [String: Any]
            let outcome: ResolveOutcome
            switch data?["status"] as? String {
            case "added":          outcome = .added
            case "requested":      outcome = .requested
            case "alreadyFriends": outcome = .alreadyFriends
            default:               outcome = .failed("Unexpected response.")
            }
            return ResolveResult(outcome: outcome, profile: Self.parseProfile(data?["profile"]))
        } catch {
            let ns = error as NSError
            var outcome = ResolveOutcome.failed(ns.localizedDescription)
            if ns.domain == FunctionsErrorDomain {
                switch FunctionsErrorCode(rawValue: ns.code) {
                case .notFound:         outcome = .notFound
                case .invalidArgument:  outcome = .isSelf      // resolve always sends a valid id
                case .permissionDenied: outcome = .blocked
                default: break
                }
            }
            return ResolveResult(outcome: outcome, profile: nil)
        }
    }

    private static func parseProfile(_ raw: Any?) -> ScannedProfile? {
        guard let p = raw as? [String: Any] else { return nil }
        return ScannedProfile(
            username: p["username"] as? String,
            displayName: p["displayName"] as? String,
            photoURL: p["photoURL"] as? String,
            cafes: (p["cafesVisited"] as? NSNumber)?.intValue ?? 0,
            stalls: (p["stallsVisited"] as? NSNumber)?.intValue ?? 0,
            restaurants: (p["restaurantsVisited"] as? NSNumber)?.intValue ?? 0
        )
    }
}
