import CoreGraphics
import Foundation
import UIKit

/// Scrub stills made from the playing file's own keyframes, for a load the
/// server has no preview sheets for.
///
/// It is on unless the hidden switch (`switchKey`) turns it off, and only
/// ever for a file played exactly as stored. The main actor does the
/// bookkeeping here; every read and decode happens on the reader's own
/// thread, and pictures are packed and unpacked on background tasks.
///
/// Nothing is opened until the load has shown its first frame and then
/// played steadily for a few seconds. After that one reader is kept for the
/// load. The viewer's target always has the lane; in between, while the
/// player's buffer is healthy and nothing else is going on, keyframes
/// around the playhead are read ahead within a byte budget.
///
/// The player always comes first. A read that is out is stopped the moment
/// a gate closes: the load changes, the picture is handed off, the app
/// stops being active, the player turns to software decoding, or playback
/// stops being settled. While playback is unsettled for any reason but
/// the scrub's own seeking, even the viewer's target is answered only from
/// stills already held.
///
/// Times: the scrub bar and the playhead are in source-media time. The
/// loaded transport's clock is that time less the plan's timeline offset
/// (`PlaybackTimelineMapper`), and counts from the start of the file. The
/// reader's times count from the file's first video picture, so for the
/// files read here a transport time is a reader time, and the reader's
/// `startTime` must not be taken off again.
@MainActor
final class KeyframeStillService {
    /// What a scrub target gets in the call that set it.
    enum Answer {
        case still(CGImage)
        /// Nothing held is honest for this target, and what was showing
        /// should go.
        case cleared
        /// What is showing, a still or nothing, still stands.
        case unchanged
    }

    private enum Kind: String {
        case viewer, ahead
    }

    private struct Target {
        /// On the reader's axis.
        let time: Double
        let sourceTime: Double
    }

    private(set) var isFinished = false
    /// True once this load can never have keyframe stills.
    private(set) var isRuledOut = false
    /// True while the platform's frame reader still has the load. The
    /// service then only counts steady play, so that it is ready the moment
    /// that reader turns out not to be able to read the file.
    private(set) var isStandingBy: Bool
    /// True while the app is in the background: no reader, no timer and no
    /// stills, but what the service has learnt about the load is kept.
    private(set) var isSuspended = false

    private let player: Player
    private let environment: Environment
    private let notifications: NotificationCenter
    private let sourceURL: URL
    private let timeline: PlaybackTimelineMapper
    private let isLocalFile: Bool
    private let isLocalNetwork: Bool
    private let carryKey: String
    private let headers = KeyframeStillHeaders()

    private var watch: KeyframeStillNetworkWatch?
    private var ticker: Task<Void, Never>?
    private var tickerIsFast = false
    private var observers: [NSObjectProtocol] = []
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTask: UInt64 = 0
    /// Readers on their way out: one for each time the app went to the
    /// background, and the last.
    private var closings: [Task<Void, Never>] = []

    // Steady play
    private var lastSample: (time: Double, uptime: TimeInterval)?
    private var steadySeconds: TimeInterval = 0
    private var hasPlayedSteadily = false

    // The reader
    private var source: KeyframeStillSource?
    /// Moves on whenever the reader is let go, so work started for an
    /// earlier reader finds it has nothing to report to.
    private var readerEpoch = 0
    private var isOpening = false
    /// The part of opening that the reader itself does, and can be told to
    /// stop.
    private var isPreparing = false
    private var openWasCancelled = false
    private var failedOpens = 0
    private var info: KeyframeStillInfo?
    private var index: [KeyframeIndexEntry] = []
    /// Reads asked of the reader and not yet answered: one running and, at
    /// most, one for the viewer waiting behind a read-ahead read.
    private var inFlight: Set<Int> = []
    /// The one read out for the viewer. Targets that come while it is out
    /// only replace `target`, and the newest is asked for when it lands, so
    /// the order the reader hears them in never depends on task scheduling.
    private var viewerAsked: Int?
    /// Reads the service itself stopped. However they end, it isn't the
    /// file's fault or the server's.
    private var stopped: Set<Int> = []
    private var refused: Set<Int> = []
    private var consecutiveRefusals = 0
    private var transientFailures = 0
    private var noReadBefore: TimeInterval = 0
    private var decoderMayBeOpen = false
    private var lastReadEnded: TimeInterval = 0

    // Held stills, by index position
    private var encoded: [Int: Data] = [:]
    /// Least recently used first.
    private var encodedOrder: [Int] = []
    /// The same positions in index order, to find the one before a target
    /// without walking the index.
    private var encodedSorted: [Int] = []
    private var encodedBytes = 0
    /// Most recently used last.
    private var decoded: [(position: Int, image: CGImage)] = []
    private var decoding: Set<Int> = []
    /// Stills read and still being packed as JPEGs.
    private var packing: Set<Int> = []
    /// Moves on when memory is given back, so work already running then
    /// doesn't put its result back.
    private var memoryEpoch = 0

    // The scrub
    private var target: Target?
    private var deliver: (@MainActor (CGImage?, Double) -> Void)?
    private var shown: Int?
    private var lastMove: (time: Double, uptime: TimeInterval)?
    private var targetRate: Double = 0
    private var rateUptime: TimeInterval = -.infinity
    /// Looks at the window again once a fast-moving target has stopped.
    private var windowCheck: Task<Void, Never>?

    // Read-ahead
    private var readAhead: Set<Int> = []
    /// Read-ahead reads that are for the stretch near the playhead.
    private var nearReads: Set<Int> = []
    private var readAheadBytes: Int
    private var nearBytes: Int
    /// What the source had fetched when it was last looked at.
    private var lastReceived = 0
    private var typicalStillBytes = HTTPStillByteSource.minimumBlockBytes
    private var lastLadderRead: TimeInterval = -.infinity
    private var noLadderWalkBefore: TimeInterval = -.infinity
    private var bufferIsHealthy = false

    // Measurements
    private var holdReason: String?
    private var isInBurst = false
    private var served = 0
    private var servedFromCache = 0
    private var stillsMade = 0
    private var viewerBytes = 0
    private var failureCounts: [String: Int] = [:]
    private var firstRequestUptime: TimeInterval?
    private var firstStillMilliseconds: Int?
    private var lastViewerRead: Int?

    /// A service for this load, or nil when a gate says no. Nothing is
    /// opened here: no reader, no file and no connection.
    static func makeIfEligible(for spec: VividLoadSpec, hasServerSheets: Bool, player: Player,
                               environment: Environment, carried: Carry?, standingBy: Bool = false) -> KeyframeStillService? {
        // The switch first, so with it off not even the player is asked.
        guard environment.isEnabled(),
              gate(for: spec, hasServerSheets: hasServerSheets, state: player.state(), environment: environment) == nil
        else { return nil }
        return KeyframeStillService(spec: spec, player: player, environment: environment, carried: carried,
                                    standingBy: standingBy)
    }

    private init(spec: VividLoadSpec, player: Player, environment: Environment, carried: Carry?, standingBy: Bool) {
        self.player = player
        self.environment = environment
        notifications = environment.notifications
        isStandingBy = standingBy
        sourceURL = spec.sourceURL
        timeline = spec.timeline
        isLocalFile = spec.sourceURL.isFileURL
        isLocalNetwork = Self.isLocalHost(spec.sourceURL.host)
        carryKey = Self.carryKey(for: spec.sourceURL)
        let carries = carried?.key == carryKey
        readAheadBytes = carries ? carried?.readAheadBytes ?? 0 : 0
        nearBytes = carries ? carried?.nearBytes ?? 0 : 0
        // Three observers and a timer, and nothing else until the load has
        // played steadily: the network monitor waits for that (see
        // `pump()`), and the provider makes the service a turn after the
        // first frame's own.
        observers = [
            notifications.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            },
            notifications.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
            notifications.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseMemory() }
            },
        ]
        if environment.startsTicker { startTicker() }
        log("start local=\(isLocalFile || isLocalNetwork ? 1 : 0) carried=\(readAheadBytes) standby=\(standingBy ? 1 : 0)")
    }

    /// A service let go without `shutdown()` still leaves nothing behind.
    /// Everything here is safe from whichever thread drops the last
    /// reference.
    deinit {
        ticker?.cancel()
        windowCheck?.cancel()
        observers.forEach { notifications.removeObserver($0) }
        watch?.cancel()
        if let reader = source?.reader {
            reader.cancel()
            Task.detached(priority: .utility) { await reader.shutdown() }
        }
    }

    /// What read-ahead has spent, for the next load of the same file.
    var carry: Carry { Carry(key: carryKey, readAheadBytes: readAheadBytes, nearBytes: nearBytes) }

    /// The frame reader can't read this load after all, so the service
    /// takes it. Steady play counted while standing by still counts.
    func leaveStandby() {
        guard isStandingBy, !isFinished else { return }
        isStandingBy = false
        log("standby over steady=\(hasPlayedSteadily ? 1 : 0)")
        if environment.startsTicker, ticker == nil, !isSuspended { startTicker() }
    }

    // MARK: - The scrub

    /// Sets the viewer's target and answers from what is already decoded.
    /// A still that arrives later for the newest target goes to `deliver`,
    /// as does nil when the still showing stops being honest.
    func request(atSourceTime sourceTime: Double, deliver: @escaping @MainActor (CGImage?, Double) -> Void) -> Answer {
        guard !isFinished, !isStandingBy, !isSuspended, let time = readerTime(forSourceTime: sourceTime), canAnswer() else {
            let wasShowing = shown != nil
            clearTarget()
            return wasShowing ? .cleared : .unchanged
        }
        let now = environment.uptime()
        if let lastMove {
            let elapsed = now - lastMove.uptime
            if elapsed > Tuning.rateHoldSeconds {
                targetRate = 0
            } else if elapsed > 0 {
                targetRate = abs(time - lastMove.time) / elapsed
                rateUptime = now
            }
        }
        lastMove = (time, now)
        if firstRequestUptime == nil { firstRequestUptime = now }
        target = Target(time: time, sourceTime: sourceTime)
        self.deliver = deliver
        scheduleWindowCheck(at: now)
        // Answered before anything is started, so what a read or an
        // unpacked JPEG brings later can only follow this answer.
        let answer: Answer
        if let best = bestDecoded(at: now) {
            if shown == best.position {
                answer = .unchanged
            } else {
                show(best.position)
                answer = .still(best.image)
            }
        } else if shown != nil {
            shown = nil
            answer = .cleared
        } else {
            answer = .unchanged
        }
        pump()
        return answer
    }

    /// A target that is moving fast may be shown a still from well before
    /// it. Requests stop coming when it stops, so the window is looked at
    /// once more just after the rate has gone stale, and a still that is
    /// then too far back is taken down without waiting for the next tick.
    private func scheduleWindowCheck(at now: TimeInterval) {
        windowCheck?.cancel()
        windowCheck = nil
        guard window(at: now) > Tuning.window else { return }
        let sleep = environment.sleep
        windowCheck = Task { @MainActor [weak self] in
            await sleep(Tuning.rateHoldSeconds + 0.05)
            guard !Task.isCancelled, let self, !self.isFinished else { return }
            self.windowCheck = nil
            self.publishBest()
        }
    }

    /// Forgets the target, so nothing more is delivered for it.
    func clearTarget() {
        windowCheck?.cancel()
        windowCheck = nil
        target = nil
        deliver = nil
        shown = nil
        lastMove = nil
        targetRate = 0
    }

    /// The scrub is over. The reader stays; its decoder is closed once it
    /// has sat idle for a moment (see `tick()`).
    func endScrub() {
        clearTarget()
        lastReadEnded = max(lastReadEnded, environment.uptime())
    }

    // MARK: - The clock

    /// Once a second, and four times a second while a read is out: counts
    /// steady play, stops a read a gate has closed on, lets the next read
    /// go, and tidies up after the last one.
    func tick() {
        guard !isFinished, !isSuspended else { return }
        guard environment.isEnabled() else {
            finish(.switchedOff)
            return
        }
        let now = environment.uptime()
        let state = player.state()
        noteSteadyPlay(state, now: now)
        if isStandingBy {
            // Nothing more to count, so nothing more to wake up for.
            if hasPlayedSteadily { stopTicker() }
            return
        }
        noteHold(state)
        stopReadsIfNeeded(state)
        // The window narrows again once the target stops moving.
        publishBest()
        if decoderMayBeOpen, inFlight.isEmpty, !isOpening,
           target == nil || hold(state) != nil, now - lastReadEnded >= Tuning.idleDecoderSeconds {
            source?.reader.closeDecoder()
            decoderMayBeOpen = false
            log("decoder closed")
        }
        if isInBurst, inFlight.isEmpty, now - lastReadEnded >= Tuning.burstGapSeconds {
            isInBurst = false
            log("burst end \(Self.sample(state))")
        }
        pump()
    }

    /// True while the reader has been asked for something it hasn't
    /// answered.
    private var hasWorkOut: Bool { !inFlight.isEmpty || isPreparing }

    /// How long until the gates are next looked at.
    var sampleInterval: TimeInterval { hasWorkOut ? Tuning.busyTickSeconds : Tuning.tickSeconds }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.nextSampleInterval() else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, !self.isFinished else { return }
                self.tick()
            }
        }
    }

    private func nextSampleInterval() -> TimeInterval {
        tickerIsFast = hasWorkOut
        return sampleInterval
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// A read has just gone out while the timer is part-way through a
    /// one-second wait: start it again on the short one.
    private func quickenTicker() {
        if ticker != nil, !tickerIsFast { startTicker() }
    }

    /// Five seconds of the playhead moving on at about the speed of
    /// playback, with nothing else going on, before any reader exists.
    private func noteSteadyPlay(_ state: PlayerState?, now: TimeInterval) {
        guard !hasPlayedSteadily else { return }
        guard let state, state.isPlaying, state.unsettled == nil, state.sourceTime.isFinite else {
            lastSample = nil
            steadySeconds = 0
            return
        }
        defer { lastSample = (state.sourceTime, now) }
        guard let lastSample else { return }
        let elapsed = now - lastSample.uptime
        let moved = state.sourceTime - lastSample.time
        guard elapsed > 0, elapsed <= 3, moved >= elapsed * 0.25, moved <= elapsed * 4 + 0.5 else {
            steadySeconds = 0
            return
        }
        steadySeconds += elapsed
        if steadySeconds >= Tuning.steadyPlaySeconds {
            hasPlayedSteadily = true
            log("steady")
        }
    }

    // MARK: - Lifetime

    /// Ends the service and starts shutting its reader down off the main
    /// actor. The task finishes once the reader's thread has stopped.
    @discardableResult
    func shutdown() -> Task<Void, Never>? {
        finish(.loadEnded)
        let closings = closings
        guard !closings.isEmpty else { return nil }
        return Task {
            for closing in closings {
                await closing.value
            }
        }
    }

    private func finish(_ reason: End) {
        guard !isFinished else { return }
        isFinished = true
        isRuledOut = reason.rulesOutTheLoad
        stopTicker()
        observers.forEach { notifications.removeObserver($0) }
        observers = []
        watch?.cancel()
        watch = nil
        logSummary(reason)
        clearTarget()
        dropHeldStills()
        closeReader()
    }

    /// Lets the reader go. A read or an open that is running is stopped
    /// here and now, on the main actor, before the wait for the reader's
    /// thread is handed to a background task: the abort flag and the
    /// source's cancel must not depend on when that task gets a turn.
    private func closeReader() {
        readerEpoch &+= 1
        if let fetched = takeReceived() { readAheadBytes += fetched }
        lastReceived = 0
        inFlight = []
        viewerAsked = nil
        stopped = []
        nearReads = []
        isOpening = false
        isPreparing = false
        openWasCancelled = false
        decoderMayBeOpen = false
        info = nil
        index = []
        guard let reader = source?.reader else { return }
        source = nil
        reader.cancel()
        closings.append(Task.detached(priority: .utility) { await reader.shutdown() })
    }

    /// The app has gone to the background: the reader, the stills, the
    /// timer and the network monitor go, and the service stays, with the
    /// steady play it has counted and the budget it has spent. Were it
    /// ended here, the next one could only be made by a scrub, and would
    /// then wait for steady play that can't be counted during a scrub.
    private func suspend() {
        guard !isFinished, !isSuspended else { return }
        isSuspended = true
        stopTicker()
        watch?.cancel()
        watch = nil
        lastSample = nil
        let wasShowing = shown != nil
        let deliver = deliver, sourceTime = target?.sourceTime ?? 0
        clearTarget()
        if wasShowing { deliver?(nil, sourceTime) }
        dropHeldStills()
        closeReader()
        log("suspended")
    }

    private func resume() {
        guard isSuspended, !isFinished else { return }
        isSuspended = false
        log("resumed")
        if environment.startsTicker, !(isStandingBy && hasPlayedSteadily) { startTicker() }
    }

    /// A memory warning: the stills and the decoder go, the reader and what
    /// it knows about the file stay.
    private func releaseMemory() {
        guard !isFinished else { return }
        dropHeldStills()
        source?.reader.closeDecoder()
        decoderMayBeOpen = false
        log("memory released")
    }

    private func dropHeldStills() {
        memoryEpoch &+= 1
        encoded = [:]
        encodedOrder = []
        encodedSorted = []
        encodedBytes = 0
        decoded = []
        decoding = []
        packing = []
    }

    private func track(_ body: @escaping @MainActor () async -> Void) {
        let id = nextTask
        nextTask &+= 1
        tasks[id] = Task { @MainActor [weak self] in
            await body()
            self?.tasks[id] = nil
        }
    }

    // MARK: - Gates

    /// Why nothing may be read just now, or nil.
    private func hold(_ state: PlayerState?) -> String? {
        guard let state else { return "loadNotCurrent" }
        if state.isHandedOff { return "handedOff" }
        if !state.isAppActive { return "notActive" }
        // Software decoding already has the processor busy.
        if state.decodesInSoftware != false { return state.decodesInSoftware == nil ? "decodeUnknown" : "softwareDecode" }
        return nil
    }

    /// Whether a target may be answered at all. Asked on every scrub
    /// request, so a gate that has just closed stops a read here too, not
    /// only at the next tick.
    private func canAnswer() -> Bool {
        let state = player.state()
        stopReadsIfNeeded(state)
        return hold(state) == nil
    }

    /// Why even the viewer's reads must wait, or nil: a hold, or playback
    /// that isn't settled for any reason but the scrub's own seeking.
    private func viewerHold(_ state: PlayerState?) -> String? {
        if let reason = hold(state) { return reason }
        if let unsettled = state?.unsettled, unsettled.stopsViewerReads { return unsettled.rawValue }
        return nil
    }

    /// Stops whatever the reader is doing when a gate has closed on it.
    /// The reader's `cancel()` returns at once. A read stopped this way is
    /// not a failure: it brings no wait before the next read and doesn't
    /// count against the file.
    private func stopReadsIfNeeded(_ state: PlayerState?) {
        guard hasWorkOut, let reason = viewerHold(state), let reader = source?.reader else { return }
        let fresh = inFlight.subtracting(stopped)
        let stopsOpen = isPreparing && !openWasCancelled
        guard !fresh.isEmpty || stopsOpen else { return }
        stopped.formUnion(fresh)
        if stopsOpen { openWasCancelled = true }
        reader.cancel()
        log("stop \(reason) reads=\(fresh.count) open=\(stopsOpen ? 1 : 0)")
    }

    private func noteHold(_ state: PlayerState?) {
        let reason = hold(state)
        guard reason != holdReason else { return }
        holdReason = reason
        log("hold \(reason ?? "none")")
        if reason != nil, target != nil {
            let wasShowing = shown != nil
            let deliver = deliver, sourceTime = target?.sourceTime ?? 0
            clearTarget()
            if wasShowing { deliver?(nil, sourceTime) }
        }
    }

    /// Why nothing may be read ahead just now, or nil. Checked before every
    /// single read. The buffer has to reach the healthy figure to start
    /// read-ahead and fall below the low one to stop it.
    private func readAheadHold(_ state: PlayerState) -> String? {
        if let unsettled = state.unsettled { return unsettled.rawValue }
        guard let buffered = state.bufferedAheadSeconds, buffered.isFinite else {
            bufferIsHealthy = false
            return "bufferUnknown"
        }
        if buffered >= Tuning.healthyBufferSeconds {
            bufferIsHealthy = true
        } else if buffered < Tuning.lowBufferSeconds {
            bufferIsHealthy = false
        }
        guard bufferIsHealthy else { return "bufferLow" }
        guard isLocalFile || watch?.allowsReadAhead == true else { return "network" }
        return nil
    }

    /// The most read-ahead may spend on this file, once its length is
    /// known: two per cent of a file on the viewer's own network or device,
    /// otherwise one per cent and never more than 60 MB.
    private var readAheadBudget: Int? {
        guard let size = source?.fileSize(), size > 0 else { return nil }
        if isLocalFile || isLocalNetwork { return Int(size / Tuning.localBudgetFraction) }
        return Int(min(size / Tuning.remoteBudgetFraction, Tuning.remoteBudgetLimit))
    }

    // MARK: - Reading

    /// Starts whatever may be read next: the file, then the viewer's
    /// target, then one read ahead.
    private func pump() {
        guard !isFinished, !isSuspended, !isStandingBy else { return }
        guard environment.isEnabled() else {
            finish(.switchedOff)
            return
        }
        let state = player.state()
        let now = environment.uptime()
        guard let state, hold(state) == nil, hasPlayedSteadily, now >= noReadBefore else { return }
        // Made here, the first time anything might be read, and not when
        // the service is: a file on the device never needs it.
        if watch == nil, !isLocalFile { watch = environment.makeNetworkWatch() }
        if target != nil {
            // With playback unsettled, the target makes do with what is
            // held: no file is opened and nothing is read. `tick()` comes
            // back here once it has settled.
            guard viewerHold(state) == nil else { return }
        } else if readAheadHold(state) != nil {
            return
        }
        guard let source else {
            open()
            return
        }
        guard !isOpening else { return }
        guard info != nil else {
            prepare(source.reader)
            return
        }
        if target != nil {
            serveTarget()
            return
        }
        // One read at a time, always.
        guard inFlight.isEmpty, let next = nextReadAhead(playhead: state.sourceTime, now: now) else { return }
        read(next.position, .ahead, isNear: next.isNear)
    }

    private func open() {
        guard !isOpening, let fields = player.headers(sourceURL) else { return }
        headers.current = fields
        isOpening = true
        let url = sourceURL, box = headers, open = environment.open, epoch = readerEpoch
        track { [weak self] in
            // Made off the main actor: a file is opened here, or a session
            // built.
            let opened = await Task.detached(priority: .utility) { open(url, box) }.value
            guard let self, !self.isFinished, self.readerEpoch == epoch else {
                await opened?.reader.shutdown()
                return
            }
            self.isOpening = false
            guard let opened else {
                self.finish(.cannotOpen)
                return
            }
            self.source = opened
            self.prepare(opened.reader)
        }
    }

    /// Reads the file's header and keyframe index. Also how a file that
    /// didn't open is tried again: with the reader already there.
    private func prepare(_ reader: any KeyframeStillReading) {
        guard !isOpening, let fields = player.headers(sourceURL) else { return }
        headers.current = fields
        isOpening = true
        isPreparing = true
        let epoch = readerEpoch
        quickenTicker()
        track { [weak self] in
            let info = await reader.prepare()
            // The index is checked once, here and off the main actor, so
            // nothing on it ever has to walk the whole of it.
            var checked: (entries: [KeyframeIndexEntry]?, hasReadable: Bool) = (nil, false)
            if let info {
                checked = await Task.detached(priority: .utility) {
                    let entries = Self.usableIndex(reader.index, duration: info.duration)
                    return (entries, entries?.contains(where: \.isReadable) == true)
                }.value
            }
            guard let self, !self.isFinished, self.readerEpoch == epoch else { return }
            self.isOpening = false
            self.isPreparing = false
            self.opened(info, entries: checked.entries, hasReadable: checked.hasReadable)
        }
    }

    private func opened(_ info: KeyframeStillInfo?, entries: [KeyframeIndexEntry]?, hasReadable: Bool) {
        let now = environment.uptime()
        lastReadEnded = now
        let wasStopped = openWasCancelled
        openWasCancelled = false
        let fetched = takeReceived()
        guard let info else {
            readAheadBytes += fetched ?? 0
            // Stopped by the service itself: nothing is held against the
            // file, and it is opened again when the gates allow.
            if wasStopped { return }
            // The reader keeps its own wait after a failed open. This only
            // stops a file that won't open from being tried all night.
            failedOpens += 1
            failureCounts["open", default: 0] += 1
            if failedOpens >= 3 {
                finish(.cannotOpen)
            } else {
                backOff(now: now)
            }
            return
        }
        readAheadBytes += fetched ?? info.bytesReadToOpen
        guard info.canProduceStills else {
            finish(.cannotProduceStills)
            return
        }
        guard let entries else {
            finish(.badIndex)
            return
        }
        guard info.hasKeyframeIndex, hasReadable else {
            finish(.noKeyframeIndex)
            return
        }
        self.info = info
        index = entries
        log("open keyframes=\(entries.count) bytes=\(info.bytesReadToOpen) width=\(info.codedWidth) height=\(info.codedHeight) "
            + "transfer=\(info.transfer) dv=\(info.dolbyVisionProfile ?? 0)")
        pump()
    }

    private func backOff(now: TimeInterval) {
        transientFailures += 1
        let wait = Tuning.firstBackOffSeconds * pow(2, Double(min(transientFailures, 6) - 1))
        noReadBefore = now + min(wait, Tuning.longestBackOffSeconds)
    }

    /// The viewer's target: decode what is held for it, and read its own
    /// keyframe if that isn't held. One slot, newest wins: a read already
    /// out for the viewer finishes first, and is shown if it is still
    /// inside the window.
    private func serveTarget() {
        guard let target else { return }
        publishBest()
        guard viewerAsked == nil, let wanted = wantedPosition(for: target.time), !isHeld(wanted),
              !inFlight.contains(wanted), !packing.contains(wanted)
        else { return }
        viewerAsked = wanted
        read(wanted, .viewer)
    }

    /// The keyframe a target should be shown: the one at or before it, or
    /// the nearest earlier one that can be read, as long as it is inside
    /// the window a still may be shown from once the target is at rest.
    private func wantedPosition(for time: Double) -> Int? {
        guard var position = Self.position(at: time, in: index) else { return nil }
        var steps = 0
        while position >= 0, steps < Tuning.walkLimit, time - index[position].time <= Tuning.window {
            // The last Matroska cue is never asked for.
            if index[position].isReadable, !refused.contains(position) { return position }
            position -= 1
            steps += 1
        }
        return nil
    }

    /// What the source has fetched since it was last asked, or nil for a
    /// source that only counts what it hands the reader. A read waiting
    /// behind the one that just finished may already have fetched a little
    /// of its own, which is then counted one read early.
    private func takeReceived() -> Int? {
        guard let total = source?.receivedBytes?() else { return nil }
        defer { lastReceived = total }
        return max(0, total - lastReceived)
    }

    private func charge(_ bytes: Int, _ kind: Kind, isNear: Bool) {
        if kind == .ahead {
            readAheadBytes += bytes
            if isNear { nearBytes += bytes }
        } else {
            viewerBytes += bytes
        }
    }

    private func read(_ position: Int, _ kind: Kind, isNear: Bool = false) {
        guard let reader = source?.reader, index.indices.contains(position) else { return }
        // The load's headers as they are now: the player may have renewed
        // its token since the last read.
        guard let fields = player.headers(sourceURL) else { return }
        headers.current = fields
        if !isInBurst {
            isInBurst = true
            log("burst begin \(Self.sample(player.state()))")
        }
        if isNear {
            nearReads.insert(position)
        } else if kind == .ahead {
            lastLadderRead = environment.uptime()
        }
        inFlight.insert(position)
        decoderMayBeOpen = true
        let time = index[position].time, epoch = readerEpoch
        quickenTicker()
        track { [weak self] in
            let result = await reader.result(at: time, maxWidth: Tuning.stillWidth, urgent: kind == .viewer)
            self?.finished(position, kind, result, epoch: epoch)
        }
    }

    private func finished(_ position: Int, _ kind: Kind, _ result: KeyframeStillResult, epoch: Int) {
        // The reader this was asked of has gone, and its books with it.
        guard epoch == readerEpoch, !isFinished else { return }
        inFlight.remove(position)
        if kind == .viewer, viewerAsked == position { viewerAsked = nil }
        let wasStopped = stopped.remove(position) != nil
        let isNear = nearReads.remove(position) != nil
        let fetched = takeReceived()
        let now = environment.uptime()
        lastReadEnded = now
        // The budget is spent by what was fetched, whatever came of it.
        if result.still == nil { charge(fetched ?? 0, kind, isNear: isNear) }
        switch result {
        case let .still(still):
            let cost = fetched ?? still.bytesRead
            charge(cost, kind, isNear: isNear)
            transientFailures = 0
            consecutiveRefusals = 0
            stillsMade += 1
            typicalStillBytes = max(typicalStillBytes, cost)
            if kind == .ahead {
                readAhead.insert(position)
            } else {
                lastViewerRead = still.indexPosition
            }
            // Kept decoded only while someone is looking.
            if kind == .viewer || target != nil { keepDecoded(still.indexPosition, still.image) }
            keepEncoded(still)
            log("still \(kind.rawValue) pos=\(still.indexPosition) bytes=\(still.bytesRead) fetched=\(cost) reads=\(still.readCount) "
                + "keyframe=\(still.keyframeBytes) ms=\(Int((still.elapsed * 1000).rounded())) cache=miss "
                + Self.sample(player.state()))
            publishBest()
        case .superseded, .cancelled:
            break
        case .transientFailure where wasStopped, .notPossible where wasStopped, .overLimit where wasStopped:
            // A read the service stopped can come back as any failure. It
            // is none of them.
            break
        case .transientFailure:
            failureCounts["transient", default: 0] += 1
            backOff(now: now)
        case .notPossible, .overLimit, .lastCue:
            failureCounts[result.reason, default: 0] += 1
            refused.insert(position)
            consecutiveRefusals += 1
            // A file that never gives a still isn't asked again.
            if stillsMade == 0, consecutiveRefusals >= 3 {
                finish(.refused)
                return
            }
        }
        pump()
    }

    // MARK: - Read-ahead

    /// What one more read-ahead read is taken to cost: the keyframe's size
    /// where the container gives it, or the most a still has cost so far,
    /// and over a network never less than the block one request fetches.
    private func expectedCost(of position: Int) -> Int {
        max(index[position].size ?? typicalStillBytes, isLocalFile ? 0 : HTTPStillByteSource.minimumBlockBytes)
    }

    /// The next keyframe worth reading ahead, or nil when there is none or
    /// the budget is spent.
    ///
    /// First the stretch near the playhead: one keyframe for every ten
    /// seconds within two minutes either side, nearest first. It may take
    /// half the budget and no more, so that the sparse ladder across the
    /// title is always reached: every five minutes, then the points
    /// halfway between, nearest first and no more often than every two
    /// seconds.
    ///
    /// Each call looks at a fixed number of points, each found by a binary
    /// search, however many keyframes the file has and whatever its
    /// metadata says about its length.
    private func nextReadAhead(playhead: Double, now: TimeInterval) -> (position: Int, isNear: Bool)? {
        guard let time = readerTime(forSourceTime: playhead), let budget = readAheadBudget, !index.isEmpty else { return nil }
        func isWanted(_ position: Int, isNear: Bool) -> Bool {
            let entry = index[position]
            guard entry.isReadable, !refused.contains(position), !readAhead.contains(position), !isHeld(position),
                  !packing.contains(position)
            else { return false }
            let cost = expectedCost(of: position)
            guard readAheadBytes + cost <= budget else { return false }
            return !isNear || nearBytes + cost <= budget / Tuning.nearBudgetDivisor
        }
        let slot = Tuning.nearSlotSeconds
        let home = (time / slot).rounded(.down)
        for distance in 0...Int(Tuning.nearSpanSeconds / slot) {
            for side in distance == 0 ? [0.0] : [Double(distance), -Double(distance)] {
                let point = (home + side) * slot
                guard point >= 0, abs(point - time) <= Tuning.nearSpanSeconds,
                      let position = Self.position(at: point, in: index),
                      abs(index[position].time - time) <= Tuning.nearSpanSeconds
                else { continue }
                if isWanted(position, isNear: true) { return (position, true) }
            }
        }
        guard now - lastLadderRead >= Tuning.ladderPauseSeconds, now >= noLadderWalkBefore else { return nil }
        let end = min(max(info?.duration ?? 0, index.last?.time ?? 0), Tuning.longestFileSeconds)
        for rung in Tuning.ladder {
            guard end > rung.offset else { continue }
            // The points are offset + n * step for n in 0...last, walked
            // outwards from the one nearest the playhead.
            let last = min(Int(((end - rung.offset) / rung.step).rounded(.up)) - 1, Tuning.ladderStepLimit)
            guard last >= 0 else { continue }
            let nearest = Int(min(max(((time - rung.offset) / rung.step - 0.5).rounded(.up), 0), Double(last)))
            func wanted(_ step: Int) -> Int? {
                guard step >= 0, step <= last,
                      let position = Self.position(at: rung.offset + Double(step) * rung.step, in: index),
                      isWanted(position, isNear: false)
                else { return nil }
                return position
            }
            if let position = wanted(nearest) { return (position, false) }
            for distance in 1...max(last, 1) {
                let below = nearest - distance, above = nearest + distance
                guard below >= 0 || above <= last else { break }
                let belowGap = abs(rung.offset + Double(below) * rung.step - time)
                let aboveGap = abs(rung.offset + Double(above) * rung.step - time)
                for step in belowGap <= aboveGap ? [below, above] : [above, below] {
                    if let position = wanted(step) { return (position, false) }
                }
            }
        }
        // Nothing left on the ladder. A still dropped from the cache can
        // make a point wanted again, so it is walked again, but not often.
        noLadderWalkBefore = now + Tuning.ladderRestSeconds
        return nil
    }

    // MARK: - Held stills

    private func isHeld(_ position: Int) -> Bool {
        encoded[position] != nil || decodedImage(position) != nil
    }

    private func decodedImage(_ position: Int) -> CGImage? {
        decoded.first { $0.position == position }?.image
    }

    private func keepDecoded(_ position: Int, _ image: CGImage) {
        decoded.removeAll { $0.position == position }
        decoded.append((position, image))
        if decoded.count > Tuning.decodedLimit { decoded.removeFirst(decoded.count - Tuning.decodedLimit) }
    }

    /// Packs a still as a JPEG off the main actor and keeps it, dropping
    /// the least recently used once the byte limit is passed.
    private func keepEncoded(_ still: KeyframeStill) {
        let position = still.indexPosition
        let epoch = memoryEpoch
        let held = HeldImage(image: still.image)
        packing.insert(position)
        track { [weak self] in
            let data = await Task.detached(priority: .utility) { Self.encode(held) }.value
            guard let self, !self.isFinished, self.memoryEpoch == epoch else { return }
            self.packing.remove(position)
            guard let data else { return }
            if let old = self.encoded.removeValue(forKey: position) {
                self.encodedBytes -= old.count
                self.encodedOrder.removeAll { $0 == position }
            }
            if self.encoded[position] == nil {
                self.encodedSorted.insert(position, at: Self.insertionPoint(for: position, in: self.encodedSorted))
            }
            self.encoded[position] = data
            self.encodedOrder.append(position)
            self.encodedBytes += data.count
            while self.encodedBytes > Tuning.encodedByteLimit || self.encodedOrder.count > Tuning.encodedCountLimit,
                  self.encodedOrder.count > 1 {
                let oldest = self.encodedOrder.removeFirst()
                if let dropped = self.encoded.removeValue(forKey: oldest) { self.encodedBytes -= dropped.count }
                let place = Self.insertionPoint(for: oldest, in: self.encodedSorted)
                if place < self.encodedSorted.count, self.encodedSorted[place] == oldest { self.encodedSorted.remove(at: place) }
            }
            self.publishBest()
        }
    }

    private func decode(_ position: Int) {
        guard !decoding.contains(position), let data = encoded[position] else { return }
        decoding.insert(position)
        encodedOrder.removeAll { $0 == position }
        encodedOrder.append(position)
        let epoch = memoryEpoch
        track { [weak self] in
            let held = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
            guard let self, !self.isFinished, self.memoryEpoch == epoch else { return }
            self.decoding.remove(position)
            guard let held else { return }
            self.keepDecoded(position, held.image)
            self.publishBest()
        }
    }

    /// How far before the target a still may be: one preview interval, or
    /// while the target is moving fast, what it covers in a fifth of a
    /// second, up to two minutes.
    private func window(at now: TimeInterval) -> Double {
        guard now - rateUptime <= Tuning.rateHoldSeconds else { return Tuning.window }
        return min(max(targetRate * Tuning.glanceSeconds, Tuning.window), Tuning.widestWindow)
    }

    /// Where `position` is, or would go, in an ascending list.
    private static func insertionPoint(for position: Int, in sorted: [Int]) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// The nearest decoded still at or before `time` and no further back
    /// than `window`. Never one after the time. Only the few decoded
    /// stills are looked at, never the index.
    private func nearestDecoded(at time: Double, window: Double) -> Int? {
        var best: Int?
        for item in decoded where index.indices.contains(item.position) {
            let gap = time - index[item.position].time
            if gap >= 0, gap <= window, item.position > best ?? -1 { best = item.position }
        }
        return best
    }

    /// The same for stills held as JPEGs, by binary search.
    private func nearestEncoded(at time: Double, window: Double) -> Int? {
        guard let position = Self.position(at: time, in: index) else { return nil }
        let place = Self.insertionPoint(for: position + 1, in: encodedSorted)
        guard place > 0 else { return nil }
        let held = encodedSorted[place - 1]
        return time - index[held].time <= window ? held : nil
    }

    /// The decoded still to show the target now. A nearer one that is only
    /// held as a JPEG starts unpacking.
    private func bestDecoded(at now: TimeInterval) -> (position: Int, image: CGImage)? {
        guard let target, !index.isEmpty else { return nil }
        let window = window(at: now)
        let ready = nearestDecoded(at: target.time, window: window)
        if let packed = nearestEncoded(at: target.time, window: window), packed > ready ?? -1 {
            decode(packed)
        }
        guard let ready, let image = decodedImage(ready) else { return nil }
        keepDecoded(ready, image)
        return (ready, image)
    }

    /// Sends the newest target whatever is now best for it: a still that
    /// has just arrived, or nothing when the one showing is no longer
    /// inside the window.
    private func publishBest() {
        guard let target, let deliver else { return }
        if let best = bestDecoded(at: environment.uptime()) {
            guard shown != best.position else { return }
            show(best.position)
            deliver(best.image, target.sourceTime)
        } else if shown != nil {
            shown = nil
            deliver(nil, target.sourceTime)
        }
    }

    private func show(_ position: Int) {
        shown = position
        served += 1
        if firstStillMilliseconds == nil, let firstRequestUptime {
            firstStillMilliseconds = Int(((environment.uptime() - firstRequestUptime) * 1000).rounded())
        }
        if lastViewerRead == position {
            lastViewerRead = nil
        } else {
            servedFromCache += 1
            log("still viewer pos=\(position) bytes=0 reads=0 keyframe=0 ms=0 cache=hit \(Self.sample(player.state()))")
        }
    }

    // MARK: - Times

    /// A source-media time on the reader's axis, or nil when the loaded
    /// transport doesn't hold it. See the type's note on the two axes.
    private func readerTime(forSourceTime sourceTime: Double) -> Double? {
        guard sourceTime.isFinite, sourceTime >= 0,
              case let .local(transportTime) = timeline.seekDisposition(forSourceTime: sourceTime)
        else { return nil }
        return transportTime
    }

    // MARK: - Measurements

    /// Numbers only: no address, title, host or token ever goes in a line.
    private func log(_ line: String) {
        if let record = environment.record {
            record(line)
        } else {
            Self.logger.info("\(line, privacy: .public)")
        }
    }

    /// The main player's own counters, read and never written, so a line
    /// before a burst of reads can be set against the lines during and
    /// after it.
    private static func sample(_ state: PlayerState?) -> String {
        func text(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        return "drops=\(state?.droppedFrames.map(String.init) ?? "-") buffer=\(text(state?.bufferedAheadSeconds)) "
            + "avsync=\(text(state?.avSyncGapMilliseconds))"
    }

    private func logSummary(_ reason: End) {
        let hitRate = served > 0 ? Int((Double(servedFromCache) / Double(served) * 100).rounded()) : 0
        let failures = failureCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        log("summary end=\(reason.rawValue) served=\(served) hits=\(servedFromCache) hit_rate=\(hitRate) stills=\(stillsMade) "
            + "ahead_bytes=\(readAheadBytes) budget=\(readAheadBudget.map(String.init) ?? "-") viewer_bytes=\(viewerBytes) "
            + "first_still_ms=\(firstStillMilliseconds.map(String.init) ?? "-") failures=\(failures.isEmpty ? "none" : failures)")
    }

    // MARK: - Tests

    #if DEBUG
    /// Tests only: what the service is holding on to.
    struct Holdings: Equatable {
        var hasReader = false
        var hasTicker = false
        var hasNetworkWatch = false
        var hasWindowCheck = false
        var observers = 0
        var pendingWork = 0
        var heldStills = 0
    }

    var holdings: Holdings {
        Holdings(hasReader: source != nil, hasTicker: ticker != nil, hasNetworkWatch: watch != nil,
                 hasWindowCheck: windowCheck != nil, observers: observers.count, pendingWork: tasks.count, heldStills: encoded.count + decoded.count)
    }

    var heldPositions: Set<Int> { Set(encoded.keys).union(decoded.map(\.position)) }
    var readAheadSpent: Int { readAheadBytes }
    var nearSpent: Int { nearBytes }
    var hasSteadyPlay: Bool { hasPlayedSteadily }

    /// Tests only: a decoded still that is honest for this time, without
    /// asking for anything.
    func cachedStill(forSourceTime sourceTime: Double) -> CGImage? {
        guard !isFinished, let time = readerTime(forSourceTime: sourceTime) else { return nil }
        let window = target == nil ? Tuning.window : window(at: environment.uptime())
        return nearestDecoded(at: time, window: window).flatMap { decodedImage($0) }
    }

    /// Tests only: waits for everything the service has started to finish.
    func settle() async {
        while let task = tasks.values.first {
            await task.value
        }
    }
    #endif
}

private extension KeyframeStillResult {
    var reason: String {
        switch self {
        case .still: "still"
        case .superseded: "superseded"
        case .cancelled: "cancelled"
        case .transientFailure: "transient"
        case .notPossible: "notPossible"
        case .lastCue: "lastCue"
        case .overLimit: "overLimit"
        }
    }
}
