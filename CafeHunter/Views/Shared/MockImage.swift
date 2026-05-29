import SwiftUI
import UIKit

/// Image that renders an asset-catalog image if one exists for `name`, and
/// otherwise falls back to a branded gradient + category-emoji placeholder.
///
/// Lets the marketing-mockup screens ship with on-brand placeholders today;
/// dropping a real image into `Assets.xcassets` under the same `name` later
/// makes it appear automatically with NO code change. Callers wrap this in
/// their own `.frame(...).clipShape(...)` (it uses `scaledToFill`), the same
/// way `CachedAsyncImage` is used elsewhere.
struct MockImage: View {
    let name: String

    var body: some View {
        if UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFill()
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        // Stable per-name gradient (same hashing idiom as the Trending grid's
        // placeholder) so a given slot keeps its look between launches.
        let t = Double(abs(name.hashValue) % 100) / 100.0
        return ZStack {
            LinearGradient(
                colors: [
                    AppTheme.cafeAccent.opacity(0.85 - t * 0.25),
                    AppTheme.stallAccent.opacity(0.45 + t * 0.20),
                    AppTheme.surfaceCanvas
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(emoji(for: name))
                .font(.system(size: 34))
                .opacity(0.9)
        }
    }

    private func emoji(for name: String) -> String {
        if name.contains("cafe")  { return "☕️" }
        if name.contains("food")  { return "🍽️" }
        if name.contains("stall") { return "🍜" }
        return "📸"
    }
}
