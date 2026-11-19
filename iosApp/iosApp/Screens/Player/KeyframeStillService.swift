import CoreGraphics
import Foundation
import UIKit

/// Scrub stills made from the playing file's own keyframes, for a load the
/// server has no preview sheets for.
///
/// It is off unless the hidden switch (`switchKey`) is on, and then only
/// for a file played exactly as stored. The main actor does the
/// bookkeeping here; every read and decode happens on the reader's own
/// thread, and pictures are packed and unpacked on background tasks.
///
/// Nothing is opened until the load has shown its first frame and then
/// played steadily for a few seconds. After that one reader is kept for the
/// load. The viewer's target always has the lane; in between, while the
/// player's buffer is healthy and nothing else is going on, the keyframes
/// around the playhead are read ahead within a byte budget.
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

    private let player: Player
    private let environment: Environment
    private let sourceURL: URL
    private let timeline: PlaybackTimelineMapper
    private let isLocalFile: Bool
    private let isLocalNetwork: Bool
    private let carryKey: String
    private let headers = KeyframeStillHeaders()

    private var watch: KeyframeStillNetworkWatch?
    private var ticker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTask: UInt64 = 0
    private var closing: Task<Void, Never>?

    // Steady play
    private var lastSample: (time: Double, uptime: TimeInterval)?
    private var steadySeconds: TimeInterval = 0
    private var hasPlayedSteadily = false

    // The reader
    private var source: KeyframeStillSource?
    private var isOpening = false
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

    // Read-ahead
    private var readAhead: Set<Int> = []
    private var readAheadBytes: Int
    private var typicalStillBytes = HTTPStillByteSource.minimumBlockBytes
    private var lastLadderRead: TimeInterval = -.infinity

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
                               environment: Environment, carried: Carry?) -> KeyframeStillService? {
        // The switch first, so with it off not even the player is asked.
        guard environment.isEnabled(),
              gate(for: spec, hasServerSheets: hasServerSheets, state: player.state(), environment: environment) == nil
        else { return nil }
        return KeyframeStillService(spec: spec, player: player, environment: environment, carried: carried)
    }

    private init(spec: VividLoadSpec, player: Player, environment: Environment, carried: Carry?) {
        self.player = player
        self.environment = environment
        sourceURL = spec.sourceURL
        timeline = spec.timeline
        isLocalFile = spec.sourceURL.isFileURL
        isLocalNetwork = Self.isLocalHost(spec.sourceURL.host)
        carryKey = Self.carryKey(for: spec.sourceURL)
        readAheadBytes = carried?.key == carryKey ? carried?.readAheadBytes ?? 0 : 0
        // A file on the device needs no network to read ahead.
        if !isLocalFile { watch = environment.makeNetworkWatch() }
        let centre = environment.notifications
        observers = [
            centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(.background) }
            },
            centre.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseMemory() }
            },
        ]
        if environment.startsTicker { startTicker() }
        log("start local=\(isLocalFile || isLocalNetwork ? 1 : 0) carried=\(readAheadBytes)")
    }

    /// What read-ahead has spent, for the next load of the same file.
    var carry: Carry { Carry(key: carryKey, readAheadBytes: readAheadBytes) }

    // MARK: - The scrub

    /// Sets the viewer's target and answers from what is already decoded.
    /// A still that arrives later for the newest target goes to `deliver`,
    /// as does nil when the still showing stops being honest.
    func request(atSourceTime sourceTime: Double, deliver: @escaping @MainActor (CGImage?, Double) -> Void) -> Answer {
        guard !isFinished, let time = readerTime(forSourceTime: sourceTime), canAnswer() else {
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

    /// A decoded still that is honest for this time, without asking for
    /// anything: its keyframe is at or before the time and no further back
    /// than the window.
    func cachedStill(forSourceTime sourceTime: Double) -> CGImage? {
        guard !isFinished, let time = readerTime(forSourceTime: sourceTime) else { return nil }
        let window = target == nil ? Tuning.window : window(at: environment.uptime())
        guard let position = nearestHeld(at: time, window: window, in: { self.decodedImage($0) != nil }) else { return nil }
        return decodedImage(position)
    }

    /// Forgets the target, so nothing more is delivered for it.
    func clearTarget() {
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

    /// Once a second: counts steady play, lets the next read go, and tidies
    /// up after the last one.
    func tick() {
        guard !isFinished else { return }
        guard environment.isEnabled() else {
            finish(.switchedOff)
            return
        }
        let now = environment.uptime()
        let state = player.state()
        noteSteadyPlay(state, now: now)
        noteHold(state)
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

    private func startTicker() {
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Tuning.tickSeconds))
                guard !Task.isCancelled, let self, !self.isFinished else { return }
                self.tick()
            }
        }
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
        return closing
    }

    private func finish(_ reason: End) {
        guard !isFinished else { return }
        isFinished = true
        isRuledOut = reason.rulesOutTheLoad
        ticker?.cancel()
        ticker = nil
        observers.forEach { environment.notifications.removeObserver($0) }
        observers = []
        watch?.cancel()
        watch = nil
        logSummary(reason)
        clearTarget()
        dropHeldStills()
        if let reader = source?.reader {
            source = nil
            closing = Task.detached(priority: .utility) { await reader.shutdown() }
        }
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

    private func canAnswer() -> Bool {
        hold(player.state()) == nil
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
    /// single read.
    private func readAheadHold(_ state: PlayerState) -> String? {
        if let unsettled = state.unsettled { return unsettled.rawValue }
        guard let buffered = state.bufferedAheadSeconds, buffered.isFinite else { return "bufferUnknown" }
        guard buffered >= Tuning.healthyBufferSeconds else { return "bufferLow" }
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
        guard !isFinished else { return }
        guard environment.isEnabled() else {
            finish(.switchedOff)
            return
        }
        let state = player.state()
        let now = environment.uptime()
        guard let state, hold(state) == nil, hasPlayedSteadily, now >= noReadBefore else { return }
        if target == nil, readAheadHold(state) != nil { return }
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
        guard inFlight.isEmpty, let position = nextReadAhead(playhead: state.sourceTime, now: now) else { return }
        read(position, .ahead)
    }

    private func open() {
        guard !isOpening, let fields = player.headers(sourceURL) else { return }
        headers.current = fields
        isOpening = true
        let url = sourceURL, box = headers, open = environment.open
        track { [weak self] in
            // Made off the main actor: a file is opened here, or a session
            // built.
            let opened = await Task.detached(priority: .utility) { open(url, box) }.value
            guard let self, !self.isFinished else {
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
        track { [weak self] in
            let info = await reader.prepare()
            guard let self, !self.isFinished else { return }
            self.isOpening = false
            self.opened(info, reader: reader)
        }
    }

    private func opened(_ info: KeyframeStillInfo?, reader: any KeyframeStillReading) {
        let now = environment.uptime()
        lastReadEnded = now
        guard let info else {
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
        guard info.canProduceStills else {
            finish(.cannotProduceStills)
            return
        }
        let entries = reader.index
        guard info.hasKeyframeIndex, entries.contains(where: \.isReadable) else {
            finish(.noKeyframeIndex)
            return
        }
        self.info = info
        index = entries
        readAheadBytes += info.bytesReadToOpen
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
        while position >= 0, time - index[position].time <= Tuning.window {
            // The last Matroska cue is never asked for.
            if index[position].isReadable, !refused.contains(position) { return position }
            position -= 1
        }
        return nil
    }

    private func read(_ position: Int, _ kind: Kind) {
        guard let reader = source?.reader, index.indices.contains(position) else { return }
        // The load's headers as they are now: the player may have renewed
        // its token since the last read.
        guard let fields = player.headers(sourceURL) else { return }
        headers.current = fields
        let now = environment.uptime()
        if !isInBurst {
            isInBurst = true
            log("burst begin \(Self.sample(player.state()))")
        }
        if kind == .ahead, !isNear(position, playhead: player.state()?.sourceTime) { lastLadderRead = now }
        inFlight.insert(position)
        decoderMayBeOpen = true
        let time = index[position].time
        track { [weak self] in
            let result = await reader.result(at: time, maxWidth: Tuning.stillWidth, urgent: kind == .viewer)
            self?.finished(position, kind, result)
        }
    }

    private func finished(_ position: Int, _ kind: Kind, _ result: KeyframeStillResult) {
        inFlight.remove(position)
        if kind == .viewer, viewerAsked == position { viewerAsked = nil }
        let now = environment.uptime()
        lastReadEnded = now
        guard !isFinished else { return }
        switch result {
        case let .still(still):
            transientFailures = 0
            consecutiveRefusals = 0
            stillsMade += 1
            typicalStillBytes = max(typicalStillBytes, still.bytesRead)
            if kind == .ahead {
                readAheadBytes += still.bytesRead
                readAhead.insert(position)
            } else {
                viewerBytes += still.bytesRead
                lastViewerRead = still.indexPosition
            }
            // Kept decoded only while someone is looking.
            if kind == .viewer || target != nil { keepDecoded(still.indexPosition, still.image) }
            keepEncoded(still)
            log("still \(kind.rawValue) pos=\(still.indexPosition) bytes=\(still.bytesRead) reads=\(still.readCount) "
                + "keyframe=\(still.keyframeBytes) ms=\(Int((still.elapsed * 1000).rounded())) cache=miss "
                + Self.sample(player.state()))
            publishBest()
        case .superseded, .cancelled:
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

    private func isNear(_ position: Int, playhead: Double?) -> Bool {
        guard let playhead, let time = readerTime(forSourceTime: playhead) else { return false }
        return abs(index[position].time - time) <= Tuning.nearSpanSeconds
    }

    /// The next keyframe worth reading ahead: the nearest one within two
    /// minutes of the playhead, either side, then the nearest point of the
    /// sparse ladder across the title, no more often than every two
    /// seconds. Nil when there is none, or the budget is spent.
    private func nextReadAhead(playhead: Double, now: TimeInterval) -> Int? {
        guard let time = readerTime(forSourceTime: playhead), let budget = readAheadBudget, !index.isEmpty else { return nil }
        func isWanted(_ position: Int) -> Bool {
            let entry = index[position]
            return entry.isReadable && !refused.contains(position) && !readAhead.contains(position)
                && !isHeld(position) && readAheadBytes + (entry.size ?? typicalStillBytes) <= budget
        }
        var behind = Self.position(at: time, in: index) ?? -1
        var ahead = behind + 1
        while true {
            let behindGap = behind >= 0 ? time - index[behind].time : .infinity
            let aheadGap = ahead < index.count ? index[ahead].time - time : .infinity
            guard min(behindGap, aheadGap) <= Tuning.nearSpanSeconds else { break }
            if aheadGap <= behindGap {
                if isWanted(ahead) { return ahead }
                ahead += 1
            } else {
                if isWanted(behind) { return behind }
                behind -= 1
            }
        }
        guard now - lastLadderRead >= Tuning.ladderPauseSeconds else { return nil }
        let end = max(info?.duration ?? 0, index.last?.time ?? 0)
        for rung in Tuning.ladder {
            var best: (position: Int, gap: Double)?
            var point = rung.offset
            while point < end {
                if let position = Self.position(at: point, in: index), isWanted(position) {
                    let gap = abs(point - time)
                    if gap < (best?.gap ?? .infinity) { best = (position, gap) }
                }
                point += rung.step
            }
            if let best { return best.position }
        }
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
            self.encoded[position] = data
            self.encodedOrder.append(position)
            self.encodedBytes += data.count
            while self.encodedBytes > Tuning.encodedByteLimit, self.encodedOrder.count > 1 {
                let oldest = self.encodedOrder.removeFirst()
                if let dropped = self.encoded.removeValue(forKey: oldest) { self.encodedBytes -= dropped.count }
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

    /// The nearest position at or before `time`, no further back than
    /// `window`, that `isHeld` says yes to. Never one after the time.
    private func nearestHeld(at time: Double, window: Double, in isHeld: (Int) -> Bool) -> Int? {
        guard var position = Self.position(at: time, in: index) else { return nil }
        while position >= 0, time - index[position].time <= window {
            if isHeld(position) { return position }
            position -= 1
        }
        return nil
    }

    /// The decoded still to show the target now. A nearer one that is only
    /// held as a JPEG starts unpacking.
    private func bestDecoded(at now: TimeInterval) -> (position: Int, image: CGImage)? {
        guard let target, !index.isEmpty else { return nil }
        let window = window(at: now)
        let ready = nearestHeld(at: target.time, window: window) { self.decodedImage($0) != nil }
        if let packed = nearestHeld(at: target.time, window: window, in: { self.encoded[$0] != nil }), packed > ready ?? -1 {
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
        var observers = 0
        var pendingWork = 0
        var heldStills = 0
    }

    var holdings: Holdings {
        Holdings(hasReader: source != nil, hasTicker: ticker != nil, hasNetworkWatch: watch != nil,
                 observers: observers.count, pendingWork: tasks.count, heldStills: encoded.count + decoded.count)
    }

    var heldPositions: Set<Int> { Set(encoded.keys).union(decoded.map(\.position)) }
    var readAheadSpent: Int { readAheadBytes }

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
