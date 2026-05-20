import SwiftUI

/// Modal "report content" sheet. Used wherever the user can flag something
/// — chat messages, feed posts, friend rows. The actual write goes through
/// `SocialService.reportContent(...)` so the server can validate the shape.
struct ReportSheet: View {
    let targetType: ReportTargetType
    let targetId: String
    @ObservedObject var socialService: SocialService
    var onCompleted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: ReportReason = .spam
    @State private var details: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private var headerTitle: String {
        switch targetType {
        case .user:    "Report user"
        case .post:    "Report post"
        case .message: "Report message"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    ForEach(ReportReason.allCases) { reason in
                        Button {
                            selectedReason = reason
                        } label: {
                            HStack {
                                Text(reason.label)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                if selectedReason == reason {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppTheme.accentAction)
                                }
                            }
                        }
                        .accessibilityAddTraits(selectedReason == reason ? .isSelected : [])
                    }
                }

                Section {
                    TextField("Anything we should know? (optional)",
                              text: $details,
                              axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Details")
                } footer: {
                    Text("Our team reviews every report within 24 hours.")
                        .font(.caption2)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(AppTheme.errorRed)
                    }
                }
            }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task { await submit() }
                    }
                    .disabled(isSending)
                }
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    private func submit() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await socialService.reportContent(
                targetType: targetType,
                targetId: targetId,
                reason: selectedReason,
                details: details
            )
            onCompleted?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
