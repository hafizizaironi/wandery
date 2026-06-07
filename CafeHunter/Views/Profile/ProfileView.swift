import SwiftUI
import FirebaseAuth

struct ProfileView: View {
    let user: FirebaseAuth.User
    let isAdmin: Bool
    let onSignOut: () -> Void

    @State private var isSigningOut = false
    @State private var copied = false

    private var displayName: String {
        user.displayName ?? user.email?.components(separatedBy: "@").first ?? "User"
    }

    private var providerLabel: String {
        user.providerData.first?.providerID == "google.com"
            ? "🔐 Google account"
            : "📧 Email account"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.espresso.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {

                        // MARK: Avatar + name
                        VStack(spacing: 12) {
                            avatarView
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(AppTheme.cafeAccent, lineWidth: 3))
                                .shadow(color: AppTheme.cafeAccent.opacity(0.2), radius: 10)

                            VStack(spacing: 4) {
                                Text(displayName)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(AppTheme.cream)
                                if let email = user.email {
                                    Text(email)
                                        .font(.system(size: 13))
                                        .foregroundColor(AppTheme.cream.opacity(0.45))
                                }
                            }

                            Text(providerLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(1.5)
                                .foregroundColor(AppTheme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(AppTheme.surfacePrimary)
                                .cornerRadius(20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                                )
                        }
                        .padding(.vertical, 32)

                        divider

                        // MARK: Stats (placeholder)
                        HStack(spacing: 12) {
                            StatCard(label: "Cafés visited", value: "—")
                            StatCard(label: "Favourites", value: "—")
                        }
                        .padding(16)

                        divider

                        // MARK: Account section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ACCOUNT")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(2)
                                .foregroundColor(AppTheme.cream.opacity(0.3))
                                .padding(.top, 4)

                            // Email verified
                            AccountRow(label: "Email verified") {
                                Text(user.isEmailVerified ? "Verified" : "Not verified")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(user.isEmailVerified ? AppTheme.successGreen : AppTheme.cafeAccent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        (user.isEmailVerified ? AppTheme.successGreen : AppTheme.cafeAccent).opacity(0.15)
                                    )
                                    .cornerRadius(10)
                            }

                            // Admin badge
                            if isAdmin {
                                AccountRow(label: "Role") {
                                    Text("★ Admin")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(AppTheme.textOnAccent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(AppTheme.cafeAccent)
                                        .cornerRadius(10)
                                }
                            }

                            // UID row
                            VStack(alignment: .leading, spacing: 4) {
                                Text("USER ID")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(1.5)
                                    .foregroundColor(AppTheme.cream.opacity(0.3))
                                HStack {
                                    Text(user.uid)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(AppTheme.cream.opacity(0.45))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = user.uid
                                        copied = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                                    } label: {
                                        Text(copied ? "Copied!" : "Copy")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(copied ? AppTheme.successGreen : AppTheme.cream.opacity(0.4))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(AppTheme.cream.opacity(0.08))
                                            .cornerRadius(8)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(AppTheme.cream.opacity(0.04))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
                            )
                        }
                        .padding(16)

                        Spacer().frame(height: 12)

                        // MARK: Sign out
                        Button {
                            isSigningOut = true
                            onSignOut()
                        } label: {
                            Group {
                                if isSigningOut {
                                    ProgressView().tint(AppTheme.textPrimary)
                                } else {
                                    Text("Sign out")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(AppTheme.textPrimary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.surfacePrimary)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
                            )
                        }
                        .disabled(isSigningOut)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("My Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.espresso, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
        .presentationBackground(AppTheme.espresso)
    }

    // MARK: - Sub views

    private var avatarView: some View {
        AvatarView(url: user.photoURL, name: displayName, size: 80)
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.borderSubtle.opacity(0.5))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

// MARK: - Stat card

struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppTheme.cream)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.cream.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(AppTheme.cream.opacity(0.04))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Account row

struct AccountRow<Trailing: View>: View {
    let label: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.cream.opacity(0.6))
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.cream.opacity(0.04))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        )
    }
}
