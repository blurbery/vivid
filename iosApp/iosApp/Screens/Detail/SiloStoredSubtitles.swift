import Foundation
import Observation

/// A subtitle Silo stores for a file: downloaded from a provider, uploaded,
/// or made by Silo's AI. Silo lists them at `GET /api/v1/subtitles/{file}`
/// (v2 `listStoredSubtitles`), oldest first, the order its playback plan uses.
struct SiloStoredSubtitle: Decodable, Equatable {
    let id: Int
    let provider: String?
    let language: String?
    let format: String?
    let releaseName: String?
    let hearingImpaired: Bool

    init(id: Int, provider: String? = nil, language: String? = nil, format: String? = nil,
         releaseName: String? = nil, hearingImpaired: Bool = false) {
        self.id = id
        self.provider = provider
        self.language = language
        self.format = format
        self.releaseName = releaseName
        self.hearingImpaired = hearingImpaired
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, language, format, releaseName, hearingImpaired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Silo v1 sends the ID as a number and v2 as a string.
        if let number = try? container.decode(Int.self, forKey: .id) {
            id = number
        } else if let text = try? container.decode(String.self, forKey: .id), let number = Int(text) {
            id = number
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Stored subtitle ID is not a number")
        }
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        releaseName = try container.decodeIfPresent(String.self, forKey: .releaseName)
        hearingImpaired = try container.decodeIfPresent(Bool.self, forKey: .hearingImpaired) ?? false
    }

    /// The label Silo's playback plan gives this subtitle: "release
    /// (provider)", or the language when it has neither. The detail page uses
    /// the same text as the player because the automatic pick reads "forced"
    /// and "SDH" in it.
    var planLabel: String? {
        let release = releaseName ?? "", provider = provider ?? ""
        let label = release.isEmpty && provider.isEmpty ? "" : release + " (" + provider + ")"
        for value in [label, language ?? ""] where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }
}

struct SiloStoredSubtitleList: Decodable {
    let subtitles: [SiloStoredSubtitle]
}

/// The subtitles Silo stores for each file a detail page shows, so its
/// subtitle menu and the automatic pick it previews include them as the
/// player does. Detail pages call `load`; everything else reads `subtitles`.
@Observable @MainActor
final class SiloStoredSubtitles {
    static let shared = SiloStoredSubtitles()
    private struct Entry { let subtitles: [SiloStoredSubtitle]; let expires: Date }
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    private func key(_ fileID: Int?) -> String? {
        guard MediaServerProvider.active == .silo, let fileID,
              let server = ServerRegistry.shared.activeServerId else { return nil }
        return "\(server)|\(AuthService.shared.profileId ?? "")|\(fileID)"
    }

    func subtitles(fileID: Int?) -> [SiloStoredSubtitle] {
        guard let key = key(fileID), let entry = entries[key] else { return [] }
        return entry.subtitles
    }

    /// Reads the file's stored subtitles unless a recent read is kept. A
    /// failed read, including from a server without the route, lists none.
    func load(fileID: Int?) async {
        guard let key = key(fileID), let fileID, !loading.contains(key) else { return }
        if let entry = entries[key], entry.expires > Date() { return }
        loading.insert(key)
        defer { loading.remove(key) }
        let subtitles = (try? await VividAPI.shared.storedSubtitles(fileID: fileID).subtitles) ?? []
        guard self.key(fileID) == key else { return }
        entries = entries.filter { $0.value.expires > Date() }
        if entries.count >= 32 { entries.removeAll() }
        entries[key] = Entry(subtitles: subtitles, expires: Date().addingTimeInterval(120))
    }
}
