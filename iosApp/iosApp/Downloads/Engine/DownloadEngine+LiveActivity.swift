#if os(iOS)
import ActivityKit
import Foundation

/// One Live Activity for the whole download queue, on the lock screen and
/// in the Dynamic Island. Driven only by changes to the scope state.
@MainActor
final class DownloadLiveActivityController {
    private typealias State = DownloadActivityAttributes.ContentState

    private var activity: Activity<DownloadActivityAttributes>?
    private var adopted = false
    /// Records seen active since the queue was last empty, and those of them
    /// that have finished.
    private var seen: Set<String> = []
    private var finished: Set<String> = []
    private var lastState: State?
    /// ActivityKit calls run one after another, in order.
    private var chain: Task<Void, Never>?

    /// `active` is newest registration first.
    func sync(active: [DownloadRecord], completedIds: Set<String>, totalRate: Double) {
        adoptLeftoverActivities()
        finished.formUnion(seen.intersection(completedIds))
        seen.formUnion(active.map(\.id))
        guard !active.isEmpty else {
            finish()
            return
        }
        let state = Self.state(active: active, finishedCount: finished.count, totalRate: totalRate)
        guard state != lastState else { return }
        if let activity {
            lastState = state
            enqueue {
                await activity.update(ActivityContent(state: state, staleDate: Self.staleDate(for: state)))
            }
            return
        }
        // A long-paused queue shouldn't fill the lock screen at every launch.
        guard state.phase != .paused, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: DownloadActivityAttributes(),
                content: ActivityContent(state: state, staleDate: Self.staleDate(for: state))
            )
            lastState = state
        } catch {
            // Starting can fail, for example in the background; a later sync tries again.
        }
    }

    /// The first sync takes over an activity an earlier run left showing and
    /// ends any extras. It has no remembered state, so the next sync updates it.
    private func adoptLeftoverActivities() {
        guard !adopted else { return }
        adopted = true
        let leftovers = Activity<DownloadActivityAttributes>.activities
        activity = leftovers.first
        for extra in leftovers.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func finish() {
        let finishedCount = finished.count
        finished = []
        seen = []
        lastState = nil
        guard let activity else { return }
        self.activity = nil
        if finishedCount > 0 {
            let final = State(
                phase: .completed,
                title: String(localized: "\(finishedCount) downloads complete",
                              comment: "Live Activity when downloads finish. One: Download complete (no number)"),
                fraction: 1, bytesDownloaded: 0, bytesExpected: 0,
                completedCount: finishedCount, totalCount: finishedCount
            )
            enqueue {
                await activity.end(ActivityContent(state: final, staleDate: nil),
                                   dismissalPolicy: .after(Date().addingTimeInterval(240)))
            }
        } else {
            // Cancelled, failed or signed out.
            enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    // MARK: Content

    private static func state(active: [DownloadRecord], finishedCount: Int, totalRate: Double) -> State {
        let oldestFirst = Array(active.reversed())
        let moving: (DownloadRecord) -> Bool = { $0.localStatus == .downloading || $0.localStatus == .fetchingAssets }
        let headline = oldestFirst.first(where: moving) ?? oldestFirst[0]
        let total = finishedCount + active.count
        let progress = Double(finishedCount) + active.reduce(0) { $0 + $1.progressFraction }
        let fraction = total > 0 ? min(progress / Double(total), 1) : 0
        let sized = active.filter { $0.fileSize > 0 }
        let downloaded = sized.reduce(Int64(0)) { $0 + min($1.bytesDownloaded, $1.fileSize) }
        let expected = sized.reduce(Int64(0)) { $0 + $1.fileSize }
        let phase: State.Phase
        if active.contains(where: moving) {
            phase = .downloading
        } else if active.allSatisfy({ $0.localStatus == .paused }) {
            phase = .paused
        } else {
            phase = .preparing
        }
        let title = headline.title ?? headline.seriesTitle ?? String(
            localized: "\(active.count) downloads",
            comment: "Live Activity headline when no title is known. One: Download (the noun, no number)"
        )
        let parts = [headline.seriesTitle.flatMap { $0 != title ? $0 : nil }, headline.subtitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var range: ClosedRange<Date>?
        if phase == .downloading, !active.contains(where: { $0.localStatus == .paused }) {
            range = DownloadLiveActivityController.timeline(
                fraction: fraction, remainingBytes: expected - downloaded, bytesPerSecond: totalRate
            )
        }
        return State(
            phase: phase,
            title: title,
            subtitle: parts.isEmpty ? nil : parts.joined(separator: DownloadEngine.dot),
            fraction: fraction,
            bytesDownloaded: downloaded,
            bytesExpected: expected,
            completedCount: finishedCount,
            totalCount: total,
            bytesPerSecond: phase == .downloading && totalRate > 0 ? totalRate : nil,
            estimateStart: range?.lowerBound,
            estimatedEnd: range?.upperBound
        )
    }

    /// Past this the widget shows the content is stale.
    private static func staleDate(for state: State) -> Date {
        let soon = Date().addingTimeInterval(90)
        guard let estimate = state.estimate else { return soon }
        return max(soon, estimate.upperBound.addingTimeInterval(60))
    }

    /// From where the bar would have started at this rate to the estimated
    /// finish, so it reads the current fraction now and keeps moving while
    /// Vivid is suspended. Ends are on 5-second marks.
    nonisolated static func timeline(fraction: Double, remainingBytes: Int64, bytesPerSecond: Double,
                                     now: Date = Date()) -> ClosedRange<Date>? {
        guard bytesPerSecond > 0, remainingBytes > 0 else { return nil }
        let secondsLeft = Double(remainingBytes) / bytesPerSecond
        guard secondsLeft.isFinite, secondsLeft >= 1, secondsLeft < 48 * 3600 else { return nil }
        let done = fraction.isFinite ? min(max(fraction, 0), 0.99) : 0
        let end = now.addingTimeInterval(secondsLeft)
        let start = now.addingTimeInterval(-secondsLeft * done / (1 - done))
        func onMark(_ date: Date) -> Date {
            Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 5).rounded() * 5)
        }
        let from = onMark(start)
        let to = onMark(end)
        guard from < to else { return nil }
        return from...to
    }
}
#endif
