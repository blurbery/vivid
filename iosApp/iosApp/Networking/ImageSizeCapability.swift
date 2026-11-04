import Foundation

/// The server's image size capability, which decides whether catalogue,
/// section and detail requests may ask for a larger image variant.
///
/// Fetched once per session and reset on sign-out and profile or server
/// switches. A generation counter makes a probe still running across a reset
/// drop its result instead of filling in the next account's capability. A
/// 404 or network error leaves it nil, which reads as "feature off", so older
/// servers simply keep their default sizes.
///
/// It isn't `@MainActor` or observable: no view reads it, and its one user,
/// the `VividAPI` actor, needs a synchronous read while building a request,
/// so a lock guards the state instead.
///
/// Image URLs stay opaque. The server builds the chosen size into the URLs it
/// returns and the app never rewrites them, so a larger variant is just a
/// different URL that the image caches store separately.
final class ImageSizeCapability: @unchecked Sendable {
    static let shared = ImageSizeCapability()

    /// Whether this platform wants larger images. tvOS draws full-screen
    /// shelves and detail art on a 4K panel; iOS and macOS keep the server's
    /// default sizes, so their requests don't change.
    static var platformPrefersLargeImages: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    /// The extra query entries for a request that returns images. Takes the
    /// platform as a parameter so the iOS test target can cover both cases.
    static func queryEntries(
        capability: ImageSizeCapabilityResponse?,
        platformPrefersLargeImages: Bool
    ) -> [String: String] {
        ImageSizeSelection.queryEntries(
            capability: capability,
            prefersLargeImages: platformPrefersLargeImages
        )
    }

    private struct Probe {
        let id: Int
        let generation: Int
        let task: Task<ImageSizeCapabilityResponse?, Never>
    }

    private let fetchCapability: @Sendable () async throws -> ImageSizeCapabilityResponse
    private let prefersLargeImages: Bool
    private let lock = NSLock()
    private var storedCapability: ImageSizeCapabilityResponse?
    private var generation = 0
    private var nextProbeID = 0
    private var inFlightProbe: Probe?

    init(
        api: VividAPI = .shared,
        platformPrefersLargeImages: Bool = ImageSizeCapability.platformPrefersLargeImages
    ) {
        self.prefersLargeImages = platformPrefersLargeImages
        self.fetchCapability = { try await api.imageSizeCapability() }
    }

    init(
        platformPrefersLargeImages: Bool,
        fetchCapability: @escaping @Sendable () async throws -> ImageSizeCapabilityResponse
    ) {
        self.prefersLargeImages = platformPrefersLargeImages
        self.fetchCapability = fetchCapability
    }

    // MARK: - Reading

    /// The probe result, or nil before it arrives and after `reset()`.
    var capability: ImageSizeCapabilityResponse? {
        lock.withLock { storedCapability }
    }

    /// Query entries for this platform and probe state: empty before the
    /// probe arrives, when the server lacks the feature, or off tvOS.
    var requestQuery: [String: String] {
        Self.queryEntries(
            capability: capability,
            platformPrefersLargeImages: prefersLargeImages
        )
    }

    // MARK: - Lifecycle

    /// Probes the server once per session. Concurrent calls share one probe.
    /// A 404 from an older server or any other error leaves the feature off
    /// and is tried again on the next foreground refresh.
    ///
    /// Platforms that wouldn't send the parameter skip the request.
    func refresh() async {
        guard prefersLargeImages else { return }
        guard let probe = lock.withLock({ () -> Probe? in
            if storedCapability != nil { return nil }
            if let inFlightProbe, inFlightProbe.generation == generation {
                return inFlightProbe
            }
            nextProbeID &+= 1
            let probe = Probe(
                id: nextProbeID,
                generation: generation,
                task: Task { [fetchCapability] in try? await fetchCapability() }
            )
            inFlightProbe = probe
            return probe
        }) else { return }

        let probed = await probe.task.value
        lock.withLock {
            // Drop the result if a reset or a newer probe came along meanwhile.
            // A nil result stays retryable; a successful one is kept.
            guard generation == probe.generation,
                  inFlightProbe?.id == probe.id else { return }
            inFlightProbe = nil
            storedCapability = probed
        }
    }

    /// Forgets the probe so a capability never carries over to another
    /// account or server. The generation moves first, so a probe still
    /// running can't overwrite the reset.
    func reset() {
        let task = lock.withLock { () -> Task<ImageSizeCapabilityResponse?, Never>? in
            generation &+= 1
            storedCapability = nil
            let task = inFlightProbe?.task
            inFlightProbe = nil
            return task
        }
        task?.cancel()
    }
}
