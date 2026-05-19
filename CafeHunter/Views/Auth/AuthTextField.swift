import SwiftUI

struct AuthTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
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
