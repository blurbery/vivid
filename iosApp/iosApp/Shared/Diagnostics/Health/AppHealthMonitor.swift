#if os(iOS) || os(tvOS)
import Foundation
import os

/// Detects unexpected exits and main-thread hangs and records them as local
/// health reports. MetricKit covers crashes and hangs on iOS with call stacks;
/// tvOS has no MetricKit, so this is its only source, and on iOS it adds what
/// the app was doing at the time.
enum AppHealthMonitor {
    private struct State {
        var installed = false
        var enabled = false
        var armed = false
        var debuggerAttached = false
        var bootTime = 0
        var armedAt: Date?
        var hangInProgressMs: Int?
        var watchdogReports = 0
        var playbackFailureReports = 0
        var downloadFailureReports = 0
        var appErrorReports = 0
        var appErrorKeys: [String: Int] = [:]
    }

    private static let markerKey = "vivid.health.exitMarker"
    private static let backgroundContextKey = "vivid.health.backgroundContext"
    /// A run of hangs is one problem; cap how many one session can record.
    private static let maxWatchdogReportsPerSession = 10
    /// Opening can briefly block on a slow device behind the splash screen,
    /// where a short stall goes unnoticed; only longer ones count then.
    private static let launchHangThresholdMs = 2_000
    private static let maxPlaybackFailuresPerSession = 10
    /// A season batch can fail many episodes at once; repeats of the same
    /// failure also fold into one report.
    private static let maxDownloadFailuresPerSession = 10
    private static let maxAppErrorsPerSession = 10
    /// One failing request can repeat; keep a couple of each kind.
    private static let maxAppErrorsPerKind = 2
    /// Attributes copied from an error line into its report. All are tokens,
    /// numbers or already-templated paths.
    private static let appErrorAttributes: Set<String> = [
        "method", "path", "status", "outcome", "error_code", "attempt", "phase", "reason", "state",
    ]
    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let storeQueue = DispatchQueue(label: "com.blurbery.vivid.health.store", qos: .utility)
    /// How often memory use is written to the exit marker while active, so a
    /// memory termination report shows how use grew before it.
    private static let memorySampleInterval: DispatchTimeInterval = .seconds(30)
    private static let memorySampler = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)
    private static let watchdog = MainThreadWatchdog(
        onStall: { stalledMs in AppHealthMonitor.mainThreadStalled(ms: stalledMs) },
        onRecovered: { durationMs in AppHealthMonitor.mainThreadRecovered(durationMs: durationMs) }
    )

    // MARK: - Lifecycle

    /// Call once at launch, before the first scene. Turns a marker left by the
    /// previous session into a report, then starts MetricKit on iOS.
    static func install() {
        let isFirstInstall = state.withLock { state -> Bool in
            guard !state.installed else { return false }
            state.installed = true
            return true
        }
        guard isFirstInstall else { return }
        // The test runner ends its host app in the foreground, which would
        // otherwise read as an unexpected exit on the next launch.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let debuggerAttached = AppHealthSystem.isDebuggerAttached()
        let bootTime = AppHealthSystem.bootTime()
        state.withLock {
            $0.enabled = true
            $0.debuggerAttached = debuggerAttached
            $0.bootTime = bootTime
        }

        let previous = UserDefaults.standard.data(forKey: markerKey)
            .flatMap { try? JSONDecoder().decode(AppHealthExitMarker.self, from: $0) }
        UserDefaults.standard.removeObject(forKey: markerKey)
        let backgroundContext = UserDefaults.standard.data(forKey: backgroundContextKey)
            .flatMap { try? JSONDecoder().decode(AppHealthBackgroundContext.self, from: $0) }
        UserDefaults.standard.removeObject(forKey: backgroundContextKey)
        let crash = AppHealthCrashCapture.collectPrevious()
        if !debuggerAttached { AppHealthCrashCapture.install() }
        let previousEvents = AppHealthTrail.collectPrevious()
        AppHealthTrail.isEnabled = true

        let verdict = AppHealthExitMarker.evaluate(
            previous,
            currentBuild: AppHealthAppInfo.current.build,
            currentBootTime: bootTime
        )
        let report: AppHealthReport?
        if let crash {
            // A recorded signal is a crash whatever the marker says, including
            // one that happened in the background.
            report = AppHealthExitMarker.crashReport(
                crash,
                marker: previous.flatMap { $0.debuggerAttached ? nil : $0 },
                backgroundContext: backgroundContext,
                detectedAt: Date(),
                app: AppHealthAppInfo.current,
                recentEvents: previousEvents
            )
        } else if case .unexpectedExit(let marker) = verdict {
            report = marker.report(detectedAt: Date(), app: AppHealthAppInfo.current, recentEvents: previousEvents)
        } else {
            report = nil
        }
        if let report {
            storeQueue.async { AppHealthStore.shared.add(report) }
            DiagTrace.breadcrumb(
                .essential,
                level: .warning,
                category: .crash,
                tag: "Health",
                message: "previous session ended unexpectedly",
                attrs: ["source": .string(AppHealthReport.Source.exitMarker.rawValue)]
            )
        }

        #if os(iOS)
        MetricKitReportSubscriber.install()
        #endif
    }

    static func sceneDidBecomeActive() {
        let watchdogAllowed = state.withLock { state -> Bool in
            guard state.enabled else { return false }
            if !state.armed {
                state.armed = true
                state.armedAt = Date()
            }
            // Breakpoints stop the main thread, so a debugger session would
            // report every pause as a hang.
            return !state.debuggerAttached
        }
        writeMarker()
        if watchdogAllowed { watchdog.start() }
        if state.withLock({ $0.enabled }) { startMemorySampler() }
    }

    /// Background and normal termination both end the foreground session
    /// cleanly. Background jetsam kills are routine and are not reported.
    static func sessionEndedCleanly() {
        watchdog.stop()
        stopMemorySampler()
        state.withLock {
            $0.armed = false
            $0.armedAt = nil
            $0.hangInProgressMs = nil
        }
        UserDefaults.standard.removeObject(forKey: markerKey)
        AppHealthCrashCapture.processSurvived()
        let background = AppHealthBackgroundContext(pid: getpid(), context: AppHealthContext.snapshot())
        if let data = try? JSONEncoder().encode(background) {
            UserDefaults.standard.set(data, forKey: backgroundContextKey)
        }
        AppHealthTrail.flushSoon()
    }

    // MARK: - Context

    static func firstContentShown() {
        contextChanged { $0.phase = "browsing" }
        #if DEBUG
        if CommandLine.arguments.contains("-healthCrashTest") {
            // Crashes after launch so the next launch records a crash report.
            // Launch without a debugger, or the handler is not installed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                fatalError("Health crash test")
            }
        }
        if CommandLine.arguments.contains("-healthHangTest") {
            // Blocks the main thread long enough for the watchdog to record a
            // hang. Launch without a debugger, or the watchdog stays off.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Thread.sleep(forTimeInterval: 2.5)
            }
        }
        #endif
    }

    static func memoryWarningReceived() {
        contextChanged { $0.memoryWarnings += 1 }
        storeQueue.async { sampleMemory() }
    }

    static func playerOpened() {
        contextChanged {
            $0.playerOpen = true
            $0.playMethod = nil
            $0.playerOpenedAt = Date()
        }
        AppHealthTrail.flushSoon()
    }

    static func playerClosed() {
        contextChanged {
            $0.playerOpen = false
            $0.playMethod = nil
            $0.playerOpenedAt = nil
        }
        AppHealthTrail.flushSoon()
    }

    static func deviceOnlineChanged(_ online: Bool) {
        contextChanged { $0.deviceOnline = online }
    }

    static func serverReachabilityChanged(_ reachable: Bool) {
        contextChanged { $0.serverReachable = reachable }
    }

    // MARK: - Playback failures and app errors

    /// Playback ended in failure. `reason` is the player's stable failure
    /// token; the position is rounded to the minute.
    static func playbackFailed(reason: String, playMethod: String?, positionMs: Int?) {
        guard shouldReportPlaybackFailure(reason: reason, context: AppHealthContext.snapshot()) else { return }
        let allowed = state.withLock { state -> Bool in
            guard state.enabled, state.playbackFailureReports < maxPlaybackFailuresPerSession else { return false }
            state.playbackFailureReports += 1
            return true
        }
        guard allowed else { return }
        var details: [String: DiagnosticsJSONValue] = [
            "reason": .string(AppHealthContextSnapshot.playMethodToken(reason) ?? "unknown"),
            "server": .string(MediaServerProvider.active.rawValue),
        ]
        if let method = AppHealthContextSnapshot.playMethodToken(playMethod) { details["play_method"] = .string(method) }
        if let positionMs { details["position_min"] = .int(max(positionMs, 0) / 60_000) }
        recordWithRecentEvents(kind: .playbackFailure, details: details)
    }

    /// A download failed for good (registration refused, or preparing or
    /// transferring it ran out of retries). Connectivity failures, and other
    /// network failures while the device is offline or the server is
    /// unreachable, aren't recorded.
    static func downloadFailed(_ failure: DownloadFailureReport) {
        guard shouldReportDownloadFailure(failure, context: AppHealthContext.snapshot()) else { return }
        let allowed = state.withLock { state -> Bool in
            guard state.enabled, state.downloadFailureReports < maxDownloadFailuresPerSession else { return false }
            state.downloadFailureReports += 1
            return true
        }
        guard allowed else { return }
        recordWithRecentEvents(kind: .downloadFailure, details: failure.details)
    }

    static func shouldReportDownloadFailure(_ failure: DownloadFailureReport, context: AppHealthContextSnapshot) -> Bool {
        guard !failure.isConnectivity else { return false }
        return !(failure.isNetwork && (!context.deviceOnline || !context.serverReachable))
    }

    /// Called by `DiagTrace` for every essential error line. Playback errors
    /// have their own report, and network errors while the device is offline
    /// are expected, so neither is recorded here.
    static func errorLogged(
        category: DiagnosticsLogCategory,
        tag: String,
        attrs: [String: DiagLogAttributeValue]
    ) {
        guard category != .playback, category != .crash else { return }
        if category == .network, !isAppSideNetworkError(attrs) { return }
        var details: [String: DiagnosticsJSONValue] = [
            "category": .string(category.rawValue),
            "tag": .string(DiagLog.sanitizedText(tag, maxLength: 64)),
            "server": .string(MediaServerProvider.active.rawValue),
        ]
        for (key, value) in attrs where appErrorAttributes.contains(key) {
            switch value {
            case .string(let text): details[key] = .string(DiagLog.sanitizedText(text, maxLength: 128))
            case .int(let number): details[key] = .int(number)
            case .bool(let flag): details[key] = .bool(flag)
            case .double, .url, .error: continue
            }
        }
        let kindKey = [category.rawValue, tag, attrs["error_code"].flatMap(Self.token) ?? attrs["outcome"].flatMap(Self.token) ?? ""]
            .joined(separator: "|")
        let allowed = state.withLock { state -> Bool in
            guard state.enabled, state.appErrorReports < maxAppErrorsPerSession,
                  state.appErrorKeys[kindKey, default: 0] < maxAppErrorsPerKind else { return false }
            state.appErrorReports += 1
            state.appErrorKeys[kindKey, default: 0] += 1
            return true
        }
        guard allowed else { return }
        recordWithRecentEvents(kind: .appError, details: details)
    }

    /// Cancelled playback is not a fault, and network failures while the
    /// device is offline or the server is down are not the app's.
    static func shouldReportPlaybackFailure(reason: String, context: AppHealthContextSnapshot) -> Bool {
        if reason == "cancelled" { return false }
        let networkReasons: Set<String> = ["network", "timeout"]
        if networkReasons.contains(reason), !context.deviceOnline || !context.serverReachable { return false }
        return true
    }

    /// Network errors only count when they point at the app: a response it
    /// could not read, or a request the server rejected as malformed.
    /// Connectivity, TLS, timeouts, server faults and the statuses a normal
    /// session meets (expired sign-in, missing item, rate limits) do not.
    static func isAppSideNetworkError(_ attrs: [String: DiagLogAttributeValue]) -> Bool {
        if case .string(let outcome)? = attrs["outcome"],
           outcome == HTTPDiagnosticsOutcome.decodeFailed || outcome == HTTPDiagnosticsOutcome.invalidResponse {
            return true
        }
        guard case .int(let status)? = attrs["status"] else { return false }
        let expected: Set<Int> = [401, 403, 404, 408, 429]
        return (400..<500).contains(status) && !expected.contains(status)
    }

    private static func token(_ value: DiagLogAttributeValue) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    /// Builds the report once the triggering line has reached the event log,
    /// so the log ends with it.
    private static func recordWithRecentEvents(kind: AppHealthReport.Kind, details: [String: DiagnosticsJSONValue]) {
        let recordedAt = Date()
        let context = AppHealthContext.snapshot().attributes
        AppHealthTrail.queue.async {
            let report = AppHealthReport(
                kind: kind,
                source: .app,
                recordedAt: recordedAt,
                app: AppHealthAppInfo.current,
                details: details,
                context: context,
                recentEvents: AppHealthTrail.recentOnQueue(),
                fingerprintSeed: "\(recordedAt.timeIntervalSince1970)|\(kind.rawValue)"
            )
            storeQueue.async { AppHealthStore.shared.add(report) }
        }
    }

    static func playMethodChanged(_ playMethod: String?) {
        let token = AppHealthContextSnapshot.playMethodToken(playMethod)
        contextChanged { $0.playMethod = token }
    }

    private static func contextChanged(_ change: (inout AppHealthContextSnapshot) -> Void) {
        _ = AppHealthContext.update(change)
        writeMarker()
    }

    // MARK: - Memory

    private static func startMemorySampler() {
        memorySampler.withLockUnchecked { timer in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: storeQueue)
            source.schedule(deadline: .now(), repeating: memorySampleInterval, leeway: .seconds(5))
            source.setEventHandler { sampleMemory() }
            source.resume()
            timer = source
        }
    }

    private static func stopMemorySampler() {
        memorySampler.withLockUnchecked { timer in
            timer?.cancel()
            timer = nil
        }
    }

    private static func sampleMemory() {
        guard let footprint = AppHealthMemory.footprintMB() else { return }
        let available = AppHealthMemory.availableMB()
        let now = Date()
        contextChanged {
            $0.memoryMB = footprint
            $0.peakMemoryMB = max($0.peakMemoryMB ?? 0, footprint)
            $0.memoryAvailableMB = available
            $0.memorySampledAt = now
        }
    }

    // MARK: - Watchdog

    private static func mainThreadStalled(ms: Int) {
        state.withLock { $0.hangInProgressMs = ms }
        writeMarker()
    }

    private static func mainThreadRecovered(durationMs: Int?) {
        let launching = AppHealthContext.snapshot().phase == "launching"
        let shouldReport = state.withLock { state -> Bool in
            state.hangInProgressMs = nil
            guard let durationMs, state.watchdogReports < maxWatchdogReportsPerSession else { return false }
            if launching, durationMs < launchHangThresholdMs { return false }
            state.watchdogReports += 1
            return true
        }
        writeMarker()
        guard shouldReport, let durationMs else { return }
        let recordedAt = Date()
        let report = AppHealthReport(
            kind: .hang,
            source: .watchdog,
            recordedAt: recordedAt,
            app: AppHealthAppInfo.current,
            details: ["duration_ms": .int(durationMs)],
            context: AppHealthContext.snapshot().attributes,
            recentEvents: AppHealthTrail.recent(),
            fingerprintSeed: "\(recordedAt.timeIntervalSince1970)|\(durationMs)"
        )
        storeQueue.async { AppHealthStore.shared.add(report) }
        DiagTrace.breadcrumb(
            .essential,
            level: .warning,
            category: .crash,
            tag: "Health",
            message: "main thread hang \(durationMs) ms",
            attrs: ["source": .string(AppHealthReport.Source.watchdog.rawValue)]
        )
    }

    // MARK: - Marker

    /// UserDefaults hands the write to the preferences daemon straight away,
    /// so it survives the process being killed moments later.
    private static func writeMarker() {
        let current = state.withLock { $0 }
        guard current.armed, let armedAt = current.armedAt else { return }
        let marker = AppHealthExitMarker(
            build: AppHealthAppInfo.current.build,
            bootTime: current.bootTime,
            armedAt: armedAt,
            debuggerAttached: current.debuggerAttached,
            pid: getpid(),
            context: AppHealthContext.snapshot(),
            hangInProgressMs: current.hangInProgressMs
        )
        guard let data = try? JSONEncoder().encode(marker) else { return }
        UserDefaults.standard.set(data, forKey: markerKey)
    }
}

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
    private var generation: UInt64 = 0
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
        // Any acknowledgement still in flight belongs to the old generation
        // and is ignored.
        generation &+= 1
        pendingSince = nil
        reportedStall = false
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastTick = now }
        if lastTick != 0, Self.milliseconds(from: lastTick, to: now) >= Self.suspensionGapMs {
            if reportedStall { onRecovered(nil) }
            resetPending()
            return
        }
        if let since = pendingSince {
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
        if lastTick != 0, Self.milliseconds(from: lastTick, to: answeredAt) >= Self.suspensionGapMs {
            if reportedStall { onRecovered(nil) }
            resetPending()
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
