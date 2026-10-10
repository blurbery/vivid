import Foundation

/// Vivid's interface settings on Silo servers, kept on this device.
///
/// Silo shares every `ui.*` and `nav.*` setting between all clients in a
/// device family, so a top menu or card size saved in Silo's own apps changed
/// Vivid's tabs and cards. Vivid's design is its own, so on Silo these keys
/// never reach the server, the same as on Emby and Jellyfin. Playback,
/// subtitle, metadata and download preferences still follow the Silo profile.
///
/// Rows are stored per server and profile under the scope each write named,
/// and resolve device, then family, then profile, as the server would.
actor SiloLocalInterfaceSettings {
    static let shared = SiloLocalInterfaceSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True for the settings that shape Vivid's interface.
    static func owns(_ key: String) -> Bool {
        key.hasPrefix("ui.") || key.hasPrefix("nav.")
    }

    static func owns(_ key: SettingKey) -> Bool { owns(key.rawValue) }

    /// Emby and Jellyfin already answer every setting on the device, so this
    /// store only takes over for Silo.
    static func applies(toServerID serverId: String?) -> Bool {
        MediaServerProvider.forServerID(serverId) == .silo
    }

    /// What this store supports. Interface settings no longer depend on the
    /// Silo server's version or on it being reachable.
    static let capabilities = SettingsContractCapabilities(
        apiVersion: 1,
        revision: SettingKey.revision,
        contractEtag: "vivid-local-interface",
        definitionCount: SettingKey.allCases.filter { owns($0) }.count,
        scopes: ["profile", "profile_client", "profile_device"],
        supportsBatchedEffective: true,
        supportsIdempotentWrites: true,
        supportsAtomicShortcuts: false
    )

    private static let resolutionOrder: [SettingScope] = [.profileDevice, .profileClient, .profile]

    /// The contract defaults Emby and Jellyfin already answer with on the
    /// device, narrowed to the keys this store owns.
    private static let contractDefaults: [String: SettingJSONValue] = {
        let owned = EmbyLocalPreferences.contractDefaults.filter { owns($0.key) }
        guard let data = try? JSONSerialization.data(withJSONObject: owned),
              let decoded = try? SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: data)
        else { return [:] }
        return decoded.objectValue ?? [:]
    }()

    func effectiveValues(
        keys: [SettingKey],
        serverId: String,
        profileId: String
    ) -> [EffectiveSettingValue] {
        let rows = load(serverId: serverId, profileId: profileId)
        return keys.map { key in
            for scope in Self.resolutionOrder {
                if let value = rows[Self.rowId(key, scope)] {
                    return EffectiveSettingValue(
                        key: key.rawValue,
                        value: value,
                        source: .scope(scope),
                        scope: scope,
                        profileId: profileId
                    )
                }
            }
            return EffectiveSettingValue(
                key: key.rawValue,
                value: Self.contractDefaults[key.rawValue] ?? .null,
                source: .contractDefault
            )
        }
    }

    /// A null value clears the row, matching the server's nullable settings.
    func put(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        serverId: String,
        profileId: String
    ) throws -> StoredSettingValue {
        guard Self.resolutionOrder.contains(scope.scope) else {
            throw SettingsAPIError.scopeNotAllowed(key: key.rawValue, scope: scope.scope)
        }
        if key == .navPrimaryMenu, value != .null {
            let data = try SettingsWireCoding.makeEncoder().encode(value)
            let menu = try SettingsWireCoding.makeDecoder().decode(PrimaryMenuPreference.self, from: data)
            guard menu.isValid else {
                throw SettingsAPIError.invalidValue(message: "The primary menu value is not valid.")
            }
        }
        var rows = load(serverId: serverId, profileId: profileId)
        rows[Self.rowId(key, scope.scope)] = value == .null ? nil : value
        try save(rows, serverId: serverId, profileId: profileId)
        return StoredSettingValue(
            key: key.rawValue,
            scope: scope.scope,
            profileId: profileId,
            clientFamily: nil,
            deviceId: nil,
            libraryId: nil,
            seriesId: nil,
            value: value,
            revision: 1,
            updatedAt: nil
        )
    }

    /// Clearing a scope with nothing stored is already done, so this never
    /// reports the server's "no value at scope".
    func delete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        serverId: String,
        profileId: String
    ) throws {
        var rows = load(serverId: serverId, profileId: profileId)
        guard rows.removeValue(forKey: Self.rowId(key, scope.scope)) != nil else { return }
        try save(rows, serverId: serverId, profileId: profileId)
    }

    private static func rowId(_ key: SettingKey, _ scope: SettingScope) -> String {
        key.rawValue + "|" + scope.rawValue
    }

    private static func storageKey(serverId: String, profileId: String) -> String {
        "vivid.silo.interface.v1." + serverId + "." + profileId
    }

    private func load(serverId: String, profileId: String) -> [String: SettingJSONValue] {
        guard let data = defaults.data(forKey: Self.storageKey(serverId: serverId, profileId: profileId)),
              let rows = try? SettingsWireCoding.makeDecoder().decode([String: SettingJSONValue].self, from: data)
        else { return [:] }
        return rows
    }

    private func save(_ rows: [String: SettingJSONValue], serverId: String, profileId: String) throws {
        let data = try SettingsWireCoding.makeEncoder().encode(rows)
        defaults.set(data, forKey: Self.storageKey(serverId: serverId, profileId: profileId))
    }
}
