import Foundation

/// Cached metadata-translation capability for catalog descriptions.
/// Results are discarded when the active server or profile changes.
@MainActor
@Observable
final class AICapabilities {
    static let shared = AICapabilities()

    /// `GET /metadata/ai/status`. Nil until fetched or after `reset()`.
    private(set) var metadataStatus: MetadataAIStatus?

    private let api: VividAI

    /// Bumped on every `reset()`. Each in-flight `refresh()`
    /// captures the value before its network awaits and only commits results
    /// when it still matches — so a slow probe that finishes after a
    /// sign-out / profile switch is discarded instead of repopulating the
    /// next account's capabilities.
    private var generation = 0

    init(api: VividAI = .shared) {
        self.api = api
    }

    // MARK: - Gating convenience

    /// Whether the metadata-language setting row + on-view affordance may
    /// appear at all.
    var metadataEnabled: Bool { metadataStatus?.enabled ?? false }

    /// How the item-detail translate affordance behaves. Defaults to
    /// `.off` when the probe hasn't landed or the feature is disabled.
    var metadataOnView: MetadataAIStatus.OnViewMode {
        guard let status = metadataStatus, status.enabled else { return .off }
        return status.onView
    }


    // MARK: - Lifecycle

    /// Failure leaves metadata translation unavailable for this session.
    func refresh() async {
        let gen = generation
        let meta = await fetchMetadataStatus()
        // Discard if a reset (sign-out / profile switch) happened while the
        // probes were in flight — otherwise we'd repopulate the next
        // account's capabilities with the previous one's results.
        guard gen == generation else { return }
        metadataStatus = meta
    }


    /// Drop every cached probe. Called on sign-out and profile/server
    /// switch so capabilities don't leak across accounts. Bumps
    /// `generation` first so any refresh still in flight discards its
    /// results instead of clobbering this reset.
    func reset() {
        generation &+= 1
        metadataStatus = nil
    }

    // MARK: - Internals

    private func fetchMetadataStatus() async -> MetadataAIStatus? {
        try? await api.metadataAIStatus()
    }

}
