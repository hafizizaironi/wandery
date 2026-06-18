import SwiftUI

// MARK: - What's New sheet
//
// Warm "here's what changed" intro shown once per release. The release
// identity is the `whatsNewReleaseKey` constant below — bump it for the
// next round of changes and the sheet shows again automatically.
// AppStorage: `whatsNew.lastSeenKey`.
//
// Each page carries an animated SF Symbol illustration and an OPTIONAL
// "jump to feature" button — tapping it dismisses the sheet and routes
// the host (`MainShellView`) to the relevant page. Users who prefer to
// read all three pages can swipe through and hit "Got it" at the end.

/// Bump when the body of `WhatsNewSheet` changes meaningfully — the
/// AppStorage gate re-presents the sheet on next launch for everyone.
let whatsNewReleaseKey = "2026.06-finale-music-receipt"

/// Features the sheet can deep-link the user into. Older cases
/// (camera/discover/myHunt) are kept so prior routes stay valid; the
/// current tour uses `widgets` + `wanderyCode`.
enum WhatsNewFeature: String {
    case camera, discover, myHunt
    case widgets, wanderyCode
}

struct WhatsNewSheet: View {
    var onDismiss: () -> Void
    /// True for users who can actually use the (still-gated) Receipt frame —
    /// only they get the "exclusive frame" page. See `AuthService.canUseThermalFrame`.
    var canUseThermalFrame: Bool = false
    var onJumpToFeature: (WhatsNewFeature) -> Void

    @State private var page: Int = 0
    private var pages: [WhatsNewPage] { .finale(includeFrame: canUseThermalFrame) }

    var body: some View {
        ZStack {
            AppTheme.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                        WhatsNewPageView(page: p, isActive: idx == page) {
                            if let feature = p.feature { onJumpToFeature(feature) }
                        }
                        .tag(idx)
                        .padding(.horizontal, 24)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                footer
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack {
            Text("What's new")
                .font(.system(size: 13, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    // MARK: footer — paces the carousel

    private var footer: some View {
        let isLast = page == pages.count - 1
        return Button {
            if isLast {
                onDismiss()
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { page += 1 }
            }
        } label: {
            Text(isLast ? "Got it" : "Continue")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.cafeAccent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }
}

// MARK: - Page model

/// Lightweight symbol-animation tag — we keep the enum so the per-page
/// effect lives in data rather than a per-page if/switch in the view.
enum WhatsNewSymbolAnim {
    case bounce          // one-shot when the page becomes active
    case pulse           // gentle continuous breathing
    case variableColor   // sparkle-style colour cycle
}

struct WhatsNewPage: Identifiable {
    let id = UUID()
    let icon: String                    // SF Symbol
    let accentIcons: [AccentIcon]       // small accent symbols floating around the main icon
    let accent: Color
    let symbolAnim: WhatsNewSymbolAnim
    let headline: String
    let body: String
    let footnote: String?
    let feature: WhatsNewFeature?       // jump target — nil hides the inline button
    let jumpCTA: String?                // inline "Try it" button copy
}

/// A small SF Symbol that floats around the main illustration. Drives the
/// "this card has more than one motion" feeling without a heavy art file.
struct AccentIcon {
    let name: String
    let offset: CGSize
    let scale: CGFloat
    let anim: WhatsNewSymbolAnim
}

extension Array where Element == WhatsNewPage {
    /// The final test-phase build tour. The exclusive Receipt frame page is
    /// inserted only for users who can use it (`includeFrame`).
    static func finale(includeFrame: Bool) -> [WhatsNewPage] {
        // Legible green for the music page — raw `Color.musicNeon` is too
        // low-contrast on the carousel's light `surfacePrimary` background.
        let musicGreen = AppTheme.successGreen

        var pages: [WhatsNewPage] = [
            WhatsNewPage(
                icon: "party.popper.fill",
                accentIcons: [
                    AccentIcon(name: "sparkles", offset: CGSize(width:  46, height: -40), scale: 0.30, anim: .variableColor),
                    AccentIcon(name: "heart.fill", offset: CGSize(width: -46, height:  44), scale: 0.28, anim: .pulse),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .bounce,
                headline: "One last build before launch 🥹",
                body: "You're holding the final build of our test phase — and it's a big one. Thank you for hunting with us through every rough edge. Here's everything that's new.",
                footnote: nil,
                feature: nil,
                jumpCTA: nil
            ),
            WhatsNewPage(
                icon: "music.note",
                accentIcons: [
                    AccentIcon(name: "waveform", offset: CGSize(width:  46, height: -40), scale: 0.32, anim: .variableColor),
                    AccentIcon(name: "dot.radiowaves.left.and.right", offset: CGSize(width: -48, height: 42), scale: 0.30, anim: .pulse),
                ],
                accent: musicGreen,
                symbolAnim: .pulse,
                headline: "Your post, soundtracked — automatically",
                body: "Connect Spotify, play a song, then snap a moment — whatever you're listening to rides along with your post and plays for friends in the feed. No picking. Nothing playing? Hit play and it shows up.",
                footnote: "Tap the cover to leave a song off. We find a clean preview even when Spotify doesn't have one.",
                feature: .camera,
                jumpCTA: "Open camera →"
            ),
        ]

        if includeFrame {
            pages.append(
                WhatsNewPage(
                    icon: "barcode",
                    accentIcons: [
                        AccentIcon(name: "music.note", offset: CGSize(width:  46, height: -40), scale: 0.30, anim: .pulse),
                        AccentIcon(name: "scroll", offset: CGSize(width: -46, height: 44), scale: 0.30, anim: .bounce),
                    ],
                    accent: AppTheme.cafeAccent,
                    symbolAnim: .pulse,
                    headline: "Your exclusive Receipt frame 🧾",
                    body: "A thank-you for testing with us: your posts can print as a thermal café receipt — torn edge, monospace rows, and a barcode that dances to your song. Tester-only, and staying that way.",
                    footnote: "Turn it on in Profile → Frame style → Receipt.",
                    feature: nil,
                    jumpCTA: nil
                )
            )
        }

        pages.append(contentsOf: [
            WhatsNewPage(
                icon: "mappin.and.ellipse",
                accentIcons: [
                    AccentIcon(name: "sparkles", offset: CGSize(width:  46, height: -40), scale: 0.30, anim: .variableColor),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .pulse,
                headline: "Tag a place, faster",
                body: "A slimmer place pill, a one-tap nearby suggestion, and swipe a pill away to clear it — plus a sweep of smoother animations and fixes across the composer and feed.",
                footnote: nil,
                feature: nil,
                jumpCTA: nil
            ),
            WhatsNewPage(
                icon: "flame.fill",
                accentIcons: [
                    AccentIcon(name: "hand.thumbsup.fill", offset: CGSize(width:  46, height: -40), scale: 0.28, anim: .bounce),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .variableColor,
                headline: "That's the build 🔥",
                body: "Poke at everything, break things, and tell us what feels off — your feedback shapes the launch. Couldn't have gotten here without you.",
                footnote: "Stay hunting. 🔥",
                feature: nil,
                jumpCTA: nil
            ),
        ])

        return pages
    }
}

// MARK: - Page view

private struct WhatsNewPageView: View {
    let page: WhatsNewPage
    /// True when this is the currently selected page in the TabView — used
    /// to retrigger one-shot animations on swipe-in.
    let isActive: Bool
    let onJump: () -> Void

    /// Toggled when the page becomes active to retrigger `.bounce` symbols.
    @State private var bounceTrigger: Int = 0

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            illustration
            Text(page.headline)
                .font(.system(size: 26, weight: .bold, design: .serif).italic())
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Text(page.body)
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.textPrimary.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 4)
            if let foot = page.footnote {
                Text(foot)
                    .font(.system(size: 12, weight: .medium))
                    .italic()
                    .foregroundStyle(page.accent.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .padding(.top, -2)
            }
            jumpButton
            Spacer(minLength: 16)
        }
        .onChange(of: isActive) { _, active in
            if active { bounceTrigger &+= 1 }
        }
        .onAppear {
            if isActive { bounceTrigger &+= 1 }
        }
    }

    // MARK: illustration

    private var illustration: some View {
        ZStack {
            // Backing disc
            Circle()
                .fill(page.accent.opacity(0.12))
                .frame(width: 132, height: 132)
            Circle()
                .stroke(page.accent.opacity(0.25), lineWidth: 1)
                .frame(width: 132, height: 132)

            // Main symbol — animated per page
            mainIcon

            // Accent symbols floating around the main icon
            ForEach(Array(page.accentIcons.enumerated()), id: \.offset) { _, accent in
                accentSymbol(accent)
            }
        }
        .shadow(color: page.accent.opacity(0.18), radius: 14, y: 4)
    }

    @ViewBuilder
    private var mainIcon: some View {
        let base = Image(systemName: page.icon)
            .font(.system(size: 56, weight: .semibold))
            .foregroundStyle(page.accent)
        applyAnim(page.symbolAnim, to: base)
    }

    private func accentSymbol(_ a: AccentIcon) -> some View {
        let base = Image(systemName: a.name)
            .font(.system(size: 28 * a.scale * 1.4, weight: .bold))
            .foregroundStyle(page.accent.opacity(0.85))
            .padding(8)
            .background(
                Circle()
                    .fill(AppTheme.surfacePrimary)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            )
        return applyAnim(a.anim, to: base)
            .offset(a.offset)
    }

    /// Maps `WhatsNewSymbolAnim` onto SwiftUI's `.symbolEffect` variants.
    /// `.bounce` is keyed off `bounceTrigger` so it replays each time the
    /// page becomes active in the TabView.
    @ViewBuilder
    private func applyAnim<V: View>(_ anim: WhatsNewSymbolAnim, to view: V) -> some View {
        switch anim {
        case .bounce:
            view.symbolEffect(.bounce, value: bounceTrigger)
        case .pulse:
            view.symbolEffect(.pulse, options: .repeating)
        case .variableColor:
            view.symbolEffect(.variableColor.cumulative.reversing, options: .repeating)
        }
    }

    // MARK: jump button — only when the page declares a destination + CTA

    @ViewBuilder
    private var jumpButton: some View {
        if let cta = page.jumpCTA, page.feature != nil {
            Button(action: onJump) {
                HStack(spacing: 4) {
                    Text(cta)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(page.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(page.accent.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(page.accent.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes this tour and opens the feature")
        }
    }
}
