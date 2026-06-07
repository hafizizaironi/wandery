import SwiftUI
import PhotosUI
import FirebaseAuth

struct EditProfileView: View {
    let user: FirebaseAuth.User
    var authService: AuthService
    var userPrivateService: UserPrivateService
    /// Required when presented outside NavigationStack/sheet (e.g. floating panel).
    var onClose: () -> Void

    @State private var displayName: String
    @State private var selectedItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @AccessibilityFocusState private var errorFocused: Bool

    init(user: FirebaseAuth.User, authService: AuthService,
         userPrivateService: UserPrivateService, onClose: @escaping () -> Void) {
        self.user               = user
        self.authService        = authService
        self.userPrivateService = userPrivateService
        self.onClose            = onClose
        _displayName            = State(initialValue: user.displayName ?? "")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Inline header ──
            HStack {
                Button("Cancel") { onClose() }
                    .font(.subheadline)
                    .contrastAware(AppTheme.cream, opacity: 0.55)

                Spacer()

                Text("Edit Profile")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.cream)

                Spacer()

                Button(action: save) {
                    if isSaving {
                        ProgressView()
                            .tint(AppTheme.cafeAccent)
                            .frame(width: 44)
                    } else {
                        Text("Save")
                            .font(.subheadline).bold()
                            .foregroundStyle(AppTheme.cafeAccent)
                    }
                }
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)

            Divider()
                .background(AppTheme.cafeAccent.opacity(0.12))

            ScrollView {
                VStack(spacing: 32) {

                    // MARK: Avatar picker
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            avatarPreview
                                .frame(width: 104, height: 104)
                                .clipShape(Circle())
                                .overlay {
                                    Circle().stroke(
                                        LinearGradient(
                                            colors: [AppTheme.cafeAccent, AppTheme.stallAccent],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 3
                                    )
                                }
                                .shadow(color: AppTheme.cafeAccent.opacity(0.35), radius: 14)

                            Circle()
                                .fill(AppTheme.cafeAccent)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "camera.fill")
                                        .font(.footnote).bold()
                                        .foregroundStyle(.white)
                                }
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
                            .font(.caption2).bold()
                            .tracking(2)
                            .contrastAware(AppTheme.cream, opacity: 0.35)

                        TextField("Your name", text: $displayName)
                            .font(.callout)
                            .foregroundStyle(AppTheme.cream)
                            .tint(AppTheme.cafeAccent)
                            .padding(14)
                            .background(AppTheme.cream.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.cafeAccent.opacity(0.25), lineWidth: 1)
                            }
                    }

                    // MARK: Account info (read-only — fixed)
                    VStack(spacing: 16) {
                        infoRow(label: "EMAIL", value: user.email ?? "—")
                        infoRow(label: "PHONE", value: phoneText)
                        infoRow(label: "BIRTHDATE", value: birthdateText)
                    }

                    // MARK: Error
                    if let msg = errorMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(AppTheme.errorRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .accessibilityFocused($errorFocused)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
        }
        .background(AppTheme.espresso)
        .keyboardDismissToolbar()
    }

    // MARK: - Avatar preview

    @ViewBuilder
    private var avatarPreview: some View {
        if let img = pendingImage {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            AvatarView(
                url: user.photoURL,
                name: displayName.isEmpty ? user.displayName : displayName,
                size: 104
            )
        }
    }

    // MARK: - Read-only account info

    private var phoneText: String {
        let p = userPrivateService.profile?.phoneNumber
        return (p?.isEmpty == false) ? p! : "Not added"
    }

    private var birthdateText: String {
        guard let d = userPrivateService.profile?.birthdate else { return "Not set" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    /// A fixed (non-editable) labelled field — muted vs the editable name field.
    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption2).bold()
                .tracking(2)
                .contrastAware(AppTheme.cream, opacity: 0.35)
            Text(value)
                .font(.callout)
                .foregroundStyle(AppTheme.cream.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppTheme.cream.opacity(0.03))
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                }
        }
    }

    // MARK: - Save

    private func save() {
        let trimmed  = displayName.trimmingCharacters(in: .whitespaces)
        isSaving     = true
        errorMessage = nil

        Task {
            do {
                if !trimmed.isEmpty, trimmed != user.displayName {
                    try await authService.updateDisplayName(trimmed)
                }
                if let img = pendingImage {
                    try await authService.updateProfilePhoto(img)
                }
                await MainActor.run {
                    isSaving = false
                    onClose()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving     = false
                    errorFocused = true
                }
            }
        }
    }
}
