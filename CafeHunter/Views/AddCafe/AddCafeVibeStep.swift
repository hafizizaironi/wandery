import SwiftUI

struct AddCafeVibeStep: View {
    @Binding var track: VibeTrack?
    /// Read-only hints from prior steps — used to seed contextual suggestions.
    let audiences: Set<Audience>
    let placeType: PlaceType
    var onContinue: () -> Void

    @State private var player = VibePreviewPlayer()

    @State private var query: String = ""
    @State private var isSearching = false
    @State private var searchResults: [VibeTrack] = []
    @State private var suggestions: [VibeTrack] = []
    @State private var suggestionsLoaded = false
    @State private var searchTask: Task<Void, Never>? = nil

    @State private var appear = false
    @State private var ctaCounter = 0
    @FocusState private var focused: Bool

    private let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.37)

    var body: some View {
        VStack(spacing: 14) {
            header
                .padding(.horizontal, 24)

            searchField
                .padding(.horizontal, 24)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    if let track {
                        pinnedSelectedRow(track: track)
                            .padding(.top, 4)
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }

                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        suggestedSection
                    } else {
                        searchResultsSection
                    }

                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.interactively)

            continueButton
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 18)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.88).delay(0.08)) {
                appear = true
            }
            loadSuggestionsIfNeeded()
        }
        .onDisappear {
            // Don't keep audio playing once we've left the step.
            player.stop()
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: track)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("What song")
                .font(.system(size: 20, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(.white.opacity(0.72))

            Text("captures this place?")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(warmGradient)
                .multilineTextAlignment(.center)
                .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.30),
                        radius: 14, x: 0, y: 3)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white.opacity(0.55))

            TextField(
                "",
                text: $query,
                prompt: Text("Search songs or artists")
                    .foregroundColor(.white.opacity(0.35))
            )
            .focused($focused)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.white)
            .tint(Color(red: 0.99, green: 0.72, blue: 0.40))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .onSubmit { runSearch(now: true) }
            .onChange(of: query) { _, _ in runSearch(now: false) }

            if isSearching {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white.opacity(0.7))
            } else if !query.isEmpty {
                Button {
                    query = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(focused ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    focused
                    ? Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.7)
                    : Color.white.opacity(0.14),
                    lineWidth: focused ? 1.2 : 0.8
                )
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
    }

    // MARK: - Suggested

    @ViewBuilder
    private var suggestedSection: some View {
        sectionHeader(VibeSuggestionSeeds.headerLabel(for: audiences))

        if !suggestionsLoaded {
            loadingRow
        } else if suggestions.isEmpty {
            Text("Couldn't load suggestions — search above instead.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
                .padding(.vertical, 12)
        } else {
            ForEach(suggestions) { item in
                TrackRow(
                    track: item,
                    isSelected: track?.id == item.id,
                    isPlaying: player.isPlaying(item),
                    progress: player.isPlaying(item) ? player.progress : 0
                ) {
                    selectTrack(item)
                }
            }
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsSection: some View {
        if isSearching && searchResults.isEmpty {
            loadingRow
        } else if searchResults.isEmpty {
            Text("No tracks match — try another name.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
                .padding(.vertical, 12)
        } else {
            ForEach(searchResults) { item in
                TrackRow(
                    track: item,
                    isSelected: track?.id == item.id,
                    isPlaying: player.isPlaying(item),
                    progress: player.isPlaying(item) ? player.progress : 0
                ) {
                    selectTrack(item)
                }
            }
        }
    }

    // MARK: - Pinned selected

    private func pinnedSelectedRow(track t: VibeTrack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOUR PICK")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
                .tracking(1.4)

            TrackRow(
                track: t,
                isSelected: true,
                isPlaying: player.isPlaying(t),
                progress: player.isPlaying(t) ? player.progress : 0
            ) {
                selectTrack(t)
            }

            HStack(spacing: 10) {
                if let url = t.spotifyOpenURL {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .bold))
                            Text("Open in Spotify")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(spotifyGreen)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    clearPick()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Pick different")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
                .tracking(1.4)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.top, 6)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(.white.opacity(0.6))
            Text("Finding tracks…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    // MARK: - Continue

    private var continueButton: some View {
        Button {
            ctaCounter += 1
            player.stop()
            onContinue()
        } label: {
            HStack(spacing: 10) {
                Text(track == nil ? "Continue without a song" : "Continue")
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(track == nil
                             ? .white.opacity(0.85)
                             : Color(red: 0.12, green: 0.04, blue: 0.06))
            .padding(.horizontal, 28)
            .padding(.vertical, 15)
            .background(
                Capsule()
                    .fill(
                        track == nil
                        ? AnyShapeStyle(Color.white.opacity(0.10))
                        : AnyShapeStyle(LinearGradient(
                            colors: [
                                Color(red: 1.00, green: 0.90, blue: 0.64),
                                Color(red: 0.99, green: 0.72, blue: 0.40)
                            ],
                            startPoint: .top,
                            endPoint:   .bottom
                        ))
                    )
                    .overlay(
                        Capsule().stroke(
                            Color.white.opacity(track == nil ? 0.18 : 0),
                            lineWidth: 0.5
                        )
                    )
                    .shadow(
                        color: track == nil
                        ? .clear
                        : Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.48),
                        radius: 16, x: 0, y: 5
                    )
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .heavy), trigger: ctaCounter)
    }

    // MARK: - Actions

    private func selectTrack(_ item: VibeTrack) {
        // Tap = select + preview. Tapping the already-selected track toggles
        // the preview without changing the selection.
        if track?.id != item.id {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                track = item
            }
        }
        player.toggle(item)
    }

    private func clearPick() {
        player.stop()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            track = nil
        }
    }

    private func runSearch(now: Bool) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            isSearching = false
            searchResults = []
            return
        }

        searchTask = Task {
            if !now {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }

            await MainActor.run { isSearching = true }
            let results = await ITunesSearchService.search(term: q, limit: 20)
            if Task.isCancelled { return }
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }

    private func loadSuggestionsIfNeeded() {
        guard !suggestionsLoaded else { return }
        let terms = VibeSuggestionSeeds.queries(for: audiences)
        Task {
            let tracks = await ITunesSearchService.mergedSearch(terms: terms, perTerm: 6)
            await MainActor.run {
                // Cap to a comfortable scrollable list length.
                suggestions = Array(tracks.prefix(16))
                suggestionsLoaded = true
            }
        }
    }
}

// MARK: - Track row

private struct TrackRow: View {
    let track: VibeTrack
    let isSelected: Bool
    let isPlaying: Bool
    /// 0…1 progress over the 15s preview cap.
    let progress: Double
    var onTap: () -> Void

    @State private var tapCounter = 0

    var body: some View {
        HStack(spacing: 12) {
            // Artwork with playing-state indicator
            ZStack {
                AsyncImage(url: URL(string: track.artworkURL(size: 200))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if isPlaying {
                    // Dim + show pause glyph over the art to signal playing state.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 52, height: 52)
                    Image(systemName: "pause.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(0.0)
                        // Only shown on hover/press states in future — keep slot.
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(track.artist)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)

                if isPlaying {
                    // Progress strip visible only during playback.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.99, green: 0.72, blue: 0.40),
                                            Color(red: 0.96, green: 0.32, blue: 0.46)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(warmGradient)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .overlay(rowBorder)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            tapCounter += 1
            onTap()
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.85), trigger: tapCounter)
    }

    @ViewBuilder private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                isSelected
                ? AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.52, blue: 0.32).opacity(0.18),
                            Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                : AnyShapeStyle(Color.white.opacity(0.05))
            )
    }

    @ViewBuilder private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isSelected
                ? Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.6)
                : Color.white.opacity(0.10),
                lineWidth: isSelected ? 1 : 0.6
            )
    }
}

// MARK: - Shared gradient

private let warmGradient = LinearGradient(
    colors: [
        Color(red: 1.00, green: 0.86, blue: 0.58),
        Color(red: 0.99, green: 0.52, blue: 0.32),
        Color(red: 0.96, green: 0.32, blue: 0.46)
    ],
    startPoint: .topLeading,
    endPoint:   .bottomTrailing
)
