import Foundation

/// Vivid's typed settings for Jellyfin accounts, kept on the device per server
/// and user. Jellyfin has no settings contract of its own, so this answers the
/// `/api/v1/settings/values/*` and contract capability routes with the same
/// shapes a Silo server sends.
///
/// Rows are stored as one JSON object under
/// `vivid.jellyfin.preferences.<server>.<user>`, keyed `<setting>.<scope>`, and
/// resolve device, then family, then profile, then the contract default.
actor JellyfinLocalPreferences {
    static let shared = JellyfinLocalPreferences()

    private static let scopes = ["profile", "profile_client", "profile_device"]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The contract's default values.
    static let contractDefaults = (try? JSONSerialization.jsonObject(with: Data(#"""
{
  "catalog.metadata_language": null,
  "catalog.metadata_language_overrides": {},
  "downloads.default_quality": "original",
  "downloads.keep_watched": false,
  "downloads.wifi_only": true,
  "nav.primary_menu": null,
  "playback.audio_language": null,
  "playback.auto_play_next": true,
  "playback.auto_play_next_preview": false,
  "playback.auto_skip_credits": false,
  "playback.auto_skip_intro": false,
  "playback.auto_skip_recap": false,
  "playback.max_bitrate_kbps": null,
  "playback.next_up_prompt_seconds": 30,
  "playback.preferred_quality": "auto",
  "playback.show_forced_subtitles": true,
  "playback.subtitle_appearance": {
    "backgroundColor": "#000000",
    "backgroundOpacity": 75,
    "backgroundStyle": "shadow",
    "fontColor": "#ffffff",
    "fontFamily": "sans-serif",
    "fontSize": "large",
    "position": "bottom",
    "textOutline": false,
    "textOutlineColor": "#000000"
  },
  "playback.subtitle_language": null,
  "playback.subtitle_mode": "auto",
  "player.audio_sync_ms": 0,
  "player.dolby_vision_enabled": true,
  "player.dv_profile7_hdr10_fallback": false,
  "player.hdr_enabled": true,
  "player.match_frame_rate": false,
  "player.orientation_mode": "landscapeLocked",
  "player.passout_threshold": 3,
  "player.picture_in_picture_enabled": true,
  "player.playback_speed": 1.0,
  "player.resume_rewind_seconds": 7,
  "player.seek_cache_enabled": true,
  "player.sleep_timer_default_minutes": 30,
  "player.subtitle_sync_ms": 0,
  "player.video_gravity": "fit",
  "search.media_scope": "video",
  "subtitle.matches_device": false,
  "ui.card_overlays": null,
  "ui.card_presentation": {
    "caption": "title_metadata",
    "poster_size": "standard"
  },
  "ui.custom_css": null,
  "ui.custom_theme_vars": null,
  "ui.date_format": "auto",
  "ui.disabled_library_ids": null,
  "ui.high_contrast": false,
  "ui.library_order": null,
  "ui.library_page_state": null,
  "ui.next_up_mode": "combined",
  "ui.remember_library_page_state": true,
  "ui.sidebar_pins": null,
  "ui.text_scale": "default",
  "ui.text_weight": "default",
  "ui.theme": "midnight-cinema",
  "ui.time_format": "auto"
}
"""#.utf8))) as? [String: Any] ?? [:]

    nonisolated static func storageKey(serverID: String, userID: String) -> String {
        "vivid.jellyfin.preferences." + serverID + "." + userID
    }

    func route(connection: JellyfinConnection, method: String, path: [String], query: [String: String], body: [String: Any]) async throws -> Any {
        try await connection.validate()
        guard let account = connection.identity?.account, let user = connection.userID else { throw JellyfinError.signInRequired }
        let storageKey = Self.storageKey(serverID: account.serverId, userID: user)
        return try apply(storageKey: storageKey, user: user, method: method, path: path, query: query, body: body)
    }

    /// The account's subtitle and audio settings, for watch details.
    func playbackValues(connection: JellyfinConnection) async throws -> [String: Any] {
        let keys = "playback.subtitle_language,playback.subtitle_mode,playback.show_forced_subtitles,playback.audio_language"
        let result = try await route(
            connection: connection, method: "GET", path: ["api", "v1", "settings", "values", "effective"],
            query: ["keys": keys], body: [:]
        ) as? [String: Any]
        let pairs = (result?["settings"] as? [[String: Any]] ?? []).compactMap { row -> (String, Any)? in
            guard let key = row["key"] as? String, let value = row["value"] else { return nil }
            return (key, value)
        }
        return Dictionary(pairs) { _, last in last }
    }

    func apply(storageKey: String, user: String, method: String, path: [String], query: [String: String], body: [String: Any]) throws -> Any {
        var rows = try loadRows(storageKey)
        switch path.last {
        case "capabilities":
            return Self.capabilities
        case "effective":
            let keys = (query["keys"] ?? "").split(separator: ",").map(String.init)
            return ["settings": keys.map { Self.effectiveValue($0, rows: rows) }, "revision": SettingKey.revision]
        default:
            break
        }

        guard path.count >= 5, let key = SettingKey(rawValue: path[4]), key != .navShortcuts else {
            throw JellyfinError.unsupportedFeature
        }
        let scope = query["scope"] ?? "profile"
        guard Self.scopes.contains(scope) else { throw JellyfinError.unsupportedFeature }
        let rowID = key.rawValue + "." + scope

        if method == "DELETE" {
            rows.removeValue(forKey: rowID)
            try save(rows, storageKey)
            return [String: Any]()
        }
        guard method == "PUT" else { throw JellyfinError.unsupportedFeature }
        let value = body["value"] ?? NSNull()
        if key == .navPrimaryMenu, !(value is NSNull) {
            let preference: PrimaryMenuPreference = try JellyfinAdapter.decode(value)
            guard preference.isValid else { throw JellyfinError.invalidResponse }
        }
        var row: [String: Any] = ["key": key.rawValue, "scope": scope, "profile_id": user, "value": value, "revision": 1]
        if let family = query["client_family"] { row["client_family"] = family }
        if let device = query["device_id"] { row["device_id"] = device }
        // A null value clears the scope.
        rows[rowID] = value is NSNull ? nil : row
        try save(rows, storageKey)
        return row
    }

    private static var capabilities: [String: Any] {
        [
            "api_version": 1,
            "revision": SettingKey.revision,
            "contract_etag": "vivid-local-jellyfin",
            "definition_count": contractDefaults.count,
            "scopes": scopes,
            "supports_batched_effective": true,
            "supports_idempotent_writes": true,
            "supports_atomic_shortcuts": false,
        ]
    }

    private static func effectiveValue(_ key: String, rows: [String: [String: Any]]) -> [String: Any] {
        let row = rows[key + ".profile_device"] ?? rows[key + ".profile_client"] ?? rows[key + ".profile"]
        var value: [String: Any] = [
            "key": key,
            "value": row?["value"] ?? contractDefaults[key] ?? NSNull(),
            "source": row?["scope"] ?? "default",
            "constrained": false,
        ]
        for field in ["scope", "profile_id", "client_family", "device_id"] { value[field] = row?[field] }
        return value
    }

    /// The stored rows. Rows for the retired `nav.shortcuts` setting are
    /// dropped, and the store saved without them.
    private func loadRows(_ storageKey: String) throws -> [String: [String: Any]] {
        let stored = defaults.data(forKey: storageKey)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
        let rows = stored.filter { !$0.key.hasPrefix("nav.shortcuts.") }
        if rows.count != stored.count { try save(rows, storageKey) }
        return rows
    }

    private func save(_ rows: [String: [String: Any]], _ storageKey: String) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: storageKey)
    }
}
