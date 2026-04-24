import SwiftUI

// MARK: - Step state

private enum CharacterPhase: Equatable {
    case generating
    case revealed
    case submitting
    case success
    case failed(String)
}

// MARK: - Step view

struct AddCafeCharacterStep: View {
    let draft: CafeDraft
    @Binding var character: GeneratedCharacter?
    /// Called after the submit sequence finishes — the flow should dismiss.
    var onComplete: () -> Void

    @State private var phase: CharacterPhase = .generating
    @State private var attempt: Int = 0

    @State private var appear = false
    @State private var ctaCounter = 0
    @State private var brewingStageIndex = 0

    // Reveal animation state
    @State private var imageScale: CGFloat = 0.3
    @State private var imageOpacity: Double = 0
    @State private var nameOpacity: Double = 0
    @State private var taglineOpacity: Double = 0
    @State private var glowStrength: Double = 0

    /// Cycled through while the mascot is being generated — 5–10s is a lot
    /// to stare at a single line.
    private let brewingStages = [
        "Listening to what you told us…",
        "Sketching their eyes…",
        "Mixing the colours…",
        "Adding the finishing touches…"
    ]

    var body: some View {
        ZStack {
            centerContent

            if phase == .success {
                ConfettiBurst()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 18)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.88).delay(0.08)) {
                appear = true
            }
            if character == nil {
                Task { await runGeneration() }
            } else {
                // Returning to the step with a character already picked.
                phase = .revealed
                imageScale = 1
                imageOpacity = 1
                nameOpacity = 1
                taglineOpacity = 1
                glowStrength = 1
            }
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        switch phase {
        case .generating:
            generatingBody
        case .revealed, .submitting, .success, .failed:
            revealedBody
        }
    }

    // MARK: - Generating

    private var generatingBody: some View {
        VStack(spacing: 26) {
            Spacer()

            SwirlingOrb()
                .frame(width: 200, height: 200)

            VStack(spacing: 6) {
                Text("Brewing your mascot")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(charGradient)
                    .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.38),
                            radius: 18, x: 0, y: 4)

                Text(brewingStages[brewingStageIndex])
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .id(brewingStageIndex)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            .frame(height: 58)

            Spacer()
        }
        .padding(.horizontal, 24)
        .task {
            // Cycle the status line every ~1.8s while this view is on-screen.
            // `.task` auto-cancels when the body disappears (on reveal).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.4)) {
                    brewingStageIndex = (brewingStageIndex + 1) % brewingStages.count
                }
            }
        }
    }

    // MARK: - Revealed / submitting / success

    private var revealedBody: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 10)

            characterPortrait

            if let c = character {
                VStack(spacing: 8) {
                    Text(c.name)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(charGradient)
                        .multilineTextAlignment(.center)
                        .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.30),
                                radius: 14, x: 0, y: 3)
                        .opacity(nameOpacity)

                    Text("\u{201C}\(c.tagline)\u{201D}")
                        .font(.system(size: 14, weight: .medium, design: .serif))
                        .italic()
                        .foregroundColor(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .opacity(taglineOpacity)
                }
            }

            Spacer(minLength: 6)

            switch phase {
            case .revealed:
                revealActions
            case .submitting:
                submittingPanel
            case .success:
                successBanner
            case .failed(let msg):
                failurePanel(msg)
            case .generating:
                EmptyView()
            }
        }
        .padding(.bottom, 22)
    }

    private var characterPortrait: some View {
        ZStack {
            // Soft warm halo behind the portrait — strength rises with reveal.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.55),
                            Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.20),
                            .clear
                        ],
                        center: .center,
                        startRadius: 30,
                        endRadius: 180
                    )
                )
                .frame(width: 320, height: 320)
                .blur(radius: 14)
                .opacity(glowStrength)

            if let c = character {
                AsyncImage(url: URL(string: c.imageURL)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "sparkles")
                            .font(.system(size: 64))
                            .foregroundColor(.white.opacity(0.8))
                    default:
                        ProgressView().tint(.white.opacity(0.7))
                    }
                }
                .frame(width: 220, height: 220)
                .background(
                    Circle().fill(Color.white.opacity(0.06))
                )
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.8),
                                    Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.5),
                                    Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.4)
                                ],
                                startPoint: .top,
                                endPoint:   .bottom
                            ),
                            lineWidth: 2
                        )
                )
                .scaleEffect(imageScale)
                .opacity(imageOpacity)
                .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.35),
                        radius: 24, x: 0, y: 10)
            }
        }
        .frame(height: 260)
    }

    // MARK: - Reveal actions

    private var revealActions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    ctaCounter += 1
                    Task { await runGeneration(isReroll: true) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .bold))
                        Text("Reroll")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                    )
                }
                .buttonStyle(.plain)

                Button {
                    ctaCounter += 1
                    Task { await runSubmit() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                        Text("Add to the map")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(Color(red: 0.12, green: 0.04, blue: 0.06))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .background(
                        Capsule()
                            .fill(charGradient)
                            .shadow(color: Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.48),
                                    radius: 16, x: 0, y: 5)
                    )
                }
                .buttonStyle(.plain)
            }
            .sensoryFeedback(.impact(weight: .heavy), trigger: ctaCounter)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Submitting

    private var submittingPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().tint(.white.opacity(0.8))
                Text("Adding to your map…")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
            }
            Text("Uploading photos, saving your story")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 22)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        )
    }

    // MARK: - Success

    private var successBanner: some View {
        VStack(spacing: 6) {
            Text("Added!")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(charGradient)
                .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.35),
                        radius: 14, x: 0, y: 3)
            Text("Your map just grew a little richer.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
        }
        .padding(.vertical, 12)
    }

    // MARK: - Failure

    private func failurePanel(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.red.opacity(0.85))
                .multilineTextAlignment(.center)

            Button {
                Task { await runSubmit() }
            } label: {
                Text("Try again")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.12, green: 0.04, blue: 0.06))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(charGradient))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Flow

    @MainActor
    private func runGeneration(isReroll: Bool = false) async {
        if isReroll {
            attempt += 1
            // Reset reveal animation state so the new character plays it again.
            withAnimation(.easeOut(duration: 0.25)) {
                imageScale = 0.4
                imageOpacity = 0
                nameOpacity = 0
                taglineOpacity = 0
                glowStrength = 0
            }
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .generating
        }

        let generated = await CharacterGenerationService.generate(for: draft, attempt: attempt)
        character = generated

        withAnimation(.easeInOut(duration: 0.35)) {
            phase = .revealed
        }

        // Reveal sequence — image bounces in, name fades, tagline settles.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.6).delay(0.05)) {
            imageScale = 1.0
            imageOpacity = 1.0
            glowStrength = 1.0
        }
        withAnimation(.easeOut(duration: 0.5).delay(0.4)) {
            nameOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.5).delay(0.75)) {
            taglineOpacity = 1.0
        }
    }

    @MainActor
    private func runSubmit() async {
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .submitting
        }

        // TODO: wire real photo upload + Firestore write here.
        // Shape of the final submit:
        //   1. Upload each draft.photos[prompt] → Storage, collect URLs
        //   2. Write new Cafe doc with draft fields + character + photos + ratings
        // For now we simulate with a short delay so the UX is flowable.
        try? await Task.sleep(nanoseconds: 1_800_000_000)

        withAnimation(.easeInOut(duration: 0.35)) {
            phase = .success
        }

        // Linger on the confetti, then close the whole flow.
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        onComplete()
    }
}

// MARK: - Swirling orb (generating state)

private struct SwirlingOrb: View {
    @State private var rotate: Double = 0
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Outer soft halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.55),
                            Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.10),
                            .clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 110
                    )
                )
                .blur(radius: 12)
                .scaleEffect(pulse ? 1.08 : 0.92)

            // Rotating conic — the "brewing"
            Circle()
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(red: 1.00, green: 0.86, blue: 0.58),
                            Color(red: 0.99, green: 0.52, blue: 0.32),
                            Color(red: 0.96, green: 0.32, blue: 0.46),
                            Color(red: 1.00, green: 0.86, blue: 0.58)
                        ]),
                        center: .center,
                        angle: .degrees(rotate)
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round, dash: [22, 14])
                )
                .frame(width: 140, height: 140)
                .rotationEffect(.degrees(rotate))

            // Inner core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.65),
                            Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.1)
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 36
                    )
                )
                .frame(width: 72, height: 72)
                .scaleEffect(pulse ? 1.06 : 0.94)
                .blur(radius: 1)
        }
        .onAppear {
            withAnimation(.linear(duration: 3.6).repeatForever(autoreverses: false)) {
                rotate = 360
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Confetti

/// Simple confetti burst — coloured tiles fall from the top with a light
/// rotation. Auto-stops after ~3 seconds so it doesn't run forever.
private struct ConfettiBurst: View {
    struct Piece: Identifiable {
        let id = UUID()
        let x: CGFloat     // 0…1 horizontal position
        let delay: Double
        let duration: Double
        let size: CGFloat
        let hue: Double
        let rotation: Double
    }

    @State private var pieces: [Piece] = (0..<60).map { _ in
        Piece(
            x: CGFloat.random(in: 0...1),
            delay: Double.random(in: 0...0.8),
            duration: Double.random(in: 1.6...2.6),
            size: CGFloat.random(in: 6...12),
            hue: Double.random(in: 0...1),
            rotation: Double.random(in: 0...360)
        )
    }

    @State private var animateOn = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    Rectangle()
                        .fill(Color(hue: piece.hue, saturation: 0.78, brightness: 0.95))
                        .frame(width: piece.size, height: piece.size * 0.45)
                        .rotationEffect(.degrees(animateOn ? piece.rotation + 540 : piece.rotation))
                        .position(
                            x: piece.x * geo.size.width,
                            y: animateOn ? geo.size.height + 40 : -40
                        )
                        .animation(
                            .easeIn(duration: piece.duration).delay(piece.delay),
                            value: animateOn
                        )
                }
            }
        }
        .onAppear { animateOn = true }
    }
}

// MARK: - Shared gradient

private let charGradient = LinearGradient(
    colors: [
        Color(red: 1.00, green: 0.86, blue: 0.58),
        Color(red: 0.99, green: 0.52, blue: 0.32),
        Color(red: 0.96, green: 0.32, blue: 0.46)
    ],
    startPoint: .topLeading,
    endPoint:   .bottomTrailing
)
