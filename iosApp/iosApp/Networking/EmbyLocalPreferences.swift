import Foundation

actor EmbyLocalPreferences {
    static let shared = EmbyLocalPreferences()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
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
"""#.utf8))) as? [String:Any] ?? [:]

    func route(connection: EmbyConnection, method: String, path: [String], query: [String:String], body: [String:Any]) async throws -> Any {
        try await connection.validate()
        guard let account = connection.identity?.account, let user = connection.userID else { throw EmbyError.signInRequired }
        let storageKey = "vivid.emby.preferences." + account.serverId + "." + user
        return try apply(storageKey:storageKey,user:user,method:method,path:path,query:query,body:body)
    }

    func playbackValues(connection: EmbyConnection) async throws -> [String:Any] {
        let result = try await route(connection:connection,method:"GET",path:["api","v1","settings","values","effective"],
            query:["keys":"playback.subtitle_language,playback.subtitle_mode,playback.show_forced_subtitles,playback.audio_language"],body:[:]) as? [String:Any]
        return Dictionary((result?["settings"] as? [[String:Any]] ?? []).compactMap { row in
            guard let key = row["key"] as? String, let value = row["value"] else { return nil }
            return (key,value)
        },uniquingKeysWith:{ _,last in last })
    }

    func apply(storageKey: String, user: String, method: String, path: [String], query: [String:String], body: [String:Any]) throws -> Any {
        var rows = defaults.data(forKey:storageKey).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:[String:Any]] } ?? [:]
        let retainedRows = rows.filter { !$0.key.hasPrefix("nav.shortcuts.") }
        if retainedRows.count != rows.count {
            rows = retainedRows
            defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: storageKey)
        }
        if path.last == "capabilities" {
            return ["api_version":1,"revision":SettingKey.revision,"contract_etag":"vivid-local-emby","definition_count":Self.contractDefaults.count,
                "scopes":["profile","profile_client","profile_device"],"supports_batched_effective":true,"supports_idempotent_writes":true,"supports_atomic_shortcuts":false]
        }
        if path.last == "effective" {
            let keys = (query["keys"] ?? "").split(separator:",").map(String.init)
            let values: [[String:Any]] = keys.map { key in
                let row = rows[key + ".profile_device"] ?? rows[key + ".profile_client"] ?? rows[key + ".profile"]
                var value: [String:Any] = ["key":key,"value":row?["value"] ?? Self.contractDefaults[key] ?? NSNull(),
                    "source":row?["scope"] ?? "default","constrained":false]
                for field in ["scope","profile_id","client_family","device_id"] { value[field] = row?[field] }
                return value
            }
            return ["settings":values,"revision":SettingKey.revision]
        }
        guard path.count >= 5, let key = SettingKey(rawValue:path[4]) else { throw EmbyError.unsupportedFeature }
        guard key != .navShortcuts else { throw EmbyError.unsupportedFeature }
        let scope = query["scope"] ?? "profile"
        guard ["profile","profile_client","profile_device"].contains(scope) else { throw EmbyError.unsupportedFeature }
        let id = key.rawValue + "." + scope
        if method == "DELETE" {
            rows.removeValue(forKey:id)
            defaults.set(try JSONSerialization.data(withJSONObject:rows),forKey:storageKey)
            return [:]
        }
        guard method == "PUT" else { throw EmbyError.unsupportedFeature }
        let value = body["value"] ?? NSNull()
        if key == .navPrimaryMenu, !(value is NSNull) {
            let preference: PrimaryMenuPreference = try EmbyAdapter.decode(value)
            guard preference.isValid else { throw EmbyError.invalidResponse }
        }
        var row: [String:Any] = ["key":key.rawValue,"scope":scope,"profile_id":user,"value":value,"revision":1]
        if let family = query["client_family"] { row["client_family"] = family }
        if let device = query["device_id"] { row["device_id"] = device }
        if value is NSNull { rows.removeValue(forKey:id) } else { rows[id] = row }
        defaults.set(try JSONSerialization.data(withJSONObject:rows),forKey:storageKey)
        return row
    }
}
