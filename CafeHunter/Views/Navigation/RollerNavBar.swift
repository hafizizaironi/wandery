import SwiftUI

// MARK: - True circular arc shape

struct ArcShape: Shape {
    var center:     CGPoint
    var radius:     CGFloat
    var startAngle: Angle
    var endAngle:   Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center:     center,
                    radius:     radius,
                    startAngle: startAngle,
                    endAngle:   endAngle,
                    clockwise:  false)
        return path
    }
}

private func pointOnCircle(angleDeg: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
    let rad = Angle.degrees(angleDeg).radians
    return CGPoint(x: center.x + radius * CGFloat(cos(rad)),
                   y: center.y + radius * CGFloat(sin(rad)))
}

/// Interpolates scalar `pageProgress` in `animatableData` so the knob stays on the arc.
/// Without this, SwiftUI animates `.position(CGPoint)` in a straight line between endpoints.
private struct ArcKnobIndicator: View, Animatable {
    var pageProgress: CGFloat
    var isEnlarged: Bool
    var center: CGPoint
    var arcRadius: CGFloat
    var trackStartDeg: Double
    var trackEndDeg: Double
    var tabIcons: [String]

    var animatableData: CGFloat {
        get { pageProgress }
        set { pageProgress = newValue }
    }

    private var activeIcon: String {
        let idx = min(tabIcons.count - 1, max(0, Int(pageProgress.rounded())))
        return tabIcons[idx]
    }

    private func angleDeg(for progress: Double) -> Double {
        trackStartDeg + (trackEndDeg - trackStartDeg) * (progress / 2.0)
    }

    var body: some View {
        let activePos = pointOnCircle(angleDeg: angleDeg(for: Double(pageProgress)),
                                    center: center, radius: arcRadius)

        ZStack {
            Circle()
                .fill(Color(hex: "#1a1208"))
                .frame(width: 72, height: 72)
            Circle()
                .fill(Color(hex: "#c87d2a").opacity(0.65))
                .frame(width: 60, height: 60)
                .shadow(color: Color(hex: "#c87d2a").opacity(0.30),
                        radius: 10, x: 0, y: 3)
            Image(systemName: activeIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
        }
        .frame(width: 72, height: 72)
        .scaleEffect(isEnlarged ? 1.24 : 1.0, anchor: .center)
        .frame(width: 100, height: 100)
        .contentShape(Circle())
        .position(activePos)
    }
}

// MARK: - Arc nav bar

struct ArcNavBar: View {
    /// Visible arc region height — use with `+ safeAreaInsets.bottom` for the shell frame.
    /// Sized so the stroked track + caps fit fully inside the navbar.
    static let frameContentHeight: CGFloat = 308
    /// Distance from the physical screen bottom (excl. safe area) to the home-button peak.
    /// Use this to position content that should sit just above the active tab indicator.
    static let homeButtonFromBottom: CGFloat = 86 + 16  // arcRadius + centerBottomInset

    @Binding var selectedPage: ShellPage
    @Binding var pageProgress: CGFloat

    private let tabs: [(page: ShellPage, icon: String)] = [
        (.map,     "map.fill"),
        (.hero,    "house.fill"),
        (.profile, "person.fill"),
    ]

    private let frameContentH: CGFloat = Self.frameContentHeight
    /// Distance from the arc center to the path (tabs + track share this radius).
    private let arcRadius: CGFloat = 86

    /// Half-angle from the top of the arc (-90°) to each track endpoint.
    /// Map sits at the **left** end of the track, profile at the **right** end; hero at -90°.
    private let arcHalfSpanDeg: Double = 60

    /// Left end of the arc (map tab) — same as track start.
    private var trackStartDeg: Double { -90.0 - arcHalfSpanDeg }
    /// Right end of the arc (profile tab) — same as track end.
    private var trackEndDeg: Double { -90.0 + arcHalfSpanDeg }

    /// Distance from the bottom of `frameContentHeight` to the arc center (smaller = navbar sits lower).
    private let centerBottomInset: CGFloat = 16

    /// Horizontal drag per unit of `pageProgress` — lower multiplier = easier / smoother drag.
    private var dragSensitivity: CGFloat {
        let degPerTab = (trackEndDeg - trackStartDeg) / 2.0
        return CGFloat(100) * CGFloat(degPerTab * .pi / 180)
    }

    /// Angle (degrees) for progress 0…2: left endpoint → center → right endpoint.
    private func angleDeg(for progress: Double) -> Double {
        trackStartDeg + (trackEndDeg - trackStartDeg) * (progress / 2.0)
    }

    @State private var dragStartProgress: CGFloat = 1
    @State private var isDragging  = false
    @State private var isEnlarged  = false
    @State private var lastTickIdx: Int = 1

    /// Bump these to fire `.sensoryFeedback` (reliable from gestures; works with mic + `allowHapticsAndSystemSoundsDuringRecording`).
    @State private var sensoryTouchDown = 0
    @State private var sensorySelection = 0
    @State private var sensoryRelease = 0

    // MARK: - Helpers

    /// Springy tab transition: fast, with slight overshoot (“terlajak”) then settle on the arc.
    private func animateTabTap(to targetIndex: Int) {
        guard targetIndex >= 0, targetIndex < tabs.count else { return }

        let end = CGFloat(targetIndex)
        guard abs(end - pageProgress) > 0.001 else { return }

        sensorySelection += 1

        let deltaTabs = abs(Double(end - pageProgress))
        let response = max(0.22, 0.24 - 0.03 * min(deltaTabs, 2))

        withAnimation(.spring(response: response, dampingFraction: 0.62)) {
            pageProgress = end
            selectedPage = tabs[targetIndex].page
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let w        = geo.size.width
            // Center above the bottom edge so the stroked arc + caps are fully contained.
            let center   = CGPoint(x: w / 2, y: frameContentH - centerBottomInset)
            // Track uses the same angles as tabs: map @ left end, profile @ right end, hero @ -90°.
            let startAng = Angle.degrees(trackStartDeg)
            let endAng   = Angle.degrees(trackEndDeg)

            ZStack {
                // ── Glass arc track ────────────────────────────────────────
                let trackWidth: CGFloat = 58
                ArcShape(center: center, radius: arcRadius,
                         startAngle: startAng, endAngle: endAng)
                    .stroke(Color.black.opacity(0.55),
                            style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))

                ArcShape(center: center, radius: arcRadius,
                         startAngle: startAng, endAngle: endAng)
                    .stroke(
                        LinearGradient(colors: [Color.white.opacity(0.22),
                                                Color.white.opacity(0.07)],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)
                    )

                // ── Ghost tab circles ──────────────────────────────────────
                ForEach(0 ..< tabs.count, id: \.self) { idx in
                    let tab     = tabs[idx]
                    let pos     = pointOnCircle(angleDeg: angleDeg(for: Double(idx)),
                                               center: center, radius: arcRadius)
                    let dist    = abs(CGFloat(idx) - pageProgress)
                    let opacity = max(0.12, 0.38 - dist * 0.22)

                    Button {
                        animateTabTap(to: idx)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 46, height: 46)
                            Image(systemName: tab.icon)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(.white.opacity(opacity))
                        }
                    }
                    .buttonStyle(.plain)
                    .position(pos)
                }

                // ── Moving active indicator (`Animatable` → motion follows the arc, not a chord)
                ArcKnobIndicator(
                    pageProgress: pageProgress,
                    isEnlarged: isEnlarged,
                    center: center,
                    arcRadius: arcRadius,
                    trackStartDeg: trackStartDeg,
                    trackEndDeg: trackEndDeg,
                    tabIcons: tabs.map(\.icon)
                )
                .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isEnlarged)
                .gesture(indicatorDragGesture)
            }
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1.2), trigger: sensoryTouchDown)
            .sensoryFeedback(.impact(weight: .heavy, intensity: 0.95), trigger: sensorySelection)
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.85), trigger: sensoryRelease)
        }
    }

    // MARK: - Indicator drag gesture

    // minimumDistance: 0 → onChanged fires on the very first touch event,
    // before any finger movement. This is what enables the instant spring
    // bounce and haptic feedback the moment the user touches the dial.
    private var indicatorDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    isDragging        = true
                    dragStartProgress = pageProgress
                    lastTickIdx       = Int(pageProgress.rounded())

                    sensoryTouchDown += 1

                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        isEnlarged = true
                    }
                }

                // Only update position once the finger has moved a bit,
                // so a simple tap on the indicator doesn't jitter.
                guard abs(value.translation.width) > 3 else { return }

                let delta = value.translation.width / dragSensitivity
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    pageProgress = max(0, min(CGFloat(tabs.count - 1),
                                              dragStartProgress + delta))
                }

                // Haptic tick each time indicator crosses a tab.
                let nearestIdx = Int(pageProgress.rounded())
                if nearestIdx != lastTickIdx {
                    lastTickIdx = nearestIdx
                    sensorySelection += 1
                }
            }
            .onEnded { value in
                let snapped = max(0, min(tabs.count - 1,
                                         Int(pageProgress.rounded())))
                isDragging = false

                if abs(value.translation.width) > 3 {
                    sensoryRelease += 1
                }

                withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
                    isEnlarged   = false
                    selectedPage = tabs[snapped].page
                    pageProgress = CGFloat(snapped)
                }
            }
    }
}
