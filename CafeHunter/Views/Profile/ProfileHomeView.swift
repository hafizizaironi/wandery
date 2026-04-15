import SwiftUI
import FirebaseAuth

struct ProfileHomeView: View {
    @ObservedObject var authService: AuthService

    private var displayName: String {
        guard let user = authService.user else { return "Explorer" }
        return user.displayName ?? user.email?.components(separatedBy: "@").first ?? "Explorer"
    }

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Profile")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(AppTheme.cream)
                        .padding(.top, 56)

                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(height: 120)
                        .overlay(
                            VStack(alignment: .leading, spacing: 6) {
                                Text(displayName)
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(AppTheme.cream)
                                Text("Achievements are coming next")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppTheme.cream.opacity(0.7))
                            }
                            .padding(16),
                            alignment: .leading
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(AppTheme.glassStroke, lineWidth: 1)
                        )

                    VStack(spacing: 10) {
                        AchievementRow(title: "Cafe Hunter", subtitle: "Visit 10 cafes", value: "2 / 10")
                        AchievementRow(title: "Stall Seeker", subtitle: "Try 6 stalls", value: "1 / 6")
                        AchievementRow(title: "Local Guide", subtitle: "Add 3 new places", value: "0 / 3")
                    }

                    Button {
                        try? authService.signOut()
                    } label: {
                        Text("Sign out")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.cafeAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppTheme.cafeAccent.opacity(0.12))
                            .cornerRadius(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(AppTheme.cafeAccent.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, ArcNavBar.frameContentHeight)
            }
        }
    }
}

private struct AchievementRow: View {
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.cream)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.cream.opacity(0.55))
            }
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.stallAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.stallAccent.opacity(0.15))
                .cornerRadius(10)
        }
        .padding(14)
        .background(AppTheme.cream.opacity(0.05))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.cream.opacity(0.09), lineWidth: 1)
        )
    }
}
