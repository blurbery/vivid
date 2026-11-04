#if os(iOS) || os(tvOS)
import Foundation

/// Pings the main queue from a utility queue and measures how long the main
/// thread takes to answer. One timer wake-up every half second while the app
/// is active; stopped in the background.
final class MainThreadWatchdog {
    static let interval: DispatchTimeInterval = .milliseconds(500)
    /// Stalls at least this long are recorded as hangs.
    static let hangThresholdMs = 1_000
    /// Stalls this long are written to the exit marker while still running,
    /// in case the system kills the app before the main thread recovers.
    static let ongoingThresholdMs = 2_000
    /// A gap between ticks this long means the whole process was suspended,
    /// not that the main thread was busy.
    static let suspensionGapMs = 2_000

    private let queue = DispatchQueue(label: "com.blurbery.vivid.health.watchdog", qos: .utility)
    private let onStall: (Int) -> Void
    /// Called when a stall ends: with its duration when it reached the hang
    /// threshold, otherwise `nil` (only after a stall was reported).
    private let onRecovered: (Int?) -> Void

    // Confined to `queue`.
    private var timer: DispatchSourceTimer?
    /// Bumped whenever a pending ping is abandoned, so its late answer is
    /// ignored.
    private var generation: UInt64 = 0
    /// When the unanswered ping was sent.
    private var pendingSince: UInt64?
    private var lastTick: UInt64 = 0
    private var reportedStall = false

    init(onStall: @escaping (Int) -> Void, onRecovered: @escaping (Int?) -> Void) {
        self.onStall = onStall
        self.onRecovered = onRecovered
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            resetPending()
            lastTick = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            resetPending()
        }
    }

    private func resetPending() {
        generation &+= 1
        pendingSince = nil
        reportedStall = false
    }

    /// A suspended process isn't a stalled main thread: any reported stall
    /// ends without a duration and the pending ping is dropped.
    private func abandonAfterSuspension() {
        if reportedStall { onRecovered(nil) }
        resetPending()
    }

    private func wasSuspended(since tick: UInt64, until now: UInt64) -> Bool {
        tick != 0 && Self.milliseconds(from: tick, to: now) >= Self.suspensionGapMs
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastTick = now }
        if wasSuspended(since: lastTick, until: now) {
            abandonAfterSuspension()
            return
        }
        if let since = pendingSince {
            // Still waiting: a long stall is reported once while it lasts.
            let stalledMs = Self.milliseconds(from: since, to: now)
            if !reportedStall, stalledMs >= Self.ongoingThresholdMs {
                reportedStall = true
                onStall(stalledMs)
            }
            return
        }
        pendingSince = now
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            let answeredAt = DispatchTime.now().uptimeNanoseconds
            self?.queue.async { self?.acknowledge(generation: expectedGeneration, answeredAt: answeredAt) }
        }
    }

    private func acknowledge(generation expected: UInt64, answeredAt: UInt64) {
        guard expected == generation, let since = pendingSince else { return }
        // Ticks keep arriving while only the main thread is stuck. A long gap
        // since the last tick means the whole process was suspended, and the
        // answer may have beaten the first tick after resuming.
        if wasSuspended(since: lastTick, until: answeredAt) {
            abandonAfterSuspension()
            return
        }
        let durationMs = Self.milliseconds(from: since, to: answeredAt)
        let wasReported = reportedStall
        pendingSince = nil
        reportedStall = false
        if durationMs >= Self.hangThresholdMs {
            onRecovered(durationMs)
        } else if wasReported {
            onRecovered(nil)
        }
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        guard end > start else { return 0 }
        return Int((end - start) / 1_000_000)
    }
}
#endif
