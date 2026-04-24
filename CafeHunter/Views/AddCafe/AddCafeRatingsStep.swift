import SwiftUI

// MARK: - Rating dimension

/// The fixed set of dimensions we rate cafes on. Stable raw values — persisted
/// in Firestore as map keys so averages can be computed across submissions.
enum RatingDimension: String, CaseIterable, Identifiable, Codable, Hashable {
    case coffee
    case matcha
    case food
    case pastries
    case decor
    case view
    case service
    case atmosphere

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .coffee:     return "☕"
        case .matcha:     return "🍵"
        case .food:       return "🍽️"
        case .pastries:   return "🥐"
        case .decor:      return "🪴"
        case .view:       return "🪟"
        case .service:    return "🫂"
        case .atmosphere: return "✨"
        }
    }

    var label: String {
        switch self {
        case .coffee:     return "Coffee"
        case .matcha:     return "Matcha"
        case .food:       return "Food"
        case .pastries:   return "Pastries"
        case .decor:      return "Decor"
        case .view:       return "View"
        case .service:    return "Service"
        case .atmosphere: return "Atmosphere"
        }
    }
}

/// 1-5 face scale — left to right, increasing delight. Tuple kept alongside
/// the enum so the row view and the summary label share one source of truth.
private let faceEmojis:  [String] = ["😐", "🙂", "😊", "😍", "🤩"]
private let faceLabels:  [String] = ["meh", "okay", "good", "great", "unreal"]

// MARK: - Step view

struct AddCafeRatingsStep: View {
    @Binding var ratings:  [RatingDimension: Int]
    @Binding var didntTry: Set<RatingDimension>
    var onContinue: () -> Void

    @State private var appear = false
    @State private var ctaCounter = 0

    private var ratedCount:   Int { ratings.count }
    private var skippedCount: Int { didntTry.count }
    private var pendingCount: Int {
        RatingDimension.allCases.count - ratedCount - skippedCount
    }

    var body: some View {
        VStack(spacing: 14) {
            header
                .padding(.horizontal, 24)

            summaryPills
                .padding(.horizontal, 24)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(RatingDimension.allCases) { dim in
                        RatingRow(
                            dimension: dim,
                            rating: ratings[dim],
                            isSkipped: didntTry.contains(dim),
                            onRate: { value in setRating(dim, to: value) },
                            onSkip: { toggleSkip(dim) }
                        )
                    }
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 20)
            }

            continueButton
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
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("How'd it feel?")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(ratingsGradient)
                .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.30),
                        radius: 14, x: 0, y: 3)

            Text("Only rate what you tried — skipping keeps the averages honest.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Summary

    private var summaryPills: some View {
        HStack(spacing: 8) {
            summaryPill(
                symbol: "hands.sparkles.fill",
                count: ratedCount,
                label: "rated",
                tintFilled: true
            )
            summaryPill(
                symbol: "hand.raised.fill",
                count: skippedCount,
                label: "skipped",
                tintFilled: false
            )
            summaryPill(
                symbol: "circle.dashed",
                count: pendingCount,
                label: "to go",
                tintFilled: false
            )
            Spacer()
        }
    }

    private func summaryPill(symbol: String, count: Int, label: String, tintFilled: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text("\(count) \(label)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
        }
        .foregroundColor(tintFilled ? Color(red: 0.12, green: 0.04, blue: 0.06)
                                    : .white.opacity(0.72))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(tintFilled
                      ? AnyShapeStyle(ratingsGradient)
                      : AnyShapeStyle(Color.white.opacity(0.08)))
                .overlay(
                    Capsule().stroke(
                        Color.white.opacity(tintFilled ? 0 : 0.14),
                        lineWidth: 0.5
                    )
                )
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: count)
    }

    // MARK: - Continue

    private var continueButton: some View {
        Button {
            ctaCounter += 1
            onContinue()
        } label: {
            HStack(spacing: 10) {
                Text(ratedCount == 0
                     ? "Continue"
                     : "Continue · \(ratedCount) rated")
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(Color(red: 0.12, green: 0.04, blue: 0.06))
            .padding(.horizontal, 28)
            .padding(.vertical, 15)
            .background(
                Capsule()
                    .fill(ratingsGradient)
                    .shadow(color: Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.48),
                            radius: 16, x: 0, y: 5)
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .heavy), trigger: ctaCounter)
    }

    // MARK: - Mutations

    private func setRating(_ dim: RatingDimension, to value: Int) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.7)) {
            if ratings[dim] == value {
                // Tap the already-selected face → clear.
                ratings.removeValue(forKey: dim)
            } else {
                ratings[dim] = value
                didntTry.remove(dim) // rating implies tried
            }
        }
    }

    private func toggleSkip(_ dim: RatingDimension) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            if didntTry.contains(dim) {
                didntTry.remove(dim)
            } else {
                didntTry.insert(dim)
                ratings.removeValue(forKey: dim) // skipping clears any rating
            }
        }
    }
}

// MARK: - Row

private struct RatingRow: View {
    let dimension: RatingDimension
    let rating: Int?
    let isSkipped: Bool
    var onRate: (Int) -> Void
    var onSkip: () -> Void

    @State private var tapCounter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(dimension.emoji)
                    .font(.system(size: 18))

                Text(dimension.label)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer(minLength: 0)

                if !isSkipped, let rating {
                    Text(faceLabels[rating - 1])
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(ratingsGradient)
                        .transition(.scale.combined(with: .opacity))
                }

                Button {
                    tapCounter += 1
                    onSkip()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isSkipped
                              ? "arrow.uturn.backward"
                              : "hand.raised")
                            .font(.system(size: 10, weight: .bold))
                        Text(isSkipped ? "undo" : "skip")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.07))
                            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
            }

            if isSkipped {
                skippedBody
            } else {
                facesBody
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(rowBackground)
        .overlay(rowBorder)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.75), trigger: tapCounter)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isSkipped)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: rating)
    }

    // 5 face buttons — selected one scales up, others fade to grayscale.
    private var facesBody: some View {
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { idx in
                let value = idx + 1
                let isSelected = rating == value
                let isOther = rating != nil && !isSelected

                Button {
                    tapCounter += 1
                    onRate(value)
                } label: {
                    Text(faceEmojis[idx])
                        .font(.system(size: 26))
                        .saturation(isOther ? 0 : 1)
                        .opacity(isOther ? 0.35 : 1)
                        .scaleEffect(isSelected ? 1.25 : 1.0)
                        .shadow(color: isSelected
                                ? Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.5)
                                : .clear,
                                radius: 10, x: 0, y: 4)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private var skippedBody: some View {
        HStack {
            Spacer()
            Text("didn't try")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
                .padding(.vertical, 4)
            Spacer()
        }
    }

    @ViewBuilder private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                rating != nil
                ? AnyShapeStyle(LinearGradient(
                    colors: [
                        Color(red: 0.99, green: 0.52, blue: 0.32).opacity(0.14),
                        Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                : AnyShapeStyle(Color.white.opacity(isSkipped ? 0.02 : 0.05))
            )
    }

    @ViewBuilder private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
                rating != nil
                ? Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.45)
                : Color.white.opacity(isSkipped ? 0.06 : 0.10),
                lineWidth: rating != nil ? 0.9 : 0.6
            )
    }
}

// MARK: - Shared gradient

private let ratingsGradient = LinearGradient(
    colors: [
        Color(red: 1.00, green: 0.86, blue: 0.58),
        Color(red: 0.99, green: 0.52, blue: 0.32),
        Color(red: 0.96, green: 0.32, blue: 0.46)
    ],
    startPoint: .topLeading,
    endPoint:   .bottomTrailing
)
