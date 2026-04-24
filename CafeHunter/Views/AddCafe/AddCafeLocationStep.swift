import SwiftUI
import MapKit
import CoreLocation

/// Default map center when we have no better signal. Kuala Lumpur city centre.
private let kKLCenter = CLLocationCoordinate2D(latitude: 3.1390, longitude: 101.6869)

struct AddCafeLocationStep: View {
    @Binding var lat: Double
    @Binding var lng: Double
    /// Read-only hint from the prior step. Used to pre-center the map the first
    /// time the user arrives here so they don't start in the wrong country.
    let neighborhood: String
    var onContinue: () -> Void

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: kKLCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    )
    @State private var centerCoord = kKLCenter
    @State private var isMoving = false
    @State private var addressText: String = ""
    @State private var settleTask: Task<Void, Never>? = nil
    @State private var didInitialize = false
    @State private var appear = false
    @State private var tapCounter = 0
    @State private var settleHaptic = 0

    var body: some View {
        VStack(spacing: 14) {
            header
                .padding(.horizontal, 24)

            mapBlock
                .padding(.horizontal, 20)

            addressCard
                .padding(.horizontal, 24)

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
            initialCenterIfNeeded()
        }
        .onDisappear {
            settleTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Where is it?")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
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
                .shadow(color: Color(red: 0.96, green: 0.32, blue: 0.46).opacity(0.30),
                        radius: 16, x: 0, y: 3)

            Text("Drag the map — drop the pin on the spot.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    // MARK: - Map

    private var mapBlock: some View {
        ZStack {
            Map(position: $position)
                .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .onMapCameraChange(frequency: .continuous) { ctx in
                    centerCoord = ctx.region.center
                    if !isMoving {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                            isMoving = true
                        }
                    }
                    scheduleSettle()
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 10)

            AnimatedPin(isLifted: isMoving)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.75), trigger: settleHaptic)
    }

    /// Cancels any pending settle-check and schedules a new one 420ms out.
    /// When the timer fires without another camera change resetting it, we
    /// consider the map "settled" → reverse-geocode + haptic.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(nanoseconds: 420_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    isMoving = false
                }
                settleHaptic += 1
                reverseGeocode(centerCoord)
            }
        }
    }

    // MARK: - Address card

    private var addressCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(red: 0.99, green: 0.72, blue: 0.40))

            Text(addressText.isEmpty ? "Finding this spot…" : addressText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if isMoving {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
        )
    }

    // MARK: - Continue

    private var continueButton: some View {
        Button {
            tapCounter += 1
            // Commit the final pinned coord into the draft and move on.
            lat = centerCoord.latitude
            lng = centerCoord.longitude
            onContinue()
        } label: {
            HStack(spacing: 10) {
                Text("This is the spot")
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(Color(red: 0.12, green: 0.04, blue: 0.06))
            .padding(.horizontal, 34)
            .padding(.vertical, 15)
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
                    .shadow(color: Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.48),
                            radius: 16, x: 0, y: 5)
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .heavy), trigger: tapCounter)
    }

    // MARK: - Initial centering

    private func initialCenterIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true

        // 1. Returning to the step with a pin already dropped — honour it.
        if lat != 0 || lng != 0 {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            centerCoord = coord
            position = .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
            reverseGeocode(coord)
            return
        }

        // 2. Forward-geocode the neighborhood hint so the map lands somewhere
        //    meaningful instead of generic KL centre.
        let trimmed = neighborhood.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Task {
                guard let request = MKGeocodingRequest(addressString: trimmed) else { return }
                let items = try? await request.mapItems
                guard let coord = items?.first?.location.coordinate else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        position = .region(MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        ))
                    }
                    centerCoord = coord
                }
                reverseGeocode(coord)
            }
            return
        }

        // 3. Fallback — KL centre is already the default, just populate label.
        reverseGeocode(centerCoord)
    }

    // MARK: - Reverse geocode

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        Task {
            let request = MKReverseGeocodingRequest(location: loc)
            guard let items = try? await request?.mapItems,
                  let placemark = items.first?.placemark else { return }
            // Prefer a tight, readable label — area + city is enough for the
            // user to confirm "yes, that's the spot".
            let parts = [placemark.subLocality, placemark.locality, placemark.administrativeArea]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            let unique = Array(NSOrderedSet(array: parts)) as? [String] ?? []
            let label = unique.prefix(2).joined(separator: ", ")
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    addressText = label.isEmpty
                        ? String(format: "📍 %.5f, %.5f", coord.latitude, coord.longitude)
                        : label
                }
            }
        }
    }
}

// MARK: - Animated pin

/// Warm conic pin that echoes the "+" button's energy. The tip sits exactly
/// at the map centre; the body renders above it. Lifts slightly while the
/// map is moving, settles with a spring on release.
private struct AnimatedPin: View {
    let isLifted: Bool

    @State private var rotate: Double = 0
    @State private var bob = false

    /// Half the total body+tip height. With 34pt circle + 10pt tip = 44,
    /// the tip sits at ZStack center when offset by -22.
    private let baseOffset: CGFloat = -22

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Rotating conic body — matches the "+" button palette.
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.96, green: 0.44, blue: 0.20),
                                Color(red: 0.84, green: 0.22, blue: 0.36),
                                Color(red: 0.71, green: 0.32, blue: 0.23),
                                Color(red: 0.98, green: 0.60, blue: 0.18),
                                Color(red: 0.96, green: 0.44, blue: 0.20)
                            ]),
                            center: .center,
                            angle: .degrees(rotate)
                        )
                    )
                    .frame(width: 34, height: 34)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.85),
                                             Color.white.opacity(0.15)],
                                    startPoint: .top,
                                    endPoint:   .bottom
                                ),
                                lineWidth: 1.2
                            )
                    )
                    .shadow(color: Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.55),
                            radius: 12, x: 0, y: 4)

                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
            }

            // Pointer tip — drops from the circle to the ground.
            PinTip()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.84, green: 0.22, blue: 0.36),
                            Color(red: 0.62, green: 0.10, blue: 0.22)
                        ],
                        startPoint: .top,
                        endPoint:   .bottom
                    )
                )
                .frame(width: 12, height: 10)
                .offset(y: -1)
                .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
        }
        .offset(y: baseOffset + (isLifted ? -10 : 0) + (bob ? -1 : 1))
        .scaleEffect(isLifted ? 1.06 : 1.0)
        .background(
            // Ground shadow — shrinks & darkens as the pin lifts, so the
            // parallax reads immediately.
            Ellipse()
                .fill(Color.black.opacity(isLifted ? 0.22 : 0.40))
                .frame(
                    width: isLifted ? 14 : 22,
                    height: isLifted ? 4 : 6
                )
                .blur(radius: 3)
                .offset(y: 2)
        )
        .onAppear {
            withAnimation(.linear(duration: 5.5).repeatForever(autoreverses: false)) {
                rotate = 360
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }
}

/// Triangle that points down — the classic map-pin tip.
private struct PinTip: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
