import SwiftUI

// MARK: - Audience

/// Who the submitter imagines bringing to this cafe. Stored on the Cafe doc as
/// `recommendedFor`. Raw values are stable — they're what gets persisted.
enum Audience: String, CaseIterable, Identifiable, Codable {
    case dateNight    = "date_night"
    case familyDinner = "family_dinner"
    case celebration  = "celebration"
    case unwinding    = "unwinding"
    case catchUp      = "catch_up"
    case workSession  = "work_session"
    case lateNight    = "late_night"
    case quickBite    = "quick_bite"

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .dateNight:    return "🌹"
        case .familyDinner: return "🏡"
        case .celebration:  return "🥂"
        case .unwinding:    return "🎧"
        case .catchUp:      return "💬"
        case .workSession:  return "💻"
        case .lateNight:    return "🌙"
        case .quickBite:    return "🥐"
        }
    }

    var label: String {
        switch self {
        case .dateNight:    return "Date night"
        case .familyDinner: return "Family dinner"
        case .celebration:  return "A celebration"
        case .unwinding:    return "Just me, unwinding"
        case .catchUp:      return "A long catch-up"
        case .workSession:  return "A work session"
        case .lateNight:    return "A late night"
        case .quickBite:    return "A quick bite"
        }
    }
}

// MARK: - Step view

struct AddCafeAudienceStep: View {
    @Binding var selected: Set<Audience>
    var onContinue: () -> Void

    @State private var appear = false
    @State private var tapCounter = 0
    @State private var shakeContinue = false

    var body: some View {
        VStack(spacing: 28) {
            // Question header
            VStack(spacing: 10) {
                Text("Who would you")
                    .font(.system(size: 22, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(.white.opacity(0.72))

                Text("bring here?")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
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
                    .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.32),
                            radius: 18, x: 0, y: 4)

                Text("Imagine them here — pick all that feel right.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 24)

            // Chips
            ChipFlow(spacing: 10) {
                ForEach(Audience.allCases) { audience in
                    AudienceChip(
                        audience: audience,
                        isSelected: selected.contains(audience)
                    ) {
                        toggle(audience)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 8)

            // Continue
            Button {
                if selected.isEmpty {
                    withAnimation(.default) { shakeContinue.toggle() }
                    tapCounter += 1
                } else {
                    tapCounter += 1
                    onContinue()
                }
            } label: {
                HStack(spacing: 10) {
                    Text("Continue")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(selected.isEmpty
                                 ? Color.white.opacity(0.45)
                                 : Color(red: 0.12, green: 0.04, blue: 0.06))
                .padding(.horizontal, 34)
                .padding(.vertical, 15)
                .background(
                    Capsule()
                        .fill(
                            selected.isEmpty
                            ? AnyShapeStyle(Color.white.opacity(0.08))
                            : AnyShapeStyle(LinearGradient(
                                colors: [
                                    Color(red: 1.00, green: 0.90, blue: 0.64),
                                    Color(red: 0.99, green: 0.72, blue: 0.40)
                                ],
                                startPoint: .top,
                                endPoint:   .bottom
                            ))
                        )
                        .overlay(
                            Capsule().stroke(
                                Color.white.opacity(selected.isEmpty ? 0.10 : 0.0),
                                lineWidth: 0.5
                            )
                        )
                        .shadow(
                            color: selected.isEmpty
                            ? .clear
                            : Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.48),
                            radius: 16, x: 0, y: 5
                        )
                )
            }
            .buttonStyle(.plain)
            .offset(x: shakeContinue ? -8 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.3),
                       value: shakeContinue)
            .sensoryFeedback(
                selected.isEmpty ? .warning : .impact(weight: .heavy),
                trigger: tapCounter
            )
        }
        .padding(.bottom, 30)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 18)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.88).delay(0.08)) {
                appear = true
            }
        }
    }

    private func toggle(_ audience: Audience) {
        if selected.contains(audience) {
            selected.remove(audience)
        } else {
            selected.insert(audience)
        }
    }
}

// MARK: - Chip

private struct AudienceChip: View {
    let audience: Audience
    let isSelected: Bool
    var onTap: () -> Void

    @State private var pressed = false
    @State private var tapCounter = 0

    var body: some View {
        Button {
            tapCounter += 1
            onTap()
        } label: {
            HStack(spacing: 8) {
                Text(audience.emoji)
                    .font(.system(size: 16))
                Text(audience.label)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isSelected
                             ? Color(red: 0.12, green: 0.04, blue: 0.06)
                             : Color.white.opacity(0.92))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(chipBackground)
            .overlay(chipBorder)
            .shadow(
                color: isSelected
                ? Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.42)
                : .clear,
                radius: 12, x: 0, y: 4
            )
            .scaleEffect(pressed ? 0.94 : (isSelected ? 1.03 : 1.0))
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: isSelected)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: pressed)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.9), trigger: tapCounter)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
    }

    @ViewBuilder private var chipBackground: some View {
        if isSelected {
            Capsule().fill(
                LinearGradient(
                    colors: [
                        Color(red: 1.00, green: 0.84, blue: 0.50),
                        Color(red: 0.99, green: 0.58, blue: 0.32),
                        Color(red: 0.92, green: 0.34, blue: 0.42)
                    ],
                    startPoint: .topLeading,
                    endPoint:   .bottomTrailing
                )
            )
        } else {
            Capsule().fill(Color.white.opacity(0.06))
        }
    }

    @ViewBuilder private var chipBorder: some View {
        if isSelected {
            Capsule().stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.7), Color.white.opacity(0.1)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        } else {
            Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        }
    }
}

// MARK: - Flow layout

/// Simple wrapping horizontal layout — chips wrap to the next row when a row
/// fills. Uses iOS 16+ `Layout` protocol.
struct ChipFlow: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                totalHeight += rowHeight + spacing
                widestRow = max(widestRow, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        totalHeight += rowHeight
        widestRow = max(widestRow, rowWidth - spacing)
        return CGSize(width: widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // First, determine row breaks + widths for centered alignment.
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var rowWidth: CGFloat = 0

        for (idx, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > bounds.width && !rows[rows.count - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append((idx, size))
            rowWidth += size.width + spacing
        }

        var y = bounds.minY
        for row in rows {
            let rowTotalWidth = row.map { $0.size.width }.reduce(0, +)
                              + CGFloat(max(0, row.count - 1)) * spacing
            var x = bounds.minX + (bounds.width - rowTotalWidth) / 2
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            for item in row {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
