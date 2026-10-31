import Foundation
import os

/// Local launch and lifecycle breadcrumbs, timed on the monotonic uptime
/// clock. Each record reports the time since the one before it, so a slow
/// step stands out; safe to call from any thread.
enum LaunchTimeline {
    private struct Marks {
        var previous: DispatchTime?
        var backgroundedAt: DispatchTime?
        var rootViewRecorded = false
        var firstContentRecorded = false
    }

    private static let marks = OSAllocatedUnfairLock(initialState: Marks())

    static func milliseconds(since mark: DispatchTime) -> Int {
        milliseconds(from: mark, to: .now())
    }

    static func milliseconds(from start: DispatchTime, to end: DispatchTime) -> Int {
        let startNanoseconds = start.uptimeNanoseconds
        let endNanoseconds = end.uptimeNanoseconds
        guard endNanoseconds > startNanoseconds else { return 0 }
        return Int((endNanoseconds - startNanoseconds) / 1_000_000)
    }

    // MARK: Records

    static func recordProcessStart() {
        marks.withLock { $0.previous = .now() }
        DiagTrace.breadcrumb(
            .essential, category: .lifecycle, tag: "App", message: "app launched",
            attrs: ["phase": .string("process_start"), "state": .string("launch"), "launch_type": .string("cold")]
        )
    }

    static func recordRootViewAppeared() {
        let isFirst = marks.withLock { marks -> Bool in
            guard !marks.rootViewRecorded else { return false }
            marks.rootViewRecorded = true
            return true
        }
        guard isFirst else { return }
        record(phase: "root_view", message: "root view appeared")
    }

    static func recordInitialStateCheckStarted() {
        record(.verbose, phase: "initial_state", message: "initial state check started")
    }

    static func recordInitialStateResolved(_ state: AppRouter.AuthState) {
        record(phase: "initial_state", message: "initial state resolved", state: state.diagnosticsState)
    }

    static func recordSplashFinished() {
        record(phase: "splash", message: "startup splash finished")
    }

    static func recordFirstContent(_ state: AppRouter.AuthState) {
        let isFirst = marks.withLock { marks -> Bool in
            guard !marks.firstContentRecorded else { return false }
            marks.firstContentRecorded = true
            return true
        }
        guard isFirst else { return }
        AppHealthMonitor.firstContentShown()
        record(
            phase: "first_content", message: "initial route committed",
            state: state.diagnosticsState, outcome: "success"
        )
    }

    static func recordScenePhase(_ token: String) {
        switch token {
        case "active":
            AppHealthMonitor.sceneDidBecomeActive()
            let now = DispatchTime.now()
            let (backgroundedAt, elapsed) = marks.withLock { marks -> (DispatchTime?, Int) in
                let backgroundedAt = marks.backgroundedAt
                marks.backgroundedAt = nil
                let elapsed = milliseconds(from: marks.previous ?? now, to: now)
                marks.previous = now
                return (backgroundedAt, elapsed)
            }
            if let backgroundedAt {
                let away = milliseconds(from: backgroundedAt, to: now)
                DiagTrace.breadcrumb(
                    .essential, category: .lifecycle, tag: "Scene", message: "app foregrounded",
                    attrs: [
                        "phase": .string("foreground"), "state": .string("active"),
                        "launch_type": .string("warm"), "duration_ms": .int(away),
                    ]
                )
            } else {
                DiagTrace.breadcrumb(
                    .essential, category: .lifecycle, tag: "Scene", message: "scene became active",
                    attrs: ["phase": .string("scene"), "state": .string("active"), "duration_ms": .int(elapsed)]
                )
            }
        case "background":
            AppHealthMonitor.sessionEndedCleanly()
            marks.withLock { $0.backgroundedAt = .now() }
            record(tag: "Scene", phase: "background", message: "app backgrounded", state: "background")
        default:
            record(.verbose, tag: "Scene", phase: "scene", message: "scene phase changed", state: token)
        }
    }

    static func recordMemoryWarning(_ state: String) {
        AppHealthMonitor.memoryWarningReceived()
        record(level: .warning, tag: "App", phase: "memory_warning", message: "memory warning", state: state)
    }

    static func recordTermination(_ state: String) {
        AppHealthMonitor.sessionEndedCleanly()
        record(tag: "App", phase: "terminate", message: "app terminating", state: state)
    }

    /// A content refresh's result. Outside the chain: it neither reads nor
    /// moves it.
    static func recordRefreshOutcome(phase: String, startedAt mark: DispatchTime, failureReason: String?) {
        var attrs: [String: DiagLogAttributeValue] = [
            "phase": .string(phase),
            "duration_ms": .int(milliseconds(since: mark)),
            "outcome": .string(failureReason == nil ? "success" : "failure"),
        ]
        if let failureReason { attrs["reason"] = .string(failureReason) }
        DiagTrace.breadcrumb(
            failureReason == nil ? .verbose : .essential,
            level: failureReason == nil ? .info : .warning,
            category: .lifecycle, tag: "Startup", message: "content refresh finished",
            attrs: attrs
        )
    }

    // MARK: Chain

    /// Writes one chained record. The chain moves on whether or not this
    /// verbosity is being captured, so a skipped record never adds its time
    /// to the next.
    private static func record(
        _ verbosity: DiagnosticsVerbosity = .essential,
        level: DiagnosticsLogLevel = .info,
        tag: String = "Startup",
        phase: String,
        message: String,
        state: String? = nil,
        outcome: String? = nil
    ) {
        let now = DispatchTime.now()
        let elapsed = marks.withLock { marks -> Int in
            let elapsed = milliseconds(from: marks.previous ?? now, to: now)
            marks.previous = now
            return elapsed
        }
        var attrs: [String: DiagLogAttributeValue] = ["phase": .string(phase), "duration_ms": .int(elapsed)]
        if let state { attrs["state"] = .string(state) }
        if let outcome { attrs["outcome"] = .string(outcome) }
        DiagTrace.breadcrumb(verbosity, level: level, category: .lifecycle, tag: tag, message: message, attrs: attrs)
    }
}
