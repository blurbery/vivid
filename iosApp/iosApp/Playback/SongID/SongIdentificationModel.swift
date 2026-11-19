import Foundation
import Observation
import ShazamKit

/// The player's "What's this song?": identifies the song playing when asked,
/// and saves it to the viewer's Shazam library when they ask for that.
///
/// Nothing happens until `identify()`: no sound is read and nothing is sent
/// to Shazam. Only a signature of the sound reaches Shazam, never the sound
/// itself, and nothing is saved without `saveToShazam()`.
@MainActor
@Observable
final class SongIdentificationModel {
    enum Phase: Equatable {
        case idle
        case listening
        case found(SongMatch)
        case notFound
        case failed(SongIdentificationFailure)
        /// Asked while the item couldn't be identified, for a reason that
        /// may pass, such as buffering.
        case refused(Unavailability)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed
    }

    /// Why the playing item can't be identified, for the panel to say.
    enum Unavailability: Equatable {
        /// The load hasn't started playing yet.
        case notReady
        /// The server is converting the stream, so the file Vivid would
        /// read isn't what is playing.
        case converted
        /// The audio track playing is a separate file.
        case externalAudio
        /// The item has no sound, or plays as music.
        case noSound
        /// A streamed file is buffering or low on buffer, and the player
        /// needs the connection more.
        case busy
    }

    /// What identification needs from the player at the moment it starts.
    struct Request {
        let sourceURL: URL
        let headers: [String: String]
        /// The sound stream playing, as mpv's `ff-index` gives it.
        let streamIndex: Int?
        /// The playhead on the player's clock.
        let transportSeconds: Double
    }

    enum Availability {
        case ready(Request)
        case unavailable(Unavailability)
    }

    /// The longest an attempt may listen before it gives up.
    static let timeLimit: Duration = .seconds(45)
    /// How far the playhead may stray from where an attempt started, beyond
    /// playing on, before it counts as a seek.
    static let seekTolerance = 3.0

    private(set) var phase: Phase = .idle
    /// Moves on when the load starts or ends. The player's own markers for
    /// that aren't observed, so `blockingReason` reads this to redraw a
    /// panel waiting for playback to start.
    private(set) var loadRevision = 0
    private(set) var saveState: SaveState = .idle

    /// Asked when identification starts and between its steps. It reads
    /// the playhead and the buffer, so views shouldn't read it.
    @ObservationIgnored var availability: () -> Availability = { .unavailable(.notReady) }
    /// The reasons that last for the whole load (a converted stream, an
    /// external audio track, no sound, no load yet), without the playhead
    /// or the buffer, so a view can read it without redrawing on every
    /// tick or flickering while playback buffers.
    @ObservationIgnored var lastingUnavailability: () -> Unavailability? = { .notReady }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Counts attempts, so an answer for one that was replaced is dropped.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private let identifier: @Sendable () -> SongIdentifier
    @ObservationIgnored private let openReader: @Sendable (Request) -> SongClipReader?
    @ObservationIgnored private let addToLibrary: @Sendable (SongMediaItem) async throws -> Void
    @ObservationIgnored private let timeLimit: Duration

    init(identifier: @escaping @Sendable () -> SongIdentifier = { SongIdentifier() },
         openReader: @escaping @Sendable (Request) -> SongClipReader? = SongIdentificationModel.openReader,
         addToLibrary: @escaping @Sendable (SongMediaItem) async throws -> Void = SongIdentificationModel.addToShazamLibrary,
         timeLimit: Duration = SongIdentificationModel.timeLimit) {
        self.identifier = identifier
        self.openReader = openReader
        self.addToLibrary = addToLibrary
        self.timeLimit = timeLimit
    }

    var isListening: Bool { phase == .listening }

    /// True when the song found can go in the Shazam library, which only
    /// takes songs from Shazam's own catalogue.
    var canSaveToShazam: Bool {
        if case let .found(match) = phase { return match.shazamID != nil }
        return false
    }

    /// Why identification can't start now, or nil when it can.
    var unavailability: Unavailability? {
        if case let .unavailable(reason) = availability() { return reason }
        return nil
    }

    /// Why the panel shouldn't offer identification at all for this load.
    /// Passing reasons only show once the viewer asks (`.refused`).
    var blockingReason: Unavailability? {
        _ = loadRevision
        return lastingUnavailability()
    }

    /// The load has started playing.
    func loadDidStart() {
        loadRevision &+= 1
    }

    /// Starts identifying the song at the playhead. Does nothing while an
    /// attempt is already listening.
    func identify() {
        guard !isListening else { return }
        let request: Request
        switch availability() {
        case let .ready(ready):
            request = ready
        case let .unavailable(reason):
            // Say why, rather than nothing happening. A song already found
            // is dropped: the panel shows one thing at a time.
            attempt += 1
            saveTask?.cancel()
            saveTask = nil
            saveState = .idle
            phase = .refused(reason)
            return
        }
        attempt += 1
        let current = attempt
        saveTask?.cancel()
        saveTask = nil
        saveState = .idle
        phase = .listening
        let identifier = identifier
        let openReader = openReader
        // Later steps only go ahead while the player could start one now,
        // on the same audio track and with no seek since: otherwise the
        // next step would read sound the viewer isn't hearing.
        let startedAt = ContinuousClock.now
        let mayReadMore: @Sendable () async -> Bool = { [weak self] in
            await MainActor.run {
                guard let self, self.attempt == current, case let .ready(now) = self.availability(),
                      now.sourceURL == request.sourceURL, now.streamIndex == request.streamIndex
                else { return false }
                let elapsed = (ContinuousClock.now - startedAt) / .seconds(1)
                let moved = now.transportSeconds - request.transportSeconds
                return moved >= -Self.seekTolerance && moved <= elapsed + Self.seekTolerance
            }
        }
        task = Task { [weak self] in
            let outcome: SongIdentificationOutcome
            if let reader = openReader(request) {
                outcome = await identifier().identify(reader: reader, at: request.transportSeconds, mayReadMore: mayReadMore)
            } else {
                outcome = .failed(.unreadable)
            }
            guard let self, self.attempt == current else { return }
            self.task = nil
            self.watchdog?.cancel()
            self.watchdog = nil
            switch outcome {
            case let .found(match): self.phase = .found(match)
            case .notFound: self.phase = .notFound
            case .failed(.cancelled): self.phase = .idle
            case let .failed(failure): self.phase = .failed(failure)
            }
        }
        let timeLimit = timeLimit
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeLimit)
            guard !Task.isCancelled, let self, self.attempt == current, self.isListening else { return }
            self.attempt += 1
            self.task?.cancel()
            self.task = nil
            self.watchdog = nil
            self.phase = .failed(.timedOut)
        }
    }

    /// Stops listening. A result already found stays.
    func cancel() {
        guard isListening else { return }
        attempt += 1
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        phase = .idle
    }

    /// Forgets everything: the item playing changed or the player closed.
    func reset() {
        loadRevision &+= 1
        attempt += 1
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        saveTask?.cancel()
        saveTask = nil
        phase = .idle
        saveState = .idle
    }

    /// Adds the song found to the viewer's synced Shazam library.
    func saveToShazam() {
        guard canSaveToShazam, case let .found(match) = phase, saveState == .idle || saveState == .failed else { return }
        saveState = .saving
        let current = attempt
        let addToLibrary = addToLibrary
        saveTask = Task { [weak self] in
            let saved: Bool
            do {
                try await addToLibrary(match.item)
                saved = true
            } catch {
                saved = false
            }
            guard let self, self.attempt == current, !Task.isCancelled else { return }
            self.saveTask = nil
            self.saveState = saved ? .saved : .failed
        }
    }

    // MARK: - Defaults

    nonisolated static func openReader(_ request: Request) -> SongClipReader? {
        let source: StillByteSource
        if request.sourceURL.isFileURL {
            guard let file = FileStillByteSource(url: request.sourceURL) else { return nil }
            source = file
        } else {
            let headers = KeyframeStillHeaders()
            headers.current = request.headers
            let server = HTTPStillByteSource(url: request.sourceURL, headers: { headers.current })
            // Sound is read straight through, so each request may as well
            // fetch the most a request may.
            server.noteKeyframeSize(HTTPStillByteSource.maximumBlockBytes)
            source = server
        }
        return SongClipReader(source: source, streamIndex: request.streamIndex)
    }

    nonisolated static func addToShazamLibrary(_ item: SongMediaItem) async throws {
        try await SHLibrary.default.addItems([item.value])
    }
}
