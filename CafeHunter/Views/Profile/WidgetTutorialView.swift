import SwiftUI

/// How-to page for adding the "Photo Feed" Home Screen widget. Reached from the
/// Profile settings. Pure explainer — no data dependencies.
struct WidgetTutorialView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        .init(title: "Touch & hold the Home Screen",
              detail: "Press an empty area until the apps start to jiggle."),
        .init(title: "Tap the ＋ button",
              detail: "It's in the top-left corner. This opens the widget gallery."),
        .init(title: "Search “Wandery”",
              detail: "Type Wandery in the search bar, then pick Photo Feed."),
        .init(title: "Choose a size, then Add Widget",
              detail: "Swipe between Small, Medium and Large and tap Add Widget."),
        .init(title: "Tap Done",
              detail: "Drag it where you like, then tap Done to finish."),
    ]

    private let tips: [(icon: String, text: String)] = [
        ("hand.tap.fill", "Posts with several photos show dots — tap the arrow to flip through them."),
        ("slider.horizontal.3", "Long-press the widget → Edit Widget to turn Auto-advance on or off."),
        ("person.2.fill", "It shows your friends' latest moments — not your own posts."),
        ("arrow.clockwise", "Open Wandery now and then so the widget has fresh photos to show."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    hero
                    stepsCard
                    tipsCard
                }
                .padding(20)
            }
            .background(AppTheme.surfaceCanvas.ignoresSafeArea())
            .navigationTitle("Home Screen Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.accentAction)
                }
            }
        }
    }

    // MARK: - Hero (mock widget + intro)

    private var hero: some View {
        VStack(spacing: 16) {
            widgetMock
                .frame(width: 168, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            VStack(spacing: 6) {
                Text("Your friends' feed, at a glance")
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Add the Photo Feed widget to your Home Screen to see the latest moments from your circle — and tap through their photos.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }

    /// A small stand-in for the real widget (no bundled photo, so a warm gradient).
    private var widgetMock: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.accentAction.opacity(0.9), AppTheme.stallAccent.opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(.white))
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 5) {
                Capsule().fill(.white).frame(width: 16, height: 6)
                Capsule().fill(.white.opacity(0.5)).frame(width: 6, height: 6)
                Capsule().fill(.white.opacity(0.5)).frame(width: 6, height: 6)
            }
            .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                Image(systemName: "square.on.square").font(.system(size: 9, weight: .semibold))
                Text("1/3").font(.system(size: 10.5, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(12)
        }
    }

    // MARK: - Steps

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("How to add it")
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                stepRow(idx: idx, step: step)
            }
        }
        .padding(16)
        .background(AppTheme.surfacePrimary.opacity(0.5))
        .clipShape(.rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppTheme.borderSubtle, lineWidth: 1) }
    }

    @ViewBuilder
    private func stepRow(idx: Int, step: Step) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(idx + 1)")
                .font(.subheadline.bold())
                .foregroundStyle(AppTheme.textOnAccent)
                .frame(width: 28, height: 28)
                .background(AppTheme.accentAction, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.subheadline.bold())
                    .foregroundStyle(AppTheme.textPrimary)
                Text(step.detail).font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)

        if idx < steps.count - 1 {
            Divider().background(AppTheme.borderSubtle).padding(.leading, 42)
        }
    }

    // MARK: - Tips

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Good to know")
            ForEach(tips, id: \.text) { tip in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: tip.icon)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.stallAccent)
                        .frame(width: 24)
                    Text(tip.text).font(.caption)
                        .foregroundStyle(AppTheme.textPrimary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .background(AppTheme.stallAccent.opacity(0.08))
        .clipShape(.rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppTheme.stallAccent.opacity(0.25), lineWidth: 1) }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.bottom, 8)
    }
}
