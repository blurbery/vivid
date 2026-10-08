#if os(iOS) || os(tvOS)
import Foundation

/// Counts what went wrong in one playback session. Pure value logic with an
/// injected clock, so it can be tested without a player.
///
/// mpv's frame counters are cumulative for the file. Each sample adds only
/// the change since the previous one, so a seek or reload that resets a
/// counter can't produce a negative or doubled count. Changes during warm-up
/// (start, seek, resume, buffering recovery and display switches) are kept
/// separately, because some dropped frames there are normal.
struct PlaybackSessionAccumulator {
    /// How long after start, seek, resume, buffering or a display switch
    /// frame drops are treated as warm-up rather than a problem.
    static let warmupSeconds: TimeInterval = 5
    /// Drift beyond this is noticeable lip-sync error.
    static let avSyncThresholdMs: Double = 100
    static let maxTimelineMinutes = 240
    /// Fault names come from a fixed list, but cap the distinct names anyway
    /// so the session can never grow with the length of the movie.
    static let maxFaultKinds = 16
    /// The playhead not moving this long in steady playback, without
    /// buffering, is a stall. On AirPlay this is how a parked speaker clock
    /// shows: video waits for it, so A/V sync stays near zero.
    static let stallSeconds: TimeInterval = 2

    private(set) var totals = PlaybackSessionReport.Totals()
    private(set) var minutes: [Int: PlaybackSessionReport.Minute] = [:]

    private var lastTick: TimeInterval?
    private var warmupUntil: TimeInterval
    private var playing = false
    private var buffering = false
    /// False while the app is in the background playing audio only, when
    /// video frame counts and A/V sync mean nothing.
    private var videoVisible = true
    private var bufferingSince: TimeInterval?
    /// Buffering before the first played second is startup, not a rebuffer.
    private var bufferingIsRebuffer = false
    private var lastAvSyncMs: Double?
    private var lastCounters: [Counter: Int] = [:]
    private let startedAt: TimeInterval
    /// Until the playhead first moves, a shown first frame is held (on
    /// AirPlay, until the speakers start), so that time isn't playback.
    private var playheadStarted = false
    private var lastPosition: Double?
    private var lastMoveAt: TimeInterval?
    private var stalled = false

    enum Counter: CaseIterable { case dropped, decoderDropped, delayed }

    init(startedAt now: TimeInterval) {
        startedAt = now
        warmupUntil = now + Self.warmupSeconds
        lastTick = now
        totals.pausedSeconds = 0
        totals.waitSeconds = 0
        totals.longestWaitSeconds = 0
    }

    private var minuteIndex: Int { min(Int(totals.playedSeconds / 60), Self.maxTimelineMinutes - 1) }

    private func inWarmup(_ now: TimeInterval) -> Bool { now < warmupUntil }

    mutating func markWarmup(at now: TimeInterval) {
        warmupUntil = max(warmupUntil, now + Self.warmupSeconds)
    }

    /// Advances played time. Call regularly, at least once a second, and on
    /// every state change so time is attributed to the right state.
    mutating func tick(at now: TimeInterval) {
        defer { lastTick = now }
        guard let lastTick, now > lastTick else { return }
        let elapsed = min(now - lastTick, 5)
        if buffering {
            guard bufferingIsRebuffer else {
                // Loading after opening, seeking or resuming isn't a rebuffer,
                // but it's still time the viewer spent waiting.
                totals.waitSeconds = (totals.waitSeconds ?? 0) + elapsed
                if let since = bufferingSince {
                    totals.longestWaitSeconds = max(totals.longestWaitSeconds ?? 0, now - since)
                }
                return
            }
            totals.rebufferSeconds += elapsed
            let index = minuteIndex
            minutes[index, default: .init(minute: index)].rebufferSeconds += elapsed
            return
        }
        guard playing else {
            if playheadStarted { totals.pausedSeconds = (totals.pausedSeconds ?? 0) + elapsed }
            return
        }
        guard playheadStarted else {
            totals.warmupSeconds += elapsed
            return
        }
        totals.playedSeconds += elapsed
        if inWarmup(now) {
            totals.warmupSeconds += elapsed
        } else if let drift = lastAvSyncMs, abs(drift) > Self.avSyncThresholdMs {
            totals.avSyncOver100msSeconds += elapsed
        }
    }

    mutating func setPlaying(_ isPlaying: Bool, at now: TimeInterval) {
        tick(at: now)
        if isPlaying && !playing {
            markWarmup(at: now)
            if totals.firstFrameSeconds == nil { totals.firstFrameSeconds = Self.rounded(now - startedAt) }
        }
        playing = isPlaying
    }

    /// The playhead position, read once a second. Nil when the player
    /// didn't report one; then the playhead is assumed to be moving.
    mutating func position(_ seconds: Double?, at now: TimeInterval) {
        let previousTick = lastTick ?? now
        tick(at: now)
        guard let seconds, seconds.isFinite else {
            if playing, !playheadStarted { startPlayhead(at: now) }
            return
        }
        defer { lastPosition = seconds }
        let moved = lastPosition.map { abs(seconds - $0) >= 0.05 } ?? false
        if moved, playing, !playheadStarted { startPlayhead(at: now) }
        // Only steady playback can stall; anything else restarts the timer.
        guard playing, playheadStarted, !buffering, !inWarmup(now) else {
            lastMoveAt = now
            stalled = false
            return
        }
        if moved || lastMoveAt == nil {
            lastMoveAt = now
            stalled = false
            return
        }
        guard let since = lastMoveAt, now - since >= Self.stallSeconds else { return }
        let index = minuteIndex
        if !stalled {
            stalled = true
            totals.stalls += 1
            totals.stallSeconds += now - since
            minutes[index, default: .init(minute: index)].stallSeconds += now - since
        } else {
            let elapsed = min(now - previousTick, 5)
            totals.stallSeconds += elapsed
            minutes[index, default: .init(minute: index)].stallSeconds += elapsed
        }
    }

    private mutating func startPlayhead(at now: TimeInterval) {
        playheadStarted = true
        totals.playbackStartSeconds = Self.rounded(now - startedAt)
        lastMoveAt = now
    }

    private static func rounded(_ seconds: TimeInterval) -> Double { (seconds * 10).rounded() / 10 }

    mutating func setBuffering(_ isBuffering: Bool, at now: TimeInterval) {
        tick(at: now)
        guard isBuffering != buffering else { return }
        buffering = isBuffering
        if isBuffering {
            // Refilling just after starting, seeking, resuming or a display
            // switch is expected; only a stall in steady playback counts.
            bufferingIsRebuffer = totals.playedSeconds > 0 && !inWarmup(now)
            if bufferingIsRebuffer { totals.rebuffers += 1 }
            bufferingSince = now
        } else {
            bufferingSince = nil
            markWarmup(at: now)
        }
    }

    mutating func seeked(at now: TimeInterval) {
        tick(at: now)
        totals.seeks += 1
        markWarmup(at: now)
        lastAvSyncMs = nil
    }

    /// Video went out of view (background audio) or came back.
    mutating func setVideoVisible(_ visible: Bool, at now: TimeInterval) {
        tick(at: now)
        guard visible != videoVisible else { return }
        videoVisible = visible
        lastAvSyncMs = nil
        markWarmup(at: now)
    }

    mutating func displaySwitched(at now: TimeInterval) {
        tick(at: now)
        totals.displaySwitches += 1
        markWarmup(at: now)
    }

    mutating func reloaded(at now: TimeInterval) {
        tick(at: now)
        totals.reloads += 1
        markWarmup(at: now)
        lastAvSyncMs = nil
    }

    mutating func audioOutputChanged(at now: TimeInterval) {
        tick(at: now)
        totals.audioOutputChanges += 1
        markWarmup(at: now)
    }

    /// A cumulative mpv frame counter. Nil leaves the counter unmeasured.
    mutating func counter(_ counter: Counter, value: Int?, at now: TimeInterval) {
        guard let value, value >= 0 else { return }
        tick(at: now)
        defer { lastCounters[counter] = value }
        if totalValue(counter) == nil { setTotal(counter, 0) }
        guard let previous = lastCounters[counter] else {
            // The first sample is a baseline. Anything counted before the
            // recorder started belongs to startup.
            if counter == .dropped, value > 0 { totals.warmupDroppedFrames = (totals.warmupDroppedFrames ?? 0) + value }
            return
        }
        guard value > previous else { return } // reset after a reload or seek
        let delta = value - previous
        guard videoVisible else { return }
        if inWarmup(now) || !playing || buffering {
            // Only dropped frames are kept for warm-up; late and decoder
            // drops there are normal and not reported.
            if counter == .dropped { totals.warmupDroppedFrames = (totals.warmupDroppedFrames ?? 0) + delta }
            return
        }
        setTotal(counter, (totalValue(counter) ?? 0) + delta)
        var minute = minutes[minuteIndex, default: .init(minute: minuteIndex)]
        switch counter {
        case .dropped: minute.droppedFrames += delta
        case .decoderDropped: minute.decoderDroppedFrames += delta
        case .delayed: minute.delayedFrames += delta
        }
        minutes[minuteIndex] = minute
    }

    mutating func avSync(ms: Double?, at now: TimeInterval) {
        tick(at: now)
        // A reading from warm-up mustn't count as drift once warm-up ends.
        guard let ms, ms.isFinite, playing, !buffering, videoVisible, !inWarmup(now) else { lastAvSyncMs = nil; return }
        lastAvSyncMs = ms
        let drift = abs(ms)
        totals.maxAvSyncMs = max(totals.maxAvSyncMs ?? 0, drift)
        var minute = minutes[minuteIndex, default: .init(minute: minuteIndex)]
        minute.maxAvSyncMs = max(minute.maxAvSyncMs ?? 0, drift)
        minutes[minuteIndex] = minute
    }

    mutating func audioFault(_ name: String, at now: TimeInterval) {
        tick(at: now)
        var token = VividMPVPlayer.formatToken(name) ?? "other"
        if totals.audioFaults[token] == nil, totals.audioFaults.count >= Self.maxFaultKinds { token = "other" }
        totals.audioFaults[token, default: 0] += 1
        let index = minuteIndex
        minutes[index, default: .init(minute: index)].faults[token, default: 0] += 1
    }

    mutating func networkKbps(_ kbps: Int?) {
        guard let kbps, kbps > 0 else { return }
        totals.lowestNetworkKbps = min(totals.lowestNetworkKbps ?? kbps, kbps)
    }

    mutating func ended(reason: String, at now: TimeInterval) {
        tick(at: now)
        totals.endReason = reason
    }

    /// Minutes with something to report, oldest first.
    var timeline: [PlaybackSessionReport.Minute] {
        minutes.values.filter { !$0.isQuiet }.sorted { $0.minute < $1.minute }
    }

    private func totalValue(_ counter: Counter) -> Int? {
        switch counter {
        case .dropped: totals.droppedFrames
        case .decoderDropped: totals.decoderDroppedFrames
        case .delayed: totals.delayedFrames
        }
    }

    private mutating func setTotal(_ counter: Counter, _ value: Int) {
        switch counter {
        case .dropped: totals.droppedFrames = value
        case .decoderDropped: totals.decoderDroppedFrames = value
        case .delayed: totals.delayedFrames = value
        }
    }
}
#endif
