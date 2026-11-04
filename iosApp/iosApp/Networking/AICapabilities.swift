import Foundation

/// Whether the server translates catalogue descriptions, checked at sign-in
/// and on each foreground, and dropped on reset.
@MainActor
@Observable
final class AICapabilities {
    static let shared = AICapabilities()

    /// Nil until checked, after `reset()`, or when the check failed.
    private(set) var metadataStatus: MetadataAIStatus?

    /// Bumped by `reset()`, so a check that finishes after a sign-out or
    /// profile switch can't fill in the next account's status.
    private var generation = 0
    private let api: VividAI

    init(api: VividAI = .shared) {
        self.api = api
    }

    /// How the detail page offers translation: `.off` until a check says
    /// the feature is on.
    var metadataOnView: MetadataAIStatus.OnViewMode {
        guard let metadataStatus, metadataStatus.enabled else { return .off }
        return metadataStatus.onView
    }

    /// A failed check turns translation off until a later check succeeds.
    func refresh() async {
        let started = generation
        let status = try? await api.metadataAIStatus()
        guard started == generation else { return }
        metadataStatus = status
    }

    func reset() {
        generation &+= 1
        metadataStatus = nil
    }
}
