import SwiftUI

struct AuthTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    @FocusState private var isFocused: Bool

    private var promptText: Text {
        Text(placeholder)
            .foregroundStyle(AppTheme.textPrimary.opacity(0.4))
    }

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: promptText)
            } else {
                TextField("", text: $text, prompt: promptText)
            }
        }
        .focused($isFocused)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppTheme.surfacePrimary.opacity(0.25))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isFocused ? AppTheme.cafeAccent.opacity(0.55) : AppTheme.borderSubtle,
                    lineWidth: 1
                )
        }
        .foregroundStyle(AppTheme.textPrimary)
        .font(.subheadline)
        .tint(AppTheme.cafeAccent)
    }
}
