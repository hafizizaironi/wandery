import SwiftUI
import UIKit

/// Full-screen surface that scans the user's contacts, classifies them
/// into "already on the app" (with Add Friend buttons) and "invite"
/// (with iOS share sheet), and lets the user act on each row.
///
/// Owns its own `FriendFindService` as `@State` — destroyed and recreated
/// on dismiss/re-open so re-entering re-runs the scan with fresh data.
struct FriendFindView: View {
    var socialService: SocialService
    var userPrivateService: UserPrivateService
    var onClose: () -> Void

    @State private var service = FriendFindService()
    @State private var didStartScan = false
    @State private var inviteShareTarget: InviteTarget?
    @State private var sendingTo: Set<String> = []
    @State private var requestSentTo: Set<String> = []
    @State private var requestError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(AppTheme.cafeAccent.opacity(0.12))
            content
        }
        .background(AppTheme.surfaceCanvas.ignoresSafeArea())
        .task {
            guard !didStartScan else { return }
            didStartScan = true
            await service.scan(
                currentUserPhone: userPrivateService.profile?.phoneNumber,
                friendIds: Set(socialService.friendIds)
            )
        }
        .sheet(item: $inviteShareTarget) { target in
            ActivityShareSheet(items: [target.message])
                .presentationDetents([.medium, .large])
        }
        .alert("Couldn't send", isPresented: Binding(
            get: { requestError != nil },
            set: { if !$0 { requestError = nil } }
        )) {
            Button("OK", role: .cancel) { requestError = nil }
        } message: {
            Text(requestError ?? "")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Button("Close", action: onClose)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            VStack(spacing: 1) {
                Text("Find Friends")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                Text(headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
            }
            Spacer()
            // Mirror Close width so the title stays centred.
            Text("Close")
                .font(.subheadline)
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var headerSubtitle: String {
        if service.isLoading { return "Scanning…" }
        let onApp = service.onApp.count
        let invite = service.invitees.count
        return "\(onApp) on app · \(invite) to invite"
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if service.isLoading && service.onApp.isEmpty && service.invitees.isEmpty {
            loading
        } else if let err = service.lastError {
            errorState(err)
        } else if service.onApp.isEmpty && service.invitees.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !service.onApp.isEmpty {
                        section(title: "On the app", count: service.onApp.count) {
                            ForEach(service.onApp) { match in
                                onAppRow(match)
                            }
                        }
                    }
                    if !service.invitees.isEmpty {
                        section(title: "Invite", count: service.invitees.count) {
                            ForEach(service.invitees) { contact in
                                inviteRow(contact)
                            }
                        }
                    }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
    }

    private var loading: some View {
        VStack {
            Spacer()
            ProgressView().tint(AppTheme.accentAction)
            Text("Looking for friends…")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.errorRed.opacity(0.6))
                .accessibilityHidden(true)
            Text("Couldn't scan contacts")
                .font(.subheadline).bold()
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.accentAction)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "person.2.slash")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.textSecondary.opacity(0.4))
                .accessibilityHidden(true)
            Text("No contacts to scan")
                .font(.subheadline).bold()
                .foregroundStyle(AppTheme.textPrimary)
            Text("Make sure you have contacts saved with phone numbers, then try again.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title.uppercased()) · \(count)")
                .font(.caption2).bold()
                .tracking(1.5)
                .foregroundStyle(AppTheme.textSecondary)
            VStack(spacing: 6) {
                content()
            }
        }
    }

    // MARK: - Rows

    private func onAppRow(_ match: ContactsOnAppMatch) -> some View {
        HStack(spacing: 12) {
            avatar(photoURL: match.photoURL, initials: match.contact.initials)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.displayName)
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(match.contact.displayName)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailingActionForMatch(match)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(AppTheme.textPrimary.opacity(0.04)))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(AppTheme.borderSubtle, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func trailingActionForMatch(_ match: ContactsOnAppMatch) -> some View {
        if match.isFriend {
            Text("Friend")
                .font(.caption2).bold()
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.textPrimary.opacity(0.06))
                .clipShape(Capsule())
        } else if requestSentTo.contains(match.uid) {
            Text("Requested")
                .font(.caption2).bold()
                .foregroundStyle(AppTheme.accentAction.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.accentAction.opacity(0.08))
                .clipShape(Capsule())
        } else if sendingTo.contains(match.uid) {
            ProgressView().tint(AppTheme.accentAction)
                .frame(width: 40)
        } else {
            Button {
                Task { await sendRequest(match) }
            } label: {
                Text("Add")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(AppTheme.accentAction)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(match.displayName) as friend")
        }
    }

    private func inviteRow(_ contact: ContactRecord) -> some View {
        HStack(spacing: 12) {
            avatar(photoURL: nil, initials: contact.initials)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(contact.phoneE164)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                inviteShareTarget = InviteTarget(contact: contact)
            } label: {
                Text("Invite")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accentAction)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(AppTheme.accentAction.opacity(0.1))
                    .overlay {
                        Capsule().stroke(AppTheme.accentAction.opacity(0.4), lineWidth: 1)
                    }
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Invite \(contact.displayName)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(AppTheme.textPrimary.opacity(0.04)))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(AppTheme.borderSubtle, lineWidth: 1)
        }
    }

    private func avatar(photoURL: String?, initials: String) -> some View {
        AvatarView(urlString: photoURL, initials: initials, size: 40)
    }

    // MARK: - Actions

    private func sendRequest(_ match: ContactsOnAppMatch) async {
        guard let username = match.username, !username.isEmpty else {
            requestError = "This account has no username, so we can't send a friend request yet."
            return
        }
        sendingTo.insert(match.uid)
        defer { sendingTo.remove(match.uid) }
        do {
            try await socialService.sendFriendRequest(toUsername: username)
            requestSentTo.insert(match.uid)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch let e as SocialError {
            requestError = e.errorDescription ?? e.localizedDescription
        } catch {
            requestError = error.localizedDescription
        }
    }
}

// MARK: - Helpers

private struct InviteTarget: Identifiable {
    let contact: ContactRecord
    var id: String { contact.id }
    var message: String {
        "Hey \(contact.displayName.split(separator: " ").first.map(String.init) ?? "")! "
            + "I'm using Wandery to discover good cafés and food spots — come check it out: https://apps.apple.com/app/idTBD"
    }
}

/// Bridges UIActivityViewController into SwiftUI's `.sheet(item:)`.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
