import Foundation

/// Silo's description translation endpoints, on the native `/api/v1` API.
actor VividAI {
    static let shared = VividAI()

    private let http: HTTPClient

    init(http: HTTPClient = .shared) {
        self.http = http
    }

    /// Whether the server translates descriptions, and how.
    func metadataAIStatus() async throws -> MetadataAIStatus {
        try await http.get("/api/v1/metadata/ai/status")
    }

    /// Starts translating an item's description. The server answers 202 with
    /// no body; the item detail shows the result once
    /// `pendingTranslationLanguage` clears.
    func translateDescription(contentId: String, targetLanguage: String) async throws {
        try await http.postVoid(
            "/api/v1/items/\(contentId)/translate-description",
            body: TranslateDescriptionBody(targetLanguage: targetLanguage)
        )
    }
}
