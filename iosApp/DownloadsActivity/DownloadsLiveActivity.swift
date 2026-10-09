import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VividDownloadsActivityBundle: WidgetBundle {
    var body: some Widget {
        DownloadsLiveActivity()
    }
}

/// Renders the downloads Live Activity started by the host app's
/// `DownloadLiveActivityController`: a lock-screen card and the Dynamic
/// Island treatments. Tapping anywhere deep-links to the Downloads tab via
/// the `vivid://downloads` route the app already handles.
struct DownloadsLiveActivity: Widget {
    private static let deepLink = URL(string: "vivid://downloads")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadsLockScreenView(state: context.state, isStale: context.isStale)
                .padding(16)
                .widgetURL(Self.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.symbolName)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    QueueTrailingText(state: context.state, isStale: context.isStale)
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let line = context.state.contextLine {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        QueueProgress(state: context.state, isStale: context.isStale, style: .linear)
                        QueueStatusText(state: context.state, isStale: context.isStale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbolName)
                    .foregroundStyle(.tint)
            } compactTrailing: {
                QueueProgress(state: context.state, isStale: context.isStale, style: .circular)
                    .tint(.blue)
            } minimal: {
                QueueProgress(state: context.state, isStale: context.isStale, style: .circular)
                    .tint(.blue)
            }
            .widgetURL(Self.deepLink)
        }
    }
}

private struct DownloadsLockScreenView: View {
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: state.phase.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let line = state.contextLine {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if state.phase != .completed {
                    QueueTrailingText(state: state, isStale: isStale)
                        .font(.title3.weight(.semibold))
                }
            }
            if state.phase != .completed {
                QueueProgress(state: state, isStale: isStale, style: .linear)
                QueueStatusText(state: state, isStale: isStale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The queue's progress. While there's an estimate the system animates it
/// along the timeline by itself, so it keeps moving while Vivid is suspended;
/// otherwise it shows the last reported fraction.
private struct QueueProgress: View {
    enum Style { case linear, circular }
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool
    let style: Style

    var body: some View {
        if let estimate = state.estimate, !isStale {
            styled(ProgressView(timerInterval: estimate, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() })
        } else {
            styled(ProgressView(value: state.fraction))
        }
    }

    @ViewBuilder
    private func styled<V: View>(_ view: V) -> some View {
        switch style {
        case .linear: view.progressViewStyle(.linear)
        case .circular: view.progressViewStyle(.circular)
        }
    }
}

/// Top-right figure: a live time-left countdown while there's an estimate,
/// otherwise the percentage.
private struct QueueTrailingText: View {
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if let end = state.estimate?.upperBound, !isStale, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 72, alignment: .trailing)
        } else {
            Text(state.percentText)
                .monospacedDigit()
        }
    }
}

/// The line under the bar. While there's an estimate it counts down on its
/// own, since byte counts can't change while Vivid is suspended.
private struct QueueStatusText: View {
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if let end = state.estimate?.upperBound, !isStale, end > Date() {
            (Text("About ") + Text(timerInterval: Date()...end, countsDown: true) + Text(" left"))
                .monospacedDigit()
        } else {
            Text(state.statusText(isStale: isStale))
                .monospacedDigit()
        }
    }
}

private extension DownloadActivityAttributes.ContentState.Phase {
    var symbolName: String {
        switch self {
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .preparing: return "clock.arrow.circlepath"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

private extension DownloadActivityAttributes.ContentState {
    var percentText: String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Secondary line under the title: item context plus queue position,
    /// e.g. "Severance · S1 · E4 · 2 of 5".
    var contextLine: String? {
        var parts: [String] = []
        if let subtitle { parts.append(subtitle) }
        if totalCount > 1, phase != .completed {
            parts.append("\(min(completedCount + 1, totalCount)) of \(totalCount)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func statusText(isStale: Bool) -> String {
        switch phase {
        case .completed:
            return "Complete"
        case .paused:
            return "Paused"
        case .preparing:
            return "Preparing…"
        case .downloading:
            // Past the stale date the app was suspended mid-transfer and
            // these numbers stopped ticking; say so instead of freezing a
            // live-looking counter.
            if isStale { return "Continuing in background…" }
            guard bytesExpected > 0 else { return "Downloading…" }
            var text = bytesDownloaded.formatted(.byteCount(style: .file))
                + " of "
                + bytesExpected.formatted(.byteCount(style: .file))
            if let bytesPerSecond, bytesPerSecond > 0 {
                text += " · " + Int64(bytesPerSecond).formatted(.byteCount(style: .file)) + "/s"
            }
            return text
        }
    }
}
