import SwiftUI

struct CafeCardView: View {
    let cafe: Cafe
    let isActive: Bool
    let onTap: () -> Void

    private var accent: Color { AppTheme.accent(for: cafe.type) }
    private var activeBg: Color {
        cafe.type == .stall
            ? Color(red: 0.102, green: 0.208, blue: 0.125)
            : Color(red: 0.176, green: 0.102, blue: 0.055)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Photo / gradient header
                ZStack(alignment: .bottom) {
                    photoOrGradient
                        .frame(height: 140)
                        .clipped()

                    // Gradient scrim
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    // Name & neighbourhood
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cafe.neighborhood.uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .tracking(1.5)
                            .foregroundColor(accent.opacity(0.9))
                        Text(cafe.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(AppTheme.cream)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                    // Type badge — top-left
                    Text(cafe.type.label.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundColor(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(AppTheme.background(for: cafe.type).opacity(0.85))
                                .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .frame(height: 140)
                .clipped()

                // Tagline + vibe tags
                VStack(alignment: .leading, spacing: 6) {
                    if !cafe.tagline.isEmpty {
                        Text(cafe.tagline)
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.cream.opacity(0.5))
                            .lineLimit(2)
                    }

                    if !cafe.vibeTags.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(cafe.vibeTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(accent.opacity(0.8))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .overlay(Capsule().stroke(accent.opacity(0.3), lineWidth: 1))
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(isActive ? activeBg : AppTheme.cream.opacity(0.04))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isActive ? accent : Color.clear, lineWidth: 2)
            )
            .shadow(color: isActive ? accent.opacity(0.2) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var photoOrGradient: some View {
        if let first = cafe.photos.first, !first.isEmpty, let url = URL(string: first) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:
                    AppTheme.gradient(for: cafe.type, index: 0)
                        .overlay(Text(cafe.type.emoji).font(.system(size: 36)).opacity(0.2))
                }
            }
        } else {
            AppTheme.gradient(for: cafe.type, index: 0)
                .overlay(Text(cafe.type.emoji).font(.system(size: 36)).opacity(0.2))
        }
    }
}
