import Foundation

/// Vivid's per-series audio and subtitle memory on Silo servers, kept on this
/// device.
///
/// Silo stores these choices on the server, shared with its own apps, and
/// folds them together with its profile and library preferences into the
/// defaults it sends with each title. On Silo, Vivid keeps its own memory, as
/// it does on Emby and Jellyfin, and puts it in place of Silo's defaults
/// before the detail page or player sees them. Tracks still come from the
/// file itself and Silo's subtitle files; only the choice between them is
/// Vivid's.
actor SiloLocalTrackPreferences {
    static let shared = SiloLocalTrackPreferences()

    enum Kind: String {
        case subtitle
        case audio
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Stored in the same snake_case shape Silo's preference routes take, so
    /// the rewrite below hands the decoder exactly what Silo would have sent.
    func save<Body: Encodable>(
        _ kind: Kind,
        key: String,
        body: Body,
        serverId: String,
        profileId: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(body)
        defaults.set(data, forKey: Self.storageKey(kind, key: key, serverId: serverId, profileId: profileId))
        var remembered = rememberedEntries(serverId: serverId, profileId: profileId)
        if remembered.insert(Self.entry(kind, key: key)).inserted {
            defaults.set(remembered.sorted(), forKey: Self.indexKey(serverId: serverId, profileId: profileId))
        }
    }

    func clear(_ kind: Kind, key: String, serverId: String, profileId: String) {
        defaults.removeObject(forKey: Self.storageKey(kind, key: key, serverId: serverId, profileId: profileId))
        var remembered = rememberedEntries(serverId: serverId, profileId: profileId)
        if remembered.remove(Self.entry(kind, key: key)) != nil {
            defaults.set(remembered.sorted(), forKey: Self.indexKey(serverId: serverId, profileId: profileId))
        }
    }

    func preference(_ kind: Kind, key: String, serverId: String, profileId: String) -> [String: Any] {
        guard let data = defaults.data(forKey: Self.storageKey(kind, key: key, serverId: serverId, profileId: profileId)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Replaces Silo's resolved defaults in a watch or catalog item response
    /// with this device's memory for the title's series (or the movie).
    func rewrite(_ data: Data, serverId: String, profileId: String) throws -> Data {
        // Nothing of Silo's to remove and nothing remembered here to add:
        // the response is decoded untouched, exactly as before.
        if data.range(of: Self.effectiveMarker) == nil,
           rememberedEntries(serverId: serverId, profileId: profileId).isEmpty {
            return data
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        let key = TrackSelectionPersistence.prefKey(
            seriesId: object["series_id"] as? String,
            contentId: object["content_id"] as? String
        )
        let subtitle = key.map { preference(.subtitle, key: $0, serverId: serverId, profileId: profileId) } ?? [:]
        let audio = key.map { preference(.audio, key: $0, serverId: serverId, profileId: profileId) } ?? [:]
        return try JSONSerialization.data(
            withJSONObject: Self.applying(subtitle: subtitle, audio: audio, to: object)
        )
    }

    private static let effectiveMarker = Data("\"effective_".utf8)

    private static let subtitleFields = [
        "effective_subtitle_language": "subtitle_language",
        "effective_subtitle_mode": "subtitle_mode",
        "effective_show_forced_subtitles": "show_forced_subtitles",
        "effective_subtitle_track_signature": "track_signature",
    ]

    /// Silo's own values are always removed. Without a choice remembered on
    /// this device the fields stay absent, the same as a fresh Emby or
    /// Jellyfin title, and the player falls back to Vivid's settings.
    static func applying(
        subtitle: [String: Any],
        audio: [String: Any],
        to object: [String: Any]
    ) -> [String: Any] {
        var result = object
        for (field, preferenceField) in subtitleFields {
            result.removeValue(forKey: field)
            if let value = subtitle[preferenceField], !(value is NSNull) {
                result[field] = value
            }
        }
        if let versions = object["versions"] as? [[String: Any]] {
            result["versions"] = versions.map { applying(audio: audio, to: $0) }
        }
        return result
    }

    private static func applying(audio: [String: Any], to version: [String: Any]) -> [String: Any] {
        var result = version
        result.removeValue(forKey: "effective_audio_track_index")
        result.removeValue(forKey: "effective_audio_language")
        guard let language = (audio["audio_language"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty,
              language != PlaybackPrefSentinel.originalLanguage,
              let tracks = version["audio_tracks"] as? [[String: Any]]
        else { return result }

        func matches(_ index: Int) -> Bool {
            SubtitleAutoResolver.languagesMatch(tracks[index]["language"] as? String ?? "", language)
        }
        // The remembered track when it's still there in that language,
        // otherwise the first track in the remembered language.
        let remembered = (audio["audio_track_index"] as? Int).flatMap {
            tracks.indices.contains($0) && matches($0) ? $0 : nil
        }
        if let index = remembered ?? tracks.indices.first(where: matches) {
            result["effective_audio_track_index"] = index
            result["effective_audio_language"] = language
        }
        return result
    }

    private func rememberedEntries(serverId: String, profileId: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.indexKey(serverId: serverId, profileId: profileId)) ?? [])
    }

    private static func entry(_ kind: Kind, key: String) -> String {
        kind.rawValue + "." + key
    }

    private static func indexKey(serverId: String, profileId: String) -> String {
        "vivid.silo.trackPrefs.v1.index.\(serverId).\(profileId)"
    }

    private static func storageKey(_ kind: Kind, key: String, serverId: String, profileId: String) -> String {
        "vivid.silo.trackPrefs.v1.\(kind.rawValue).\(serverId).\(profileId).\(key)"
    }
}
