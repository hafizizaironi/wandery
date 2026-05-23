import SwiftUI

/// Small centered label like "Today" / "Yesterday" / "Wed, Apr 12" that
/// breaks long threads into calendar days. Same pattern as iMessage.
struct DaySeparatorView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}
