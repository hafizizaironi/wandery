import SwiftUI

/// Admin-only usage dashboard: which areas users wander (views + avg dwell),
/// the top button actions, and a 7-day trend. Reads the server-aggregated
/// `adminAnalytics/*` rollups via `AdminAnalyticsService`. Admin-gated entry
/// lives in `ProfileHomeView`'s settings section.
struct AdminAnalyticsView: View {
    var onClose: () -> Void = {}

    @State private var svc = AdminAnalyticsService()

    /// Pseudo-events (screen views / dwell) live in `areas`; keep them out of
    /// the button leaderboard.
    private var buttonEvents: [AdminAnalyticsService.EventStat] {
        svc.events.filter { !$0.id.hasPrefix("screen_") && !$0.id.hasPrefix("dwell_") }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if svc.loading && svc.totalEvents == 0 {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        summary
                        trendSection
                        areaSection
                        buttonSection
                    }
                    if let error = svc.error {
                        Text(error).font(.caption).foregroundStyle(AppTheme.errorRed)
                    }
                }
                .padding(20)
            }
            .background(AppTheme.surfaceCanvas.ignoresSafeArea())
            .navigationTitle("Analytics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done", action: onClose) } }
            .refreshable { await svc.reload() }
            .task { await svc.reload() }
        }
    }

    // MARK: - Sections

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(svc.totalEvents)").font(.huntSerif(40)).foregroundStyle(AppTheme.textPrimary)
            Text("events tracked").font(.caption).foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Last 7 days")
            let maxV = max(svc.trend.map(\.total).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(svc.trend) { p in
                    VStack(spacing: 5) {
                        Text("\(p.total)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.cafeAccent.opacity(0.85))
                            .frame(height: max(4, CGFloat(p.total) / CGFloat(maxV) * 90))
                        Text(p.label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
    }

    private var areaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Where they wander")
            if svc.areas.isEmpty {
                emptyHint
            } else {
                let maxV = max(svc.areas.map(\.views).max() ?? 1, 1)
                ForEach(svc.areas) { a in
                    statRow(label: prettify(a.id),
                            value: "\(a.views) views · \(dwell(a.avgDwell)) avg",
                            fraction: Double(a.views) / Double(maxV))
                }
            }
        }
    }

    private var buttonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Top actions")
            if buttonEvents.isEmpty {
                emptyHint
            } else {
                let maxV = max(buttonEvents.map(\.count).max() ?? 1, 1)
                ForEach(buttonEvents) { e in
                    statRow(label: prettify(e.id), value: "\(e.count)",
                            fraction: Double(e.count) / Double(maxV))
                }
            }
        }
    }

    // MARK: - Bits

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(AppTheme.cafeAccent)
    }

    private func statRow(label: String, value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(value).font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(AppTheme.cafeAccent.opacity(0.85))
                    .frame(width: max(6, geo.size.width * CGFloat(min(max(fraction, 0), 1))), height: 6)
            }
            .frame(height: 6)
        }
    }

    private var emptyHint: some View {
        Text("No data yet — use the app (or have testers use it), then pull to refresh.")
            .font(.caption).foregroundStyle(AppTheme.textSecondary)
    }

    private func dwell(_ s: Double) -> String {
        s >= 60 ? String(format: "%.1fm", s / 60) : String(format: "%.0fs", s)
    }

    private func prettify(_ id: String) -> String {
        id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
