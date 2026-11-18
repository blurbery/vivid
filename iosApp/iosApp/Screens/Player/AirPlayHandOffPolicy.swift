import Foundation

/// How committing a prepared receiver session went.
enum AirPlayReceiverCommit: Equatable, Sendable {
    /// The receiver session is live and the session it replaced is retired.
    case committed
    /// Nothing changed: the session that was live still is, and the prepared
    /// receiver session has been abandoned.
    case refused
    /// The session that was live is gone and the receiver session isn't
    /// live either, so playback needs a fresh session.
    case failed
}

/// Where an AirPlay hand-off gets the stream the receiver plays.
///
/// A receiver session is prepared first (started and checked on the server,
/// with nothing retired), and committed only once Lucid has stepped aside.
/// A prepared session that isn't committed is released.
@MainActor
protocol AirPlayReceiverStreamSource: AnyObject {
    /// Starts a receiver session for the current title at `position` (source
    /// axis) with the current tracks and quality, leaving the live session as
    /// it is. Throws if the provider can't produce one.
    func prepareAirPlayReceiverSession(position: Double) async throws -> AirPlayReceiverStream

    /// Makes a prepared receiver session the live one, retiring the session
    /// that was live at `position`.
    func commitAirPlayReceiverSession(_ stream: AirPlayReceiverStream, position: Double) async -> AirPlayReceiverCommit

    /// Ends a prepared receiver session that won't be committed.
    func releaseAirPlayReceiverSession(_ stream: AirPlayReceiverStream) async

    /// The receiver's clock has started moving.
    func airPlayReceiverDidStart() async
}

/// Decides when the player hands a title to an AirPlay video receiver and
/// when Lucid takes it back.
///
/// An Apple TV and a HomePod both show up as `.airPlay` outputs, so a route
/// change only starts a probe: a tiny local video on an `AVPlayer` that may
/// go external. If it does within the probe window the receiver shows video
/// and the title is handed over; if it doesn't, it's a speaker and nothing
/// about Lucid changes.
///
/// Pure and deterministic: the caller turns the returned effects into work
/// and feeds what happens back as events. Positions are on the source axis.
struct AirPlayHandOffPolicy: Equatable {
    enum State: Equatable {
        case idle
        /// The probe is playing; Lucid is untouched.
        case probing(route: String)
        /// The probe went external. The receiver session is being prepared
        /// while Lucid keeps playing on its own session.
        case preparing(route: String, request: Int)
        /// Lucid is paused and muted and the receiver has (or is about to
        /// have) the title.
        case active(Active)
        /// This route has had its answer: it's a speaker, or a hand-off on it
        /// ended. Nothing more happens until the route changes or the viewer
        /// picks a receiver again, so a burst of notifications for the same
        /// route can't start a loop of probes.
        case ending(route: String)
    }

    struct Active: Equatable {
        var route: String
        /// Where the current receiver stream starts. At first that's where
        /// Lucid paused, which is also where it resumes if the receiver never
        /// starts.
        var startPosition: Double
        /// A receiver session has been committed, so the phone's own session
        /// is gone.
        var committed = false
        /// The receiver's clock has moved on the current stream.
        var started = false
        /// External playback dropped and hasn't come back yet. A debounced
        /// loss that arrives after it came back is stale.
        var externalLost = false
        /// A receiver session being committed, and where its stream starts.
        var pendingCommit: Int?
        var commitPosition: Double = 0
        /// A replacement stream being prepared (new tracks, quality, or a
        /// seek the current stream can't reach), and the position it was
        /// asked for, if any.
        var pendingRestart: Int?
        var restartPosition: Double?
        /// A restart asked for while a commit was out, made once it lands,
        /// at this position if a seek gave one.
        var deferredRestart = false
        var deferredRestartPosition: Double?
    }

    enum EndReason: String, Equatable, Sendable {
        case routeLocal = "route_local"
        case receiverLost = "receiver_lost"
        case receiverFailed = "receiver_failed"
        case startTimedOut = "start_timed_out"
        case prepareTimedOut = "prepare_timed_out"
        case commitFailed = "commit_failed"
        case userStopped = "user_stopped"
        case loadReplaced = "load_replaced"
    }

    enum Event: Equatable {
        /// The output route includes AirPlay, and playback could be handed
        /// off. `route` identifies the receiver, so repeats are recognised.
        case airPlayRouteAppeared(route: String)
        case routeBecameLocal
        /// The viewer closed the AirPlay route picker, which may have been to
        /// pick the same receiver again.
        case routePickerClosed
        case probeExternalActive
        case probeTimedOut
        /// The probe couldn't run, so there's no answer; the next route
        /// change may try again.
        case probeFailed
        /// The receiver session took too long to prepare or commit.
        case prepareTimedOut
        /// `position` is where playback is when the stream arrives.
        case streamReady(request: Int, position: Double)
        case streamFailed(request: Int)
        /// The player can't hand off right now after all (Picture in
        /// Picture, Next Up, an error): back to idle, so the route is tried
        /// again once that clears.
        case handOffBlocked(request: Int)
        case commitFinished(request: Int, result: AirPlayReceiverCommit)
        /// Replace the receiver stream: new tracks or quality (`position`
        /// nil, use where playback is), or a seek the stream can't reach.
        /// While a commit is out it waits for the commit to land.
        case restartRequested(position: Double?)
        /// A seek during the hand-off. Any stream not yet on the player
        /// (being committed or prepared, or a restart waiting) starts there.
        case seekRequested(position: Double)
        /// The receiver's clock moved after the start.
        case playbackStarted
        case startTimedOut
        case externalLost
        case externalRestored
        /// External playback stayed off past the debounce, or (before the
        /// stream started) went off with the route no longer on AirPlay.
        /// `position` is the receiver's last position.
        case externalLostDebounced(position: Double)
        /// The receiver's item failed.
        case receiverFailed(position: Double)
        /// The receiver reached the end of the item.
        case playbackEnded
        case userStopped
        case loadReplaced
    }

    enum Effect: Equatable {
        case startProbe
        /// Tears the probe down without having touched Lucid.
        case stopProbe
        case requestStream(request: Int)
        case pauseAndMuteLucid
        /// Make this prepared receiver session live, retiring the live one
        /// at `at`.
        case commitStream(request: Int, at: Double)
        /// Put this stream on the receiver's player at `at`: once committed
        /// for the first stream, and before the commit for a restart, so the
        /// outgoing stream's session is only retired once nothing plays it.
        case startStream(request: Int, at: Double)
        /// Lucid comes back at `at` through a fresh load, which also starts a
        /// normal server session (the receiver session replaced the old one).
        case resumeLucid(at: Double)
        /// Lucid comes back where it paused, on its own session, which was
        /// never retired.
        case resumeLucidInPlace
        /// Leaves hand-off mode: the receiver player goes and Lucid is
        /// unmuted. Always comes before a resume.
        case endHandOff(EndReason)
        /// A prepared receiver session nothing will commit.
        case releaseStream(request: Int)
        /// The route is Lucid's again without a reload, so a route-dependent
        /// plan held back during the probe gets its check now.
        case recheckOutputRoute
    }

    private(set) var state: State = .idle
    private var nextRequest = 0

    /// True while the probe or hand-off owns the output route, so a route
    /// change mustn't replan Lucid's stream.
    var ownsOutputRoute: Bool {
        switch state {
        case .probing, .preparing, .active: true
        case .idle, .ending: false
        }
    }

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .streamReady(let request, let position):
            return streamArrived(request: request, position: position)
        case .streamFailed(let request):
            return streamFailed(request: request)
        case .handOffBlocked(let request):
            guard case .preparing(_, let current) = state, current == request else { return [] }
            state = .idle
            return [.stopProbe, .recheckOutputRoute]
        case .commitFinished(let request, let result):
            return commitFinished(request: request, result: result)
        default:
            break
        }
        switch state {
        case .idle:
            return handleIdle(event)
        case .probing(let route):
            return handleProbing(event, route: route)
        case .preparing(let route, _):
            return handlePreparing(event, route: route)
        case .active(let active):
            return handleActive(event, active: active)
        case .ending(let route):
            return handleEnding(event, route: route)
        }
    }

    private mutating func newRequest() -> Int {
        nextRequest &+= 1
        return nextRequest
    }

    // MARK: - States

    private mutating func handleIdle(_ event: Event) -> [Effect] {
        guard case .airPlayRouteAppeared(let route) = event else { return [] }
        state = .probing(route: route)
        return [.startProbe]
    }

    private mutating func handleProbing(_ event: Event, route: String) -> [Effect] {
        switch event {
        case .probeExternalActive:
            let request = newRequest()
            state = .preparing(route: route, request: request)
            return [.requestStream(request: request)]
        case .probeTimedOut:
            // A speaker: Lucid's audio is already going to it.
            state = .ending(route: route)
            return [.stopProbe, .recheckOutputRoute]
        case .probeFailed, .routeBecameLocal:
            state = .idle
            return [.stopProbe, .recheckOutputRoute]
        case .airPlayRouteAppeared(let newRoute) where newRoute != route:
            state = .probing(route: newRoute)
            return [.stopProbe, .startProbe]
        case .loadReplaced, .userStopped, .playbackEnded:
            state = .idle
            return [.stopProbe]
        default:
            return []
        }
    }

    /// Lucid still plays on its own session here, so leaving needs no resume.
    /// A stream that arrives afterwards is released.
    private mutating func handlePreparing(_ event: Event, route: String) -> [Effect] {
        switch event {
        case .routeBecameLocal:
            state = .idle
            return [.stopProbe, .recheckOutputRoute]
        case .airPlayRouteAppeared(let newRoute) where newRoute != route:
            state = .probing(route: newRoute)
            return [.stopProbe, .startProbe]
        case .externalLostDebounced, .prepareTimedOut:
            state = .ending(route: route)
            return [.stopProbe, .recheckOutputRoute]
        case .loadReplaced, .userStopped, .playbackEnded:
            state = .idle
            return [.stopProbe]
        default:
            return []
        }
    }

    private mutating func handleActive(_ event: Event, active: Active) -> [Effect] {
        var active = active
        switch event {
        case .playbackStarted:
            active.started = true
            state = .active(active)
            return []
        case .externalLost:
            guard active.started else { return [] }
            active.externalLost = true
            state = .active(active)
            return []
        case .externalRestored:
            active.externalLost = false
            state = .active(active)
            return []
        case .externalLostDebounced(let position):
            if active.started {
                guard active.externalLost else { return [] }
                return end(active, .receiverLost, resumeAt: position)
            }
            // Before the stream runs the player only reports a loss the route
            // confirms, so it ends at once rather than after the start timeout.
            return end(active, .receiverLost, resumeAt: active.startPosition)
        case .routeBecameLocal:
            // Once the stream runs, a local route on its own isn't trusted:
            // it can flicker while a receiver switches, and the receiver
            // dropping external playback is what ends it.
            guard !active.started else { return [] }
            let effects = end(active, .routeLocal, resumeAt: active.startPosition)
            state = .idle
            return effects
        case .receiverFailed(let position):
            return end(active, .receiverFailed, resumeAt: active.started ? position : active.startPosition)
        case .startTimedOut:
            guard !active.started else { return [] }
            return end(active, .startTimedOut, resumeAt: active.startPosition)
        case .prepareTimedOut:
            guard !active.committed else { return [] }
            return end(active, .prepareTimedOut, resumeAt: active.startPosition)
        case .restartRequested(let position):
            guard active.committed, active.pendingCommit == nil else {
                // A commit is out: the restart waits for it to land.
                active.deferredRestart = true
                if let position { active.deferredRestartPosition = position }
                state = .active(active)
                return []
            }
            if active.pendingRestart != nil, let position {
                // A stream is already being prepared; it starts at the seek.
                active.restartPosition = position
                state = .active(active)
                return []
            }
            return restart(&active, at: position ?? active.restartPosition)
        case .seekRequested(let position):
            if !active.committed {
                active.startPosition = position
                active.commitPosition = position
            } else if active.pendingCommit != nil {
                active.commitPosition = position
            }
            if active.pendingRestart != nil { active.restartPosition = position }
            if active.deferredRestart { active.deferredRestartPosition = position }
            state = .active(active)
            return []
        case .playbackEnded:
            // The receiver keeps the title paused at its end, so the normal
            // end (Next Up, Replay, a scrub back) runs against it. A next
            // item loads on Lucid and hands off again from there.
            return []
        case .userStopped:
            state = .idle
            return [.endHandOff(.userStopped)]
        case .loadReplaced:
            state = .idle
            return [.endHandOff(.loadReplaced)]
        case .airPlayRouteAppeared, .routePickerClosed, .probeExternalActive, .probeTimedOut, .probeFailed,
             .streamReady, .streamFailed, .handOffBlocked, .commitFinished:
            return []
        }
    }

    /// Asks for a replacement stream, releasing any older one still being
    /// prepared when it arrives.
    private mutating func restart(_ active: inout Active, at position: Double?) -> [Effect] {
        let request = newRequest()
        active.pendingRestart = request
        active.restartPosition = position
        active.deferredRestart = false
        active.deferredRestartPosition = nil
        state = .active(active)
        return [.requestStream(request: request)]
    }

    /// Makes a restart that waited for a commit.
    private mutating func takeDeferredRestart(_ active: inout Active) -> [Effect] {
        guard active.deferredRestart else {
            state = .active(active)
            return []
        }
        return restart(&active, at: active.deferredRestartPosition)
    }

    /// Ends the hand-off with Lucid resuming at `resumeAt`: through a fresh
    /// load once a receiver session has been committed (or may be, if a
    /// commit is still out), otherwise in place on its own session.
    private mutating func end(_ active: Active, _ reason: EndReason, resumeAt position: Double) -> [Effect] {
        state = .ending(route: active.route)
        let sessionChanged = active.committed || active.pendingCommit != nil
        return [.endHandOff(reason), sessionChanged ? .resumeLucid(at: position) : .resumeLucidInPlace]
    }

    private mutating func handleEnding(_ event: Event, route: String) -> [Effect] {
        switch event {
        case .airPlayRouteAppeared(let newRoute) where newRoute != route:
            state = .probing(route: newRoute)
            return [.startProbe]
        case .routeBecameLocal, .routePickerClosed:
            // A picker closed may mean the same receiver was picked again;
            // the next route check probes it afresh.
            state = .idle
            return []
        default:
            // A load (including the reload that ended a hand-off) keeps the
            // answer for this route.
            return []
        }
    }

    // MARK: - Streams

    private mutating func streamArrived(request: Int, position: Double) -> [Effect] {
        switch state {
        case .preparing(let route, let current) where current == request:
            state = .active(Active(route: route, startPosition: position, pendingCommit: request,
                                   commitPosition: position))
            return [.pauseAndMuteLucid, .commitStream(request: request, at: position)]
        case .active(var active) where active.pendingRestart == request:
            // Swap first, then commit: the outgoing stream's session is only
            // retired once the receiver has let go of it.
            let at = active.restartPosition ?? position
            active.pendingRestart = nil
            active.restartPosition = nil
            active.pendingCommit = request
            active.commitPosition = at
            active.startPosition = at
            active.started = false
            active.externalLost = false
            state = .active(active)
            return [.startStream(request: request, at: at), .commitStream(request: request, at: at)]
        default:
            // Overtaken: nothing will commit it, and the live session stays.
            return [.releaseStream(request: request)]
        }
    }

    private mutating func streamFailed(request: Int) -> [Effect] {
        switch state {
        case .preparing(let route, let current) where current == request:
            state = .ending(route: route)
            return [.stopProbe, .recheckOutputRoute]
        case .active(var active) where active.pendingRestart == request:
            // The current stream plays on.
            active.pendingRestart = nil
            active.restartPosition = nil
            state = .active(active)
            return []
        default:
            return []
        }
    }

    private mutating func commitFinished(request: Int, result: AirPlayReceiverCommit) -> [Effect] {
        guard case .active(var active) = state, active.pendingCommit == request else { return [] }
        active.pendingCommit = nil
        let isRestart = active.committed
        switch result {
        case .committed:
            active.committed = true
            guard !isRestart else {
                // The restart's stream is already on the player.
                return takeDeferredRestart(&active)
            }
            active.started = false
            active.externalLost = false
            active.startPosition = active.commitPosition
            let start = Effect.startStream(request: request, at: active.commitPosition)
            return [start] + takeDeferredRestart(&active)
        case .refused where !isRestart:
            // The first commit: Lucid's session was never retired.
            state = .ending(route: active.route)
            return [.endHandOff(.commitFailed), .resumeLucidInPlace]
        case .refused, .failed:
            // A refused restart has lost the stream already on the player.
            state = .ending(route: active.route)
            return [.endHandOff(.commitFailed), .resumeLucid(at: active.commitPosition)]
        }
    }
}
