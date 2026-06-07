import SwiftUI
import UIKit

/// Admin-only curation surface for the "Creator's Pick" Discover feed.
/// Lists currently-featured places in their display order with drag-to-
/// reorder + swipe-to-remove, and offers a sheet to add more places from
/// the rest of the catalogue. All writes go to `places/{id}.creatorPickOrder`
/// via `CreatorPicksAdminService` — no separate collection.
struct CreatorPicksAdminView: View {
    let onClose: () -> Void

    @State private var service = CreatorPicksAdminService()
    @State private var showAddSheet = false
    @State private var pendingRemove: CreatorPickRow?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(AppTheme.cafeAccent.opacity(0.12))
            content
        }
        .background(AppTheme.espresso.ignoresSafeArea())
        .task { await service.reload() }
        .sheet(isPresented: $showAddSheet) {
            CreatorPicksAddSheet(service: service)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("Remove from picks?", isPresented: Binding(
            get: { pendingRemove != nil },
            set: { if !$0 { pendingRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRemove = nil }
            Button("Remove", role: .destructive) {
                if let row = pendingRemove {
                    Task {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        await service.remove(row)
                    }
                }
                pendingRemove = nil
            }
        } message: {
            if let row = pendingRemove {
                Text("“\(row.name)” will no longer appear in Creator's Pick.")
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Button("Done", action: onClose)
                .font(.subheadline)
                .contrastAware(AppTheme.cream, opacity: 0.55)

            Spacer()

            VStack(spacing: 1) {
                Text("Creator's Pick")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)
                Text("\(service.picks.count) featured")
                    .font(.caption2)
                    .contrastAware(AppTheme.cream, opacity: 0.45)
            }

            Spacer()

            // Mirror Done width so the title stays optically centred.
            Text("Done")
                .font(.subheadline)
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if service.isLoading && service.picks.isEmpty {
            loading
        } else if service.picks.isEmpty {
            emptyState
        } else {
            picksList
        }
    }

    private var loading: some View {
        VStack {
            Spacer()
            ProgressView().tint(AppTheme.cream)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 60)
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .contrastAware(AppTheme.cream, opacity: 0.25)
                .accessibilityHidden(true)
            Text("No picks yet")
                .font(.subheadline).bold()
                .contrastAware(AppTheme.cream, opacity: 0.65)
            Text("Featured places appear in the Creator's Pick map for everyone within 15 km.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .contrastAware(AppTheme.cream, opacity: 0.4)
                .padding(.horizontal, 32)
            Spacer()
            addButton
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
    }

    private var picksList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(service.picks) { pick in
                    CreatorPickRowView(
                        row: pick,
                        index: (service.picks.firstIndex(of: pick) ?? 0) + 1
                    )
                    .listRowBackground(AppTheme.espresso)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pendingRemove = pick
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .onMove { source, destination in
                    var reordered = service.picks
                    reordered.move(fromOffsets: source, toOffset: destination)
                    let ids = reordered.map(\.id)
                    Task {
                        UISelectionFeedbackGenerator().selectionChanged()
                        await service.reorder(byIds: ids)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppTheme.espresso)
            .environment(\.editMode, .constant(.active))

            if let err = service.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.errorRed.opacity(0.7))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }

            addButton
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
    }

    private var addButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showAddSheet = true
        } label: {
            Label("Add to picks", systemImage: "plus")
                .font(.subheadline).bold()
                .foregroundStyle(AppTheme.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.cafeAccent)
                .clipShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pick row

private struct CreatorPickRowView: View {
    let row: CreatorPickRow
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.caption.monospacedDigit()).bold()
                .frame(width: 22, alignment: .leading)
                .contrastAware(AppTheme.cream, opacity: 0.4)

            if let url = URL(string: row.photoURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: AppTheme.cream.opacity(0.08)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.type.emoji)
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(row.name)
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.cream)
                        .lineLimit(1)
                }
                if !row.neighborhood.isEmpty {
                    Text(row.neighborhood)
                        .font(.caption2)
                        .contrastAware(AppTheme.cream, opacity: 0.45)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Add sheet

private struct CreatorPicksAddSheet: View {
    let service: CreatorPicksAdminService
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [CreatorPickRow] {
        guard !query.isEmpty else { return service.candidates }
        return service.candidates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.neighborhood.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to picks")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.cafeAccent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            searchField
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            if filtered.isEmpty {
                Spacer()
                Text(query.isEmpty
                     ? "No more places with photos to feature."
                     : "No matches for “\(query)”.")
                    .font(.caption)
                    .contrastAware(AppTheme.cream, opacity: 0.5)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { row in
                            Button {
                                Task {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    await service.add(row)
                                }
                            } label: {
                                CreatorPickCandidateRow(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(AppTheme.espresso.ignoresSafeArea())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .contrastAware(AppTheme.cream, opacity: 0.4)
            TextField("Search places", text: $query)
                .font(.footnote)
                .foregroundStyle(AppTheme.textPrimary)
                .tint(AppTheme.cafeAccent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.cream.opacity(0.05))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        }
    }
}

private struct CreatorPickCandidateRow: View {
    let row: CreatorPickRow

    var body: some View {
        HStack(spacing: 12) {
            if let url = URL(string: row.photoURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: AppTheme.cream.opacity(0.08)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.type.emoji)
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(row.name)
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.cream)
                        .lineLimit(1)
                }
                if !row.neighborhood.isEmpty {
                    Text(row.neighborhood)
                        .font(.caption2)
                        .contrastAware(AppTheme.cream, opacity: 0.45)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "plus.circle.fill")
                .font(.body)
                .foregroundStyle(AppTheme.cafeAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppTheme.cream.opacity(0.05)))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        }
    }
}
