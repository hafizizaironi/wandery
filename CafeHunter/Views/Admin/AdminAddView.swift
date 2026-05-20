import SwiftUI
import PhotosUI
import MapKit

struct AdminAddView: View {
    @ObservedObject var firestoreService: FirestoreService
    let editCafe: Cafe?
    let onClose: () -> Void

    // Form state
    @State private var type: PlaceType = .cafe
    @State private var name = ""
    @State private var tagline = ""
    @State private var neighborhood = ""
    @State private var hours = ""
    @State private var descriptionText = ""
    @State private var vibeTags: [String] = []
    @State private var tagInput = ""
    @State private var latText = ""
    @State private var lngText = ""

    // Photos
    @State private var existingPhotos: [String] = []
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var newImages: [UIImage] = []

    // UI state
    @State private var errorMessage = ""
    @State private var isSaving = false
    @State private var isSuccess = false
    @State private var showMapPicker = false

    private var isEdit: Bool { editCafe != nil }
    private var accent: Color { AppTheme.accent(for: type) }
    private var totalPhotos: Int { existingPhotos.count + newImages.count }

    init(firestoreService: FirestoreService, editCafe: Cafe?, onClose: @escaping () -> Void) {
        self.firestoreService = firestoreService
        self.editCafe = editCafe
        self.onClose = onClose

        if let c = editCafe {
            _type         = State(initialValue: c.type)
            _name         = State(initialValue: c.name)
            _tagline      = State(initialValue: c.tagline)
            _neighborhood = State(initialValue: c.neighborhood)
            _hours        = State(initialValue: c.hours)
            _descriptionText = State(initialValue: c.description)
            _vibeTags     = State(initialValue: c.vibeTags)
            _latText      = State(initialValue: String(c.lat))
            _lngText      = State(initialValue: String(c.lng))
            _existingPhotos = State(initialValue: c.photos)
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Inline header (replaces NavigationStack toolbar) ──
            HStack {
                Button("Cancel", action: onClose)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.cream.opacity(0.55))

                Spacer()

                Text(isEdit ? "Edit Place" : "Add New Place")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)

                Spacer()

                // Mirror Cancel width so title stays centred
                Text("Cancel")
                    .font(.subheadline)
                    .foregroundStyle(.clear)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)

            Divider()
                .background(AppTheme.cafeAccent.opacity(0.12))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                        // Type picker
                        AdminField(label: "Type") {
                            HStack(spacing: 8) {
                                ForEach(PlaceType.allCases, id: \.self) { t in
                                    let picked = type == t
                                    Button { type = t } label: {
                                        Text(t == .cafe ? "☕ Café" : "🍜 Street Stall")
                                            .font(.footnote).bold()
                                            .foregroundStyle(picked ? AppTheme.accent(for: t) : AppTheme.textSecondary)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(picked ? AppTheme.surfacePrimary : AppTheme.textPrimary.opacity(0.04))
                                            .clipShape(.rect(cornerRadius: 12))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(
                                                        picked ? AppTheme.accent(for: t).opacity(0.4) : AppTheme.borderSubtle,
                                                        lineWidth: 1
                                                    )
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        AdminField(label: "Name *") {
                            AdminTextField(placeholder: "e.g. Kopi Bukit Sentosa", text: $name)
                        }

                        AdminField(label: "Tagline") {
                            AdminTextField(placeholder: "One-line description", text: $tagline)
                        }

                        AdminField(label: "Neighbourhood") {
                            AdminTextField(placeholder: "e.g. Bukit Sentosa", text: $neighborhood)
                        }

                        AdminField(label: "Hours") {
                            AdminTextField(placeholder: "e.g. 7:00 AM – 5:00 PM (Closed Tue)", text: $hours)
                        }

                        // Vibe tags
                        AdminField(label: "Vibe Tags") {
                            VStack(alignment: .leading, spacing: 8) {
                                AdminTextField(placeholder: "Type a tag & press Return", text: $tagInput)
                                    .onSubmit {
                                        let tag = tagInput.trimmingCharacters(in: .whitespaces).lowercased()
                                        if !tag.isEmpty && !vibeTags.contains(tag) {
                                            vibeTags.append(tag)
                                        }
                                        tagInput = ""
                                    }
                                if !vibeTags.isEmpty {
                                    FlowLayout(spacing: 6) {
                                        ForEach(vibeTags, id: \.self) { tag in
                                            Button { vibeTags.removeAll { $0 == tag } } label: {
                                                HStack(spacing: 4) {
                                                    Text(tag)
                                                    Text("×").opacity(0.6)
                                                }
                                                .font(.caption)
                                                .foregroundStyle(accent)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 4)
                                                .background(accent.opacity(0.1))
                                                .overlay {
                                                    Capsule().stroke(accent.opacity(0.4), lineWidth: 1)
                                                }
                                                .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Remove tag \(tag)")
                                        }
                                    }
                                }
                            }
                        }

                        AdminField(label: "Description") {
                            AdminTextField(placeholder: "Tell the story of this place…", text: $descriptionText, multiLine: true)
                        }

                        // Coordinates
                        AdminField(label: "Coordinates *") {
                            VStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    AdminTextField(placeholder: "Latitude", text: $latText)
                                        .keyboardType(.decimalPad)
                                    AdminTextField(placeholder: "Longitude", text: $lngText)
                                        .keyboardType(.decimalPad)
                                }
                                Button {
                                    showMapPicker = true
                                } label: {
                                    Label("Pin on map", systemImage: "map")
                                        .font(.footnote).bold()
                                        .foregroundStyle(AppTheme.cream.opacity(0.6))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(AppTheme.cream.opacity(0.06))
                                        .clipShape(.rect(cornerRadius: 12))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(AppTheme.cream.opacity(0.12), lineWidth: 1)
                                        }
                                }
                                .buttonStyle(.plain)

                                if !latText.isEmpty, !lngText.isEmpty {
                                    let lat = Double(latText) ?? 0
                                    let lng = Double(lngText) ?? 0
                                    Text("\(lat, format: .number.precision(.fractionLength(5))), \(lng, format: .number.precision(.fractionLength(5)))")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.cream.opacity(0.35))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }

                        // Photos
                        AdminField(label: "Photos (\(totalPhotos)/3)") {
                            HStack(spacing: 8) {
                                // Existing
                                ForEach(Array(existingPhotos.enumerated()), id: \.offset) { i, url in
                                    photoThumb(url: url) { existingPhotos.remove(at: i) }
                                }
                                // New
                                ForEach(Array(newImages.enumerated()), id: \.offset) { i, img in
                                    newPhotoThumb(image: img) { newImages.remove(at: i) }
                                }
                                // Add button
                                if totalPhotos < 3 {
                                    PhotosPicker(
                                        selection: $selectedItems,
                                        maxSelectionCount: 3 - totalPhotos,
                                        matching: .images
                                    ) {
                                        VStack(spacing: 4) {
                                            Text("+").font(.title2)
                                            Text("Photo").font(.caption2)
                                        }
                                        .foregroundStyle(AppTheme.cream.opacity(0.35))
                                        .frame(width: 80, height: 80)
                                        .background(AppTheme.cream.opacity(0.03))
                                        .clipShape(.rect(cornerRadius: 12))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12)
                                                .strokeBorder(
                                                    style: StrokeStyle(lineWidth: 2, dash: [4])
                                                )
                                                .foregroundStyle(accent.opacity(0.4))
                                        }
                                    }
                                    .onChange(of: selectedItems) { _, items in
                                        Task {
                                            for item in items {
                                                if let data = try? await item.loadTransferable(type: Data.self),
                                                   let img = UIImage(data: data) {
                                                    newImages.append(img)
                                                }
                                            }
                                            selectedItems = []
                                        }
                                    }
                                }
                            }
                        }

                        // Error
                        if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(AppTheme.errorRed)
                        }

                        // Submit
                        Button { Task { await submit() } } label: {
                            Group {
                                if isSaving {
                                    ProgressView().tint(AppTheme.textOnAccent)
                                } else if isSuccess {
                                    Label("Saved!", systemImage: "checkmark")
                                        .font(.subheadline).bold()
                                        .foregroundStyle(AppTheme.textOnAccent)
                                } else {
                                    Text(isEdit ? "Save Changes" : "Add \(type == .stall ? "Stall" : "Café")")
                                        .font(.subheadline).bold()
                                        .foregroundStyle(AppTheme.textOnAccent)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(isSuccess ? AppTheme.successGreen : accent)
                            .clipShape(.rect(cornerRadius: 14))
                        }
                        .disabled(isSaving || isSuccess)
                        .buttonStyle(.plain)

                        Color.clear.frame(height: 20)
                    }
                    .padding(20)
                }
            }
        .background(AppTheme.espresso)
        .keyboardDismissToolbar()
        // Map picker presented full-screen (no NavigationStack needed)
        .fullScreenCover(isPresented: $showMapPicker) {
            MapPickerView { coord in
                latText = String(format: "%.6f", coord.latitude)
                lngText = String(format: "%.6f", coord.longitude)
            }
        }
    }

    // MARK: - Photo thumbnails

    @ViewBuilder
    private func photoThumb(url: String, onRemove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            if let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: AppTheme.espresso
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(.rect(cornerRadius: 12))
                .clipped()
            }
            removeButton(action: onRemove)
        }
    }

    @ViewBuilder
    private func newPhotoThumb(image: UIImage, onRemove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: 80, height: 80)
                .clipShape(.rect(cornerRadius: 12))
                .clipped()
            removeButton(action: onRemove)
        }
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption2).bold()
                .foregroundStyle(AppTheme.cream)
                .frame(width: 20, height: 20)
                .background(Color.black.opacity(0.7))
                .clipShape(Circle())
        }
        .padding(4)
        .accessibilityLabel("Remove photo")
    }

    // MARK: - Submit

    private func submit() async {
        errorMessage = ""
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Name is required."
            return
        }
        guard !latText.isEmpty, !lngText.isEmpty,
              let lat = Double(latText), let lng = Double(lngText) else {
            errorMessage = "Coordinates are required — pin on map or type manually."
            return
        }

        isSaving = true

        var form = CafeFormData()
        form.type        = type
        form.name        = name.trimmingCharacters(in: .whitespaces)
        form.tagline     = tagline.trimmingCharacters(in: .whitespaces)
        form.neighborhood = neighborhood.trimmingCharacters(in: .whitespaces)
        form.hours       = hours.trimmingCharacters(in: .whitespaces)
        form.description = descriptionText.trimmingCharacters(in: .whitespaces)
        form.vibeTags    = vibeTags
        form.lat         = lat
        form.lng         = lng

        do {
            if let cafe = editCafe, let id = cafe.id {
                form.slug = cafe.slug
                try await firestoreService.updatePlace(
                    id: id, data: form,
                    existingPhotos: existingPhotos, newImages: newImages
                )
            } else {
                form.generateSlug()
                try await firestoreService.addPlace(data: form, photoImages: newImages)
            }
            isSuccess = true
            try? await Task.sleep(for: .seconds(1.4))
            onClose()
        } catch {
            errorMessage = "Failed to save. Check Firebase rules and try again."
        }
        isSaving = false
    }
}

// MARK: - Reusable admin field

struct AdminField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2).bold()
                .tracking(1.5)
                .foregroundStyle(AppTheme.cream.opacity(0.4))
            content
        }
    }
}

struct AdminTextField: View {
    let placeholder: String
    @Binding var text: String
    var multiLine: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if multiLine {
                TextEditor(text: $text)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .focused($isFocused)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.cream.opacity(0.05))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isFocused ? AppTheme.cafeAccent.opacity(0.55) : AppTheme.borderSubtle,
                    lineWidth: 1
                )
        }
        .foregroundStyle(AppTheme.textPrimary)
        .font(.footnote)
        .tint(AppTheme.cafeAccent)
    }
}
