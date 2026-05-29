import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + lock-screen presentation for the post-upload Live Activity.
/// The app drives it via `UploadLiveActivityController`; this is compiled into
/// the Widget Extension target. Uses the shared `UploadActivityAttributes`
/// (a copy lives in this target so both modules declare the same type — that's
/// how ActivityKit bridges the app and the extension).
struct UploadLiveActivity: Widget {
    // Terracotta accent, mirrored from AppTheme.accentAction (#B5523A) — kept
    // local so the widget target doesn't need the app's theme file.
    private static let accent = Color(red: 0xB5 / 255, green: 0x52 / 255, blue: 0x3A / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UploadActivityAttributes.self) { context in
            // Lock screen / banner presentation.
            HStack(spacing: 12) {
                Image(systemName: glyph(context.state))
                    .font(.title3)
                    .foregroundStyle(tint(context.state))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(context.state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    ProgressView(value: context.state.progress)
                        .tint(tint(context.state))
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: glyph(context.state))
                        .foregroundStyle(tint(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusBadge(context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                        .tint(tint(context.state))
                }
            } compactLeading: {
                Image(systemName: "camera.fill")
                    .font(.caption2)
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                ring(context.state)
            } minimal: {
                ring(context.state)
            }
            .keylineTint(Self.accent)
        }
    }

    /// Circular progress ring in the compact/minimal DI region — the "loading
    /// around the Dynamic Island" cue.
    @ViewBuilder
    private func ring(_ s: UploadActivityAttributes.ContentState) -> some View {
        if s.failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if s.done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            ProgressView(value: s.progress)
                .progressViewStyle(.circular)
                .tint(Self.accent)
        }
    }

    @ViewBuilder
    private func statusBadge(_ s: UploadActivityAttributes.ContentState) -> some View {
        if s.failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if s.done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Text("\(Int(s.progress * 100))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private func glyph(_ s: UploadActivityAttributes.ContentState) -> String {
        s.failed ? "exclamationmark.triangle.fill" : (s.done ? "checkmark.circle.fill" : "arrow.up.circle.fill")
    }

    private func tint(_ s: UploadActivityAttributes.ContentState) -> Color {
        s.failed ? .orange : (s.done ? .green : Self.accent)
    }

    private func title(_ s: UploadActivityAttributes.ContentState) -> String {
        s.failed ? "Post failed" : (s.done ? "Posted" : "Posting your moment")
    }
}
