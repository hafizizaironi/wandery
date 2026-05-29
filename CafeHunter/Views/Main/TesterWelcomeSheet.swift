import SwiftUI

// MARK: - Tester welcome sheet
//
// One-time warm intro for TestFlight/alpha testers, shown inside the app on
// first launch (gated by `AppEnvironment.isTester` + the
// `tester.welcome.seen` AppStorage flag in MainShellView). Re-showable any
// time from the "Welcome message" row in Profile.
//
// Tone is the warm/humble-indie voice with the 🔥 brand closer — keep the
// data line honest (no "secure/private/encrypted"; messages aren't E2EE).

struct TesterWelcomeSheet: View {
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            AppTheme.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        flameBadge
                        title
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                            Text(p)
                                .font(.callout)
                                .foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        closer
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                footer
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack {
            Text("Welcome")
                .font(.system(size: 13, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var flameBadge: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(AppTheme.accentAction)
            .padding(18)
            .background(Circle().fill(AppTheme.accentAction.opacity(0.12)))
            .accessibilityHidden(true)
    }

    private var title: some View {
        Text("Thanks for testing Wandery 🙏")
            .font(.title2).bold()
            .foregroundStyle(AppTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private let paragraphs: [String] = [
        "You're one of the first people here. Wandery's an indie app, and it's a social one at heart — it comes alive when your friends are on it too, so invite anyone you'd love to hunt cafés and food spots with.",
        "Found a bug? Got an idea? Something feels off? Send it through TestFlight feedback — screenshots are very welcome. Every note genuinely shapes what we build next.",
        "On your data: we don't sell it or hand it to anyone. Whatever's stored is used only to run and improve the app — nothing else.",
    ]

    private var closer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Stay hunting. 🔥")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text("— Wandery")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.top, 4)
    }

    // MARK: footer

    private var footer: some View {
        Button(action: onDismiss) {
            Text("Got it")
                .font(.headline)
                .foregroundStyle(AppTheme.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Capsule().fill(AppTheme.accentAction))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 4)
    }
}
