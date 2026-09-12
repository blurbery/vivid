#if os(iOS) || os(tvOS)
import Foundation
import CryptoKit

struct VividCloudPreference: Codable, Equatable {
    var value: Data?
    var modifiedAt: Date
    var writer: String
}

enum VividCloudPreferencePolicy {
    static func merge(_ local: [String: VividCloudPreference], _ remote: [String: VividCloudPreference]) -> [String: VividCloudPreference] {
        local.merging(remote) { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs }
            return lhs.writer >= rhs.writer ? lhs : rhs
        }
    }
    /// A missing local credential is not an explicit disconnect. Keep the
    /// last known value so an update or unavailable Keychain cannot erase it.
    static func capturedPluginCredential(_ observed: Data?, previous: VividCloudPreference?,
                                         modifiedAt: Date, writer: String) -> VividCloudPreference? {
        guard let observed else { return previous }
        guard previous?.value != observed else { return previous }
        return VividCloudPreference(value: observed, modifiedAt: modifiedAt, writer: writer)
    }

    static func needsCredentialRestore(_ entry: VividCloudPreference, stored: Data?) -> Bool {
        entry.value != stored
    }

    static func matchesAccountContext(server: String, profile: String,
                                      accountServer: String, accountProfile: String?,
                                      requiresLogin: Bool) -> Bool {
        !requiresLogin && !profile.isEmpty && server == accountServer && profile == accountProfile
    }

    static func ordered(_ identities: [String], preferred: [String]) -> [String] {
        let available = Set(identities)
        var seen = Set<String>()
        return (preferred.filter { available.contains($0) } + identities).filter { seen.insert($0).inserted }
    }
    static func moving(_ identities: [String], id: String, by offset: Int) -> [String] {
        guard offset == -1 || offset == 1,
              let source = identities.firstIndex(of: id),
              identities.indices.contains(source + offset) else { return identities }
        var result = identities
        result.swapAt(source, source + offset)
        return result
    }
    static func isSharedSetting(_ key: String) -> Bool {
        !(key.hasPrefix("playback.") || key.hasPrefix("player.") || key.hasPrefix("subtitle."))
    }
}

/// Values, including credentials, are retained in Keychain and transported
/// only inside the existing CloudKit encrypted account-vault payload.
@MainActor
final class VividCloudPreferences {
    static let shared = VividCloudPreferences()
    private let keychain = SharedKeychain(audience: .currentUser)
    private let ledgerKey = "vivid.cloud.preferences.ledger.v1"
    private let writerKey = "vivid.cloud.preferences.writer.v1"
    private(set) var applying = false
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var entries: [String: VividCloudPreference] = [:]
    private var loaded = false
    private var capturedOnce = false
    private var credentialSyncPending = false
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private var writer: String {
        if let value = UserDefaults.standard.string(forKey: writerKey) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: writerKey)
        return value
    }
    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
    }
    func schedule() {
        guard !applying else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            let previous = self.entries
            guard (try? self.capture(accounts: TVSavedAccountStore.shared.accounts)) != nil else { return }
            try? await self.captureSharedSettings()
            guard previous != self.entries || self.credentialSyncPending else { return }
            self.credentialSyncPending = false
            await VividCloudAccountSync.shared.synchronize()
        }
    }
    private func load() throws {
        guard !loaded else { return }
        if let raw = keychain.get(ledgerKey) {
            capturedOnce = true
            entries = try JSONDecoder().decode([String: VividCloudPreference].self, from: Data(raw.utf8))
        }
        loaded = true
    }
    private func persist() throws {
        let data = try Self.encoder.encode(entries)
        guard let raw = String(data: data, encoding: .utf8), keychain.set(raw, for: ledgerKey) else { throw ServerRegistryError.persistenceFailed }
    }
    private var settingsIdentity: HTTPRequestIdentity?
    private var settingRows: [String: EffectiveSettingValue] = [:]

    private func activeSettingsIdentity() -> HTTPRequestIdentity? {
        guard Self.matchingActiveAccount != nil,
              let server = ServerRegistry.shared.activeServer,
              let profile = AuthService.shared.profileId, !profile.isEmpty,
              AuthService.shared.isLoggedIn else { return nil }
        return HTTPRequestIdentity(serverId: server.id, serverURL: server.url, profileId: profile,
                                   clientFamily: AppleDeviceIdentity.current.clientFamily)
    }

    private func settingPrefix(_ identity: HTTPRequestIdentity) -> String {
        "setting|" + Data("\(identity.serverId)|\(identity.profileId)".utf8).base64EncodedString() + "|"
    }

    /// Server-backed UI, metadata and download preferences use the same vault.
    /// Playback and subtitle keys never enter this snapshot or its write path.
    func captureSharedSettings() async throws {
        try load()
        guard let identity = activeSettingsIdentity() else { return }
        let keys = SettingKey.allCases.filter { VividCloudPreferencePolicy.isSharedSetting($0.rawValue) }
        let response = try await VividAPI.shared.getEffectiveValues(keys: keys, requestIdentity: identity)
        guard activeSettingsIdentity() == identity else { throw CancellationError() }
        settingsIdentity = identity
        settingRows = Dictionary(response.settings.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var changed = false
        for row in response.settings where VividCloudPreferencePolicy.isSharedSetting(row.key) && !row.constrained {
            let key = settingPrefix(identity) + row.key
            let value = try Self.encoder.encode(row.value)
            let observationKey = "vivid.cloud.observed." + key
            let previous = UserDefaults.standard.data(forKey: observationKey)
            if let previous, previous != value {
                entries[key] = VividCloudPreference(value: value, modifiedAt: Date(), writer: writer)
                changed = true
            } else if entries[key] == nil, row.scope != nil {
                entries[key] = VividCloudPreference(value: value, modifiedAt: .distantPast, writer: writer)
                changed = true
            }
            if previous != value { UserDefaults.standard.set(value, forKey: observationKey) }
        }
        if changed { try persist() }
    }

    func applySharedSettings() async throws {
        guard let identity = activeSettingsIdentity() else { return }
        try await captureSharedSettings()
        guard activeSettingsIdentity() == identity else { throw CancellationError() }
        var changed = false
        for row in settingRows.values where VividCloudPreferencePolicy.isSharedSetting(row.key) && !row.constrained {
            let name = settingPrefix(identity) + row.key
            guard let key = SettingKey(rawValue: row.key), let data = entries[name]?.value else { continue }
            let value = try JSONDecoder().decode(SettingJSONValue.self, from: data)
            guard value != row.value else { continue }
            guard activeSettingsIdentity() == identity else { throw CancellationError() }
            let scope: SettingScopeIdentity
            switch row.scope {
            case .profileDevice: scope = .profileDevice
            case .profileClient: scope = .profileClient
            case .account: scope = .account
            case .profileLibrary, .profileSeries: continue
            default: scope = .profile
            }
            _ = try await VividAPI.shared.putValue(key: key, scope: scope, value: value,
                                                  mutationId: UUID().uuidString, requestIdentity: identity)
            guard activeSettingsIdentity() == identity else { throw CancellationError() }
            UserDefaults.standard.set(data, forKey: "vivid.cloud.observed." + name)
            changed = true
        }
        if changed {
            await UICustomizationPreferences.shared.refresh()
            await OverlayPrefsStore.shared.refresh()
        }
    }

    private func defaultsKeys(accounts: [TVSavedAccount], remoteNames: [String] = []) -> Set<String> {
        var keys = Set<String>()
        let storedKeys = Set(UserDefaults.standard.dictionaryRepresentation().keys)
            .union(SharedStorage.suite.dictionaryRepresentation().keys)
        let candidateKeys = storedKeys.union(remoteNames.filter { $0.hasPrefix("defaults|") }.map { String($0.dropFirst(9)) })
        // Only names within the explicit profile allowlist are inspected.

        for account in accounts {
            guard let profile = account.profile?.id else { continue }
            let suffix = "\(account.serverID).\(profile)"
            keys.formUnion(["tvos.homeSections.v1.\(suffix)", "tvos.homeSpotlight.v1.\(suffix)", "tvos.homeCards.v1.\(suffix)", "tvos.homeCards.v1.\(suffix).captions"])
            for key in storedKeys {
                for prefix in ["ios.browsePrefs.", "tv.browsePrefs."] where key.hasPrefix(prefix + suffix + ".") {
                    let canonical = "vivid.browsePrefs." + String(key.dropFirst(prefix.count))
                    if !SharedDefaults.shared.containsObject(forKey: canonical),
                       let value = SharedStorage.suite.object(forKey: key) ?? UserDefaults.standard.object(forKey: key) {
                        SharedStorage.suite.set(value, forKey: canonical)
                        UserDefaults.standard.set(value, forKey: canonical)
                    }
                    SharedDefaults.shared.removeObject(forKey: key)
                    keys.insert(canonical)
                }
            }
            keys.formUnion(candidateKeys.filter { $0.hasPrefix("vivid.browsePrefs." + suffix + ".") && ($0.hasSuffix(".state") || $0.hasSuffix(".preserve")) })
            let scope = Data("\(account.serverID)|\(profile)".utf8).base64EncodedString()
            keys.formUnion(["vivid.mobile.swapMenuUtilities.profile.\(scope)", "vivid.mobile.showDownloadsTab.profile.\(scope)"])
        }
        return keys
    }
    private func credentialKeys(accounts: [TVSavedAccount]) -> Set<String> {
        var result = Set<String>()
        for account in accounts {
            guard let profile = account.profile?.id else { continue }
            let scope = Data("\(account.serverID)|\(profile)".utf8).base64EncodedString()
            let tmdb = Self.credentialKey("tmdb", server: account.serverID, profile: profile)
            let seerr = Self.credentialKey("seerr", server: account.serverID, profile: profile)
            // An old global credential has no provable owner. Never assign it
            // to whichever account happens to become active first.
            let tmdbAliases = ["vivid.tmdb.credential.v1.profile." + scope]
            let seerrAliases = [account.id, profile].map { context in
                let raw = [account.serverID, context, profile].joined(separator: "\u{0}")
                return "vivid.seerr." + SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            migrateCredential(tmdb, aliases: tmdbAliases)
            migrateCredential(seerr, aliases: seerrAliases)
            let pluginScope = Self.pluginScope(server: account.serverID, user: account.userID, profile: profile)
            result.formUnion([tmdb, seerr, "vivid.mdblist.key.v1." + pluginScope,
                              "vivid.opensubtitles.key.v1." + pluginScope])
        }
        return result
    }
    func removeAccountPreferences(_ account: TVSavedAccount) throws {
        try load()
        let defaults = defaultsKeys(accounts: [account])
        let credentials = credentialKeys(accounts: [account])
        let profile = account.profile?.id ?? ""
        let settingsPrefix = "setting|" + Data("\(account.serverID)|\(profile)".utf8).base64EncodedString() + "|"
        let eligible = Set(defaults.map { "defaults|" + $0 } + credentials.map { "keychain|" + $0 })
            .union(entries.keys.filter { $0.hasPrefix(settingsPrefix) })
        for key in eligible {
            entries[key] = VividCloudPreference(value: nil, modifiedAt: Date(), writer: writer)
        }
        for key in credentials {
            guard keychain.delete(key) else { throw ServerRegistryError.persistenceFailed }
        }
        for key in defaults { SharedDefaults.shared.removeObject(forKey: key) }
        try persist()
    }

    private func migrateCredential(_ key: String, aliases: [String]) {
        if let saved = entries["keychain|" + key], saved.value == nil {
            for alias in aliases { _ = keychain.delete(alias) }
            return
        }
        if keychain.get(key) == nil {
            for alias in aliases {
                if let value = keychain.get(alias), keychain.set(value, for: key) { break }
            }
        }
        if keychain.get(key) != nil {
            for alias in aliases { _ = keychain.delete(alias) }
        }
    }
    nonisolated static func pluginScope(server: String, user: String, profile: String) -> String {
        let data = try! JSONEncoder().encode([server, user, profile])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func credentialKey(_ name: String, server: String, profile: String) -> String {
        let scope = Data("\(server)|\(profile)".utf8).base64EncodedString()
        return "vivid.cloud.credential.\(name).\(scope)"
    }
    static var matchingActiveAccount: TVSavedAccount? {
        guard AuthService.shared.isLoggedIn,
              let account = TVSavedAccountStore.shared.activeAccount,
              let server = ServerRegistry.shared.activeServerId,
              let profile = AuthService.shared.profileId,
              VividCloudPreferencePolicy.matchesAccountContext(
                server: server, profile: profile, accountServer: account.serverID,
                accountProfile: account.profile?.id, requiresLogin: account.requiresLogin
              ) else { return nil }
        return account
    }
    static func activeCredentialKey(_ name: String) -> String? {
        guard let account = matchingActiveAccount, let profile = account.profile?.id else { return nil }
        return credentialKey(name, server: account.serverID, profile: profile)
    }
    private func encodedDefault(_ key: String) throws -> Data? {
        guard let value = SharedStorage.suite.object(forKey: key) ?? UserDefaults.standard.object(forKey: key) else { return nil }
        return try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }
    /// Explicit moves must beat the bootstrap order, even before first capture.
    func setAccountOrder(_ identities: [String]) throws {
        try load()
        let previous = entries
        entries["accountOrder"] = VividCloudPreference(
            value: try Self.encoder.encode(identities), modifiedAt: Date(), writer: writer
        )
        do { try persist() }
        catch { entries = previous; throw error }
    }

    /// Record explicit plugin edits immediately, including disconnect tombstones.
    /// Background observation cannot distinguish a missing key from a failed read.
    func setPluginCredential(_ value: String?, for key: String) throws {
        try load()
        let name = "keychain|" + key
        let previous = entries[name]
        let oldValue = keychain.get(key)
        let written = value.map { keychain.set($0, for: key) } ?? keychain.delete(key)
        guard written else { throw ServerRegistryError.persistenceFailed }
        entries[name] = VividCloudPreference(value: value.map { Data($0.utf8) },
                                             modifiedAt: Date(), writer: writer)
        do { try persist() }
        catch {
            entries[name] = previous
            if let oldValue { _ = keychain.set(oldValue, for: key) }
            else { _ = keychain.delete(key) }
            throw error
        }
        credentialSyncPending = true
        schedule()
    }

    private func isPluginCredential(_ name: String) -> Bool {
        name.hasPrefix("keychain|vivid.mdblist.key.v1.") ||
        name.hasPrefix("keychain|vivid.opensubtitles.key.v1.")
    }

    func capture(accounts: [TVSavedAccount]) throws -> [String: VividCloudPreference] {
        try load()
        var values: [String: Data] = [:]
        let keys = defaultsKeys(accounts: accounts)
        let credentials = credentialKeys(accounts: accounts)
        for key in keys { values["defaults|" + key] = try encodedDefault(key) }
        for key in credentials { values["keychain|" + key] = keychain.get(key).map { Data($0.utf8) } }
        if !accounts.isEmpty { values["accountOrder"] = try Self.encoder.encode(accounts.map { VividCloudAccountIdentity.key(for: $0) }) }
        let eligible = Set(keys.map { "defaults|" + $0 } + credentials.map { "keychain|" + $0 } + ["accountOrder"])
        var changed = false
        for key in eligible {
            let value = values[key]
            if isPluginCredential(key) {
                let observation = VividCloudPreferencePolicy.capturedPluginCredential(
                    value, previous: entries[key],
                    modifiedAt: capturedOnce ? Date() : .distantPast, writer: writer
                )
                if entries[key] != observation { entries[key] = observation; changed = true }
                continue
            }
            if let old = entries[key] {
                guard old.value != value else { continue }
                entries[key] = VividCloudPreference(value: value, modifiedAt: Date(), writer: writer)
                changed = true
            } else if let value {
                entries[key] = VividCloudPreference(value: value, modifiedAt: capturedOnce ? Date() : .distantPast, writer: writer)
                changed = true
            }
        }
        capturedOnce = true
        if changed { try persist() }
        return entries
    }
    func reconcile(_ remote: [String: VividCloudPreference], accounts: [TVSavedAccount]) throws -> [String: VividCloudPreference] {
        try load()
        let local = entries
        let candidates = local.filter { key, value in remote[key] == nil || value.modifiedAt != .distantPast }
        let merged = VividCloudPreferencePolicy.merge(candidates, remote)
        let keys = defaultsKeys(accounts: accounts, remoteNames: Array(remote.keys))
        let credentials = credentialKeys(accounts: accounts)
        applying = true
        defer { applying = false }
        var changed = false
        for (name, entry) in merged {
            if name.hasPrefix("defaults|"), keys.contains(String(name.dropFirst(9))) {
                guard local[name] != entry else { continue }
                let key = String(name.dropFirst(9))
                if let data = entry.value {
                    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    guard let value = (plist as? [String: Any])?["value"] else { continue }
                    SharedStorage.suite.set(value, forKey: key)
                    UserDefaults.standard.set(value, forKey: key)
                } else { SharedDefaults.shared.removeObject(forKey: key) }
                changed = true
            } else if name.hasPrefix("keychain|"), credentials.contains(String(name.dropFirst(9))) {
                let key = String(name.dropFirst(9))
                let stored = keychain.get(key).map { Data($0.utf8) }
                guard local[name] != entry || VividCloudPreferencePolicy.needsCredentialRestore(entry, stored: stored) else { continue }
                if let value = entry.value {
                    guard let text = String(data: value, encoding: .utf8), keychain.set(text, for: key) else { throw ServerRegistryError.persistenceFailed }
                } else if !keychain.delete(key) { throw ServerRegistryError.persistenceFailed }
                changed = true
            }
        }
        if entries != merged { entries = merged; try persist() }
        if changed {
            HomeSectionPreferences.shared.refresh(force: true)
            TVHomeSpotlightPreferences.shared.refresh(force: true)
            TVHomeCardPreferences.shared.cloudPreferencesChanged()
            TVTMDbStore.shared.reloadForCurrentProfile(force: true)
            TVSeerrConnectionStore.shared.cloudPreferencesChanged()
            MDBListSyncStore.shared.reload()
            OpenSubtitlesStore.shared.reload()
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        }
        return merged
    }
}
#endif
