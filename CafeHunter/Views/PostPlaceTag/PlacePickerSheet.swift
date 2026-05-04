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
}

@MainActor
@Observable
final class PlacePickerViewModel {
    var query: String = ""
    var candidates: [PlaceCandidate] = []
    var isLoading = false
    var errorMessage: String?

    var lastKnownCoord: CLLocationCoordinate2D?

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
            return
        }
        lastKnownCoord = center
        do {
            candidates = try await PlacePickerService.shared.nearby(center)
        } catch {
            errorMessage = error.localizedDescription
            candidates = []
        }
    }

    func search(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            await loadNearby(around: lastKnownCoord)
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            candidates = try await PlacePickerService.shared.autocomplete(text, around: lastKnownCoord)
        } catch {
            errorMessage = error.localizedDescription
            candidates = []
        }
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
        NavigationStack {
            ZStack {
                AppTheme.surfaceCanvas.ignoresSafeArea()
                content
            }
            .navigationTitle("Tag a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Skip") {
                        dismiss()
                    }
                }
            }
            .task { await vm.loadNearby(around: nil) }
        }
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
            TextField("Search places nearby", text: $vm.query)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit { Task { await vm.search(vm.query) } }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(AppTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var typeChips: some View {
        HStack(spacing: 8) {
            ForEach(PlaceType.allCases, id: \.self) { t in
                Button {
                    typeOverride = (typeOverride == t) ? nil : t
                } label: {
                    Text("\(t.emoji)  \(t.label)")
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 6).padding(.horizontal, 12)
                        .background(
                            (typeOverride == t ? AppTheme.accentAction : AppTheme.surfacePrimary),
                            in: Capsule()
                        )
                        .foregroundStyle(typeOverride == t ? AppTheme.textOnAccent : AppTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
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
            Text("No food places nearby")
                .font(.subheadline.weight(.semibold))
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
                    Text(c.name).font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
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
            isNew: c.source == .google
        ))
        dismiss()
    }

    private func formatDistance(_ m: Double) -> String {
        m < 1000 ? "\(Int(m)) m" : String(format: "%.1f km", m / 1000)
    }
}

#Preview {
    PlacePickerSheet { sel in
        print("picked:", sel)
    }
}
