import Foundation

// MARK: - Metadata AI

/// `GET /api/v1/metadata/ai/status`. `enabled` gates the metadata-language
/// setting + the on-view translate affordance; `onView` decides whether the
/// affordance is a button, auto-fires, or is hidden.
struct MetadataAIStatus: Codable {
    let enabled: Bool
    let onView: OnViewMode

    /// How the item-detail "translate this description" affordance behaves.
    /// Unknown wire values decode to `.off` (feature hidden) so an older or
    /// future server degrades silently.
    enum OnViewMode: String, Codable {
        case off
        case button
        case auto

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = OnViewMode(rawValue: raw) ?? .off
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        onView = try c.decodeIfPresent(OnViewMode.self, forKey: .onView) ?? .off
    }
}

/// Body for `POST /api/v1/items/{id}/translate-description` (202, no
/// response body — observe completion by re-fetching the item detail
/// until `pendingTranslationLanguage` clears).
struct TranslateDescriptionBody: Encodable {
    let targetLanguage: String
}
