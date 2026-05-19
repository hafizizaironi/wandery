import SwiftUI

private enum IdentityField: Hashable {
    case name, neighborhood
}

struct AddCafeIdentityStep: View {
    @Binding var name: String
    @Binding var neighborhood: String
    @Binding var placeType: PlaceType
    var onContinue: () -> Void

    @FocusState private var focused: IdentityField?
    @State private var appear = false
    @State private var tapCounter = 0
    @State private var shake = false

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !neighborhood.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 26) {
            header
                .padding(.horizontal, 24)

            typeToggle
                .padding(.horizontal, 24)

            VStack(spacing: 14) {
                WarmTextField(
                    label: "Name",
                    placeholder: "e.g. Moony Coffee",
                    text: $name,
                    focused: $focused,
                    field: .name,
                    nextField: .neighborhood,
                    submitLabel: .next,
                    autocapitalization: .words,
                    autocorrect: false
                )
                WarmTextField(
                    label: "Neighborhood",
                    placeholder: "e.g. Bangsar, TTDI",
                    text: $neighborhood,
                    focused: $focused,
                    field: .neighborhood,
                    nextField: nil,
                    submitLabel: .done,
                    autocapitalization: .words,
                    autocorrect: true
                )
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            continueButton
                .offset(x: shake ? -8 : 0)
                .animation(.spring(response: 0.18, dampingFraction: 0.3), value: shake)
        }
        .padding(.bottom, 28)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 18)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.88).delay(0.08)) {
                appear = true
            }
        }
        // Tap anywhere outside the fields to dismiss the keyboard.
        .contentShape(Rectangle())
        .onTapGesture { focused = nil }
        .keyboardDismissToolbar()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("What should we")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(.white.opacity(0.72))

            Text("call this place?")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
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
        }
    }

    // MARK: - Type toggle

    private var typeToggle: some View {
        HStack(spacing: 10) {
            typeButton(for: .cafe)
            typeButton(for: .stall)
        }
    }

    private func typeButton(for type: PlaceType) -> some View {
        let isSelected = placeType == type
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                placeType = type
            }
            tapCounter += 1
        } label: {
            HStack(spacing: 8) {
                Text(type.emoji).font(.system(size: 18))
                Text(type.label)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isSelected
                             ? Color(red: 0.12, green: 0.04, blue: 0.06)
                             : Color.white.opacity(0.88))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    isSelected
                    ? AnyShapeStyle(LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.84, blue: 0.50),
                            Color(red: 0.99, green: 0.58, blue: 0.32),
                            Color(red: 0.92, green: 0.34, blue: 0.42)
                        ],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    ))
                    : AnyShapeStyle(Color.white.opacity(0.06))
                )
            )
            .overlay(
                Capsule().stroke(
                    Color.white.opacity(isSelected ? 0.55 : 0.14),
                    lineWidth: isSelected ? 1 : 0.8
                )
            )
            .shadow(color: isSelected
                    ? Color(red: 0.98, green: 0.60, blue: 0.20).opacity(0.42)
                    : .clear,
                    radius: 14, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: tapCounter)
    }

    // MARK: - Continue

    private var continueButton: some View {
        Button {
            if canContinue {
                tapCounter += 1
                focused = nil
                onContinue()
            } else {
                withAnimation(.default) { shake.toggle() }
                tapCounter += 1
            }
        } label: {
            HStack(spacing: 10) {
                Text("Continue")
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(canContinue
                             ? Color(red: 0.12, green: 0.04, blue: 0.06)
                             : Color.white.opacity(0.45))
            .padding(.horizontal, 34)
            .padding(.vertical, 15)
            .background(
                Capsule().fill(
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
            trigger: tapCounter
        )
    }
}

// MARK: - Warm text field

private struct WarmTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<IdentityField?>.Binding
    let field: IdentityField
    let nextField: IdentityField?
    let submitLabel: SubmitLabel
    let autocapitalization: TextInputAutocapitalization
    let autocorrect: Bool

    private var isFocused: Bool { focused.wrappedValue == field }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(isFocused ? 0.85 : 0.5))
                .tracking(1.1)
                .animation(.easeInOut(duration: 0.2), value: isFocused)

            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundColor(.white.opacity(0.30))
            )
            .focused(focused, equals: field)
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .foregroundColor(.white)
            .tint(Color(red: 0.99, green: 0.72, blue: 0.40))
            .submitLabel(submitLabel)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(!autocorrect)
            .onSubmit {
                focused.wrappedValue = nextField
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isFocused
                        ? Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.75)
                        : Color.white.opacity(0.14),
                        lineWidth: isFocused ? 1.3 : 0.8
                    )
            )
            .shadow(color: isFocused
                    ? Color(red: 0.99, green: 0.72, blue: 0.40).opacity(0.24)
                    : .clear,
                    radius: 12, x: 0, y: 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
        }
    }
}
