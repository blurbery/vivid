import Foundation

/// Protocol V3's timeline as the engine sees it.
///
/// The engine's load and clock use the transport (player) axis; Silo's
/// progress, chapters, markers and commands use the source media axis. Doing
/// the conversion in one value keeps an HLS re-anchor from leaking into the
/// rest of the player as an ad-hoc offset.
struct PlaybackTimelineMapper: Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case nonFinite(field: String)
        case negative(field: String)
        case invalidSeekWindow
        case unsupportedSeekRestoration(String)
    }

    enum SeekDisposition: Equatable {
        /// The loaded source can seek here.
        case local(playerSeconds: Double)
        /// The server must issue a plan whose transport contains this source
        /// position before the engine loads again.
        case replan(sourceSeconds: Double)
    }

    let sourceStartSeconds: Double
    let streamOriginSeconds: Double
    let playerStartSeconds: Double
    let timelineOffsetSeconds: Double
    let seekWindowStartSeconds: Double?
    let seekWindowEndSeconds: Double?
    let canSeekAnywhere: Bool
    let seekRestoration: String

    /// A source played as it is, where both axes are the same.
    init(directStartSeconds: Double) {
        let start = directStartSeconds.isFinite ? max(0, directStartSeconds) : 0
        sourceStartSeconds = start
        streamOriginSeconds = 0
        playerStartSeconds = start
        timelineOffsetSeconds = 0
        seekWindowStartSeconds = nil
        seekWindowEndSeconds = nil
        canSeekAnywhere = true
        seekRestoration = "player_position"
    }

    /// A plan's timeline. Every time must be finite and non-negative, the
    /// seek window in order, and the restoration one this client knows.
    init(validating timeline: PlaybackV3Timeline) throws {
        let fields: [(String, Double?)] = [
            ("source_start_seconds", timeline.sourceStartSeconds),
            ("stream_origin_seconds", timeline.streamOriginSeconds),
            ("player_start_seconds", timeline.playerStartSeconds),
            ("timeline_offset_seconds", timeline.timelineOffsetSeconds),
            ("seek_window_start_seconds", timeline.seekWindowStartSeconds),
            ("seek_window_end_seconds", timeline.seekWindowEndSeconds),
        ]
        for case let (field, value?) in fields {
            guard value.isFinite else { throw ValidationError.nonFinite(field: field) }
            guard value >= 0 else { throw ValidationError.negative(field: field) }
        }
        if let start = timeline.seekWindowStartSeconds, let end = timeline.seekWindowEndSeconds, start > end {
            throw ValidationError.invalidSeekWindow
        }
        guard ["player_position", "source_position"].contains(timeline.seekRestoration) else {
            throw ValidationError.unsupportedSeekRestoration(timeline.seekRestoration)
        }

        sourceStartSeconds = timeline.sourceStartSeconds
        streamOriginSeconds = timeline.streamOriginSeconds
        playerStartSeconds = timeline.playerStartSeconds
        timelineOffsetSeconds = timeline.timelineOffsetSeconds
        seekWindowStartSeconds = timeline.seekWindowStartSeconds
        seekWindowEndSeconds = timeline.seekWindowEndSeconds
        canSeekAnywhere = timeline.canSeekAnywhere
        seekRestoration = timeline.seekRestoration
    }

    /// The position the engine loads at: the plan's player coordinate, not
    /// its source one.
    var vividStartPosition: Double { playerStartSeconds }

    func sourcePosition(forPlayerTime playerSeconds: Double) -> Double {
        guard playerSeconds.isFinite else { return sourceStartSeconds }
        return max(0, playerSeconds + timelineOffsetSeconds)
    }

    func playerPosition(forSourceTime sourceSeconds: Double) -> Double {
        guard sourceSeconds.isFinite else { return playerStartSeconds }
        return max(0, sourceSeconds - timelineOffsetSeconds)
    }

    /// A sidecar cue time on the player axis. Artefact times count from the
    /// artefact's own source origin, which can differ from the plan's.
    func playerPosition(forArtifactTime artifactSeconds: Double, timingOriginSeconds: Double) -> Double {
        guard artifactSeconds.isFinite, timingOriginSeconds.isFinite else { return playerStartSeconds }
        return playerPosition(forSourceTime: artifactSeconds + timingOriginSeconds)
    }

    /// The earliest source position this transport can reach. Player time is
    /// `source - timelineOffsetSeconds`, so anything earlier has no
    /// non-negative player time, whatever the seek window says.
    var earliestLocalSourceSeconds: Double { timelineOffsetSeconds }

    /// Whether the loaded source can seek to a source position. A target
    /// before the transport's offset always needs a new plan: a re-anchored
    /// transport often has no seek window, and seeking locally would clamp
    /// to the transport's origin instead of the requested moment.
    func seekDisposition(forSourceTime requestedSeconds: Double) -> SeekDisposition {
        let sourceSeconds = requestedSeconds.isFinite ? max(0, requestedSeconds) : sourceStartSeconds
        if sourceSeconds < earliestLocalSourceSeconds || !canSeekAnywhere {
            return .replan(sourceSeconds: sourceSeconds)
        }
        if let start = seekWindowStartSeconds, sourceSeconds < start {
            return .replan(sourceSeconds: sourceSeconds)
        }
        if let end = seekWindowEndSeconds, sourceSeconds > end {
            return .replan(sourceSeconds: sourceSeconds)
        }
        return .local(playerSeconds: playerPosition(forSourceTime: sourceSeconds))
    }
}
