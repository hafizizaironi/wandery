import SwiftUI

/// Admin-only inspector for the on-device Discover classifier
/// (`PostClassifier` + Apple Vision aesthetic scorer). Lists recent
/// place-tagged posts alongside their stamped `aestheticScore`,
/// `containsFaces`, and `discoverable` verdict — and lets the admin slide
/// a hypothetical threshold to see which photos would pass / blur / be
/// excluded if the floor were tuned.
///
/// Useful for picking the right `PostClassifier.aestheticFloor` value
/// (currently 0.6, suspected too strict).
struct AdminClassifierTuningView: View {
    let onClose: () -> Void

    @State private var service = AdminClassifierTuningService()
    /// Hypothetical aesthetic floor — purely client-side, doesn't persist.
    /// Defaults to the live `PostClassifier.aestheticFloor` so the view
    /// opens showing what the current prod gate produces.
    @State private var threshold: Double = PostClassifier.aestheticFloor
    @State private var sortMode: SortMode = .scoreAscending
    @State private var hideUnclassified = false

    enum SortMode: String, CaseIterable, Identifiable {
        case scoreAscending  = "Score ↑"
        case scoreDescending = "Score ↓"
        case newest          = "Newest"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(AppTheme.cafeAccent.opacity(0.12))
            thresholdPanel
            Divider().background(AppTheme.cafeAccent.opacity(0.12))
            content
        }
        .background(AppTheme.espresso.ignoresSafeArea())
        .task { await service.reload() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Button("Done", action: onClose)
                .font(.subheadline)
                .foregroundStyle(AppTheme.cream.opacity(0.55))
            Spacer()
            VStack(spacing: 1) {
                Text("Classifier Tuning")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)
                Text("\(service.rows.count) loaded")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.cream.opacity(0.45))
            }
            Spacer()
            // Mirror the Done button width so the title stays centred.
            Text("Done")
                .font(.subheadline)
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - Threshold + stats

    private var thresholdPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Aesthetic floor")
                    .font(.caption).bold()
                    .foregroundStyle(AppTheme.cream.opacity(0.75))
                Spacer()
                Text(String(format: "%.2f", threshold))
                    .font(.system(.subheadline, design: .monospaced)).bold()
                    .foregroundStyle(AppTheme.cafeAccent)
            }
            Slider(value: $threshold, in: 0...1, step: 0.01)
                .tint(AppTheme.cafeAccent)

            // Live distribution at the chosen threshold.
            HStack(spacing: 10) {
                statChip(label: "Clear",    count: bucket.clear,    color: .green)
                statChip(label: "Blur",     count: bucket.blur,     color: .orange)
                statChip(label: "Excluded", count: bucket.excluded, color: .red)
                statChip(label: "Unrated",  count: bucket.unrated,  color: .gray)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func statChip(label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(count)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.cream.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Counts at the current threshold — mirrors `classifyPhoto` semantics
    /// in `functions/index.js` so the numbers match what the server does.
    private var bucket: (clear: Int, blur: Int, excluded: Int, unrated: Int) {
        var c = 0, b = 0, e = 0, u = 0
        for row in service.rows {
            switch hypotheticalVerdict(row) {
            case .clear:    c += 1
            case .blur:     b += 1
            case .excluded: e += 1
            case .unrated:  u += 1
            }
        }
        return (c, b, e, u)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if service.isLoading && service.rows.isEmpty {
            VStack(spacing: 8) {
                ProgressView().tint(AppTheme.cream)
                Text("Loading posts…")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.cream.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = service.lastError, service.rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await service.reload() } }
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.cafeAccent)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    Toggle("Hide unclassified", isOn: $hideUnclassified)
                        .font(.caption)
                        .foregroundStyle(AppTheme.cream.opacity(0.75))
                        .tint(AppTheme.cafeAccent)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)

                    Picker("Sort", selection: $sortMode) {
                        ForEach(SortMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)

                    ForEach(filteredRows) { row in
                        rowCard(row)
                            .padding(.horizontal, 14)
                    }

                    if service.hasMore {
                        loadMoreButton
                            .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 28)
            }
        }
    }

    private var filteredRows: [ClassifierTuningRow] {
        let base = hideUnclassified ? service.rows.filter(\.isClassified) : service.rows
        switch sortMode {
        case .newest:
            return base.sorted { $0.createdAt > $1.createdAt }
        case .scoreAscending:
            // Unclassified posts (nil score) sink to the bottom so the
            // visible head is the lowest *classified* scores.
            return base.sorted { (a, b) in
                let sa = a.aestheticScore ?? 999
                let sb = b.aestheticScore ?? 999
                return sa < sb
            }
        case .scoreDescending:
            return base.sorted { (a, b) in
                let sa = a.aestheticScore ?? -1
                let sb = b.aestheticScore ?? -1
                return sa > sb
            }
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await service.loadMore() }
        } label: {
            HStack(spacing: 8) {
                if service.isLoadingMore {
                    ProgressView().tint(AppTheme.cream)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline)
                }
                Text(service.isLoadingMore ? "Loading…" : "Load more")
                    .font(.subheadline.bold())
            }
            .foregroundStyle(AppTheme.cream)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(AppTheme.cream.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(AppTheme.cream.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(service.isLoadingMore)
    }

    // MARK: - Row

    private enum Verdict { case clear, blur, excluded, unrated }

    /// Recomputes what the verdict WOULD be at the user-picked threshold.
    /// Mirrors `classifyPhoto` in `functions/index.js`.
    private func hypotheticalVerdict(_ row: ClassifierTuningRow) -> Verdict {
        guard let faces = row.containsFaces,
              let score = row.aestheticScore else {
            return .unrated
        }
        if faces { return .excluded }
        // Author manually hid (discoverable=false on a photo that would
        // otherwise qualify) — keep excluded so admins see the same gate
        // the server applies.
        if row.discoverable == false && score >= threshold {
            return .excluded
        }
        return score >= threshold ? .clear : .blur
    }

    private func rowCard(_ row: ClassifierTuningRow) -> some View {
        let verdict = hypotheticalVerdict(row)
        return HStack(alignment: .top, spacing: 12) {
            thumbnail(row)
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(verdictColor(verdict).opacity(0.5), lineWidth: 2)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(row.placeName.isEmpty ? "(unnamed place)" : row.placeName)
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    scoreBadge(row)
                    facesBadge(row)
                    verdictBadge(verdict)
                }

                HStack(spacing: 6) {
                    Text(relativeDate(row.createdAt))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.cream.opacity(0.45))
                    if let d = row.discoverable {
                        Text("· stored: \(d ? "clear" : "blur")")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cream.opacity(0.45))
                    } else {
                        Text("· stored: unrated")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.cream.opacity(0.45))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(AppTheme.cream.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.cream.opacity(0.10), lineWidth: 1)
        )
    }

    private func scoreBadge(_ row: ClassifierTuningRow) -> some View {
        Group {
            if let score = row.aestheticScore {
                Text(String(format: "%.2f", score))
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(scoreTint(score).opacity(0.18), in: Capsule())
                    .foregroundStyle(scoreTint(score))
            } else {
                Text("—")
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.gray.opacity(0.18), in: Capsule())
                    .foregroundStyle(.gray)
            }
        }
    }

    private func facesBadge(_ row: ClassifierTuningRow) -> some View {
        Group {
            if let faces = row.containsFaces {
                HStack(spacing: 3) {
                    Image(systemName: faces ? "person.fill" : "person")
                        .font(.caption2)
                    Text(faces ? "faces" : "no")
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((faces ? Color.red : Color.green).opacity(0.18), in: Capsule())
                .foregroundStyle(faces ? .red : .green)
            } else {
                EmptyView()
            }
        }
    }

    private func verdictBadge(_ v: Verdict) -> some View {
        let label: String = {
            switch v {
            case .clear: return "CLEAR"
            case .blur: return "BLUR"
            case .excluded: return "EXCLUDE"
            case .unrated: return "UNRATED"
            }
        }()
        return Text(label)
            .font(.caption2.bold().monospaced())
            .kerning(0.5)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(verdictColor(v).opacity(0.18), in: Capsule())
            .foregroundStyle(verdictColor(v))
    }

    private func verdictColor(_ v: Verdict) -> Color {
        switch v {
        case .clear: return .green
        case .blur: return .orange
        case .excluded: return .red
        case .unrated: return .gray
        }
    }

    private func scoreTint(_ s: Double) -> Color {
        if s >= threshold { return .green }
        if s >= max(0, threshold - 0.15) { return .orange }
        return .red
    }

    @ViewBuilder
    private func thumbnail(_ row: ClassifierTuningRow) -> some View {
        let urlString = row.thumbnailURL ?? row.mediaURL
        if let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Color.black.opacity(0.4)
                }
            }
        } else {
            Color.black.opacity(0.4)
        }
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}
