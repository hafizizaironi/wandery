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
let whatsNewReleaseKey = "2026.05-private-posts"

/// Features the sheet can deep-link the user into.
enum WhatsNewFeature: String {
    case camera, discover, myHunt
}

struct WhatsNewSheet: View {
    var onDismiss: () -> Void
    var onJumpToFeature: (WhatsNewFeature) -> Void

    @State private var page: Int = 0
    private let pages: [WhatsNewPage] = .v2026_05

    var body: some View {
        ZStack {
            AppTheme.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                        WhatsNewPageView(page: p, isActive: idx == page) {
                            onJumpToFeature(p.feature)
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
    let feature: WhatsNewFeature        // jump target
    let jumpCTA: String                 // inline "Try it" button copy
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
    static var v2026_05: [WhatsNewPage] {
        [
            WhatsNewPage(
                icon: "person.2.fill",
                accentIcons: [
                    AccentIcon(name: "lock.fill",             offset: CGSize(width:  44, height: -42), scale: 0.34, anim: .bounce),
                    AccentIcon(name: "checkmark.circle.fill", offset: CGSize(width: -46, height:  44), scale: 0.32, anim: .pulse),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .pulse,
                headline: "Pick who sees each post",
                body: "Before you share, tap the faces in the new picker above your photo to choose which friends it goes to. Everyone's in by default — deselect anyone to leave them out. The friends you keep see a quiet “Shared with you.”",
                footnote: "Only the friends you pick can see it.",
                feature: .camera,
                jumpCTA: "Try it →"
            ),
            WhatsNewPage(
                icon: "camera.aperture",
                accentIcons: [
                    AccentIcon(name: "sparkles",      offset: CGSize(width:  46, height: -40), scale: 0.32, anim: .variableColor),
                    AccentIcon(name: "circle.dashed", offset: CGSize(width: -46, height:  44), scale: 0.34, anim: .pulse),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .pulse,
                headline: "Your camera scores the shot",
                body: "A soft ring around the viewfinder slides from red to green as you frame — green means it's bright and crisp enough to shine in Discover. No numbers, just a gentle nudge toward your best photo.",
                footnote: nil,
                feature: .camera,
                jumpCTA: "Open the camera →"
            ),
            WhatsNewPage(
                icon: "sparkle.magnifyingglass",
                accentIcons: [
                    AccentIcon(name: "person.2.fill",   offset: CGSize(width:  46, height:  40), scale: 0.32, anim: .pulse),
                    AccentIcon(name: "sparkle",         offset: CGSize(width: -48, height: -42), scale: 0.30, anim: .variableColor),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .variableColor,
                headline: "Discover beyond your friends",
                body: "Open the Map and you'll spot soft, blurred pins where friends-of-friends have hunted — a tease, not a tell. Tap ✨ to see what's trending across the whole hunt.",
                footnote: "Your photos only ever appear blurred to strangers when shown.",
                feature: .discover,
                jumpCTA: "Show me the map →"
            ),
            WhatsNewPage(
                icon: "map.fill",
                accentIcons: [
                    AccentIcon(name: "mappin.and.ellipse", offset: CGSize(width:  44, height: -40), scale: 0.34, anim: .bounce),
                    AccentIcon(name: "checkmark.shield.fill", offset: CGSize(width: -46, height:  42), scale: 0.30, anim: .pulse),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .pulse,
                headline: "Your hunt, your control",
                body: "Profile → My Hunt is now a month-by-month map of every place you've tagged. New there too: a “Help your circle discover” toggle that decides whether your visits hint at friends-of-friends.",
                footnote: "Default on — turn it off any time, you stay opted-in to seeing others.",
                feature: .myHunt,
                jumpCTA: "Open my hunt →"
            ),
        ]
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

    // MARK: jump button

    private var jumpButton: some View {
        Button(action: onJump) {
            HStack(spacing: 4) {
                Text(page.jumpCTA)
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
