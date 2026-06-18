import SwiftUI

/// The two looks for the My Hunt screen. Local-only preference, available to
/// everyone (no entitlement gate), persisted under `storageKey`.
enum MyHuntStyle: String, CaseIterable, Identifiable {
    case standard
    case thermalReceipt
    var id: String { rawValue }
    static let storageKey = "myHunt.style"
}

/// "Hunt receipt" rendering of My Hunt: a printed café receipt that itemises the
/// user's visited places. Header → grand totals + category subtotals → an
/// itemised, month-grouped place list (name …… visits · last-visit date) →
/// barcode, with torn top & bottom edges on receipt paper.
///
/// Driven entirely by data `MyHuntView` has already computed, so the two styles
/// share one source of truth. Self-contained — its receipt primitives are
/// private and uniquely named (`HuntReceipt*`) so they never collide with the
/// feed's `ThermalReceiptFeedFrame` primitives.
struct MyHuntReceiptView: View {
    let sinceLabel: String
    let placeCount: Int
    let cityCount: Int
    let daysActive: Int
    let counts: (cafes: Int, restaurants: Int, stalls: Int)
    let groupedByMonth: [(label: String, places: [FriendPlace])]
    let username: String?
    let myUid: String

    private let paper = Color(red: 0.99, green: 0.99, blue: 0.975)
    private let ink   = Color(red: 0.07, green: 0.07, blue: 0.07)
    private let tearDepth: CGFloat = 7

    var body: some View {
        ScrollView {
            slip
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)   // centre the slip
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 48)
        }
    }

    private var slip: some View {
        VStack(spacing: 0) {
            header
            rule
            totals
            rule
            ForEach(groupedByMonth, id: \.label) { group in
                monthSection(group.label, group.places)
            }
            rule
            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, tearDepth + 18)
        .padding(.bottom, tearDepth + 22)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                paper
                HuntReceiptGrain().blendMode(.multiply).opacity(0.5)
            }
        )
        .clipShape(HuntReceiptTornEdge(depth: tearDepth))
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            Text("WANDERY")
                .font(mono(20, .bold)).tracking(6)
                .foregroundStyle(ink)
            Text("HUNT RECEIPT")
                .font(mono(10)).tracking(3)
                .foregroundStyle(ink.opacity(0.5))
            if !sinceLabel.isEmpty {
                Text(sinceLabel.uppercased())
                    .font(mono(9)).tracking(1.5)
                    .foregroundStyle(ink.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var totals: some View {
        VStack(spacing: 0) {
            totalRow("PLACES", placeCount, big: true)
            totalRow("CITIES", cityCount, big: true)
            totalRow("DAYS ON THE HUNT", daysActive, big: true)
            thinRule
            if counts.cafes > 0       { totalRow("☕ CAFES", counts.cafes) }
            if counts.restaurants > 0 { totalRow("🍽️ RESTAURANTS", counts.restaurants) }
            if counts.stalls > 0      { totalRow("🍜 STALLS", counts.stalls) }
        }
    }

    private func totalRow(_ label: String, _ value: Int, big: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(big ? ink : ink.opacity(0.7))
            Spacer(minLength: 8)
            Text(String(value))
                .fontWeight(.bold)
                .foregroundStyle(ink)
        }
        .font(mono(big ? 13 : 11.5, big ? .semibold : .regular))
        .tracking(0.5)
        .padding(.vertical, big ? 3.5 : 2.5)
    }

    @ViewBuilder
    private func monthSection(_ label: String, _ places: [FriendPlace]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label.uppercased())
                    .font(mono(12, .bold)).tracking(1)
                    .foregroundStyle(ink)
                Spacer()
                Text("\(places.count) PLACE\(places.count == 1 ? "" : "S")")
                    .font(mono(9.5)).tracking(1)
                    .foregroundStyle(ink.opacity(0.5))
            }
            .padding(.top, 11)
            .padding(.bottom, 5)

            ForEach(places) { place in
                placeLine(place)
            }
        }
    }

    private func placeLine(_ place: FriendPlace) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                Text(place.name)
                    .font(mono(12, .bold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing(for: place))
                    .font(mono(11, .semibold))
                    .foregroundStyle(ink)
                    .fixedSize()
            }
            HStack {
                Text("\(place.type.emoji) \(place.cityName ?? "—")")
                    .font(mono(9.5))
                    .foregroundStyle(ink.opacity(0.5))
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.vertical, 5)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HuntReceiptBarcode(ink: ink).frame(height: 40)
            Text("* \(serial) *")
                .font(mono(10)).tracking(3)
                .foregroundStyle(ink)
                .lineLimit(1)
            Text("THANK YOU FOR HUNTING")
                .font(mono(9)).tracking(1.5)
                .foregroundStyle(ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - Rules

    private var rule: some View {
        HuntReceiptDashRule()
            .stroke(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.4, dash: [4, 4]))
            .frame(height: 1.4)
            .padding(.vertical, 9)
    }

    private var thinRule: some View {
        HuntReceiptDashRule()
            .stroke(ink.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .frame(height: 1)
            .padding(.vertical, 6)
    }

    // MARK: - Derived

    /// "3× · MAY 15" — visit count + last-visit short date. Mirrors `PlaceRow`'s
    /// (private) logic: prefer the server-deduped count, fall back to my posts.
    private func trailing(for place: FriendPlace) -> String {
        let server = max(place.myVisitCount, 0)
        let visits = server > 0 ? server : place.posts.filter { $0.authorId == myUid }.count
        let last = place.posts.filter { $0.authorId == myUid }.map(\.createdAt).max()
        guard let last else { return "\(visits)×" }
        let f = DateFormatter()
        f.dateFormat = "MMM dd"
        return "\(visits)× · \(f.string(from: last).uppercased())"
    }

    private var serial: String {
        let base = (username ?? "wandery").uppercased()
        return "\(base) HUNT"
    }

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Self-contained receipt primitives
// Private + `HuntReceipt`-prefixed so they never collide with the feed's
// `ThermalReceiptFeedFrame` `Receipt*` primitives.

/// A long slip torn (zig-zag) along BOTH the top and bottom edges.
private struct HuntReceiptTornEdge: Shape {
    var teeth: Int = 26
    var depth: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step = rect.width / CGFloat(max(teeth, 1))

        // Top edge — zig-zag left → right.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        var up = true
        var x = rect.minX
        while x < rect.maxX - 0.5 {
            x += step
            let y = up ? rect.minY : rect.minY + depth
            p.addLine(to: CGPoint(x: min(x, rect.maxX), y: y))
            up.toggle()
        }

        // Right side down.
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))

        // Bottom edge — zig-zag right → left.
        up = true
        x = rect.maxX
        while x > rect.minX + 0.5 {
            x -= step
            let y = up ? rect.maxY : rect.maxY - depth
            p.addLine(to: CGPoint(x: max(x, rect.minX), y: y))
            up.toggle()
        }

        // Left side up.
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        p.closeSubpath()
        return p
    }
}

/// A single horizontal line, centred; dashed via the caller's stroke style.
private struct HuntReceiptDashRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Faint thermal-paper print grain, multiplied across the slip.
private struct HuntReceiptGrain: View {
    var body: some View {
        Canvas { ctx, size in
            let dot: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.8, height: 0.8)),
                             with: .color(.black.opacity(0.16)))
                    x += dot
                }
                y += dot
            }
        }
        .opacity(0.22)
        .allowsHitTesting(false)
    }
}

/// Decorative drawn barcode (fixed bar pattern — purely cosmetic).
private struct HuntReceiptBarcode: View {
    let ink: Color
    private let heights: [CGFloat] = [6, 2, 5, 2, 7, 3, 2, 6, 4, 2, 7, 2, 5, 3, 6, 2, 4, 7, 2, 5, 3, 2, 6, 2, 5]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { i, h in
                Rectangle()
                    .fill(ink)
                    .frame(width: i % 4 == 0 ? 3 : 1.5, height: 24 + h * 1.7)
            }
        }
    }
}

#if DEBUG
#Preview("My Hunt — receipt") {
    ZStack {
        Color(red: 0.92, green: 0.90, blue: 0.85).ignoresSafeArea()
        MyHuntReceiptView(
            sinceLabel: "since May 2026 · @feez",
            placeCount: 12,
            cityCount: 4,
            daysActive: 22,
            counts: (cafes: 7, restaurants: 3, stalls: 2),
            groupedByMonth: [],
            username: "feez",
            myUid: "preview"
        )
    }
}
#endif
