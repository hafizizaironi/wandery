import SwiftUI
import UIKit

/// Full-screen conversational flow for submitting a new cafe or stall.
/// Presented via the portal transition from the "+" button.
///
/// Step 2 scaffold: welcome step is live, remaining steps are placeholders
/// so we can land them one at a time without breaking the shell.
/// Draft model that accumulates user answers across the conversational flow.
/// Persists into Firestore at the final submit step.
struct CafeDraft {
    var audiences: Set<Audience> = []
    var name: String = ""
    var neighborhood: String = ""
    var placeType: PlaceType = .cafe
    /// 0,0 means "unset" — matches the existing Cafe document convention.
    var lat: Double = 0
    var lng: Double = 0
    /// Photo prompts → captured image. Uploaded to Storage at submit.
    var photos: [PhotoPrompt: UIImage] = [:]
    /// Track the user tagged with this cafe. nil = skipped.
    var vibeTrack: VibeTrack? = nil
    /// Per-dimension scores (1–5). Missing dimension = unrated.
    var ratings: [RatingDimension: Int] = [:]
    /// Dimensions the user explicitly opted out of ("didn't try").
    var didntTry: Set<RatingDimension> = []
    /// The AI-generated mascot for this cafe. nil = not yet revealed.
    var character: GeneratedCharacter? = nil
}

struct AddCafeFlowView: View {
    var onDismiss: () -> Void

    /// Reads the actual top safe-area inset via UIKit.
    /// Needed because this view extends under the status bar (ignoresSafeArea)
    /// so SwiftUI's GeometryProxy reports 0 for safeAreaInsets.top.
    private var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.top ?? 47
    }

    @State private var draft = CafeDraft()

    @State private var step: Int = 0
    private let totalSteps = 8

    var body: some View {
        ZStack {
            // Warm, deep backdrop — feels like "inside the portal", not just a dark sheet.
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.04, blue: 0.10),
                    Color(red: 0.16, green: 0.06, blue: 0.09),
                    Color(red: 0.11, green: 0.03, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            AmbientBokeh()
                .ignoresSafeArea()
                .opacity(0.85)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, safeTop + 8)

                Spacer(minLength: 0)

                Group {
                    switch step {
                    case 0:
                        AddCafeWelcomeStep(onContinue: { advance() })
                    case 1:
                        AddCafeAudienceStep(
                            selected: $draft.audiences,
                            onContinue: { advance() }
                        )
                    case 2:
                        AddCafeIdentityStep(
                            name: $draft.name,
                            neighborhood: $draft.neighborhood,
                            placeType: $draft.placeType,
                            onContinue: { advance() }
                        )
                    case 3:
                        AddCafeLocationStep(
                            lat: $draft.lat,
                            lng: $draft.lng,
                            neighborhood: draft.neighborhood,
                            onContinue: { advance() }
                        )
                    case 4:
                        AddCafePhotoStep(
                            photos: $draft.photos,
                            onContinue: { advance() }
                        )
                    case 5:
                        AddCafeVibeStep(
                            track: $draft.vibeTrack,
                            audiences: draft.audiences,
                            placeType: draft.placeType,
                            onContinue: { advance() }
                        )
                    case 6:
                        AddCafeRatingsStep(
                            ratings: $draft.ratings,
                            didntTry: $draft.didntTry,
                            onContinue: { advance() }
                        )
                    case 7:
                        AddCafeCharacterStep(
                            draft: draft,
                            character: $draft.character,
                            onComplete: onDismiss
                        )
                    default:
                        ComingSoonStep(stepNumber: step + 1, onBack: { step = 0 })
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 40)),
                    removal:   .opacity.combined(with: .offset(x: -40))
                ))
                .id(step)
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: step)

                Spacer(minLength: 0)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            // Left: back chevron — shown only once the user has left welcome.
            if step > 0 {
                Button(action: goBack) {
                    topBarIcon("chevron.left")
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale))
            } else {
                Color.clear.frame(width: 36, height: 36)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.white : Color.white.opacity(0.22))
                        .frame(width: i == step ? 20 : 6, height: 6)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
                }
            }

            Spacer()

            // Right: X always closes the whole flow.
            Button(action: onDismiss) {
                topBarIcon("xmark")
            }
            .buttonStyle(.plain)
        }
    }

    private func topBarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white.opacity(0.9))
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
            )
    }

    private func advance() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            step = min(totalSteps - 1, step + 1)
        }
    }

    private func goBack() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            step = max(0, step - 1)
        }
    }
}

// MARK: - Welcome

private struct AddCafeWelcomeStep: View {
    var onContinue: () -> Void

    @State private var appear = false
    @State private var tap = 0

    var body: some View {
        VStack(spacing: 36) {
            VStack(spacing: 12) {
                Text("You found")
                    .font(.system(size: 26, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(Color.white.opacity(0.72))

                Text("something worth\nsharing.")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 1.00, green: 0.86, blue: 0.58),
                                Color(red: 0.99, green: 0.52, blue: 0.32),
                                Color(red: 0.96, green: 0.32, blue: 0.46)
                            ],
                            startPoint: .topLeading,
                            endPoint:   .bottomTrailing
                        )
                    )
                    .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.38),
                            radius: 22, x: 0, y: 4)
            }

            Text("Let's bring your people along — tell us what makes this place yours.")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 24)

            Button {
                tap += 1
                onContinue()
            } label: {
                HStack(spacing: 10) {
                    Text("I'm ready")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .bold))
                }
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.12, green: 0.04, blue: 0.06))
                .padding(.horizontal, 34)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.00, green: 0.90, blue: 0.64),
                                    Color(red: 0.99, green: 0.72, blue: 0.40)
                                ],
                                startPoint: .top,
                                endPoint:   .bottom
                            )
                        )
                        .shadow(color: Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.55),
                                radius: 18, x: 0, y: 6)
                )
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .heavy), trigger: tap)
        }
        .padding(.horizontal, 28)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 24)
        .onAppear {
            // Delay so the portal finishes opening before the title rises in.
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.35)) {
                appear = true
            }
        }
    }
}

// MARK: - Placeholder for not-yet-built steps

private struct ComingSoonStep: View {
    let stepNumber: Int
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Step \(stepNumber)")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color.white.opacity(0.55)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            Text("Lands next — this is the scaffold.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.6))

            Button(action: onBack) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                    Text("Back to start")
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(.horizontal, 28)
    }
}

// MARK: - Ambient bokeh

/// Slow-drifting glowing blobs in the background — keeps the flow feeling
/// "alive" rather than a static dark sheet.
private struct AmbientBokeh: View {
    @State private var phase: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let blobs: [(x: Double, y: Double, r: Double, hue: Double)] = [
                (0.20, 0.22, 190, 0.04),
                (0.82, 0.32, 160, 0.92),
                (0.30, 0.78, 220, 0.02),
                (0.72, 0.84, 180, 0.08),
                (0.50, 0.50, 140, 0.95)
            ]
            for (i, b) in blobs.enumerated() {
                let drift = sin(phase + Double(i) * 1.3) * 26
                let x = b.x * size.width + drift
                let y = b.y * size.height + cos(phase * 0.7 + Double(i)) * 20
                let rect = CGRect(x: x - b.r, y: y - b.r, width: b.r * 2, height: b.r * 2)
                ctx.fill(
                    Circle().path(in: rect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(hue: b.hue, saturation: 0.62, brightness: 0.95)
                                .opacity(0.22),
                            Color(hue: b.hue, saturation: 0.62, brightness: 0.95)
                                .opacity(0.0)
                        ]),
                        center: CGPoint(x: x, y: y),
                        startRadius: 0,
                        endRadius: b.r
                    )
                )
            }
        }
        .blur(radius: 22)
        .blendMode(.screen)
        .onAppear {
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}
