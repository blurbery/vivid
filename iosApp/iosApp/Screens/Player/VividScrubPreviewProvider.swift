import CoreGraphics
import Foundation

/// Still frames over the scrub bar for the current load.
///
/// There are two sources. The server's own preview sheets
/// (``ScrubPreviewSheets``) come first, on iPhone, iPad and Apple TV: a still
/// is a crop of a sheet already in memory, so it's published the moment the
/// target moves. Where the server has none, iPhone and iPad fall back to
/// reading a frame from the stream, and Apple TV shows no still.
///
/// The controls scrub in source-media time. Sheets are indexed on that axis,
/// but the engine's frame reader works on the loaded transport's own clock.
/// Doing the conversion here, behind session and request counters, stops a
/// still from a Silo plan that has since been replaced from landing on the
/// next item. The reader opens the very URL and headers the load used.
@MainActor
final class VividScrubPreviewProvider {
    struct Preview {
        let image: CGImage
        let sourceTime: Double
    }

    /// Where a load's preview sheets come from. `key` names the server, item
    /// and file, so a new load of the same file keeps the sheets it has.
    struct SheetSource {
        let key: String
        let load: @MainActor () async -> ScrubPreviewSheets?
    }

    var onPreview: ((Preview?) -> Void)?

    /// One scrub target waiting for the frame reader, with the counters it
    /// was asked under.
    private struct Job {
        let sourceTime: Double
        let transportTime: Double
        let reader: FrameExtractor
        let session: UInt64
        let ticket: UInt64
    }

    /// The newest target that a sheet still on its way will answer.
    private struct SheetTarget {
        let sourceTime: Double
        let tile: ScrubPreviewSheets.Tile
    }

    /// How long a drag has to pause on a target before the reader decodes it.
    private static let settleDelay: Duration = .milliseconds(80)
    private static let stillWidth = 480

    private let engine: VividEngine
    private let makeStore: @MainActor (ScrubPreviewSheets) -> ScrubPreviewSheetStore
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

    /// The sheets of the file last loaded. They outlive a session end that
    /// asks to keep them, so a replan of the same file doesn't fetch again.
    private var store: ScrubPreviewSheetStore?
    /// Whether `store` belongs to the current load.
    private var storeIsLive = false
    private var sheetSource: SheetSource?
    private var sheetLoad: Task<Void, Never>?
    private var sheetTarget: SheetTarget?
    /// The scrub's current target, for sheets that arrive part-way through.
    private var scrubSourceTime: Double?
    /// When the last request for sheets came back with none.
    private var sheetLoadFailedAt: Date?
    /// Where playback is, so the first sheet a scrub needs can be fetched
    /// before the scrub starts.
    private var warmSourceTime: Double?

    init(
        engine: VividEngine,
        makeStore: @escaping @MainActor (ScrubPreviewSheets) -> ScrubPreviewSheetStore = { ScrubPreviewSheetStore(sheets: $0) }
    ) {
        self.engine = engine
        self.makeStore = makeStore
    }

    /// Starts previews for a load that has opened. `sheets` is nil for a
    /// source with no server previews, such as a download. The frame reader
    /// is given the load's URL and headers directly, so an authenticated Silo
    /// transport is read with the inputs `VividLoadSpec` already checked.
    func activate(_ spec: VividLoadSpec, sheets: SheetSource? = nil, startSourceTime: Double? = nil) {
        endSession(keepingSheets: true)
        session &+= 1
        load = spec
        sheetSource = sheets
        sheetLoadFailedAt = nil
        warmSourceTime = startSourceTime
        guard let sheets else {
            dropStore()
            return
        }
        if let store, store.sheets.key == sheets.key, !store.sheets.isExpiring() {
            storeIsLive = true
            warmStore()
        } else {
            dropStore()
            loadSheets(from: sheets)
        }
    }

    /// Opens one scrub and clears the last still.
    func begin(atSourceTime sourceTime: Double) {
        guard load != nil else { return }
        onPreview?(nil)
        refreshExpiringSheets()
        request(atSourceTime: sourceTime)
    }

    /// Asks for a still at the newest scrub target only.
    ///
    /// With server sheets, a decoded sheet answers at once and one still
    /// arriving answers the newest target when it lands. Without them, a
    /// short settle delay, one queued slot and retiring the reader as soon as
    /// the scrub ends keep a fast drag cheap. Either way a good request
    /// leaves the current still up until a newer one arrives, and a failure
    /// doesn't clear it. The counters are checked again before anything is
    /// published.
    ///
    /// A target the transport can't reach (mostly a scrub back past a
    /// re-anchored HLS plan's `timeline_offset_seconds`) gets no still from
    /// the reader. `playerPosition(forSourceTime:)` would clamp it to the
    /// transport's first frame and pass that off as the moment asked for;
    /// only a new server plan could reach it. Sheets cover the whole file,
    /// so they still have one.
    func request(atSourceTime sourceTime: Double) {
        guard sourceTime.isFinite, sourceTime >= 0 else {
            // Even a bad target replaces what was being decoded, so a stale
            // still can't land after it.
            supersedePending()
            return
        }
        guard load != nil else { return }
        scrubSourceTime = sourceTime
        if requestFromSheets(atSourceTime: sourceTime) { return }
        sheetTarget = nil
        requestFromReader(atSourceTime: sourceTime)
    }

    func endInteraction() {
        scrubSourceTime = nil
        supersedePending()
        retireReader()
    }

    /// Detaches the load straight away and starts shutting its reader down.
    /// The returned task lets the player's final cleanup wait for the
    /// reader's decode queue to stop without blocking the main actor.
    /// `keepingSheets` holds on to the file's preview sheets for a load of
    /// the same file that follows straight away.
    @discardableResult
    func endSession(keepingSheets: Bool = false) -> Task<Void, Never>? {
        session &+= 1
        endInteraction()
        load = nil
        sheetSource = nil
        sheetLoad?.cancel()
        sheetLoad = nil
        storeIsLive = false
        warmSourceTime = nil
        if !keepingSheets { dropStore() }
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

    // MARK: - Server sheets

    private func loadSheets(from source: SheetSource) {
        sheetLoad?.cancel()
        let expected = session
        sheetLoad = Task { @MainActor [weak self] in
            let sheets = await source.load()
            guard let self, self.session == expected, !Task.isCancelled else { return }
            self.sheetLoad = nil
            guard let sheets, sheets.key == source.key, !sheets.isExpiring() else {
                self.sheetLoadFailedAt = Date()
                return
            }
            self.sheetLoadFailedAt = nil
            self.dropStore()
            self.store = self.makeStore(sheets)
            self.storeIsLive = true
            self.warmStore()
            // A scrub that began while the sheets were on their way.
            if let pending = self.scrubSourceTime {
                self.request(atSourceTime: pending)
            }
        }
    }

    /// Signed sheet URLs stop working. Past that point the sheets already in
    /// memory keep serving while a fresh set is asked for.
    private func refreshExpiringSheets() {
        guard storeIsLive, let store, store.sheets.isExpiring(), sheetLoad == nil, let sheetSource else { return }
        if let sheetLoadFailedAt, Date().timeIntervalSince(sheetLoadFailedAt) < 30 { return }
        loadSheets(from: sheetSource)
    }

    /// Fetches the sheet around the playhead ahead of the first scrub.
    private func warmStore() {
        guard let store, let warmSourceTime, let tile = store.sheets.tile(atSourceTime: warmSourceTime) else { return }
        store.prefetch(tile.sheet)
    }

    /// True when the sheets own this target, even if its still isn't in yet.
    private func requestFromSheets(atSourceTime sourceTime: Double) -> Bool {
        guard storeIsLive, let store,
              let tile = store.sheets.tile(atSourceTime: sourceTime),
              !store.hasFailed(tile.sheet)
        else { return false }
        // Whatever the reader had queued or decoding is now out of date.
        ticket &+= 1
        queued = nil
        if let sheet = store.cached(tile.sheet) {
            sheetTarget = nil
            if let still = store.sheets.crop(tile, from: sheet) {
                onPreview?(Preview(image: still, sourceTime: sourceTime))
            }
        } else {
            let alreadyWaiting = sheetTarget?.tile.sheet == tile.sheet
            sheetTarget = SheetTarget(sourceTime: sourceTime, tile: tile)
            if !alreadyWaiting { fetchSheet(tile.sheet, from: store) }
        }
        // The sheets either side, so crossing into one costs no request.
        store.prefetch(tile.sheet - 1)
        store.prefetch(tile.sheet + 1)
        return true
    }

    private func fetchSheet(_ sheet: Int, from store: ScrubPreviewSheetStore) {
        let expected = session
        Task { @MainActor [weak self] in
            let image = await store.image(sheet)
            guard let self, self.session == expected, self.store === store,
                  let target = self.sheetTarget, target.tile.sheet == sheet
            else { return }
            self.sheetTarget = nil
            if let image, let still = store.sheets.crop(target.tile, from: image) {
                self.onPreview?(Preview(image: still, sourceTime: target.sourceTime))
            } else {
                // The sheet is marked as failed, so this goes to the reader.
                self.request(atSourceTime: target.sourceTime)
            }
        }
    }

    private func dropStore() {
        store?.shutdown()
        store = nil
        storeIsLive = false
        sheetTarget = nil
    }

    // MARK: - Frame reader

    private func requestFromReader(atSourceTime sourceTime: Double) {
        guard let spec = load else { return }
        guard case let .local(transportTime) = spec.timeline.seekDisposition(forSourceTime: sourceTime) else {
            supersedePending()
            return
        }
        if reader == nil {
            reader = engine.makeFrameExtractor(url: spec.sourceURL, httpHeaders: spec.options.httpHeaders)
        }
        // Apple TV has no frame reader, so it starts no worker either.
        guard let reader else {
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

    /// Fences off whatever is queued, decoding or on its way and clears the
    /// still.
    private func supersedePending() {
        ticket &+= 1
        queued = nil
        sheetTarget = nil
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

            let still = await job.reader.thumbnail(at: job.transportTime, maxWidth: Self.stillWidth)

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
