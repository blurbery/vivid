import Foundation

/// What song identification may know about the player. Everything is read
/// from state the player already publishes; the engine is never asked to
/// do anything.
extension PlayerViewModel {
    /// Seconds a streamed file must have buffered ahead before its sound is
    /// read for identification.
    static let songIdentificationMinimumBuffer = 10.0

    /// Hooks the song identification model up to this player. Called once,
    /// when the player is set up.
    func connectSongIdentification() {
        songIdentification.availability = { [weak self] in
            self?.songIdentificationAvailability ?? .unavailable(.notReady)
        }
        songIdentification.lastingUnavailability = { [weak self] in
            guard let self else { return .notReady }
            return songIdentificationLastingUnavailability
        }
    }

    /// The reasons that last for the whole load. Reads neither the playhead
    /// nor the buffer.
    private var songIdentificationLastingUnavailability: SongIdentificationModel.Unavailability? {
        guard !isDisposed, let epoch = activeVividLoadEpoch, startedVividLoadEpoch == epoch,
              vividPlaybackController.activeLoadEpoch == epoch,
              let spec = vividPlaybackController.activeSpec
        else { return .notReady }
        if spec.options.audioOnly { return .noSound }
        // A transcode or a server's HLS isn't the stored file, so the file
        // Vivid would read isn't what is playing.
        guard spec.playsStoredFile else { return .converted }
        let engine = vividEngine
        guard !engine.audioTracks.isEmpty else { return .noSound }
        let playing = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
        if playing?.isExternal == true { return .externalAudio }
        return nil
    }

    private var songIdentificationAvailability: SongIdentificationModel.Availability {
        if let lasting = songIdentificationLastingUnavailability { return .unavailable(lasting) }
        guard let spec = vividPlaybackController.activeSpec else { return .unavailable(.notReady) }
        let engine = vividEngine
        let playing = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
        // The player comes first: a streamed file isn't read while the
        // player is short of buffer. A download costs the connection nothing.
        // Near the end the buffer can only hold what is left.
        let remaining = duration > currentTime ? duration - currentTime : 0
        let wantedBuffer = min(Self.songIdentificationMinimumBuffer, max(remaining - 1, 0))
        if !spec.sourceURL.isFileURL,
           isBuffering || (playbackReadAheadSeconds.map { $0 < wantedBuffer } ?? false) {
            return .unavailable(.busy)
        }
        // The scrub bar and playhead are in source time; the file is read on
        // the loaded transport's clock.
        guard currentTime.isFinite, currentTime >= 0,
              case let .local(transportSeconds) = spec.timeline.seekDisposition(forSourceTime: currentTime)
        else { return .unavailable(.notReady) }
        return .ready(SongIdentificationModel.Request(
            sourceURL: spec.sourceURL,
            headers: spec.options.httpHeaders,
            streamIndex: playing?.sourceStreamIndex ?? playing?.id,
            transportSeconds: transportSeconds,
            playbackRate: isHoldFastForwarding ? max(settings.playbackSpeed, 2) : settings.playbackSpeed
        ))
    }
}
