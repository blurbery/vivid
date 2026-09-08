import Foundation

/// Typed facade over the native Silo **AI** endpoints — metadata
/// translation.
///
/// Sibling to ``VividAPI``: a separate actor keeps the AI surface
/// cohesive and independently testable rather than swelling the much
/// larger `VividAPI`. Methods are thin pass-throughs over
/// ``HTTPClient/shared``; snake_case auto-converts both ways, so the wire
/// shapes in ``AIModels`` stay camelCase.
///
/// All paths are on the native API (`/api/v1/...`). The Jellyfin-compat
/// API does not mirror the AI trigger/status/job endpoints; the Apple
/// clients use the native API exclusively.
actor VividAI {
    static let shared = VividAI()

    private let http: HTTPClient

    init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: - Metadata

    /// Server-wide metadata-translation capability + the on-view mode.
    func metadataAIStatus() async throws -> MetadataAIStatus {
        try await http.get("/api/v1/metadata/ai/status")
    }

    /// Kick off an on-demand description translation for `contentId`.
    /// Returns `202` with no body; observe completion by re-fetching the
    /// item detail until `pendingTranslationLanguage` clears.
    func translateDescription(contentId: String, targetLanguage: String) async throws {
        try await http.postVoid(
            "/api/v1/items/\(contentId)/translate-description",
            body: TranslateDescriptionBody(targetLanguage: targetLanguage)
        )
    }

}
