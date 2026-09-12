// Vivid licensing: see ../../LICENSE and ../../LICENSE-APPLE-EXCEPTION.
// GPLv3 section 7(b)/(c) attribution and origin terms: ../../ATTRIBUTION.md.
// Those terms apply only to material within the authority and scope stated there.
import SwiftUI

@main
struct VividApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(VividAppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(iOS) || os(tvOS)
        FreshInstallLocalData.prepare()
        #endif
        #if os(tvOS)
        // No-op unless launched with `-perfHitchLog`.
        TVFrameHitchMonitor.installIfRequested()
        #endif

        // Install the shared Nuke-backed image cache before any SwiftUI view
        // runs so poster/backdrop-heavy screens reuse the same pipeline on
        // both iOS and tvOS.
        PosterImageCache.install()

        #if os(iOS) || os(tvOS)
        // Record local launch timing for development troubleshooting.
        LaunchTimeline.recordProcessStart()
        #endif

    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    NotificationCenter.default.post(
                        name: .vividDeepLink,
                        object: nil,
                        userInfo: ["url": url]
                    )
                }
        }
    }
}

extension Notification.Name {
    /// Posted whenever the app receives a `vivid://` deep-link URL
    /// (debug launches, Top Shelf taps). `ContentView` consumes it and
    /// queues until the auth state machine reaches `.authenticated`.
    static let vividDeepLink = Notification.Name("vividDeepLink")
}

#if os(iOS) || os(tvOS)
/// Local launch and lifecycle timing for development builds.
/// Each duration measures the gap since the previous phase.
enum LaunchTimeline {
    /// `DispatchTime` rather than `Date` so a mid-launch wall-clock correction
    /// (NTP settling right after boot is the common one) cannot render a
    /// negative or wildly inflated `duration_ms`.
    nonisolated(unsafe) private static var lastMark = DispatchTime.now()
    /// When the app entered the background, or `nil` when it is not currently
    /// backgrounded. Serves two purposes that a plain "has ever backgrounded"
    /// flag could not:
    ///
    /// * It distinguishes the warm return-to-foreground from the
    ///   `.inactive → .active` step every cold launch also performs, which is
    ///   what `launch_type` encodes. Clearing it when the foreground edge
    ///   consumes it is what keeps the *next* `.inactive → .active` pair —
    ///   Control Centre, a notification banner, an app-switcher peek, none of
    ///   which background the app — from being mislabelled as a warm return.
    /// * It times the foreground event against the moment the app actually
    ///   backgrounded rather than against the phase chain's `lastMark`, which
    ///   the intervening `.inactive` step advances. See `record`.
    nonisolated(unsafe) private static var backgroundedAt: DispatchTime?
    nonisolated(unsafe) private static var didRecordRootView = false
    nonisolated(unsafe) private static var didRecordFirstContent = false
    /// Synchronizes local timing state if future callers run off the main actor.
    private static let lock = NSLock()

    // MARK: - Marks

    /// A monotonic point for callers that time their own work (prefetches,
    /// foreground refreshes) rather than advancing the phase chain.
    static func mark() -> DispatchTime { .now() }

    static func milliseconds(since mark: DispatchTime) -> Int {
        milliseconds(from: mark, to: .now())
    }

    /// Unsigned subtraction on `uptimeNanoseconds` traps on underflow, so the
    /// ordering is checked rather than assumed. `end < start` is not reachable
    /// from a correctly-paired mark, but a clamp is cheaper than a crash inside
    /// diagnostics code.
    private static func milliseconds(from start: DispatchTime, to end: DispatchTime) -> Int {
        let startNanos = start.uptimeNanoseconds
        let endNanos = end.uptimeNanoseconds
        guard endNanos > startNanos else { return 0 }
        return Int((endNanos - startNanos) / 1_000_000)
    }

    // MARK: - Launch chain

    /// Begins the local timeline for this process launch.
    static func recordProcessStart() {
        lock.lock()
        lastMark = .now()
        lock.unlock()
        record(
            tag: "App",
            phase: "process_start",
            message: "app launched",
            state: "launch",
            launchType: "cold",
            includesDuration: false
        )
    }

    /// The root view's first `onAppear` — the first evidence that SwiftUI got
    /// as far as rendering. A launch that logs `process_start` and nothing
    /// else died in static setup or scene creation.
    static func recordRootViewAppeared() {
        lock.lock()
        let alreadyRecorded = didRecordRootView
        didRecordRootView = true
        lock.unlock()
        guard !alreadyRecorded else { return }
        record(phase: "root_view", message: "root view appeared")
    }

    /// Entering the stored-credential / profile resolution that decides the
    /// initial route. Verbose because the interesting line is its completion;
    /// this one only exists to separate "never started the check" from
    /// "started it and hung", which is the difference between a broken scene
    /// and a wedged Keychain or server probe.
    static func recordInitialStateCheckStarted() {
        record(.verbose, phase: "initial_state", message: "initial state check started")
    }

    /// The resolved initial route. `state` is the auth-state token, so a
    /// trace shows which tree the app was trying to build.
    static func recordInitialStateResolved(state: String) {
        record(phase: "initial_state", message: "initial state resolved", state: state)
    }

    /// The startup splash animation finished. Recorded separately from the
    /// route commit because the two gate each other: the app shows real
    /// content only once both this and the state check are done, so seeing
    /// which arrived last tells you whether launch was animation-bound or
    /// network/Keychain-bound.
    static func recordSplashFinished() {
        record(phase: "splash", message: "startup splash finished")
    }

    /// First real content: the initial route is committed and the splash is
    /// gone. This closes the cold-launch chain — its absence in a trace is
    /// the signal that the user never got a usable app.
    static func recordFirstContent(state: String) {
        lock.lock()
        let alreadyRecorded = didRecordFirstContent
        didRecordFirstContent = true
        lock.unlock()
        guard !alreadyRecorded else { return }
        record(
            phase: "first_content",
            message: "initial route committed",
            state: state,
            outcome: "success"
        )
    }

    // MARK: - Run lifecycle

    /// The single scene-phase funnel. `.active` and `.background` are the
    /// state changes worth keeping unconditionally; `.inactive` fires for
    /// every control-centre pull, notification banner, and app-switcher peek,
    /// so it is verbose-tier detail rather than timeline.
    static func recordScenePhase(_ state: String) {
        switch state {
        case "active":
            // Consume the background mark: a resume is `.background →
            // .inactive → .active`, and the app stays active until the next
            // real `.background`. Leaving the mark set would relabel every
            // later `.inactive → .active` blip — Control Centre, a banner, an
            // app-switcher peek — as a warm foreground with a nonsense
            // duration.
            lock.lock()
            let backgroundStart = backgroundedAt
            backgroundedAt = nil
            lock.unlock()
            if let backgroundStart {
                // `duration_ms` here is the time spent backgrounded, which is
                // what distinguishes a quick app-switch from a resume the
                // system may have jetsammed state out from under. It is
                // measured from the `.background` edge rather than from the
                // phase chain's `lastMark`, because the intervening
                // `.inactive` step advances that mark even when its verbose
                // line is suppressed — timing it off the chain would report
                // the inactive→active gap (a few milliseconds) as the
                // background dwell.
                record(
                    tag: "Scene",
                    phase: "foreground",
                    message: "app foregrounded",
                    state: state,
                    launchType: "warm",
                    duration: milliseconds(since: backgroundStart)
                )
            } else {
                record(tag: "Scene", phase: "scene", message: "scene became active", state: state)
            }
        case "background":
            lock.lock()
            backgroundedAt = .now()
            lock.unlock()
            record(tag: "Scene", phase: "background", message: "app backgrounded", state: state)
        default:
            record(.verbose, tag: "Scene", phase: "scene", message: "scene phase changed", state: state)
        }
    }

    /// Memory pressure. Warning level because the usual next event is a jetsam
    /// kill, which leaves no other trace at all — this line plus a missing
    /// termination line is how that reads in a trace.
    static func recordMemoryWarning(state: String) {
        record(
            level: .warning,
            tag: "App",
            phase: "memory_warning",
            message: "memory warning",
            state: state
        )
    }

    /// A clean termination. Its presence is as diagnostic as its content: an
    /// trace whose breadcrumbs end without this line did not
    /// shut down through the normal path.
    static func recordTermination(state: String) {
        record(tag: "App", phase: "terminate", message: "app terminating", state: state)
    }

    // MARK: - Off-chain outcomes

    /// Outcome of a server refresh that is not a phase transition (the
    /// post-authentication hydration and its foreground retry). Timed by the
    /// caller against its own `mark()`, so it does not disturb the phase
    /// chain's inter-phase deltas.
    ///
    /// Failures are essential and successes are verbose, deliberately: a
    /// foreground refresh runs on every return to the app, so recording the
    /// happy path at essential tier would spend the local log budget
    /// on the one outcome that needs no explanation. A refresh that failed —
    /// leaving overlays, capabilities, or nav customization stale for the rest
    /// of the session — is the useful trace line.
    static func recordRefreshOutcome(
        phase: String,
        since mark: DispatchTime,
        failureReason: String?
    ) {
        var attrs: [String: DiagLogAttributeValue] = [
            "phase": .string(phase),
            "duration_ms": .int(milliseconds(since: mark)),
            "outcome": .string(failureReason == nil ? "success" : "failure"),
        ]
        if let failureReason {
            attrs["reason"] = .string(failureReason)
        }
        DiagTrace.breadcrumb(
            failureReason == nil ? .verbose : .essential,
            level: failureReason == nil ? .info : .warning,
            category: .lifecycle,
            tag: "Startup",
            message: "content refresh finished",
            attrs: attrs
        )
    }

    // MARK: - Emission

    private static func record(
        _ verbosity: DiagnosticsVerbosity = .essential,
        level: DiagnosticsLogLevel = .info,
        tag: String = "Startup",
        phase: String,
        message: String,
        state: String? = nil,
        outcome: String? = nil,
        launchType: String? = nil,
        includesDuration: Bool = true,
        duration: Int? = nil
    ) {
        // Advance the chain even when the tier suppresses the line, so a
        // suppressed verbose step cannot silently fold its time into the next
        // essential one's `duration_ms`. One `now` for both the delta and the
        // new mark, so the segments tile the timeline exactly.
        //
        // `duration` overrides only what is *reported*, for the one event whose
        // documented interval is not the inter-phase gap (the background dwell
        // on `foreground`). The mark still advances, so the chain keeps tiling
        // and the next phase's delta stays honest.
        var attrs: [String: DiagLogAttributeValue] = ["phase": .string(phase)]
        if includesDuration {
            let now = DispatchTime.now()
            lock.lock()
            let previous = lastMark
            lastMark = now
            lock.unlock()
            attrs["duration_ms"] = .int(duration ?? milliseconds(from: previous, to: now))
        }
        if let state { attrs["state"] = .string(state) }
        if let outcome { attrs["outcome"] = .string(outcome) }
        if let launchType { attrs["launch_type"] = .string(launchType) }
        DiagTrace.breadcrumb(
            verbosity,
            level: level,
            category: .lifecycle,
            tag: tag,
            message: message,
            attrs: attrs
        )
    }
}
#endif
