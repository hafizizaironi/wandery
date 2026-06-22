import SwiftUI
import UIKit

// MARK: - What's New sheet
//
// Warm "here's what changed" intro shown once per release. The release
// identity is the `whatsNewReleaseKey` constant below — bump it for the
// next round of changes and the sheet shows again automatically.
// AppStorage: `whatsNew.lastSeenKey`.
//
// Each page carries an animated SF Symbol illustration and an OPTIONAL
// "jump to feature" button — tapping it dismisses the sheet and routes
// the host (`MainShellView`) to the relevant page. Users can swipe through
// every page and hit "Got it" at the end. Page 1 is a special tester
// celebration (pulse rings + bouncing icon + line-by-line thank-you reveal).

/// Bump when the body of `WhatsNewSheet` changes meaningfully — the
/// AppStorage gate re-presents the sheet on next launch for everyone.
let whatsNewReleaseKey = "2026.06-badges-streaks"

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
    /// only they get the "exclusive frame" footnote. See `AuthService.canUseThermalFrame`.
    var canUseThermalFrame: Bool = false
    var onJumpToFeature: (WhatsNewFeature) -> Void
    /// Number of test-phase hunters, shouted out on the celebration opener.
    var testerCount: Int = 18

    @State private var page: Int = 0
    /// Stable clock origin for the celebration's line reveal — captured ONCE when
    /// the sheet is created. The reveal is a pure function of elapsed time since
    /// this instant, so it advances monotonically and can never restart/loop when
    /// the carousel re-renders the page.
    @State private var revealStart = Date()

    private var pages: [WhatsNewPage] {
        .badgesAndStreaks(includeFrame: canUseThermalFrame, testerCount: testerCount)
    }

    var body: some View {
        ZStack {
            AppTheme.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                        WhatsNewPageView(page: p, isActive: idx == page, revealStart: revealStart) {
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
        .onAppear {
            // One celebratory tap as the opener lands (page 1 is the celebration).
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
    /// When true this page renders the tester celebration (pulse rings + bouncing
    /// icon + line-by-line thank-you reveal) instead of the standard body text.
    var isCelebration: Bool = false
    /// Tester count shouted out on the celebration page.
    var testerCount: Int? = nil
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
    /// This build's tour — a tester celebration opener, then the achievements
    /// glow-up, posting streaks, and the frame wardrobe. The Receipt-frame
    /// footnote only shows for testers who can use it (`includeFrame`).
    static func badgesAndStreaks(includeFrame: Bool, testerCount: Int) -> [WhatsNewPage] {
        [
            WhatsNewPage(
                icon: "party.popper.fill",
                accentIcons: [
                    AccentIcon(name: "sparkles", offset: CGSize(width:  46, height: -40), scale: 0.30, anim: .variableColor),
                    AccentIcon(name: "heart.fill", offset: CGSize(width: -46, height:  44), scale: 0.28, anim: .pulse),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .bounce,   // ignored for the celebration page — `celebrationIcon` hardcodes a repeating bounce
                headline: "One last build before launch 🥹",
                body: "",   // celebration uses the line-reveal thank-you, not the standard body
                footnote: "Here's everything new — swipe through 👉",
                feature: nil,
                jumpCTA: nil,
                isCelebration: true,
                testerCount: testerCount
            ),
            WhatsNewPage(
                icon: "trophy.fill",
                accentIcons: [
                    AccentIcon(name: "star.fill", offset: CGSize(width:  46, height: -40), scale: 0.30, anim: .variableColor),
                    AccentIcon(name: "lock.fill", offset: CGSize(width: -46, height:  44), scale: 0.26, anim: .pulse),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .bounce,
                headline: "47 badges to chase 🏆",
                body: "Achievements got a massive glow-up. Climb tiered ladders for cafés, stalls, photos, friends and more — with a few secret ??? badges hidden for you to uncover. Earn one and watch it pop.",
                footnote: "Find them all in Profile → Achievements.",
                feature: nil,
                jumpCTA: nil
            ),
            WhatsNewPage(
                icon: "flame.fill",
                accentIcons: [
                    AccentIcon(name: "calendar", offset: CGSize(width:  46, height: -40), scale: 0.28, anim: .pulse),
                    AccentIcon(name: "checkmark.circle.fill", offset: CGSize(width: -46, height:  44), scale: 0.28, anim: .bounce),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .variableColor,
                headline: "Keep the streak alive 🔥",
                body: "Post on back-to-back days and your streak climbs. Your profile now shows a live flame counter — lock in today's hunt before midnight, or watch it cool off. How long can you go?",
                footnote: "Your current run + personal best sit at the top of Profile.",
                feature: nil,
                jumpCTA: nil
            ),
            WhatsNewPage(
                icon: "square.stack.3d.up.fill",
                accentIcons: [
                    AccentIcon(name: "sparkles", offset: CGSize(width:  46, height: -40), scale: 0.30, anim: .variableColor),
                    AccentIcon(name: "scroll", offset: CGSize(width: -46, height:  44), scale: 0.28, anim: .bounce),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .pulse,
                headline: "Your frame wardrobe 🖼️",
                body: "Browse your post styles in one swipeable place and preview each on a sample before you wear it. We'll keep dropping new frames into your wardrobe — so check back often.",
                footnote: includeFrame
                    ? "Your exclusive Receipt frame is waiting in there. 🧾"
                    : "Open it in Profile → Frame style.",
                feature: nil,
                jumpCTA: nil
            ),
            WhatsNewPage(
                icon: "heart.fill",
                accentIcons: [
                    AccentIcon(name: "flame.fill", offset: CGSize(width:  46, height: -40), scale: 0.28, anim: .variableColor),
                ],
                accent: AppTheme.cafeAccent,
                symbolAnim: .bounce,
                headline: "That's the drop 🔥",
                body: "Poke at everything, earn some badges, start a streak, and tell us what feels off — your feedback is shaping the launch. Couldn't have gotten here without you.",
                footnote: "Stay hunting. 🔥",
                feature: nil,
                jumpCTA: nil
            ),
        ]
    }
}

// MARK: - Page view

private struct WhatsNewPageView: View {
    let page: WhatsNewPage
    /// True when this is the currently selected page in the TabView — used
    /// to retrigger the standard pages' one-shot `.bounce` symbol.
    let isActive: Bool
    /// Stable clock origin (from the sheet) for the celebration line reveal.
    let revealStart: Date
    let onJump: () -> Void

    /// Bumped when the page becomes active to replay the standard `.bounce` symbol.
    @State private var bounceTrigger: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            if page.isCelebration {
                celebrationIllustration
            } else {
                illustration
            }
            Text(page.headline)
                .font(.system(size: 26, weight: .bold, design: .serif).italic())
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            if page.isCelebration {
                // The centerpiece: each thank-you line wipes in left→right,
                // staggered top-to-bottom. Driven purely by elapsed time since
                // `revealStart` (monotonic, capped) — it reveals once and holds,
                // and cannot loop no matter how the carousel re-renders.
                LineRevealText(
                    lines: celebrationLines,
                    font: .system(size: 16.5, weight: .medium, design: .serif),
                    color: AppTheme.textPrimary,
                    start: reduceMotion ? nil : revealStart
                )
                .padding(.horizontal, 10)
                .padding(.top, 2)
            } else {
                Text(page.body)
                    .font(.system(size: 15))
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 4)
            }
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

    /// The thank-you revealed line-by-line on the celebration opener.
    private var celebrationLines: [String] {
        [
            "To our \(page.testerCount ?? 18) hunters —",
            "every bug caught, every late-night hunt,",
            "you got us to the doorstep of launch.",
            "Thank you. 🔥",
        ]
    }

    /// Celebration variant — expanding pulse rings behind a continuously
    /// bouncing icon, on top of the standard disc + accent floaters.
    private var celebrationIllustration: some View {
        ZStack {
            if !reduceMotion {
                // FIXED layout footprint. CelebrationPulse's rings grow/shrink
                // every frame; without a fixed frame its oscillating size reflows
                // the whole VStack and BOBS the text up/down (the "looping" bug).
                // The frame pins layout to the disc size; rings overflow visually.
                CelebrationPulse(color: page.accent)
                    .frame(width: 132, height: 132)
            }
            Circle()
                .fill(page.accent.opacity(0.12))
                .frame(width: 132, height: 132)
            Circle()
                .stroke(page.accent.opacity(0.25), lineWidth: 1)
                .frame(width: 132, height: 132)
            celebrationIcon
            ForEach(Array(page.accentIcons.enumerated()), id: \.offset) { _, accent in
                accentSymbol(accent)
            }
        }
        .shadow(color: page.accent.opacity(0.18), radius: 14, y: 4)
    }

    @ViewBuilder
    private var celebrationIcon: some View {
        let base = Image(systemName: page.icon)
            .font(.system(size: 56, weight: .semibold))
            .foregroundStyle(page.accent)
        if reduceMotion {
            base
        } else {
            base.symbolEffect(.bounce, options: .repeating)
        }
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
        return Group {
            if reduceMotion {
                base   // honour Reduce Motion — no repeating symbol effect
            } else {
                applyAnim(a.anim, to: base)
            }
        }
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

// MARK: - Celebration animation primitives (tester-celebration opener)

/// Expanding concentric rings behind the celebration icon (RadialPulse-style).
private struct CelebrationPulse: View {
    var color: Color
    var maxDiameter: CGFloat = 176
    private let count = 3
    private let period = 2.6

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let p = ((t / period) + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(color.opacity((1 - p) * 0.5), lineWidth: 2)
                        .frame(width: maxDiameter * p, height: maxDiameter * p)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Reveals a block of text one line at a time, each wiping in horizontally
/// (left→right) staggered top-to-bottom.
///
/// CRITICAL: the reveal is a PURE FUNCTION of elapsed time since `start` (a
/// stable timestamp owned by the sheet), evaluated each frame inside a
/// `TimelineView`. Per-line progress is `clamp((elapsed − i·perLine) / dur, 0…1)`
/// — strictly monotonic and capped at 1, so it reveals exactly once and HOLDS.
/// There is NO `@State`, NO `onAppear`, NO reset — so it cannot restart or loop
/// when the carousel re-renders/recreates the page (the bug the old version had).
/// `start == nil` (Reduce Motion) renders every line fully, statically.
private struct LineRevealText: View {
    let lines: [String]
    var font: Font
    var color: Color
    var start: Date?

    private let perLine: Double = 0.42   // stagger between lines
    private let dur: Double = 0.6        // each line's wipe duration

    var body: some View {
        Group {
            if start == nil {
                rows { _ in 1 }                       // static, fully revealed
            } else {
                TimelineView(.animation) { ctx in
                    rows { i in progress(line: i, now: ctx.date) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.joined(separator: " "))
    }

    private func rows(_ amount: @escaping (Int) -> CGFloat) -> some View {
        VStack(spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(font)
                    .foregroundStyle(color)
                    .multilineTextAlignment(.center)
                    .mask(Rectangle().scaleEffect(x: amount(i), anchor: .leading))
            }
        }
    }

    /// 0→1 reveal fraction for line `i` at `now`, clamped — never decreases.
    private func progress(line i: Int, now: Date) -> CGFloat {
        guard let start else { return 1 }
        let elapsed = now.timeIntervalSince(start) - Double(i) * perLine
        return CGFloat(min(1, max(0, elapsed / dur)))
    }
}
