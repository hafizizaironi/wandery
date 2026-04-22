import SwiftUI

struct CafeCardView: View {
    let cafe: Cafe
    let isActive: Bool
    let onTap: () -> Void

    private var accent: Color { AppTheme.accent(for: cafe.type) }
    private var activeBg: Color { AppTheme.surfacePrimary }

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
                            .foregroundColor(.white.opacity(0.85))
                        Text(cafe.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
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
                                .fill(AppTheme.background(for: cafe.type))
                                .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 1))
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
                            .foregroundColor(AppTheme.textSecondary)
                            .lineLimit(2)
                    }

                    if !cafe.vibeTags.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(cafe.vibeTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(AppTheme.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .overlay(Capsule().stroke(AppTheme.borderSubtle, lineWidth: 1))
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(
                ZStack {
                    // Card body — slightly brighter than panel to read as its own surface
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isActive ? activeBg : AppTheme.surfacePrimary.opacity(0.55))
                    // Active: warm tint wash
                    if isActive {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(accent.opacity(0.06))
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                // Always-on accent outline — differentiates items from the panel.
                // Active state strengthens the outline into a clear focus ring.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isActive
                                ? [accent.opacity(0.65), accent.opacity(0.35)]
                                : [accent.opacity(0.32), accent.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isActive ? 2 : 1
                    )
            )
            .shadow(color: isActive
                    ? accent.opacity(0.18)
                    : AppTheme.textPrimary.opacity(0.04),
                    radius: isActive ? 10 : 4,
                    x: 0,
                    y: isActive ? 3 : 1)
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
