import SwiftUI
import UIKit

/// Celebratory card shown when an achievement unlocks DURING the session — a
/// glowing badge, the title + flavour, a confetti burst, and a success haptic.
/// Driven by `UserStatsService.justUnlocked`; presented by `MainShellView`.
struct AchievementUnlockToast: View {
    let achievement: Achievement
    var onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(AppTheme.cafeAccent.opacity(0.18))
                    .frame(width: 74, height: 74)
                    .overlay(Circle().stroke(AppTheme.cafeAccent.opacity(0.55), lineWidth: 2))
                    .shadow(color: AppTheme.cafeAccent.opacity(0.55), radius: 16)
                Text(achievement.icon)
                    .font(.system(size: 38))
                    .scaleEffect(appeared ? 1 : 0.3)
                ConfettiBurst().allowsHitTesting(false)
            }
            VStack(spacing: 3) {
                Text("ACHIEVEMENT UNLOCKED")
                    .font(.caption2.weight(.heavy)).tracking(2)
                    .foregroundStyle(AppTheme.cafeAccent)
                Text(achievement.title)
                    .font(.headline.bold())
                    .foregroundStyle(AppTheme.cream)
                    .multilineTextAlignment(.center)
                Text(achievement.flavourText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: 330)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.espresso)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.cafeAccent.opacity(0.3), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .scaleEffect(appeared ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .padding(.horizontal, 24)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Achievement unlocked: \(achievement.title)")
    }
}

/// Lightweight radial confetti burst — fires once on appear, GPU-cheap.
private struct ConfettiBurst: View {
    @State private var go = false
    private let colors: [Color] = [.pink, .orange, .yellow, .green, .blue, .purple, AppTheme.cafeAccent]

    var body: some View {
        ZStack {
            ForEach(0..<18, id: \.self) { i in
                let angle = Double(i) / 18 * 2 * .pi
                let dist: CGFloat = go ? 130 : 0
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: 7, height: 7)
                    .offset(x: cos(angle) * dist, y: sin(angle) * dist + (go ? 70 : 0))
                    .opacity(go ? 0 : 1)
                    .scaleEffect(go ? 0.3 : 1)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1)) { go = true } }
    }
}
