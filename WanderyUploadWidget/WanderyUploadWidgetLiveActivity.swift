import ActivityKit
import SwiftUI
import WidgetKit

/// Terracotta accent, mirrored from AppTheme.accentAction (#B5523A) — kept local
/// so the widget target doesn't need the app's theme file.
private let uploadAccent = Color(red: 0xB5 / 255, green: 0x52 / 255, blue: 0x3A / 255)

/// Determinate progress ring with explicit sizing so it actually renders in the
/// tiny Dynamic Island compact/minimal regions (a bare `ProgressView(.circular)`
/// collapses to nothing there).
private struct DIProgressRing: View {
    let progress: Double
    var diameter: CGFloat = 18
    var lineWidth: CGFloat = 2.6

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.28), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(uploadAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Small status glyph for the compact/minimal regions (done / failed / progress).
private struct DIStatus: View {
    let state: UploadActivityAttributes.ContentState
    var diameter: CGFloat = 18

    var body: some View {
        if state.failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: diameter * 0.8)).foregroundStyle(.orange)
        } else if state.done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: diameter)).foregroundStyle(.green)
        } else {
            DIProgressRing(progress: state.progress, diameter: diameter)
        }
    }
}

/// Dynamic Island + lock-screen presentation for the post-upload Live Activity.
/// Driven by the app via `UploadLiveActivityController`.
struct UploadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UploadActivityAttributes.self) { context in
            // Lock screen / banner presentation.
            HStack(spacing: 12) {
                Image(systemName: glyph(context.state))
                    .font(.title3)
                    .foregroundStyle(tint(context.state))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(context.state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    ProgressView(value: max(0.02, min(context.state.progress, 1)))
                        .tint(uploadAccent)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: glyph(context.state))
                        .font(.title3)
                        .foregroundStyle(tint(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if context.state.done {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("\(Int(context.state.progress * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(context.state))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: max(0.02, min(context.state.progress, 1)))
                        .tint(uploadAccent)
                }
            } compactLeading: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(uploadAccent)
            } compactTrailing: {
                DIStatus(state: context.state, diameter: 18)
            } minimal: {
                DIStatus(state: context.state, diameter: 18)
            }
            .keylineTint(uploadAccent)
        }
    }

    private func glyph(_ s: UploadActivityAttributes.ContentState) -> String {
        s.failed ? "exclamationmark.triangle.fill" : (s.done ? "checkmark.circle.fill" : "arrow.up.circle.fill")
    }

    private func tint(_ s: UploadActivityAttributes.ContentState) -> Color {
        s.failed ? .orange : (s.done ? .green : uploadAccent)
    }

    private func title(_ s: UploadActivityAttributes.ContentState) -> String {
        s.failed ? "Post failed" : (s.done ? "Posted" : "Posting your moment")
    }
}
