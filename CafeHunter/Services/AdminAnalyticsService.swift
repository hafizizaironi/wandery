import Foundation
import FirebaseFirestore

/// Reads the server-aggregated `adminAnalytics/*` rollups for the admin
/// dashboard. Direct Firestore reads, gated by the `isAdmin()` rule (same
/// pattern as `AdminClassifierTuningService`). No writes.
@MainActor
@Observable
final class AdminAnalyticsService {
    struct AreaStat: Identifiable { let id: String; let views: Int; let avgDwell: Double }
    struct EventStat: Identifiable { let id: String; let count: Int }
    struct DayPoint: Identifiable { let id: String; let label: String; let total: Int }

    private(set) var totalEvents = 0
    private(set) var areas: [AreaStat] = []
    private(set) var events: [EventStat] = []
    private(set) var trend: [DayPoint] = []
    private(set) var loading = false
    private(set) var error: String?

    private let db = Firestore.firestore()

    func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let rollup = try await db.collection("adminAnalytics").document("rollup").getDocument()
            parseRollup(rollup.data() ?? [:])
            try await loadTrend()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func parseRollup(_ data: [String: Any]) {
        totalEvents = intOf(data["totalEvents"])
        if let ev = data["events"] as? [String: Any] {
            events = ev.map { EventStat(id: $0.key, count: intOf($0.value)) }
                .filter { $0.count > 0 }
                .sorted { $0.count > $1.count }
        }
        if let ar = data["areas"] as? [String: Any] {
            areas = ar.compactMap { key, value in
                guard let m = value as? [String: Any] else { return nil }
                let dc = intOf(m["dwellCount"])
                let avg = dc > 0 ? dblOf(m["dwellSeconds"]) / Double(dc) : 0
                return AreaStat(id: key, views: intOf(m["views"]), avgDwell: avg)
            }
            .sorted { $0.views > $1.views }
        }
    }

    private func loadTrend() async throws {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd"
        let cal = Calendar.current
        var points: [DayPoint] = []
        for offset in (0..<7).reversed() {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let id = fmt.string(from: date)
            let doc = try await db.collection("adminAnalytics").document("daily_\(id)").getDocument()
            points.append(DayPoint(id: id, label: String(id.suffix(2)), total: intOf(doc.data()?["totalEvents"])))
        }
        trend = points
    }

    // Firestore numbers can bridge as Int / Int64 / Double / NSNumber.
    private func intOf(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let i = any as? Int64 { return Int(i) }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }
    private func dblOf(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }
}
