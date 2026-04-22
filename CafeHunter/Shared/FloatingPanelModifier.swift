import SwiftUI

// MARK: - Design tokens

enum FloatingPanelStyle {
    /// Matches the device's physical corner radius on modern iPhones.
    static let cornerRadius:       CGFloat = 36
    static let horizontalInset:    CGFloat = 12
    static let bottomInset:        CGFloat = 12
    static let handleWidth:        CGFloat = 36
    static let handleHeight:       CGFloat = 4
    static let dismissThreshold:   CGFloat = 100
    static let maxHeightFraction:  CGFloat = 0.90   // panel never reaches screen top
}

// MARK: - Overlay container

struct FloatingPanelOverlay<PanelContent: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder let panelContent: () -> PanelContent

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {

                // ── Dim background ──
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { dismissPanel() }
                    .transition(.opacity)

                // ── Floating card ──
                VStack(spacing: 0) {
                    // Drag handle
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: FloatingPanelStyle.handleWidth,
                               height: FloatingPanelStyle.handleHeight)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    panelContent()
                }
                .frame(maxWidth: .infinity)
                .frame(
                    maxHeight: geo.size.height * FloatingPanelStyle.maxHeightFraction
                )
                .background(AppTheme.espresso)
                .clipShape(RoundedRectangle(
                    cornerRadius: FloatingPanelStyle.cornerRadius,
                    style: .continuous
                ))
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: -6)
                .padding(.horizontal, FloatingPanelStyle.horizontalInset)
                .padding(.bottom,
                         FloatingPanelStyle.bottomInset + geo.safeAreaInsets.bottom)
                .offset(y: max(0, dragOffset))
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            let hard     = value.translation.height >
                                           FloatingPanelStyle.dismissThreshold
                            let momentum = value.predictedEndTranslation.height > 250
                            if hard || momentum {
                                dismissPanel()
                            } else {
                                withAnimation(.spring(response: 0.32,
                                                      dampingFraction: 0.88)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
    }

    private func dismissPanel() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            isPresented = false
            dragOffset  = 0
        }
    }
}

// MARK: - ViewModifier

private struct FloatingPanelModifier<PanelContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let panelContent: () -> PanelContent

    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                FloatingPanelOverlay(isPresented: $isPresented,
                                     panelContent: panelContent)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88),
                   value: isPresented)
    }
}

// MARK: - View extensions

extension View {

    /// Present a floating panel driven by a Bool binding.
    func floatingPanel<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.modifier(
            FloatingPanelModifier(isPresented: isPresented,
                                  panelContent: content)
        )
    }

    /// Present a floating panel driven by an optional Identifiable item.
    func floatingPanel<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let binding = Binding<Bool>(
            get:  { item.wrappedValue != nil },
            set:  { if !$0 { item.wrappedValue = nil } }
        )
        return self.modifier(
            FloatingPanelModifier(isPresented: binding) {
                if let i = item.wrappedValue { content(i) }
            }
        )
    }
}
