import SwiftUI
import PhotosUI

// MARK: - Photo prompt

/// Guided prompts that shape a consistent, story-driven photo set for a cafe.
/// Raw values are stable — used as keys when persisting to Firestore/Storage.
enum PhotoPrompt: String, CaseIterable, Identifiable, Codable {
    case vibe    = "vibe"
    case hero    = "hero"
    case counter = "counter"
    case corner  = "corner"

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .vibe:    return "🏠"
        case .hero:    return "☕"
        case .counter: return "🪧"
        case .corner:  return "✨"
        }
    }

    var label: String {
        switch self {
        case .vibe:    return "The vibe"
        case .hero:    return "The hero"
        case .counter: return "The counter"
        case .corner:  return "Your corner"
        }
    }

    var hint: String {
        switch self {
        case .vibe:    return "A wide shot — floor to ceiling."
        case .hero:    return "Close on your drink or dish."
        case .counter: return "Where you ordered."
        case .corner:  return "Whatever caught your eye."
        }
    }
}

// MARK: - Step view

struct AddCafePhotoStep: View {
    @Binding var photos: [PhotoPrompt: UIImage]
    var onContinue: () -> Void

    // Deck state — rotates as the user swipes.
    @State private var order: [PhotoPrompt] = PhotoPrompt.allCases

    // Top-card drag state.
    @State private var dragOffset: CGSize = .zero
    @State private var dragRotation: Double = 0

    // Picker flow.
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var showPicker = false
    @State private var pickingFor: PhotoPrompt? = nil

    // Crop flow.
    @State private var cropImage: UIImage? = nil
    @State private var cropPrompt: PhotoPrompt? = nil
    @State private var showCrop = false

    // Feedback.
    @State private var appear = false
    @State private var swipeCounter = 0
    @State private var shakeCTA = false
    @State private var ctaCounter = 0

    private var captured: Int { photos.count }
    private var canContinue: Bool { captured > 0 }

    var body: some View {
        VStack(spacing: 18) {
            header
                .padding(.horizontal, 24)

            deck
                .frame(maxHeight: .infinity)

            progressRow

            continueButton
                .offset(x: shakeCTA ? -8 : 0)
                .animation(.spring(response: 0.18, dampingFraction: 0.3), value: shakeCTA)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 18)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.88).delay(0.08)) {
                appear = true
            }
        }
        .photosPicker(
            isPresented: $showPicker,
            selection: $pickerItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickerItem) { _, newItem in
            handlePickerResult(newItem)
        }
        .fullScreenCover(isPresented: $showCrop) {
            if let cropImage, let cropPrompt {
                PhotoCropView(
                    image: cropImage,
                    prompt: cropPrompt,
                    onConfirm: { cropped in
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                            photos[cropPrompt] = cropped
                        }
                        endCrop()
                    },
                    onCancel: { endCrop() }
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("Show us")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(.white.opacity(0.72))
            Text("the moments.")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(warmGradient)
                .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.30),
                        radius: 16, x: 0, y: 3)

            Text("Swipe through the deck — tap any card to capture it.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Deck

    private var deck: some View {
        GeometryReader { geo in
            let cardW = min(geo.size.width - 48, 320)
            let cardH = min(cardW / 0.72, geo.size.height - 20)

            ZStack {
                // Iterate PhotoPrompt (Hashable) — position derived from its
                // index in `order`. zIndex drives visual stacking, so iteration
                // order doesn't matter.
                ForEach(Array(order.prefix(3)), id: \.self) { prompt in
                    let position = order.firstIndex(of: prompt) ?? 0
                    stackedCard(for: prompt, position: position,
                                size: CGSize(width: cardW, height: cardH))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func stackedCard(for prompt: PhotoPrompt, position: Int, size: CGSize) -> some View {
        let isTop = position == 0
        let depth = CGFloat(position)

        PhotoCard(
            prompt: prompt,
            image: photos[prompt],
            onTap: { openPicker(for: prompt) }
        )
        .frame(width: size.width, height: size.height)
        .scaleEffect(1 - depth * 0.05, anchor: .top)
        .offset(y: depth * 14)
        .opacity(1 - depth * 0.18)
        .rotationEffect(.degrees(isTop ? dragRotation : 0))
        .offset(isTop ? dragOffset : .zero)
        .allowsHitTesting(isTop)
        .zIndex(Double(100 - position))
        // Gesture attached always; `allowsHitTesting(false)` on non-top cards
        // keeps only the top card draggable, so dragOffset only tracks it.
        .gesture(dragGesture)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: order)
    }

    // MARK: - Drag gesture

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
                dragRotation = Double(value.translation.width / 22)
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > 120 || abs(dy) > 180 {
                    swipeOut(dx: dx, dy: dy)
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                        dragOffset = .zero
                        dragRotation = 0
                    }
                }
            }
    }

    private func swipeOut(dx: CGFloat, dy: CGFloat) {
        swipeCounter += 1
        let outX: CGFloat = dx > 0 ? 700 : -700
        let outY: CGFloat = max(-400, min(400, dy * 1.8))
        let outRot: Double = dx > 0 ? 24 : -24

        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
            dragOffset = CGSize(width: outX, height: outY)
            dragRotation = outRot
        }

        // After the top card has flown off, rotate the queue and reset.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            withTransaction(t) {
                order.append(order.removeFirst())
                dragOffset = .zero
                dragRotation = 0
            }
        }
    }

    // MARK: - Progress row

    private var progressRow: some View {
        HStack(spacing: 10) {
            ForEach(PhotoPrompt.allCases) { prompt in
                let isDone = photos[prompt] != nil
                let isActive = order.first == prompt
                Capsule()
                    .fill(isDone
                          ? AnyShapeStyle(warmGradient)
                          : AnyShapeStyle(Color.white.opacity(isActive ? 0.9 : 0.22)))
                    .frame(width: isActive ? 26 : 8, height: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8),
                               value: order.first)
                    .animation(.easeInOut(duration: 0.25), value: isDone)
            }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: swipeCounter)
    }

    // MARK: - Continue

    private var continueButton: some View {
        Button {
            ctaCounter += 1
            if canContinue {
                onContinue()
            } else {
                withAnimation(.default) { shakeCTA.toggle() }
            }
        } label: {
            HStack(spacing: 10) {
                Text(captured == 0
                     ? "Continue"
                     : "Continue · \(captured)/\(PhotoPrompt.allCases.count) shared")
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(canContinue
                             ? Color(red: 0.12, green: 0.04, blue: 0.06)
                             : Color.white.opacity(0.45))
            .padding(.horizontal, 28)
            .padding(.vertical, 15)
            .background(
                Capsule()
                    .fill(
                        canContinue
                        ? AnyShapeStyle(LinearGradient(
                            colors: [
                                Color(red: 1.00, green: 0.90, blue: 0.64),
                                Color(red: 0.99, green: 0.72, blue: 0.40)
                            ],
                            startPoint: .top,
                            endPoint:   .bottom
                        ))
                        : AnyShapeStyle(Color.white.opacity(0.08))
                    )
                    .shadow(color: canContinue
                            ? Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.48)
                            : .clear,
                            radius: 16, x: 0, y: 5)
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(
            canContinue ? .impact(weight: .heavy) : .warning,
            trigger: ctaCounter
        )
    }

    // MARK: - Picker flow

    private func openPicker(for prompt: PhotoPrompt) {
        pickingFor = prompt
        pickerItem = nil
        showPicker = true
    }

    private func handlePickerResult(_ item: PhotosPickerItem?) {
        guard let item, let prompt = pickingFor else { return }
        Task {
            guard
                let data = try? await item.loadTransferable(type: Data.self),
                let img  = UIImage(data: data)
            else {
                await MainActor.run {
                    pickerItem = nil
                    pickingFor = nil
                }
                return
            }
            await MainActor.run {
                cropImage = img
                cropPrompt = prompt
                showCrop = true
                pickerItem = nil
                pickingFor = nil
            }
        }
    }

    private func endCrop() {
        showCrop = false
        cropImage = nil
        cropPrompt = nil
    }
}

// MARK: - Shared gradient

private let warmGradient = LinearGradient(
    colors: [
        Color(red: 1.00, green: 0.86, blue: 0.58),
        Color(red: 0.99, green: 0.52, blue: 0.32),
        Color(red: 0.96, green: 0.32, blue: 0.46)
    ],
    startPoint: .topLeading,
    endPoint:   .bottomTrailing
)

// MARK: - Photo card

private struct PhotoCard: View {
    let prompt: PhotoPrompt
    let image: UIImage?
    var onTap: () -> Void

    @State private var tapCounter = 0

    var body: some View {
        ZStack {
            // Base plate
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.08, blue: 0.12),
                            Color(red: 0.10, green: 0.04, blue: 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                filledBody(image: image)
            } else {
                emptyBody
            }

            // Rim highlight
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 14)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        // Not a Button — Button's internal press recogniser fights the parent
        // DragGesture. `.onTapGesture` coexists with drag cleanly.
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture {
            tapCounter += 1
            onTap()
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.9), trigger: tapCounter)
    }

    // Empty — big emoji, label, hint, capture CTA.
    private var emptyBody: some View {
        VStack(spacing: 14) {
            Spacer()

            Text(prompt.emoji)
                .font(.system(size: 86))
                .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.35),
                        radius: 24, x: 0, y: 8)

            Text(prompt.label)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(warmGradient)

            Text(prompt.hint)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("Tap to capture")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .foregroundColor(Color(red: 0.12, green: 0.04, blue: 0.06))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(warmGradient))
            .padding(.bottom, 22)
        }
        .padding(.top, 18)
    }

    // Filled — 1:1 photo fills the top, gradient info bar at the bottom.
    private func filledBody(image: UIImage) -> some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()

            HStack(spacing: 8) {
                Text(prompt.emoji).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.label)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Tap to change")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.08, blue: 0.12),
                        Color(red: 0.10, green: 0.04, blue: 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
}

// MARK: - Crop view

/// Full-screen crop-to-square UI. Photo is displayed inside a 1:1 window —
/// pinch to zoom, drag to pan. Confirm captures the window via ImageRenderer
/// so the output is a true square regardless of source aspect ratio.
struct PhotoCropView: View {
    let image: UIImage
    let prompt: PhotoPrompt
    var onConfirm: (UIImage) -> Void
    var onCancel:  () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    @State private var tapCounter = 0

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let cropSize = min(geo.size.width - 32, geo.size.height * 0.62)

            ZStack {
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

                // The clipped 1:1 region that shows the image with live gestures.
                croppedImageView(size: cropSize)
                    .frame(width: cropSize, height: cropSize)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.65), lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 12)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                VStack {
                    header
                    Spacer()
                    footer(cropSize: cropSize)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Button {
                tapCounter += 1
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text(prompt.emoji + "  " + prompt.label)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Pinch & drag to frame")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func footer(cropSize: CGFloat) -> some View {
        Button {
            tapCounter += 1
            Task { @MainActor in
                let cropped = renderCrop(size: cropSize)
                onConfirm(cropped)
            }
        } label: {
            HStack(spacing: 10) {
                Text("Use this frame")
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(Color(red: 0.12, green: 0.04, blue: 0.06))
            .padding(.horizontal, 32)
            .padding(.vertical, 15)
            .background(
                Capsule().fill(warmGradient)
                    .shadow(color: Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.48),
                            radius: 16, x: 0, y: 5)
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 36)
        .sensoryFeedback(.impact(weight: .heavy), trigger: tapCounter)
    }

    // MARK: - Gestures

    @ViewBuilder
    private func croppedImageView(size: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1.0, min(5.0, baseScale * value))
                        }
                        .onEnded { _ in
                            baseScale = scale
                        },
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            baseOffset = offset
                        }
                )
            )
    }

    // MARK: - Render

    /// Rasterise the current scale/offset state into a square UIImage using
    /// ImageRenderer. The content intentionally omits the gesture modifier —
    /// only the visual transform matters for the output.
    @MainActor
    private func renderCrop(size: CGFloat) -> UIImage {
        let content = Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: size, height: size)
            .clipShape(Rectangle())

        let renderer = ImageRenderer(content: content)
        renderer.scale = displayScale
        return renderer.uiImage ?? image
    }
}
