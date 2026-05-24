import SwiftUI
import UIKit

// MARK: - Floating-pill nav bar
//
// iOS-26-Files-style floating capsule pill. Replaces the previous
// curved arc design (kept the `ArcNavBar` type name so the 5 call
// sites don't need to change).
//
// Structure:
//   • Outer `Capsule` with `.ultraThinMaterial` — adapts automatically
//     to the underlying page (dark over Hero's black, light over
//     Profile's cream) so the pill never clashes.
//   • Three equal-width tab cells inside, each with icon + label.
//   • A sliding inner `Capsule` indicator behind the cells that tracks
//     `pageProgress` continuously (so an edge-drag shows the highlight
//     interpolating smoothly between tabs, not snapping).
//   • Drop shadow for "floating" weight.
//
// The pill sits 8pt above the system home-indicator safe area, with
// 20pt left/right margins from the screen edges.

struct ArcNavBar: View {
    /// Total content height (above the bottom safe area). MainShellView
    /// adds `safeAreaInsets.bottom` on top of this for the frame.
    static let frameContentHeight: CGFloat = 80
    /// Distance from the physical screen bottom (excl. safe area) up
    /// to the top of the visible pill. Used by layout sibling code
    /// (e.g. HeroCameraLayout) to position content that should sit
    /// just above the navbar.
    static let homeButtonFromBottom: CGFloat = 80

    @Binding var selectedPage: ShellPage
    @Binding var pageProgress: CGFloat

    /// `(page, outline icon, filled icon, label)` — outline shown on
    /// unselected tabs, filled on the selected one (standard iOS
    /// tab-bar convention).
    private let tabs: [(page: ShellPage, icon: String, filledIcon: String, label: String)] = [
        (.map,     "map",               "map.fill",     "Map"),
        (.hero,    "camera.viewfinder", "camera.fill",  "Hero"),
        (.profile, "person",            "person.fill",  "Profile"),
    ]

    /// Pill geometry. Tweaked here, not at call sites.
    private let pillHeight: CGFloat            = 64
    private let pillInnerPadding: CGFloat      = 6
    private let pillHorizontalMargin: CGFloat  = 20
    private let pillBottomGap: CGFloat         = 8

    @State private var sensoryTap: Int = 0

    /// Reads the home-indicator inset from the key window. Required
    /// because the parent chain (MainShellView's GeometryReader)
    /// already applied `.ignoresSafeArea()`, so a child GeometryReader
    /// here would report `safeAreaInsets.bottom == 0`.
    private static var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    private func tap(_ idx: Int) {
        guard idx >= 0, idx < tabs.count else { return }
        sensoryTap += 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            selectedPage = tabs[idx].page
            pageProgress = CGFloat(idx)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
                .frame(height: pillHeight)
                .padding(.horizontal, pillHorizontalMargin)
                .padding(.bottom, Self.bottomSafeAreaInset + pillBottomGap)
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.85), trigger: sensoryTap)
    }

    private var pill: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabs.count, id: \.self) { idx in
                tabCell(idx: idx)
                    .frame(maxWidth: .infinity)
            }
        }
        // Sliding indicator BEHIND the cells — iOS-26 segmented-control
        // style: a subtle "raised glass" capsule that looks like a lifted
        // inner pane, not a colored accent fill.
        .background(alignment: .leading) {
            GeometryReader { geo in
                let cellWidth = geo.size.width / CGFloat(tabs.count)
                Capsule()
                    .fill(.white.opacity(0.22))
                    .overlay {
                        Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1)
                    .frame(width: cellWidth - 6, height: geo.size.height - 4)
                    .padding(.vertical, 2)
                    .offset(x: cellWidth * pageProgress + 3)
            }
        }
        .padding(pillInnerPadding)
        // Outer pill surface — project-wide Liquid Glass chrome treatment
        // so the navbar reads as the same material as the sheet panels
        // and floating buttons.
        .liquidGlassChrome(in: Capsule())
    }

    @ViewBuilder
    private func tabCell(idx: Int) -> some View {
        let tab        = tabs[idx]
        let isSelected = Int(pageProgress.rounded()) == idx
        // Smooth distance-based fade for the unselected tabs so an
        // edge-drag mid-transition reads as a continuous handoff,
        // not a snap.
        let dist       = abs(CGFloat(idx) - pageProgress)
        let alpha      = max(0.55, 1.0 - dist * 0.40)
        let tint: Color = isSelected ? AppTheme.accentAction : AppTheme.textPrimary

        Button {
            tap(idx)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.filledIcon : tab.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint.opacity(alpha))
                Text(tab.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint.opacity(alpha))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.scalePress)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
