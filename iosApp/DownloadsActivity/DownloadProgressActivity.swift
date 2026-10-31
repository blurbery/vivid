#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DownloadProgressBundle: WidgetBundle {
    var body: some Widget {
        DownloadProgressActivity()
    }
}

/// Draws the downloads Live Activity the app starts and updates. Tapping it
/// opens the Downloads tab.
struct DownloadProgressActivity: Widget {
    private static let downloadsLink = URL(string: "vivid://downloads")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenCard(content: ActivityContent(state: context.state, isStale: context.isStale))
                .widgetURL(Self.downloadsLink)
        } dynamicIsland: { context in
            let content = ActivityContent(state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    content.phaseSymbol
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    content.trailingFigure
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(verbatim: content.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let secondary = content.secondaryLine {
                            Text(verbatim: secondary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        content.progress
                            .progressViewStyle(.linear)
                        content.statusLine
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                content.phaseSymbol
                    .foregroundStyle(.tint)
            } compactTrailing: {
                content.progress
                    .progressViewStyle(.circular)
                    .tint(.blue)
            } minimal: {
                content.progress
                    .progressViewStyle(.circular)
                    .tint(.blue)
            }
            .widgetURL(Self.downloadsLink)
        }
    }
}

/// The lock screen card. A finished activity shows only its symbol, title
/// and context line.
private struct LockScreenCard: View {
    let content: ActivityContent

    var body: some View {
        let completed = content.state.phase == .completed
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                content.phaseSymbol
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: content.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let secondary = content.secondaryLine {
                        Text(verbatim: secondary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !completed {
                    content.trailingFigure
                        .font(.title3.weight(.semibold))
                }
            }
            if !completed {
                content.progress
                    .progressViewStyle(.linear)
                content.statusLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

/// The pieces every presentation draws from one content state.
private struct ActivityContent {
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool

    /// The estimate to animate along, unless the system has marked the
    /// activity stale.
    private var liveEstimate: ClosedRange<Date>? {
        isStale ? nil : state.estimate
    }

    var phaseSymbol: Image {
        switch state.phase {
        case .downloading: Image(systemName: "arrow.down.circle.fill")
        case .paused: Image(systemName: "pause.circle.fill")
        case .preparing: Image(systemName: "clock.arrow.circlepath")
        case .completed: Image(systemName: "checkmark.circle.fill")
        }
    }

    /// The subtitle and, while several are going, which one this is.
    var secondaryLine: String? {
        var parts: [String] = []
        if let subtitle = state.subtitle { parts.append(subtitle) }
        if state.totalCount > 1, state.phase != .completed {
            let position = min(state.completedCount + 1, state.totalCount)
            parts.append(String(
                localized: "\(position) of \(state.totalCount)",
                comment: "Position of the current download in the queue, e.g. 2 of 5"
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A timer bar that moves on its own while the app is suspended, or the
    /// last reported fraction.
    @ViewBuilder
    var progress: some View {
        if let estimate = liveEstimate {
            ProgressView(timerInterval: estimate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
        } else {
            ProgressView(value: state.fraction)
        }
    }

    /// A countdown to the estimated end, or the percentage done.
    @ViewBuilder
    var trailingFigure: some View {
        if let estimate = liveEstimate {
            Text(timerInterval: Date.now...estimate.upperBound, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 72, alignment: .trailing)
        } else {
            Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
    }

    var statusLine: some View {
        statusText.monospacedDigit()
    }

    private var statusText: Text {
        if let estimate = liveEstimate {
            let countdown = Text(timerInterval: Date.now...estimate.upperBound, countsDown: true)
            return Text("About \(countdown) left", comment: "Downloads time left; the middle is a live countdown")
        }
        switch state.phase {
        case .completed:
            return Text("Complete", comment: "Downloads Live Activity status")
        case .paused:
            return Text("Paused", comment: "Downloads Live Activity status")
        case .preparing:
            return Text("Preparing…", comment: "Downloads Live Activity status")
        case .downloading:
            if isStale {
                return Text("Continuing in background…", comment: "Downloads Live Activity status")
            }
            guard state.bytesExpected > 0 else {
                return Text("Downloading…", comment: "Downloads Live Activity status")
            }
            let done = Self.bytes(state.bytesDownloaded)
            let total = Self.bytes(state.bytesExpected)
            if let rate = state.bytesPerSecond, rate > 0 {
                let speed = Self.bytes(Int64(rate))
                return Text(
                    "\(done) of \(total) · \(speed)/s",
                    comment: "Downloaded size of total size, then the download speed per second"
                )
            }
            return Text("\(done) of \(total)", comment: "Downloaded size of total size")
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
#endif
