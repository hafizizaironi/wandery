import Foundation
import FirebaseFirestore
import FirebaseAuth

/// First-party, pseudonymous product analytics. Buffers a curated set of
/// events and batch-writes them to `analyticsEvents`; the `onAnalyticsEvent`
/// Cloud Function aggregates them into the admin-only `adminAnalytics/*`
/// rollups that power the in-app Admin → Analytics dashboard.
///
/// No third-party SDK and no cross-app tracking — events carry the signed-in
/// uid (so the admin can see journeys) but raw rows TTL-expire (~30 days) and
/// `NSPrivacyTracking` stays false. Singleton so the ~20 call sites don't need
/// dependency-injection threading; the uid is resolved from FirebaseAuth at
/// log time, so signed-out taps are simply dropped.
@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()
    private init() {}

    private let db = Firestore.firestore()
    private var buffer: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?

    private var currentArea: AnalyticsArea?
    private var areaEnteredAt: Date?

    private static let build =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    // MARK: - Public API

    /// A discrete button / action.
    func log(_ event: AnalyticsEvent, area: AnalyticsArea) {
        enqueue(event: event.rawValue, area: area.rawValue, kind: "button", value: nil)
    }

    /// The user moved to a new area. Emits a dwell event for the area they're
    /// leaving and a screen-view for the one they're entering.
    func screen(_ area: AnalyticsArea) {
        guard area != currentArea else { return }
        closeDwell(now: Date())
        currentArea = area
        areaEnteredAt = Date()
        enqueue(event: "screen_\(area.rawValue)", area: area.rawValue,
                kind: "screen_view", value: nil)
    }

    /// App went to background — close the open dwell and flush the buffer.
    func appBackgrounded() {
        closeDwell(now: Date())
        flush()
    }

    /// App returned to foreground — restart the dwell clock for the current area.
    func appForegrounded() { areaEnteredAt = Date() }

    // MARK: - Internals

    private func closeDwell(now: Date) {
        guard let area = currentArea, let start = areaEnteredAt else { return }
        let secs = now.timeIntervalSince(start)
        areaEnteredAt = now
        guard secs >= 1 else { return }            // ignore flickers
        enqueue(event: "dwell_\(area.rawValue)", area: area.rawValue,
                kind: "screen_dwell", value: min(secs, 3600))   // cap outliers
    }

    private func enqueue(event: String, area: String, kind: String, value: Double?) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let now = Date()
        var doc: [String: Any] = [
            "uid": uid,
            "event": event,
            "area": area,
            "kind": kind,
            "build": Self.build,
            "day": Self.dayFormatter.string(from: now),
            "ts": FieldValue.serverTimestamp(),
            "expireAt": Timestamp(date: now.addingTimeInterval(30 * 24 * 3600)),
        ]
        if let value { doc["value"] = value }
        buffer.append(doc)
        if buffer.count >= 15 { flush() } else { scheduleFlush() }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        let docs = buffer
        buffer.removeAll()
        let batch = db.batch()
        for doc in docs {
            batch.setData(doc, forDocument: db.collection("analyticsEvents").document())
        }
        Task { try? await batch.commit() }   // fire-and-forget; offline cache queues it
    }
}

/// The areas a user can "wander" between (screen views + dwell).
enum AnalyticsArea: String {
    case map, hero, profile, chat, camera, placeDetail, friends, myHunt, trending, code
}

/// The curated set of high-value button/action events.
enum AnalyticsEvent: String {
    case postPublish      = "post_publish"
    case openMessages     = "open_messages"
    case sendMessage      = "send_message"
    case reactPost        = "react_post"
    case addFriend        = "add_friend"
    case acceptFriend     = "accept_friend"
    case openWanderyCode  = "open_wandery_code"
    case scanWanderyCode  = "scan_wandery_code"
    case savePlace        = "save_place"
    case openTrending     = "open_trending"
    case recenterMap      = "recenter_map"
    case toggleCircle     = "toggle_circle"
    case openPlaceDetail  = "open_place_detail"
    case openGoogleMaps   = "open_google_maps"
    case openWaze         = "open_waze"
    case inviteContact    = "invite_contact"
    case editProfile      = "edit_profile"
    case openLibrary      = "open_library"
    case tagPlace         = "tag_place"
    case addWidgetTutorial = "open_widget_tutorial"
}
