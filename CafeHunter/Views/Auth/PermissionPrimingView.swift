import SwiftUI

/// Post-onboarding permission queue. Renders ONE explanatory card per
/// still-`.notDetermined` permission and fires that permission's OS prompt on
/// "Allow", `await`-ing the result before advancing — which is what serializes
/// the system prompts into a smooth one-at-a-time flow instead of a burst.
///
/// Inserted as a `RootRouterView` gate after the phone step and latched by
/// `@AppStorage("hasSeenPermissionPriming")`, so it shows once per install
/// (re-shows on re-download, never on a same-device account switch). Styled to
/// match `WelcomeView`'s cards — espresso canvas, cream ink, terracotta CTA,
/// staggered reveals, honoring Reduce Motion.
struct PermissionPrimingView: View {
    var permissions: PermissionsManager
    /// Called once every pending card has been answered (allowed or skipped).
    /// The router flips `hasSeenPermissionPriming` here.
    var onComplete: () -> Void

    /// Frozen on appear so the card list stays stable even as statuses change
    /// mid-flow (a granted permission shouldn't reshuffle the remaining cards).
    @State private var queue: [PermissionKind] = []
    @State private var index = 0
    @State private var isRequesting = false

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            if let kind = current {
                PrimingCard(
                    content: .content(for: kind),
                    isBusy: isRequesting,
                    onAllow: { Task { await allow() } },
                    onSkip: advance
                )
                .id(kind)                       // re-mount per card → replays the reveal
                .transition(.opacity)
            }
        }
        .task {
            // Correct the async-only notification status before snapshotting, so
            // an already-granted notification permission (re-download case) is
            // dropped from the queue rather than shown as a dead card.
            await permissions.refreshAllStatuses()
            queue = permissions.pendingPermissions
            if queue.isEmpty { onComplete() }
        }
    }

    private var current: PermissionKind? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    private func allow() async {
        guard !isRequesting, let kind = current else { return }
        isRequesting = true
        await permissions.request(kind)   // the `await` IS the queue
        isRequesting = false
        advance()
    }

    private func advance() {
        guard !isRequesting else { return }
        if index + 1 < queue.count {
            withAnimation(Motion.iosDrawer(duration: Motion.Duration.drawer)) {
                index += 1
            }
        } else {
            onComplete()
        }
    }
}

// MARK: - Card

/// One permission card. Visually mirrors `WelcomeView`'s `WelcomeLocationCard`:
/// hero glyph, title, body, and an "Allow" / "Maybe later" CTA pair, with the
/// same staggered reveal. "Allow" shows a spinner while the OS prompt is live.
private struct PrimingCard: View {
    let content: PrimingContent
    let isBusy: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void

    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)

            Text(content.emoji)
                .font(.system(size: 96))
                .accessibilityHidden(true)
                .scaleEffect(visible || reduceMotion ? 1.0 : 0.95)
                .opacity(visible ? 1.0 : 0.0)
                .animation(reduceMotion ? Motion.staggerReveal : Motion.cozyReveal, value: visible)

            Text(content.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.cream)
                .multilineTextAlignment(.center)
                .opacity(visible ? 1.0 : 0.0)
                .offset(y: visible || reduceMotion ? 0 : 8)
                .animation(Motion.staggerReveal.delay(0.06), value: visible)

            Text(content.body)
                .font(.body)
                .foregroundStyle(AppTheme.cream.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .opacity(visible ? 1.0 : 0.0)
                .offset(y: visible || reduceMotion ? 0 : 8)
                .animation(Motion.staggerReveal.delay(0.12), value: visible)

            Spacer()

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    Group {
                        if isBusy {
                            ProgressView().tint(AppTheme.textOnAccent)
                        } else {
                            Text(content.allowLabel)
                                .font(.subheadline).bold()
                                .foregroundStyle(AppTheme.textOnAccent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.cafeAccent)
                    .clipShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.scalePress)
                .disabled(isBusy)

                Button(action: onSkip) {
                    Text("Maybe later")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.cream.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.scalePress)
                .disabled(isBusy)
            }
            .padding(.horizontal, 24)
            .opacity(visible ? 1.0 : 0.0)
            .animation(Motion.staggerReveal.delay(0.18), value: visible)
        }
        .frame(maxWidth: .infinity)
        .onAppear { visible = true }
    }
}

// MARK: - Copy

private struct PrimingContent {
    let emoji: String
    let title: String
    let body: String
    let allowLabel: String

    static func content(for kind: PermissionKind) -> PrimingContent {
        switch kind {
        case .cameraMic:
            PrimingContent(
                emoji: "📸",
                title: "Snap your\ncafe finds.",
                body: "Wandery uses the camera and mic so you can capture the photos and videos of every place you hunt.",
                allowLabel: "Allow Camera & Mic")
        case .notifications:
            PrimingContent(
                emoji: "🔔",
                title: "Stay in\nthe loop.",
                body: "Get a nudge when friends post, react, send a request, or message you. No spam — just your people.",
                allowLabel: "Allow Notifications")
        case .contacts:
            PrimingContent(
                emoji: "👋",
                title: "Find your\nfriends.",
                body: "Match your contacts to friends already on Wandery. They stay on your device — only hashed numbers are ever checked.",
                allowLabel: "Allow Contacts")
        case .photos:
            PrimingContent(
                emoji: "🖼️",
                title: "Post from\nyour library.",
                body: "Add photos and videos from your library to your posts, and see your recent shots right on the capture screen.",
                allowLabel: "Allow Photos")
        }
    }
}
