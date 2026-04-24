import SwiftUI

/// High-energy "+" button that floats at the geometric center of the arc navbar's
/// imaginary circle. Cradled by the arc above it, sits in empty space below.
///
/// Idle: slow breathing halo + continuously rotating conic gradient (amber →
/// magenta → terracotta → gold) so the button reads as "alive" and inviting.
/// Press: punchy spring scale-down with heavy haptic.
struct AddCafeButton: View {
    var action: () -> Void

    @State private var breathe = false
    @State private var rotate: Double = 0
    @State private var pressed = false
    @State private var tapCount = 0

    private let size: CGFloat = 58

    var body: some View {
        Button {
            tapCount += 1
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) {
                pressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.7)) {
                    pressed = false
                }
                action()
            }
        } label: {
            ZStack {
                // Bloom halo — breathes to telegraph "tap me".
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                AppTheme.accentAction.opacity(0.55),
                                AppTheme.accentAction.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.95
                        )
                    )
                    .frame(width: size * 1.9, height: size * 1.9)
                    .blur(radius: 10)
                    .opacity(breathe ? 0.95 : 0.5)

                // Rotating conic gradient body — the energy.
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.96, green: 0.44, blue: 0.20), // amber
                                Color(red: 0.84, green: 0.22, blue: 0.36), // magenta
                                Color(red: 0.71, green: 0.32, blue: 0.23), // terracotta
                                Color(red: 0.98, green: 0.60, blue: 0.18), // gold
                                Color(red: 0.96, green: 0.44, blue: 0.20)  // loop
                            ]),
                            center: .center,
                            angle: .degrees(rotate)
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.85),
                                        Color.white.opacity(0.28),
                                        Color.white.opacity(0.06)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.4
                            )
                    )
                    .shadow(color: AppTheme.accentAction.opacity(0.45),
                            radius: 14, x: 0, y: 4)
                    .shadow(color: .black.opacity(0.22),
                            radius: 4, x: 0, y: 2)

                // Specular catchlight — top crescent of light.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .frame(width: size * 0.84, height: size * 0.46)
                    .offset(y: -size * 0.22)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1, x: 0, y: 1)
                    .rotationEffect(.degrees(pressed ? 90 : 0))
            }
            .scaleEffect(pressed ? 0.86 : (breathe ? 1.035 : 1.0))
            .frame(width: 88, height: 88)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: tapCount)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                breathe = true
            }
            withAnimation(.linear(duration: 5.5).repeatForever(autoreverses: false)) {
                rotate = 360
            }
        }
    }
}
