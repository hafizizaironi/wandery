import CoreLocation
import SwiftUI

/// First-time user welcome carousel. Shown once before the user has ever
/// seen the LoginView, gated by `@AppStorage("hasSeenWelcome")` from
/// `ContentView`. Three cards:
///
///   1. Value prop — why CafeHunter exists
///   2. Social hook — what makes it different from "yelp but cafes"
///   3. Location prime — explains the *one* permission we'll ask for so
///      the system prompt has context and converts better
///
/// Design language is Emil Kowalski's principles applied to CafeHunter's
/// cozy-coffee personality: 60ms staggered element entries, never-from-
/// scale-zero, strong ease-out for snappy UI feedback, subtle spring with
/// bounce for the cozy brand reveals, all under 300ms for UI-functional
/// animations. `accessibilityReduceMotion` is honored throughout.
struct WelcomeView: View {
    /// Called when the user finishes or skips the carousel. ContentView
    /// flips `hasSeenWelcome` and routes onward to LoginView from here.
    var onComplete: () -> Void

    @State private var currentPage: Int = 0
    @State private var locationManager = LocationManager()

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                TabView(selection: $currentPage) {
                    WelcomeCard(
                        emoji: "☕",
                        title: "Find cafés people\nactually love.",
                        subtitle: "Skip the algorithm. See where friends in your neighborhood are hunting.",
                        isActive: currentPage == 0
                    )
                    .tag(0)

                    WelcomeCard(
                        emoji: "👀",
                        title: "Tag where\nyou've been.",
                        subtitle: "Build your hunting history. React to friends' finds. Start conversations from a post.",
                        isActive: currentPage == 1
                    )
                    .tag(1)

                    WelcomeLocationCard(
                        isActive: currentPage == 2,
                        onAllow: handleAllowLocation,
                        onSkip: finish
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(Motion.iosDrawer(duration: Motion.Duration.drawer), value: currentPage)

                pageControl
                    .padding(.bottom, 28)

                bottomActions
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Spacer()
            // Skip is hidden on the final card — by then the user has only
            // two actions in front of them (Allow / Maybe later), and a
            // third "Skip" would muddle the choice.
            if currentPage < 2 {
                Button(action: finish) {
                    Text("Skip")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.cream.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.scalePress)
                .transition(.opacity)
            }
        }
        .frame(height: 36)
        .animation(Motion.tooltip, value: currentPage)
    }

    private var pageControl: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage
                          ? AppTheme.cafeAccent
                          : AppTheme.cream.opacity(0.25))
                    .frame(
                        width: index == currentPage ? 24 : 8,
                        height: 8
                    )
                    .animation(Motion.dropdown, value: currentPage)
            }
        }
    }

    @ViewBuilder
    private var bottomActions: some View {
        // The Next / Get started CTA only shows on cards 1 and 2. The
        // location card owns its own CTAs (Allow / Maybe later) so this
        // bar disappears to keep the choice clean.
        if currentPage < 2 {
            Button {
                advance()
            } label: {
                Text(currentPage == 1 ? "Get started" : "Next")
                    .font(.subheadline).bold()
                    .foregroundStyle(AppTheme.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.cafeAccent)
                    .clipShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.scalePress)
        } else {
            // Reserve the space so the layout doesn't jump when the bar
            // disappears on card 3 — animation transitions a height
            // collapse, which is jarring next to the smooth page slide.
            Color.clear.frame(height: 48)
        }
    }

    // MARK: - Actions

    private func advance() {
        // `withAnimation` here would double up on the TabView's own
        // animation (set via the `.animation` modifier on TabView), so
        // let the modifier handle it and just bump the page index.
        currentPage = min(currentPage + 1, 2)
    }

    private func handleAllowLocation() {
        // Triggers the system permission prompt. iOS layers the alert
        // over whatever's on screen, so it's fine that we navigate away
        // immediately — the user responds with LoginView underneath.
        locationManager.requestPermission()
        finish()
    }

    private func finish() {
        onComplete()
    }
}

// MARK: - Card

/// Generic value-prop card. Stagger-animates its content in whenever it
/// becomes the active page so users who linger on card 2 still see the
/// reveal motion rather than landing on a fully-settled card.
private struct WelcomeCard: View {
    let emoji: String
    let title: String
    let subtitle: String
    let isActive: Bool

    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)

            // Hero glyph — biggest visual anchor. Subtle bounce on reveal
            // matches the warm-coffee brand personality; under reduced
            // motion the bounce is skipped but the fade survives.
            Text(emoji)
                .font(.system(size: 96))
                .accessibilityHidden(true)
                .scaleEffect(visible || reduceMotion ? 1.0 : 0.95)
                .opacity(visible ? 1.0 : 0.0)
                .animation(
                    reduceMotion
                        ? Motion.staggerReveal
                        : Motion.cozyReveal,
                    value: visible
                )

            // Title — staggered 60ms after the hero.
            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.cream)
                .multilineTextAlignment(.center)
                .opacity(visible ? 1.0 : 0.0)
                .offset(y: visible || reduceMotion ? 0 : 8)
                .animation(Motion.staggerReveal.delay(0.06), value: visible)

            // Subtitle — staggered another 60ms.
            Text(subtitle)
                .font(.body)
                .foregroundStyle(AppTheme.cream.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .opacity(visible ? 1.0 : 0.0)
                .offset(y: visible || reduceMotion ? 0 : 8)
                .animation(Motion.staggerReveal.delay(0.12), value: visible)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { visible = isActive }
        .onChange(of: isActive) { _, active in
            visible = active
        }
    }
}

// MARK: - Location card

/// The final card. Visually mirrors a value-prop card but owns its own
/// CTA pair — "Allow Location" (primary) and "Maybe later" (secondary).
/// Tapping primary fires the *real* iOS permission prompt; tapping
/// secondary just finishes the carousel and lets the user grant later
/// from the map screen.
private struct WelcomeLocationCard: View {
    let isActive: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void

    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)

            Text("📍")
                .font(.system(size: 96))
                .accessibilityHidden(true)
                .scaleEffect(visible || reduceMotion ? 1.0 : 0.95)
                .opacity(visible ? 1.0 : 0.0)
                .animation(
                    reduceMotion ? Motion.staggerReveal : Motion.cozyReveal,
                    value: visible
                )

            Text("One last thing.")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.cream)
                .multilineTextAlignment(.center)
                .opacity(visible ? 1.0 : 0.0)
                .offset(y: visible || reduceMotion ? 0 : 8)
                .animation(Motion.staggerReveal.delay(0.06), value: visible)

            Text("Share your location so the map opens on your neighborhood — not a random city. You can change this anytime in Settings.")
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
                    Text("Allow Location")
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.cafeAccent)
                        .clipShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.scalePress)

                Button(action: onSkip) {
                    Text("Maybe later")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.cream.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.scalePress)
            }
            .padding(.horizontal, 24)
            .opacity(visible ? 1.0 : 0.0)
            .animation(Motion.staggerReveal.delay(0.18), value: visible)
        }
        .frame(maxWidth: .infinity)
        .onAppear { visible = isActive }
        .onChange(of: isActive) { _, active in
            visible = active
        }
    }
}

#Preview {
    WelcomeView(onComplete: {})
}
