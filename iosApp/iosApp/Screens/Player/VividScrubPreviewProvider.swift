import CoreGraphics
import Foundation

/// Scrub preview stills for the current load, on iPhone and iPad.
///
/// The controls work in source-media time, while the engine's frame
/// extractor works on the loaded transport's own timeline. Keeping the
/// conversion and the generation fences here stops a late frame from a
/// replaced Silo plan appearing over the next item. The extractor reads the
/// exact URL and headers the load was opened with. Apple TV shows no
/// thumbnails, so there it never starts.
@MainActor
final class VividScrubPreviewProvider {
    struct Preview {
        let image: CGImage
        let sourceTime: Double
    }

    var onPreview: ((Preview?) -> Void)?

    private static let requestDebounce: Duration = .milliseconds(80)
    private static let thumbnailWidth = 480

    private struct PendingRequest {
        let sourceTime: Double
        let playerTime: Double
        let extractor: FrameExtractor?
        let sessionGeneration: UInt64
        let requestGeneration: UInt64
    }

    private let engine: VividEngine
    private var activeSpec: VividLoadSpec?
    private var extractor: FrameExtractor?
    private var sessionGeneration: UInt64 = 0
    private var requestGeneration: UInt64 = 0
    private var pendingRequest: PendingRequest?
    private var workerTask: Task<Void, Never>?
    private var shutdownTasks: [UUID: Task<Void, Never>] = [:]

    init(engine: VividEngine) {
        self.engine = engine
    }

    /// Binds previews to a load that has opened. The extractor gets the
    /// load's URL and headers explicitly, so an authenticated Silo transport
    /// is read with the same inputs `VividLoadSpec` checked.
    func activate(_ spec: VividLoadSpec) {
        endSession()
        // Apple TV keeps timeline scrubbing without any thumbnail work.
        #if !os(tvOS)
        sessionGeneration &+= 1
        activeSpec = spec
        extractor = engine.makeFrameExtractor(
            url: spec.sourceURL,
            httpHeaders: spec.options.httpHeaders
        )
        #endif
    }

    /// Starts one interaction, clearing the previous still and opening a
    /// fresh extractor if the last interaction retired it.
    func begin(atSourceTime sourceTime: Double) {
        guard let spec = activeSpec else { return }
        onPreview?(nil)
        if extractor == nil {
            extractor = engine.makeFrameExtractor(url: spec.sourceURL, httpHeaders: spec.options.httpHeaders)
        }
        request(atSourceTime: sourceTime)
    }

    /// Requests only the latest scrub target. The short trailing debounce,
    /// the single pending slot and the prompt extractor shutdown bound the
    /// work during a fast drag. A valid request keeps the last still up until
    /// a newer one succeeds; a miss doesn't clear it. Session and request
    /// generations both fence late results before they're published.
    ///
    /// A target the loaded transport can't reach (chiefly a scrub back before
    /// a re-anchored HLS plan's `timeline_offset_seconds`) publishes no still.
    /// Converting it with `playerPosition(forSourceTime:)` would clamp to the
    /// transport's first frame and show that as the requested moment. Only a
    /// server replan could produce a transport that holds it.
    func request(atSourceTime sourceTime: Double) {
        guard sourceTime.isFinite, sourceTime >= 0 else {
            // An invalid target still supersedes whatever was decoding: fence
            // the in-flight result and clear the published preview, or a stale
            // frame can land after this newer request.
            requestGeneration &+= 1
            pendingRequest = nil
            onPreview?(nil)
            return
        }
        guard let spec = activeSpec else {
            return
        }

        requestGeneration &+= 1
        guard case let .local(playerTime) = spec.timeline.seekDisposition(
            forSourceTime: sourceTime
        ) else {
            pendingRequest = nil
            onPreview?(nil)
            return
        }
        pendingRequest = PendingRequest(
            sourceTime: sourceTime,
            playerTime: playerTime,
            extractor: extractor,
            sessionGeneration: sessionGeneration,
            requestGeneration: requestGeneration
        )
        if workerTask == nil {
            workerTask = Task { @MainActor [weak self] in
                await self?.runRequestWorker()
            }
        }
    }

    func endInteraction() {
        requestGeneration &+= 1
        pendingRequest = nil
        onPreview?(nil)
        retireExtractor()
    }

    /// Detaches the active load immediately and begins prompt asynchronous
    /// teardown. The returned task lets final player cleanup await the
    /// extractor's decode-queue shutdown without blocking the main actor.
    @discardableResult
    func endSession() -> Task<Void, Never>? {
        sessionGeneration &+= 1
        endInteraction()
        activeSpec = nil
        let extractorShutdowns = Array(shutdownTasks.values)
        let requestWorker = workerTask
        guard !extractorShutdowns.isEmpty || requestWorker != nil else { return nil }
        return Task {
            for task in extractorShutdowns {
                await task.value
            }
            await requestWorker?.value
        }
    }

    /// One worker means at most one cache decode or independent-reader pull
    /// is in flight. Requests arriving during that await replace the single
    /// pending slot, so a drag is bounded to one active + one latest target.
    private func runRequestWorker() async {
        defer { workerTask = nil }
        while pendingRequest != nil {
            try? await Task.sleep(for: Self.requestDebounce)
            guard let request = pendingRequest else { continue }
            pendingRequest = nil
            guard sessionGeneration == request.sessionGeneration else { continue }

            let playerTime = request.playerTime
            let image: CGImage?
            if let extractor = request.extractor {
                image = await extractor.thumbnail(at: playerTime, maxWidth: Self.thumbnailWidth)
            } else {
                image = nil
            }

            guard sessionGeneration == request.sessionGeneration,
                  requestGeneration == request.requestGeneration else {
                continue
            }
            guard let image else { continue }
            onPreview?(Preview(image: image, sourceTime: request.sourceTime))
        }
    }

    private func retireExtractor() {
        guard let extractor else { return }
        self.extractor = nil
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await extractor.shutdown()
            self?.shutdownTasks.removeValue(forKey: id)
        }
        shutdownTasks[id] = task
    }
}
