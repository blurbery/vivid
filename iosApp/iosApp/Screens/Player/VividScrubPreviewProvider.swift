import CoreGraphics
import Foundation

/// Still frames over the scrub bar for the current load, on iPhone and iPad.
///
/// The controls scrub in source-media time, but the engine's frame reader
/// works on the loaded transport's own clock. Doing the conversion here,
/// behind session and request counters, stops a still from a Silo plan that
/// has since been replaced from landing on the next item. The reader opens
/// the very URL and headers the load used. Apple TV shows no thumbnails, so
/// there nothing is ever started.
@MainActor
final class VividScrubPreviewProvider {
    struct Preview {
        let image: CGImage
        let sourceTime: Double
    }

    var onPreview: ((Preview?) -> Void)?

    /// One scrub target waiting for the worker, with the counters it was
    /// asked under.
    private struct Job {
        let sourceTime: Double
        let transportTime: Double
        let reader: FrameExtractor?
        let session: UInt64
        let ticket: UInt64
    }

    /// How long a drag has to pause on a target before it's decoded.
    private static let settleDelay: Duration = .milliseconds(80)
    private static let stillWidth = 480

    private let engine: VividEngine
    private var load: VividLoadSpec?
    private var reader: FrameExtractor?
    /// Moves on with every load and every session end.
    private var session: UInt64 = 0
    /// Moves on with every request, so only the newest one may publish.
    private var ticket: UInt64 = 0
    /// Only ever the latest target; a newer one replaces it.
    private var queued: Job?
    private var worker: Task<Void, Never>?
    private var readerShutdowns: [UUID: Task<Void, Never>] = [:]

    init(engine: VividEngine) {
        self.engine = engine
    }

    /// Starts previews for a load that has opened. The reader is given the
    /// load's URL and headers directly, so an authenticated Silo transport is
    /// read with the inputs `VividLoadSpec` already checked.
    func activate(_ spec: VividLoadSpec) {
        endSession()
        // Apple TV scrubs its timeline without any thumbnail work.
        #if !os(tvOS)
        session &+= 1
        load = spec
        reader = openReader(for: spec)
        #endif
    }

    /// Opens one scrub: clears the last still, and opens a new reader when
    /// the previous scrub retired it.
    func begin(atSourceTime sourceTime: Double) {
        guard let spec = load else { return }
        onPreview?(nil)
        if reader == nil {
            reader = openReader(for: spec)
        }
        request(atSourceTime: sourceTime)
    }

    /// Asks for a still at the newest scrub target only. A short settle
    /// delay, one queued slot and retiring the reader as soon as the scrub
    /// ends keep a fast drag cheap. A good request leaves the current still
    /// up until a newer one arrives, and a failed decode doesn't clear it.
    /// Both counters are checked again before anything is published.
    ///
    /// A target the transport can't reach (mostly a scrub back past a
    /// re-anchored HLS plan's `timeline_offset_seconds`) gets no still.
    /// `playerPosition(forSourceTime:)` would clamp it to the transport's
    /// first frame and pass that off as the moment asked for; only a new
    /// server plan could reach it.
    func request(atSourceTime sourceTime: Double) {
        guard sourceTime.isFinite, sourceTime >= 0 else {
            // Even a bad target replaces what was being decoded, so a stale
            // still can't land after it.
            supersedePending()
            return
        }
        guard let spec = load else { return }
        guard case let .local(transportTime) = spec.timeline.seekDisposition(forSourceTime: sourceTime) else {
            supersedePending()
            return
        }
        ticket &+= 1
        queued = Job(
            sourceTime: sourceTime,
            transportTime: transportTime,
            reader: reader,
            session: session,
            ticket: ticket
        )
        startWorkerIfIdle()
    }

    func endInteraction() {
        supersedePending()
        retireReader()
    }

    /// Detaches the load straight away and starts shutting its reader down.
    /// The returned task lets the player's final cleanup wait for the
    /// reader's decode queue to stop without blocking the main actor.
    @discardableResult
    func endSession() -> Task<Void, Never>? {
        session &+= 1
        endInteraction()
        load = nil
        // Read after `endInteraction()`, so the reader it just retired is
        // waited for too.
        let shutdowns = Array(readerShutdowns.values)
        let runningWorker = worker
        if shutdowns.isEmpty, runningWorker == nil { return nil }
        return Task {
            for shutdown in shutdowns {
                await shutdown.value
            }
            await runningWorker?.value
        }
    }

    private func openReader(for spec: VividLoadSpec) -> FrameExtractor? {
        engine.makeFrameExtractor(url: spec.sourceURL, httpHeaders: spec.options.httpHeaders)
    }

    /// Fences off whatever is queued or decoding and clears the still.
    private func supersedePending() {
        ticket &+= 1
        queued = nil
        onPreview?(nil)
    }

    private func startWorkerIfIdle() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            await self?.drainQueue()
        }
    }

    /// The single worker means at most one decode or reader pull runs at a
    /// time. Requests made while it waits overwrite the one queued slot, so
    /// a drag never has more than one decode running and one target waiting.
    private func drainQueue() async {
        defer { worker = nil }
        while queued != nil {
            try? await Task.sleep(for: Self.settleDelay)
            guard let job = queued else { continue }
            queued = nil
            guard job.session == session else { continue }

            let still = await job.reader?.thumbnail(at: job.transportTime, maxWidth: Self.stillWidth)

            guard job.session == session, job.ticket == ticket, let still else { continue }
            onPreview?(Preview(image: still, sourceTime: job.sourceTime))
        }
    }

    private func retireReader() {
        guard let retiring = reader else { return }
        reader = nil
        let key = UUID()
        readerShutdowns[key] = Task { @MainActor [weak self] in
            await retiring.shutdown()
            self?.readerShutdowns[key] = nil
        }
    }
}
