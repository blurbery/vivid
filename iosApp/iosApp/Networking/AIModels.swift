import Foundation

/// `GET /api/v1/metadata/ai/status`: whether the server translates
/// descriptions, and how the detail page offers it.
struct MetadataAIStatus: Codable {
    let enabled: Bool
    let onView: OnViewMode

    /// How the detail page's description translation behaves. A value this
    /// app doesn't know reads as `.off`, which hides it.
    enum OnViewMode: String, Codable {
        case off
        case button
        case auto

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .off
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        onView = try container.decodeIfPresent(OnViewMode.self, forKey: .onView) ?? .off
    }
}

/// Body of `POST /api/v1/items/{id}/translate-description`.
struct TranslateDescriptionBody: Encodable {
    let targetLanguage: String
}
