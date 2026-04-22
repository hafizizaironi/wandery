import SwiftUI
import PhotosUI
import FirebaseAuth

struct EditProfileView: View {
    let user: FirebaseAuth.User
    @ObservedObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var selectedItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(user: FirebaseAuth.User, authService: AuthService) {
        self.user        = user
        self.authService = authService
        _displayName     = State(initialValue: user.displayName ?? "")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.espresso.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 32) {

                        // MARK: Avatar picker
                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                avatarPreview
                                    .frame(width: 104, height: 104)
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle().stroke(
                                            LinearGradient(
                                                colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 3
                                        )
                                    )
                                    .shadow(color: AppTheme.cafeAccent.opacity(0.35), radius: 14)

                                // Camera badge
                                Circle()
                                    .fill(AppTheme.cafeAccent)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Image(systemName: "camera.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                    )
                                    .shadow(color: AppTheme.cafeAccent.opacity(0.5), radius: 6)
                                    .offset(x: 2, y: 2)
                            }
                        }
                        .onChange(of: selectedItem) { _, item in
                            Task {
                                if let data = try? await item?.loadTransferable(type: Data.self),
                                   let img = UIImage(data: data) {
                                    pendingImage = img
                                }
                            }
                        }
                        .padding(.top, 8)

                        // MARK: Display name
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DISPLAY NAME")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(2)
                                .foregroundColor(AppTheme.cream.opacity(0.35))

                            TextField("Your name", text: $displayName)
                                .font(.system(size: 16))
                                .foregroundColor(AppTheme.cream)
                                .tint(AppTheme.cafeAccent)
                                .padding(14)
                                .background(AppTheme.cream.opacity(0.06))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1)
                                )
                        }

                        // MARK: Error
                        if let msg = errorMessage {
                            Text(msg)
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.errorRed)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.espresso, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(AppTheme.cream.opacity(0.55))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView().tint(AppTheme.cafeAccent)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                                .foregroundColor(AppTheme.cafeAccent)
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationBackground(AppTheme.espresso)
    }

    // MARK: - Avatar preview

    @ViewBuilder
    private var avatarPreview: some View {
        if let img = pendingImage {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let url = user.photoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: initialsCircle
                }
            }
        } else {
            initialsCircle
        }
    }

    private var initialsCircle: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(AppTheme.cream)
        }
    }

    private var initials: String {
        let name = displayName.isEmpty ? (user.displayName ?? "") : displayName
        return name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined().uppercased()
    }

    // MARK: - Save

    private func save() {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        isSaving    = true
        errorMessage = nil

        Task {
            do {
                if !trimmed.isEmpty, trimmed != user.displayName {
                    try await authService.updateDisplayName(trimmed)
                }
                if let img = pendingImage {
                    try await authService.updateProfilePhoto(img)
                }
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving     = false
                }
            }
        }
    }
}
