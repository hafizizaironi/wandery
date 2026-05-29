import FirebaseFirestore
import Observation
import SwiftUI

/// Soft "update available" check. Reads `config/app` once and compares the
/// published `latestBuild` to this install's build number. The admin bumps
/// `config/app.latestBuild` (and sets `updateURL`) on each TestFlight / App
/// Store upload. Best-effort: any failure is silent — an update nudge must
/// never block the app. The nudge is a dismissible banner (see
/// `AppUpdateBanner`); dismissal is remembered per-build so it doesn't nag
/// again until a newer build ships.
@MainActor
@Observable
final class AppUpdateChecker {
    /// `config/app.latestBuild`, or nil when unread / unset.
    private(set) var latestBuild: Int?
    /// Where "Update" sends the user (`config/app.updateURL`) — the TestFlight
    /// or App Store link. Nil hides the button (banner stays informational).
    private(set) var updateURL: URL?

    /// This install's build number (`CFBundleVersion`).
    static let currentBuild: Int = {
        let s = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return Int(s) ?? 0
    }()

    /// A newer build exists AND the user hasn't dismissed that specific build.
    func updateAvailable(dismissedBuild: Int) -> Bool {
        guard let latest = latestBuild else { return false }
        return latest > Self.currentBuild && latest > dismissedBuild
    }

    func check() async {
        do {
            let snap = try await Firestore.firestore()
                .collection("config").document("app").getDocument()
            guard let d = snap.data() else { return }
            // Firestore integers can arrive as Int or NSNumber depending on path.
            if let b = d["latestBuild"] as? Int {
                latestBuild = b
            } else if let n = d["latestBuild"] as? NSNumber {
                latestBuild = n.intValue
            }
            if let s = d["updateURL"] as? String, !s.isEmpty, let u = URL(string: s) {
                updateURL = u
            }
        } catch {
            #if DEBUG
            print("[AppUpdateChecker] check failed: \(error.localizedDescription)")
            #endif
        }
    }
}

/// Slim, dismissible "a new version is available" bar shown at the top of the
/// main shell. Soft only — there's always an X.
struct AppUpdateBanner: View {
    let updateURL: URL?
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Text("🔥").font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("A new version is available")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Update to keep hunting with everyone.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 8)
            if let updateURL {
                Button {
                    openURL(updateURL)
                } label: {
                    Text("Update")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.textOnAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(AppTheme.accentAction))
                }
                .buttonStyle(.plain)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.surfacePrimary)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}
