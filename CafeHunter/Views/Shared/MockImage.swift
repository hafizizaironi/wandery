import SwiftUI
import UIKit
import PhotosUI

/// When true (set via `.environment(\.mockImageEditing, …)`), `MockImage`
/// slots become tappable to pick / replace / remove a photo. Defaults to off
/// so screenshots stay clean.
private struct MockImageEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mockImageEditing: Bool {
        get { self[MockImageEditingKey.self] }
        set { self[MockImageEditingKey.self] = newValue }
    }
}

/// Image that renders, in priority order: an admin-picked photo (`MockImageStore`),
/// then an asset-catalog image for `name`, then a branded gradient + category-emoji
/// placeholder.
///
/// Lets the marketing-mockup screens ship with on-brand placeholders today and
/// be filled with real photos in `mockImageEditing` mode (tap a slot to pick).
/// Dropping a real image into `Assets.xcassets` under the same `name` also makes
/// it appear automatically with NO code change. Callers wrap this in their own
/// `.frame(...).clipShape(...)` (it uses `scaledToFill`), the same way
/// `CachedAsyncImage` is used elsewhere.
struct MockImage: View {
    let name: String

    @Environment(\.mockImageEditing) private var editing
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showOptions = false

    private var store: MockImageStore { MockImageStore.shared }

    var body: some View {
        content
            .overlay { if editing { editOverlay } }
            .contentShape(Rectangle())
            .onTapGesture { if editing { handleTap() } }
            .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
            .confirmationDialog("Photo", isPresented: $showOptions, titleVisibility: .hidden) {
                Button("Replace photo") { showPicker = true }
                Button("Remove photo", role: .destructive) { store.clear(name) }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: pickerItem) { _, newItem in
                guard let newItem else { return }
                Task { @MainActor in
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        store.set(image, for: name)
                    }
                    pickerItem = nil
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let picked = store.image(for: name) {
            Image(uiImage: picked)
                .resizable()
                .scaledToFill()
        } else if UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFill()
        } else {
            placeholder
        }
    }

    private func handleTap() {
        // A picked photo offers replace/remove; otherwise jump straight to the picker.
        if store.image(for: name) != nil {
            showOptions = true
        } else {
            showPicker = true
        }
    }

    // MARK: - Edit affordance

    private var editOverlay: some View {
        let hasPhoto = store.image(for: name) != nil
        return ZStack {
            Color.black.opacity(0.28)
            VStack(spacing: 5) {
                Image(systemName: hasPhoto ? "arrow.triangle.2.circlepath" : "photo.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                Text(hasPhoto ? "Replace" : "Add photo")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.45), in: Capsule())
        }
        .allowsHitTesting(false)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        // Stable per-name gradient (same hashing idiom as the Trending grid's
        // placeholder) so a given slot keeps its look between launches.
        let t = Double(abs(name.hashValue) % 100) / 100.0
        return ZStack {
            LinearGradient(
                colors: [
                    AppTheme.cafeAccent.opacity(0.85 - t * 0.25),
                    AppTheme.stallAccent.opacity(0.45 + t * 0.20),
                    AppTheme.surfaceCanvas
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(emoji(for: name))
                .font(.system(size: 34))
                .opacity(0.9)
        }
    }

    private func emoji(for name: String) -> String {
        if name.contains("cafe")  { return "☕️" }
        if name.contains("food")  { return "🍽️" }
        if name.contains("stall") { return "🍜" }
        return "📸"
    }
}
