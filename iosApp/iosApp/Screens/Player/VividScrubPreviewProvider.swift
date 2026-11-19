import CoreGraphics
import Foundation

/// Still frames over the scrub bar for the current load.
///
/// There are two sources. The server's own preview sheets
/// (``ScrubPreviewSheets``) come first, on iPhone, iPad and Apple TV: a still
/// is a crop of a sheet already in memory, so it's published the moment the
/// target moves. Emby's stills, one JPEG each inside a container file, come
/// through the same store as sheets of a single cell. Where the server has none, iPhone and iPad fall back to
/// reading a frame from the stream, and Apple TV shows no still.
///
/// A third source sits behind a hidden switch that is off unless set:
/// ``KeyframeStillService`` makes stills from the file's own keyframes for
/// a load with no sheets and no working frame reader. The switch is read
/// once for each load, when its first frame is up; with it off none of it
/// is created, and every path into it returns on that one remembered
/// answer.
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
        let reader: any ScrubStillSource
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
    /// How long a still from another sheet may outstay a slow sheet.
    private static let staleStillGrace: Duration = .milliseconds(250)

    private let engine: VividEngine
    private let makeStore: @MainActor (ScrubPreviewSheets) -> ScrubPreviewSheetStore
    private let makeReader: @MainActor (VividLoadSpec) -> (any ScrubStillSource)?
    private var load: VividLoadSpec?
    private var reader: (any ScrubStillSource)?
    /// Moves on with every load and every session end.
    private var session: UInt64 = 0
    /// Moves on with every request, so only the newest one may publish.
    private var ticket: UInt64 = 0
    /// Only ever the latest target; a newer one replaces it.
    private var queued: Job?
    private var worker: Task<Void, Never>?
    private var readerShutdowns: [UUID: Task<Void, Never>] = [:]

    /// The sheets of the file last loaded. They outlive a session end that
    /// asks to keep them, so a replan, quality change or reloading seek of
    /// the same file doesn't fetch again.
    private var store: ScrubPreviewSheetStore?
    /// Whether `store` belongs to the current load.
    private var storeIsLive = false
    private var sheetSource: SheetSource?
    private var sheetLoad: Task<Void, Never>?
    private var sheetTarget: SheetTarget?
    /// The one sheet being fetched, so a fast drag never decodes several at
    /// once. The newest target is picked up when it lands.
    private var sheetFetch: UUID?
    /// The still on screen, so a target inside the same still publishes
    /// nothing new.
    private var shownTile: Int?
    /// Clears a still left over from another sheet when the new sheet is
    /// slow to arrive.
    private var staleStillClear: Task<Void, Never>?
    /// Whether this load has shown its first frame.
    private var hasStarted = false
    /// How many times this load has asked for its sheets.
    private var sheetLoadAttempts = 0
    /// The scrub's current target, for sheets that arrive part-way through.
    private var scrubSourceTime: Double?
    /// When the last request for sheets came back with none.
    private var sheetLoadFailedAt: Date?
    /// Where playback is, so the first sheet a scrub needs can be fetched
    /// before the scrub starts.
    private var warmSourceTime: Double?

    /// The player as the keyframe still service sees it, set directly by
    /// tests. With neither this nor `stillPlayerSource` the service is
    /// never made.
    var stillPlayer: KeyframeStillService.Player?
    /// Where the app gets that view: the view model, held weakly and asked
    /// only once the switch is known to be on.
    weak var stillPlayerSource: KeyframeStillPlayerSource?
    private let isStillSwitchOn: @MainActor () -> Bool
    private let makeStillEnvironment: @MainActor () -> KeyframeStillService.Environment
    /// Built the first time the switch is found on, never before.
    private var builtStillEnvironment: KeyframeStillService.Environment?
    /// The switch as it was at this load's first frame. False until then,
    /// so nothing to do with keyframe stills runs before it.
    private var stillsAreOn = false
    /// Makes the service a turn after the first frame's own.
    private var stillStart: Task<Void, Never>?
    /// On Apple TV the still isn't shown until the selection has moved, so
    /// nothing is read for the place a scrub began at.
    private let stillsWaitForMove: Bool
    /// Where the scrub began, until its target moves.
    private var scrubOrigin: Double?
    /// Whether this platform has a frame reader to try before keyframe
    /// stills. Where it has, the service waits until the reader has shown
    /// it can't read the load.
    private let expectsFrameReader: Bool
    /// The keyframe still service for this load, once it has started
    /// playing and every gate allows one.
    private var stillService: KeyframeStillService?
    private var stillShutdowns: [UUID: Task<Void, Never>] = [:]
    /// The frame reader said it can't take stills from this load.
    private var readerIsUnusable = false
    /// Asks a frame reader that gave no still whether it can read the load
    /// at all. Its own task, so that ending the session never waits on it.
    private var readerProbe: Task<Void, Never>?
    /// A scrub found no frame reader for this load.
    private var readerIsMissing = false
    /// The load can never have keyframe stills, so none is tried again.
    private var stillsAreRuledOut = false
    private var stillCarry: KeyframeStillService.Carry?

    init(
        engine: VividEngine,
        makeStore: @escaping @MainActor (ScrubPreviewSheets) -> ScrubPreviewSheetStore = { ScrubPreviewSheetStore(sheets: $0) },
        makeReader: (@MainActor (VividLoadSpec) -> (any ScrubStillSource)?)? = nil,
        stillSwitch: (@MainActor () -> Bool)? = nil,
        stills: @autoclosure @escaping @MainActor () -> KeyframeStillService.Environment = .init(),
        expectsFrameReader: Bool? = nil,
        stillsWaitForMove: Bool? = nil
    ) {
        self.engine = engine
        self.makeStore = makeStore
        self.makeReader = makeReader ?? { spec in
            engine.makeFrameExtractor(url: spec.sourceURL, httpHeaders: spec.options.httpHeaders)
        }
        isStillSwitchOn = stillSwitch ?? { KeyframeStillService.isSwitchedOn() }
        makeStillEnvironment = stills
        #if os(iOS)
        self.expectsFrameReader = expectsFrameReader ?? true
        self.stillsWaitForMove = stillsWaitForMove ?? false
        #else
        self.expectsFrameReader = expectsFrameReader ?? false
        self.stillsWaitForMove = stillsWaitForMove ?? true
        #endif
    }

    /// Readies previews for a load that has opened, without asking the
    /// server for anything yet (see `playbackStarted()`). `sheets` is nil for a
    /// source with no server previews, such as a download. The frame reader
    /// is given the load's URL and headers directly, so an authenticated Silo
    /// transport is read with the inputs `VividLoadSpec` already checked.
    func activate(_ spec: VividLoadSpec, sheets: SheetSource? = nil, startSourceTime: Double? = nil) {
        endSession(keepingSheets: true)
        session &+= 1
        load = spec
        sheetSource = sheets
        sheetLoadFailedAt = nil
        sheetLoadAttempts = 0
        warmSourceTime = startSourceTime
        hasStarted = false
        guard let sheets else {
            dropStore()
            return
        }
        // Nothing goes on the network here: this runs before the first
        // frame, and startup keeps the connection and the main thread to
        // itself. `playbackStarted()` does the asking.
        if let store, store.sheets.key == sheets.key, !store.sheets.isExpiring() {
            storeIsLive = true
        } else {
            dropStore()
        }
    }

    /// The load's first frame is up, so the sheet list and the sheet around
    /// the playhead can be fetched without getting in startup's way.
    func playbackStarted() {
        guard load != nil, !hasStarted else { return }
        hasStarted = true
        if storeIsLive {
            warmStore()
        } else if let sheetSource, sheetLoad == nil {
            loadSheets(from: sheetSource)
        }
        // The one place the hidden switch is read for this load. With it
        // off, nothing else in the keyframe path runs, here or anywhere.
        stillsAreOn = (stillPlayer != nil || stillPlayerSource != nil) && isStillSwitchOn()
        if stillsAreOn {
            // Not in the first frame's own turn: the service, its observers
            // and its timer are made in the next one.
            let expected = session
            stillStart = Task { @MainActor [weak self] in
                guard let self, self.session == expected, !Task.isCancelled else { return }
                self.stillStart = nil
                // A scrub already going gets its answer from the service.
                if self.startStillService(), self.sheetLoad == nil, let pending = self.scrubSourceTime {
                    self.request(atSourceTime: pending)
                }
            }
        }
        // A scrub that began before the first frame. With a sheet list on
        // its way, the list answers it when it lands, and where only the
        // keyframe service could, the service does once it is made.
        if sheetLoad == nil, let pending = scrubSourceTime, !stillsAreOn || expectsFrameReader {
            request(atSourceTime: pending)
        }
    }

    /// Opens one scrub and clears the last still.
    func begin(atSourceTime sourceTime: Double) {
        guard load != nil else { return }
        onPreview?(nil)
        shownTile = nil
        stillService?.clearTarget()
        refreshSheetsIfNeeded()
        scrubOrigin = stillsWaitForMove ? sourceTime : nil
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
        scrubOrigin = nil
        store?.setScrubbing(false)
        supersedePending()
        retireReader()
        // The still service keeps its reader for the load.
        stillService?.endScrub()
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
        hasStarted = false
        // A fetch still running belongs to the load that just ended. It's
        // disowned here, so the next load's first target starts its own
        // (the store shares the download) instead of waiting on one that
        // will never answer it.
        sheetFetch = nil
        warmSourceTime = nil
        if !keepingSheets { dropStore() }
        stillStart?.cancel()
        stillStart = nil
        stillsAreOn = false
        // Cancelled and left behind: the task returned below never waits
        // on an asset load.
        readerProbe?.cancel()
        readerProbe = nil
        retireStillService()
        readerIsUnusable = false
        readerIsMissing = false
        stillsAreRuledOut = false
        // Read after `endInteraction()`, so the reader it just retired is
        // waited for too.
        let shutdowns = Array(readerShutdowns.values) + Array(stillShutdowns.values)
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
        sheetLoadAttempts += 1
        let expected = session
        sheetLoad = Task { @MainActor [weak self] in
            let sheets = await source.load()
            guard let self, self.session == expected, !Task.isCancelled else { return }
            self.sheetLoad = nil
            guard let sheets, sheets.key == source.key, !sheets.isExpiring() else {
                self.sheetLoadFailedAt = Date()
                self.startStillService()
                // A scrub that was waiting on the list goes to the frame
                // reader instead, where there is one.
                if self.store == nil, let pending = self.scrubSourceTime {
                    self.request(atSourceTime: pending)
                }
                return
            }
            self.sheetLoadFailedAt = nil
            // Sheets win: a keyframe service started while there were none
            // goes.
            self.retireStillService()
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
    /// memory keep serving while a fresh set is asked for. A load whose
    /// sheets never arrived asks again, twice at most, in case the first
    /// request only failed in passing.
    private func refreshSheetsIfNeeded() {
        guard hasStarted, sheetLoad == nil, let sheetSource else { return }
        if let sheetLoadFailedAt, Date().timeIntervalSince(sheetLoadFailedAt) < 30 { return }
        if storeIsLive, let store {
            guard store.sheets.isExpiring() else { return }
        } else {
            guard sheetLoadAttempts < 3 else { return }
        }
        loadSheets(from: sheetSource)
    }

    /// Fetches the sheet around the playhead ahead of the first scrub.
    private func warmStore() {
        guard let store, let warmSourceTime, let tile = store.sheets.tile(atSourceTime: warmSourceTime) else { return }
        store.prefetch(tile.sheet)
    }

    /// True when the sheets own this target, even if its still isn't in yet.
    private func requestFromSheets(atSourceTime sourceTime: Double) -> Bool {
        // Until the first frame is up a scrub gets nothing, from the sheets
        // here or from the frame reader, so even an early scrub can't put
        // requests in startup's way.
        guard hasStarted, storeIsLive, let store,
              let tile = store.sheets.tile(atSourceTime: sourceTime),
              !store.hasFailed(tile.sheet)
        else { return false }
        // Whatever the reader had queued or decoding is now out of date.
        ticket &+= 1
        queued = nil
        store.setScrubbing(true)
        if let sheet = store.cached(tile.sheet) {
            sheetTarget = nil
            guard publish(tile, from: sheet, in: store, sourceTime: sourceTime) else {
                store.markFailed(tile.sheet)
                return false
            }
        } else {
            sheetTarget = SheetTarget(sourceTime: sourceTime, tile: tile)
            // The wanted sheet's download starts ahead of its neighbours'.
            store.prefetch(tile.sheet)
            if sheetFetch == nil { fetchSheet(tile.sheet, from: store) }
            clearStaleStillIfSlow()
        }
        // The sheets either side, so crossing into one costs no request.
        store.prefetch(tile.sheet - 1)
        store.prefetch(tile.sheet + 1)
        return true
    }

    /// Publishes the tile's still unless it's the one already showing. False
    /// when the sheet can't be cropped on its grid.
    private func publish(
        _ tile: ScrubPreviewSheets.Tile,
        from sheet: CGImage,
        in store: ScrubPreviewSheetStore,
        sourceTime: Double
    ) -> Bool {
        staleStillClear?.cancel()
        staleStillClear = nil
        if shownTile == tile.index { return true }
        guard let still = store.sheets.crop(tile, from: sheet) else { return false }
        shownTile = tile.index
        onPreview?(Preview(image: still, sourceTime: sourceTime))
        return true
    }

    /// A still from the sheet just left stays up while the next sheet
    /// decodes, which is too brief to notice. On a slow connection it would
    /// sit there while the time moves on, so it's cleared after a moment.
    private func clearStaleStillIfSlow() {
        guard shownTile != nil, staleStillClear == nil else { return }
        staleStillClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.staleStillGrace)
            guard let self, !Task.isCancelled else { return }
            self.staleStillClear = nil
            guard self.sheetTarget != nil, self.shownTile != nil else { return }
            self.shownTile = nil
            self.onPreview?(nil)
        }
    }

    /// One sheet at a time. When it lands, the newest target decides what
    /// happens next: publish from it, or fetch the sheet the drag has since
    /// moved to.
    private func fetchSheet(_ sheet: Int, from store: ScrubPreviewSheetStore) {
        let fetch = UUID()
        sheetFetch = fetch
        let expected = session
        Task { @MainActor [weak self] in
            let image = await store.image(sheet)
            guard let self, self.sheetFetch == fetch else { return }
            self.sheetFetch = nil
            guard self.session == expected, self.store === store, self.storeIsLive,
                  let target = self.sheetTarget
            else { return }
            if target.tile.sheet != sheet {
                // The drag moved on while this one was on its way.
                self.request(atSourceTime: target.sourceTime)
                return
            }
            self.sheetTarget = nil
            if let image, self.publish(target.tile, from: image, in: store, sourceTime: target.sourceTime) {
                return
            }
            // Marked as failed, so this target goes to the frame reader.
            store.markFailed(sheet)
            self.request(atSourceTime: target.sourceTime)
        }
    }

    private func dropStore() {
        store?.shutdown()
        store = nil
        storeIsLive = false
        sheetTarget = nil
        sheetFetch = nil
        shownTile = nil
        staleStillClear?.cancel()
        staleStillClear = nil
    }

    // MARK: - Frame reader

    private func requestFromReader(atSourceTime sourceTime: Double) {
        guard let spec = load else { return }
        // The reader opens the stream a second time, so it waits for the
        // first frame like the sheets do.
        guard hasStarted else {
            supersedePending()
            return
        }
        if startStillService() {
            requestFromStills(atSourceTime: sourceTime)
            return
        }
        guard case let .local(transportTime) = spec.timeline.seekDisposition(forSourceTime: sourceTime) else {
            supersedePending()
            return
        }
        if reader == nil, !readerIsUnusable {
            reader = makeReader(spec)
        }
        // Apple TV has no frame reader, so it starts no worker either.
        guard let reader else {
            readerIsMissing = true
            if startStillService() {
                requestFromStills(atSourceTime: sourceTime)
            } else {
                supersedePending()
            }
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
        shownTile = nil
        staleStillClear?.cancel()
        staleStillClear = nil
        stillService?.clearTarget()
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

            if still == nil, job.session == session, stillsAreOn, !readerIsUnusable {
                probe(job.reader)
            }
            guard job.session == session, job.ticket == ticket, let still else { continue }
            shownTile = nil
            onPreview?(Preview(image: still, sourceTime: job.sourceTime))
        }
    }

    /// Asks a reader that gave no still whether it can read the load at
    /// all, and hands the load to the keyframe service if it can't. The
    /// question may wait on AVFoundation loading the asset, so it runs on
    /// its own: the worker goes on, and `endSession` cancels it and never
    /// waits for it.
    private func probe(_ asked: any ScrubStillSource) {
        guard readerProbe == nil else { return }
        let expected = session
        readerProbe = Task { @MainActor [weak self] in
            let canRead = await asked.canProduceStills()
            guard let self, !Task.isCancelled, self.session == expected else { return }
            self.readerProbe = nil
            guard !canRead else { return }
            // AVFoundation can't read this file at all. The keyframe
            // service takes the load from here, where it may.
            self.readerIsUnusable = true
            self.retireReader()
            if self.startStillService(), let pending = self.scrubSourceTime {
                self.request(atSourceTime: pending)
            }
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

    // MARK: - Keyframe stills

    /// The environment the service runs in, built on first use.
    private var stills: KeyframeStillService.Environment {
        if let builtStillEnvironment { return builtStillEnvironment }
        let made = makeStillEnvironment()
        builtStillEnvironment = made
        return made
    }

    /// True when this load has a keyframe still service that may answer,
    /// making one if it has none yet and every gate allows it: the hidden
    /// switch, no server sheets, and the service's own (see
    /// `KeyframeStillService.gate`). Never before the load's first frame.
    ///
    /// Where the platform has a frame reader, the service is made standing
    /// by: it counts steady play and does nothing else until the reader has
    /// shown it can't read the load. Were it only made then, in the middle
    /// of a scrub, its wait for steady play could not even begin until the
    /// scrub was over.
    @discardableResult
    private func startStillService() -> Bool {
        // The switch as read at the first frame. Off, or not read yet:
        // nothing else is looked at.
        guard stillsAreOn, stillStart == nil else { return false }
        let readerIsOut = !expectsFrameReader || readerIsUnusable || readerIsMissing
        if let stillService {
            if !stillService.isFinished {
                if readerIsOut { stillService.leaveStandby() }
                return !stillService.isStandingBy
            }
            // It ended itself: the file turned out to be one it can't read.
            retireStillService()
        }
        guard hasStarted, !stillsAreRuledOut, let spec = load,
              let player = stillPlayer ?? stillPlayerSource?.keyframeStillPlayer
        else { return false }
        let hasSheets = storeIsLive || sheetLoad != nil || (sheetSource != nil && sheetLoadFailedAt == nil)
        stillService = KeyframeStillService.makeIfEligible(
            for: spec, hasServerSheets: hasSheets, player: player, environment: stills, carried: stillCarry,
            standingBy: !readerIsOut)
        return stillService != nil && readerIsOut
    }

    /// Hands the target to the keyframe service. What it already holds
    /// answers in this call; a still read for it lands later, behind the
    /// same counters as the frame reader's.
    private func requestFromStills(atSourceTime sourceTime: Double) {
        guard let stillService else { return }
        ticket &+= 1
        queued = nil
        staleStillClear?.cancel()
        staleStillClear = nil
        if shownTile != nil {
            // A sheet's still mustn't outlive the sheet that failed.
            shownTile = nil
            stillService.clearTarget()
            onPreview?(nil)
        }
        if let origin = scrubOrigin {
            // The selection hasn't moved from where the scrub began, so no
            // still would be shown: nothing is asked for yet.
            if sourceTime == origin { return }
            scrubOrigin = nil
        }
        let expectedSession = session, expectedTicket = ticket
        let answer = stillService.request(atSourceTime: sourceTime) { [weak self] image, target in
            guard let self, self.session == expectedSession, self.ticket == expectedTicket else { return }
            self.onPreview?(image.map { Preview(image: $0, sourceTime: target) })
        }
        switch answer {
        case let .still(image): onPreview?(Preview(image: image, sourceTime: sourceTime))
        case .cleared: onPreview?(nil)
        case .unchanged: break
        }
    }

    #if DEBUG
    /// Tests only.
    var debugStillService: KeyframeStillService? { stillService }
    #endif

    private func retireStillService() {
        guard let retiring = stillService else { return }
        stillService = nil
        stillCarry = retiring.carry
        if retiring.isRuledOut { stillsAreRuledOut = true }
        guard let shutdown = retiring.shutdown() else { return }
        let key = UUID()
        stillShutdowns[key] = Task { @MainActor [weak self] in
            await shutdown.value
            self?.stillShutdowns[key] = nil
        }
    }
}
