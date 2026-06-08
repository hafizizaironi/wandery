import SwiftUI
import CoreLocation

/// Lightweight selection result handed back to the post composer.
/// `id` is nil for places that don't exist in our DB yet — the post
/// service will call `findOrCreatePlace` to dedup/insert before writing.
struct PlaceSelection: Equatable, Hashable {
    var id: String?
    var googlePlaceId: String?
    var name: String
    var type: PlaceType
    var lat: Double
    var lng: Double
    /// True when the user is creating a new place (not picking an existing one).
    var isNew: Bool
    /// Google formatted address, carried through so `findOrCreatePlace` can
    /// store it on a newly-created place doc (nil for DB picks / by-name adds).
    var address: String? = nil
}

/// Candidate row shown in the picker — sourced from Google Places nearby/autocomplete
/// or our own places collection. Source labelled so the UI can hint provenance.
struct PlaceCandidate: Identifiable, Equatable {
    enum Source: Equatable { case google, db }
    let id: String
    var googlePlaceId: String?
    var name: String
    var address: String?
    var suggestedType: PlaceType
    var lat: Double
    var lng: Double
    var distanceMeters: Double?
    var source: Source
    /// Total number of post-tags against this place across all users.
    /// Stamped by the `onPostCreatePlaceVisit` Cloud Function. Only set
    /// for `.db` candidates; nil for fresh Google rows we haven't ingested
    /// yet.
    var globalVisitCount: Int?
}

@MainActor
@Observable
final class PlacePickerViewModel {
    var query: String = ""
    var candidates: [PlaceCandidate] = []
    var isLoading = false
    var errorMessage: String?

    var lastKnownCoord: CLLocationCoordinate2D?

    /// Unfiltered nearby results, kept so we can re-rank instantly on every
    /// keystroke without hitting the network. Network autocomplete is layered
    /// on top after a debounce to enrich with names that are out of the
    /// nearby radius.
    private var nearbyCache: [PlaceCandidate] = []
    private var searchTask: Task<Void, Never>?

    func loadNearby(around coord: CLLocationCoordinate2D?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let center: CLLocationCoordinate2D?
        if let coord {
            center = coord
        } else {
            center = await LocationProvider.shared.currentCoordinate()
        }
        guard let center else {
            errorMessage = "Couldn't get your location."
            candidates = []
            nearbyCache = []
            return
        }
        lastKnownCoord = center
        do {
            let result = try await PlacePickerService.shared.nearby(center)
            nearbyCache = result
            candidates = result
        } catch {
            errorMessage = error.localizedDescription
            candidates = []
            nearbyCache = []
        }
    }

    /// Called on every keystroke. Re-ranks the cached nearby list immediately
    /// (zero latency) and schedules a debounced remote autocomplete to fold in
    /// non-nearby matches.
    func queryChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        if trimmed.isEmpty {
            candidates = nearbyCache
            errorMessage = nil
            return
        }
        candidates = Self.rank(nearbyCache, by: trimmed)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await self?.runAutocomplete(trimmed)
        }
    }

    private func runAutocomplete(_ text: String) async {
        // Two parallel sources — Google's text autocomplete (broad, can find
        // anything with a Place ID) and a Firestore name-prefix query against
        // the global `places` collection (catches DB places outside the
        // nearby radius). Both are best-effort; either failing must not erase
        // the other or the local nearbyCache re-rank we already showed.
        async let remoteR: Result<[PlaceCandidate], Error> = {
            do { return .success(try await PlacePickerService.shared.autocomplete(text, around: self.lastKnownCoord)) }
            catch { return .failure(error) }
        }()
        async let dbR: Result<[PlaceCandidate], Error> = {
            do { return .success(try await PlacePickerService.shared.searchDbByName(text, around: self.lastKnownCoord)) }
            catch { return .failure(error) }
        }()

        let (remoteResult, dbResult) = await (remoteR, dbR)
        let remote = (try? remoteResult.get()) ?? []
        let dbHits = (try? dbResult.get()) ?? []

        // Merge order matters — `byId` keeps the FIRST insertion per id, and
        // nearbyCache rows carry coords + distance the autocomplete results
        // don't. Order: nearbyCache → DB-name-hits → Google autocomplete.
        var byId: [String: PlaceCandidate] = [:]
        for c in nearbyCache { byId[c.id] = c }
        for c in dbHits where byId[c.id] == nil {
            byId[c.id] = c
        }
        for c in remote where byId[c.id] == nil {
            byId[c.id] = c
        }
        candidates = Self.rank(Array(byId.values), by: text)
        errorMessage = nil
    }

    /// Score-then-filter relevance ranking. Anything scoring 0 is dropped so
    /// the list reflects only items related to what's typed.
    /// - Exact name match: 1000
    /// - Name starts with query: 500
    /// - Any word in the name starts with query: 300
    /// - Name contains query substring: 150
    /// - Each multi-word query token found in name: +60 each
    /// - Address contains query: 50
    /// - Distance penalty: −d/50000 (5 km ≈ −0.1, just a tiebreak)
    private static func rank(_ items: [PlaceCandidate], by query: String) -> [PlaceCandidate] {
        let q = query.lowercased()
        let qWords = q.split(separator: " ").map(String.init)

        func score(_ c: PlaceCandidate) -> Double {
            let name = c.name.lowercased()
            let addr = (c.address ?? "").lowercased()
            var s: Double = 0
            if name == q { s += 1000 }
            if name.hasPrefix(q) { s += 500 }
            for w in name.split(separator: " ") where w.hasPrefix(q) {
                s += 300
                break
            }
            if name.contains(q) { s += 150 }
            if qWords.count > 1 {
                for w in qWords where name.contains(w) {
                    s += 60
                }
            }
            if addr.contains(q) { s += 50 }
            if let d = c.distanceMeters {
                s -= d / 50_000
            }
            return s
        }
        return items
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func search(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            await loadNearby(around: lastKnownCoord)
            return
        }
        await runAutocomplete(text)
    }
}

struct PlacePickerSheet: View {
    let onSelect: (PlaceSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var vm = PlacePickerViewModel()
    @State private var typeOverride: PlaceType?
    @State private var addingNew = false
    @State private var newName = ""
    @State private var newType: PlaceType = .restaurant

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()
            content.padding(.top, 16)
        }
        .task { await vm.loadNearby(around: nil) }
        .keyboardDismissToolbar()
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            searchField
            typeChips
            if addingNew {
                addNewSection
            } else {
                listSection
            }
        }
        .padding(.horizontal)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textSecondary)
                .accessibilityHidden(true)
            TextField("Search places nearby", text: $vm.query)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit { Task { await vm.search(vm.query) } }
                .onChange(of: vm.query) { _, newValue in
                    vm.queryChanged(newValue)
                }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(AppTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppTheme.borderSubtle, lineWidth: 1) }
    }

    private var typeChips: some View {
        HStack(spacing: 12) {
            ForEach(PlaceType.allCases, id: \.self) { t in
                let selected = (typeOverride == t)
                Button {
                    typeOverride = selected ? nil : t
                } label: {
                    Text(t.emoji)
                        .font(.title2)
                        .frame(width: 72, height: 52)
                        .background(
                            selected ? AppTheme.accentAction.opacity(0.15) : AppTheme.surfacePrimary,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().stroke(
                                selected ? AppTheme.accentAction : AppTheme.borderSubtle,
                                lineWidth: selected ? 1.5 : 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var listSection: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredCandidates) { c in
                    candidateRow(c)
                }
                if filteredCandidates.isEmpty && !vm.isLoading {
                    emptyStateHint
                }
                Button {
                    newName = vm.query
                    newType = typeOverride ?? .restaurant
                    addingNew = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text(vm.query.isEmpty ? "Add a new place" : "Add \"\(vm.query)\" as a new place")
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(12)
                    .background(AppTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(AppTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)
        }
        .overlay {
            if vm.isLoading { ProgressView().controlSize(.large) }
        }
    }

    private var emptyStateHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "mappin.slash")
                .font(.title3)
                .foregroundStyle(AppTheme.textSecondary)
                .accessibilityHidden(true)
            Text("No food places nearby")
                .font(.subheadline).bold()
                .foregroundStyle(AppTheme.textPrimary)
            Text("Search by name above, or add a new place below.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var filteredCandidates: [PlaceCandidate] {
        guard let t = typeOverride else { return vm.candidates }
        return vm.candidates.filter { $0.suggestedType == t }
    }

    private func candidateRow(_ c: PlaceCandidate) -> some View {
        Button {
            Task { await selectCandidate(c) }
        } label: {
            HStack(spacing: 12) {
                Text(c.suggestedType.emoji).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.name)
                            .font(.subheadline).bold()
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        if let visits = c.globalVisitCount, visits >= 3 {
                            // Trending pill — only shown for places that
                            // have meaningfully accumulated activity.
                            // Threshold (3) keeps brand-new popular places
                            // from getting an under-earned badge.
                            Text("🔥 \(visits)")
                                .font(.caption2).bold()
                                .foregroundStyle(AppTheme.accentAction)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AppTheme.accentAction.opacity(0.12)))
                                .overlay {
                                    Capsule().stroke(AppTheme.accentAction.opacity(0.30), lineWidth: 0.7)
                                }
                        }
                    }
                    if let addr = c.address {
                        Text(addr).font(.caption).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer()
                if let d = c.distanceMeters {
                    Text(formatDistance(d))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(12)
            .background(AppTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var addNewSection: some View {
        VStack(spacing: 12) {
            TextField("Place name", text: $newName)
                .padding(12)
                .background(AppTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 12))

            Picker("Type", selection: $newType) {
                ForEach(PlaceType.allCases, id: \.self) { t in
                    Text("\(t.emoji)  \(t.label)").tag(t)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button("Back") { addingNew = false }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save place") {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onSelect(PlaceSelection(
                        id: nil, googlePlaceId: nil,
                        name: trimmed, type: newType,
                        lat: 0, lng: 0,  // will be filled by current-location lookup at write time
                        isNew: true
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func selectCandidate(_ c: PlaceCandidate) async {
        let resolvedType = typeOverride ?? c.suggestedType
        var lat = c.lat
        var lng = c.lng
        // Autocomplete results don't carry coordinates — resolve before returning.
        if (lat == 0 && lng == 0), let gid = c.googlePlaceId {
            if let coord = try? await PlacePickerService.shared.fetchCoordinate(googlePlaceId: gid) {
                lat = coord.latitude
                lng = coord.longitude
            }
        }
        onSelect(PlaceSelection(
            id: c.source == .db ? c.id : nil,
            googlePlaceId: c.googlePlaceId,
            name: c.name,
            type: resolvedType,
            lat: lat, lng: lng,
            isNew: c.source == .google,
            address: c.address
        ))
        dismiss()
    }

    private func formatDistance(_ m: Double) -> String {
        if m < 1000 {
            "\(Int(m)) m"
        } else {
            "\((m / 1000).formatted(.number.precision(.fractionLength(1)))) km"
        }
    }
}

#Preview {
    PlacePickerSheet { sel in
        dlog("picked:", sel)
    }
}
