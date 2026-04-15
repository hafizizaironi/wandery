import SwiftUI

struct CafeDetailSheetContent: View {
    let cafe: Cafe
    let isAdmin: Bool
    let onBack: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

    private var accent: Color { AppTheme.accent(for: cafe.type) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: Hero
                ZStack(alignment: .bottom) {
                    heroImage
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    // Back + type badge
                    HStack {
                        Button(action: onBack) {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Back")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(AppTheme.cream.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                        }
                        Spacer()
                        Text(cafe.type.label.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1)
                            .foregroundColor(accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(AppTheme.background(for: cafe.type).opacity(0.9))
                                    .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
                            )
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 54)

                    // Name
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(cafe.neighborhood.uppercased()) · RAWANG")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.5)
                            .foregroundColor(accent.opacity(0.85))
                        Text(cafe.name)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(AppTheme.cream)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
                .frame(height: 220)
                .clipped()

                // MARK: Body
                VStack(alignment: .leading, spacing: 20) {

                    // Tagline
                    if !cafe.tagline.isEmpty {
                        Text("\"\(cafe.tagline)\"")
                            .font(.system(size: 15, weight: .medium))
                            .italic()
                            .foregroundColor(accent.opacity(0.85))
                    }

                    // Info cards
                    HStack(spacing: 10) {
                        InfoCard(title: "Hours", value: cafe.hours.isEmpty ? "—" : cafe.hours)
                        InfoCard(title: "Location", value: "\(cafe.neighborhood), Rawang")
                    }

                    // Vibe tags
                    if !cafe.vibeTags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(cafe.vibeTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(accent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(accent.opacity(0.1))
                                    .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 1))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    // Photo gallery
                    if !cafe.photos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("Gallery")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(Array(cafe.photos.enumerated()), id: \.offset) { i, photoURL in
                                        if let url = URL(string: photoURL) {
                                            AsyncImage(url: url) { phase in
                                                switch phase {
                                                case .success(let img): img.resizable().scaledToFill()
                                                default: AppTheme.gradient(for: cafe.type, index: i)
                                                }
                                            }
                                            .frame(width: 160, height: 110)
                                            .cornerRadius(12)
                                            .clipped()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Description
                    if !cafe.description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("About")
                            Text(cafe.description)
                                .font(.system(size: 14))
                                .foregroundColor(AppTheme.cream.opacity(0.7))
                                .lineSpacing(4)
                        }
                    }

                    // Navigation buttons
                    HStack(spacing: 12) {
                        NavigateButton(title: "Waze", bgColor: Color(red: 0.212, green: 0.765, blue: 0.941), icon: "car.fill") {
                            if let url = URL(string: "waze://?ll=\(cafe.lat),\(cafe.lng)&navigate=yes") {
                                UIApplication.shared.open(url)
                            }
                        }
                        NavigateButton(title: "Google Maps", bgColor: .white, icon: "map") {
                            let gmaps = URL(string: "comgooglemaps://?daddr=\(cafe.lat),\(cafe.lng)&directionsmode=driving")!
                            let web   = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(cafe.lat),\(cafe.lng)")!
                            UIApplication.shared.open(UIApplication.shared.canOpenURL(gmaps) ? gmaps : web)
                        }
                    }

                    // Admin controls
                    if isAdmin {
                        adminControls
                    }

                    Color.clear.frame(height: 8)
                }
                .padding(16)
            }
        }
    }

    // MARK: - Admin controls

    @ViewBuilder
    private var adminControls: some View {
        VStack(spacing: 8) {
            Button(action: onEdit) {
                Label("Edit details", systemImage: "pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.cafeAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(AppTheme.cafeAccent.opacity(0.08))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.cafeAccent.opacity(0.35), lineWidth: 1))
            }

            if confirmDelete {
                VStack(spacing: 10) {
                    Text("Remove \(cafe.name) from the map?")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.errorRed)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        Button("Cancel") { confirmDelete = false }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.cream.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(AppTheme.cream.opacity(0.1))
                            .cornerRadius(10)
                        Button("Yes, remove") { confirmDelete = false; onDelete() }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(AppTheme.cream)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(red: 0.753, green: 0.224, blue: 0.169))
                            .cornerRadius(10)
                    }
                }
                .padding()
                .background(Color(red: 0.122, green: 0.047, blue: 0.047))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.errorRed.opacity(0.3), lineWidth: 1))
            } else {
                Button { confirmDelete = true } label: {
                    Label("Remove this place", systemImage: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.errorRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(AppTheme.errorRed.opacity(0.08))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.errorRed.opacity(0.3), lineWidth: 1))
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var heroImage: some View {
        if let first = cafe.photos.first, !first.isEmpty, let url = URL(string: first) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: AppTheme.gradient(for: cafe.type, index: 0)
                    .overlay(Text(cafe.type.emoji).font(.system(size: 60)).opacity(0.2))
                }
            }
        } else {
            AppTheme.gradient(for: cafe.type, index: 0)
                .overlay(Text(cafe.type.emoji).font(.system(size: 60)).opacity(0.2))
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(2)
            .foregroundColor(AppTheme.cream.opacity(0.35))
    }
}

// MARK: - Info card

struct InfoCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(AppTheme.cream.opacity(0.35))
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.cream)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cream.opacity(0.05))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.cream.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Navigate button

struct NavigateButton: View {
    let title: String
    let bgColor: Color
    let icon: String
    let action: () -> Void

    private var isDark: Bool { bgColor == .white }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(isDark ? Color(red: 0.1, green: 0.1, blue: 0.1) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(bgColor)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}
