import Foundation
import OSLog
import Security

private let storageLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app", category: "SharedStorage")

/// Storage shared by the apps and the Top Shelf extension: the App Group
/// defaults, the shared Keychain and every key either side reads. Installed
/// apps already hold values under these names, so none of them may change.
enum SharedStorage {
    static let appGroupIdentifier = "group.com.blurbery.vivid"
    static let keychainService = "com.blurbery.vivid"
    static let sharedKeychainGroup = "com.blurbery.vivid.shared"

    static let accountCredentialAudience: KeychainAudience = .currentUser

    static let mirroredAccessTokenAccount = "com.blurbery.vivid.topshelf.accessToken"
    static let mirroredProfileTokenAccount = "com.blurbery.vivid.topshelf.profileToken"
    static let applePushDisplayTokenAccount = "com.blurbery.vivid.push.displayToken"
    static let applePushDisplayTokenExpiresAtKey = "applePush.displayTokenExpiresAt"
    static let applePushDisplayTokenServerIdKey = "applePush.displayTokenServerId"

    static func accessTokenAccount(for serverID: String) -> String { serverAccount(serverID, "accessToken") }
    static func refreshTokenAccount(for serverID: String) -> String { serverAccount(serverID, "refreshToken") }
    static func profileTokenAccount(for serverID: String) -> String { serverAccount(serverID, "profileToken") }
    static func accountEpochAccount(for serverID: String) -> String { serverAccount(serverID, "accountEpoch") }

    private static func serverAccount(_ serverID: String, _ name: String) -> String {
        "com.blurbery.vivid." + serverID + "." + name
    }

    static let serverUrlKey = "serverUrl"
    static let activeServerIdKey = "activeServerId"
    static let profileIdKey = "profileId"
    static let profileLaunchStateKey = "profileLaunchState.v1"
    static let savedAccountsKey = "vivid.accounts.v1"
    static let activeSavedAccountKey = "vivid.activeAccount.v1"
    static let viewingProfileCountsKey = "vivid.viewingProfileCounts.v1"
    static let topShelfLastStatusKey = "topShelf.lastStatus"
    static let topShelfLastRunAtKey = "topShelf.lastRunAt"
    static let appLanguageKey = "vivid.appLanguage.v1"

    /// The App Group defaults, or the standard defaults when the group can't
    /// be opened. Each read makes a new instance.
    static var suite: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    // MARK: - Configuration from the Info.plist, worked out once

    /// Only an unsigned sideload on a system older than iOS 26 may keep
    /// Keychain items outside the shared group.
    static let allowsAppLocalFallback: Bool = {
        #if os(tvOS) || DEBUG
        return false
        #else
        let channel = Bundle.main.object(forInfoDictionaryKey: "VividBuildChannel") as? String
        let iOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        return SharedKeychainPolicy.allowsAppLocalFallback(
            buildChannel: channel,
            isOlderThanIOS26: !ProcessInfo.processInfo.isOperatingSystemAtLeast(iOS26)
        )
        #endif
    }()

    static let keychainAccessGroup: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "VividKeychainAccessGroup") as? String
        let group = SharedKeychainPolicy.acceptedAccessGroup(value, allowsBareGroup: allowsAppLocalFallback)
        if group == nil {
            storageLog.error("The Info.plist has no usable shared Keychain access group")
        }
        return group
    }()

    static let usesUserIndependentKeychain: Bool = {
        switch Bundle.main.object(forInfoDictionaryKey: "VividUsesUserIndependentKeychain") {
        case let flag as Bool: return flag
        case let text as String: return ["1", "true", "yes"].contains(text.lowercased())
        default: return false
        }
    }()

    /// The team prefix older builds put in front of the bundle identifier to
    /// form their Keychain group.
    static let legacyTeamPrefix: String? = {
        guard let prefix = SharedKeychainPolicy.legacyTeamPrefix(forAccessGroup: keychainAccessGroup) else {
            storageLog.error("No legacy team prefix can be derived from the shared Keychain access group")
            return nil
        }
        return prefix
    }()
}

/// The rules behind the shared Keychain configuration, kept apart from the
/// Info.plist so they can be checked directly.
enum SharedKeychainPolicy {
    private static let sharedGroupSuffix = "." + SharedStorage.sharedKeychainGroup

    static func allowsAppLocalFallback(buildChannel: String?, isOlderThanIOS26: Bool) -> Bool {
        buildChannel?.trimmingCharacters(in: .whitespacesAndNewlines) == "sideload" && isOlderThanIOS26
    }

    /// A team-prefixed shared group, or the bare group an unsigned archive
    /// carries when that is allowed.
    static func acceptedAccessGroup(_ value: String?, allowsBareGroup: Bool) -> String? {
        guard let value else { return nil }
        if value.hasSuffix(sharedGroupSuffix) { return value }
        if allowsBareGroup, value == SharedStorage.sharedKeychainGroup { return value }
        return nil
    }

    static func legacyTeamPrefix(forAccessGroup group: String?) -> String? {
        guard let group, group.hasSuffix(sharedGroupSuffix) else { return nil }
        return String(group.dropLast(sharedGroupSuffix.count)) + "."
    }
}

/// Reads prefer the App Group and fall back to the standard defaults; writes
/// go to both.
struct SharedDefaults: @unchecked Sendable {
    static let shared = SharedDefaults()

    let suite: UserDefaults
    private let standard: UserDefaults

    init(suite: UserDefaults = SharedStorage.suite, standard: UserDefaults = .standard) {
        self.suite = suite
        self.standard = standard
    }

    func string(forKey key: String) -> String? {
        suite.string(forKey: key) ?? standard.string(forKey: key)
    }

    func data(forKey key: String) -> Data? {
        suite.data(forKey: key) ?? standard.data(forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        suite.object(forKey: key) != nil ? suite.bool(forKey: key) : standard.bool(forKey: key)
    }

    func containsObject(forKey key: String) -> Bool {
        suite.object(forKey: key) != nil || standard.object(forKey: key) != nil
    }

    func set(_ value: String?, forKey key: String) {
        guard let value else {
            removeObject(forKey: key)
            return
        }
        suite.set(value, forKey: key)
        standard.set(value, forKey: key)
    }

    func set(_ value: Data, forKey key: String) {
        suite.set(value, forKey: key)
        standard.set(value, forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        suite.set(value, forKey: key)
        standard.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        suite.removeObject(forKey: key)
        standard.removeObject(forKey: key)
    }
}

/// A Keychain read that failed for a reason other than a missing item.
struct KeychainReadFailure: Error, Equatable {
    let status: OSStatus

    /// The Keychain is briefly unavailable, for example before first unlock.
    var isTemporary: Bool {
        status == errSecInteractionNotAllowed || status == errSecNotAvailable
    }

    /// Runs `operation` up to three times while it fails with a temporary
    /// status, waiting between attempts. Any other error ends it at once.
    static func retryTemporaryRead<Value>(
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) },
        operation: () async throws -> Value
    ) async throws -> Value {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let failure as KeychainReadFailure where failure.isTemporary && attempt < 3 {
                try await wait()
                attempt += 1
            }
        }
    }
}

/// Generic-password items under one service. Items don't sync.
struct SharedKeychain {
    let service: String
    let accessGroup: String?
    let audience: KeychainAudience
    let usesUserIndependentKeychain: Bool
    let allowsAppLocalFallback: Bool
    private let readItem: (([String: Any]) -> (OSStatus, Data?))?

    init(
        service: String = SharedStorage.keychainService,
        accessGroup: String? = SharedStorage.keychainAccessGroup,
        audience: KeychainAudience = .currentUser,
        usesUserIndependentKeychain: Bool = SharedStorage.usesUserIndependentKeychain,
        allowsAppLocalFallback: Bool = SharedStorage.allowsAppLocalFallback,
        readItem: (([String: Any]) -> (OSStatus, Data?))? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.audience = audience
        self.usesUserIndependentKeychain = usesUserIndependentKeychain
        self.allowsAppLocalFallback = allowsAppLocalFallback
        self.readItem = readItem
    }

    func withAudience(_ audience: KeychainAudience) -> SharedKeychain {
        SharedKeychain(
            service: service,
            accessGroup: accessGroup,
            audience: audience,
            usesUserIndependentKeychain: usesUserIndependentKeychain,
            allowsAppLocalFallback: allowsAppLocalFallback,
            readItem: readItem
        )
    }

    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            storageLog.error("Keychain value for \(account, privacy: .public) is not UTF-8")
            return false
        }
        let status = write(data, account: account, group: accessGroup)
        if status == errSecSuccess { return true }
        if fallbackApplies(to: status) {
            let local = write(data, account: account, group: nil)
            if local == errSecSuccess {
                storageLog.notice("Stored an item in the app's own Keychain")
                return true
            }
            storageLog.error("App Keychain write failed: \(local, privacy: .public)")
            return false
        }
        storageLog.error("Keychain write for \(account, privacy: .public) failed: \(status, privacy: .public)")
        return false
    }

    func get(_ account: String) -> String? {
        try? getChecked(account)
    }

    /// Nil only when the item doesn't exist. Every other failure throws.
    func getChecked(_ account: String) throws -> String? {
        let (status, value) = read(account, group: accessGroup)
        if status == errSecSuccess { return value }
        if fallbackApplies(to: status) {
            let (localStatus, localValue) = read(account, group: nil)
            switch localStatus {
            case errSecSuccess: return localValue
            case errSecItemNotFound: return nil
            default:
                storageLog.error("App Keychain read failed: \(localStatus, privacy: .public)")
                throw KeychainReadFailure(status: localStatus)
            }
        }
        guard status == errSecItemNotFound else { throw KeychainReadFailure(status: status) }
        return try migrateFromLegacyLocation(account)
    }

    @discardableResult
    func delete(_ account: String) -> Bool {
        let status = deleteItem(account, group: accessGroup)
        if status == errSecSuccess || status == errSecItemNotFound {
            guard allowsAppLocalFallback, accessGroup != nil else { return true }
            let local = deleteItem(account, group: nil)
            if local == errSecSuccess || local == errSecItemNotFound { return true }
            storageLog.error("App Keychain delete failed: \(local, privacy: .public)")
            return false
        }
        if fallbackApplies(to: status) {
            let local = deleteItem(account, group: nil)
            if local == errSecSuccess || local == errSecItemNotFound {
                storageLog.notice("Deleted an item from the app's own Keychain")
                return true
            }
            storageLog.error("App Keychain delete failed: \(local, privacy: .public)")
            return false
        }
        storageLog.error("Keychain delete for \(account, privacy: .public) failed: \(status, privacy: .public)")
        return false
    }

    /// Removes every item of this service from each place this keychain may
    /// have used. False when any of them failed.
    @discardableResult
    func deleteAllItems() -> Bool {
        var groups: [String?] = [accessGroup]
        if accessGroup != nil { groups += legacyGroups }
        if allowsAppLocalFallback { groups.append(nil) }
        var visited: [String?] = []
        var succeeded = true
        for group in groups where !visited.contains(group) {
            let isConfigured = visited.isEmpty
            visited.append(group)
            let status = SecItemDelete(baseQuery(group: group) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { continue }
            if isConfigured, fallbackApplies(to: status) { continue }
            storageLog.error("Keychain clean-up failed: \(status, privacy: .public)")
            succeeded = false
        }
        return succeeded
    }

    // MARK: - Private

    /// The older places an item may still be: no group, then the team-prefixed
    /// bundle group earlier builds used.
    private var legacyGroups: [String?] {
        var groups: [String?] = [nil]
        if let prefix = SharedStorage.legacyTeamPrefix, let bundleID = Bundle.main.bundleIdentifier {
            groups.append(prefix + bundleID)
        }
        return groups
    }

    private func fallbackApplies(to status: OSStatus) -> Bool {
        allowsAppLocalFallback && accessGroup != nil && status == errSecMissingEntitlement
    }

    private func migrateFromLegacyLocation(_ account: String) throws -> String? {
        #if os(tvOS)
        if audience == .userIndependent {
            let personal = withAudience(.currentUser)
            if let value = try personal.getChecked(account) {
                if set(value, for: account) { personal.delete(account) }
                return value
            }
        }
        #endif
        guard accessGroup != nil else { return nil }
        for group in legacyGroups {
            let (status, value) = read(account, group: group)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let value else { throw KeychainReadFailure(status: status) }
            if set(value, for: account) { _ = deleteItem(account, group: group) }
            return value
        }
        return nil
    }

    private func baseQuery(group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        #if os(tvOS)
        if audience == .userIndependent, usesUserIndependentKeychain {
            query[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue
        }
        #endif
        return query
    }

    private func itemQuery(_ account: String, group: String?) -> [String: Any] {
        var query = baseQuery(group: group)
        query[kSecAttrAccount as String] = account
        return query
    }

    private func read(_ account: String, group: String?) -> (OSStatus, String?) {
        var query = itemQuery(account, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status: OSStatus
        let data: Data?
        if let readItem {
            (status, data) = readItem(query)
        } else {
            var result: CFTypeRef?
            status = SecItemCopyMatching(query as CFDictionary, &result)
            data = result as? Data
        }
        guard status == errSecSuccess else { return (status, nil) }
        guard let data, let value = String(data: data, encoding: .utf8) else { return (errSecDecode, nil) }
        return (errSecSuccess, value)
    }

    private func write(_ data: Data, account: String, group: String?) -> OSStatus {
        let query = itemQuery(account, group: group)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }

    private func deleteItem(_ account: String, group: String?) -> OSStatus {
        SecItemDelete(itemQuery(account, group: group) as CFDictionary)
    }
}

/// A clean install must not pick up Keychain items left by an earlier install,
/// because the Keychain outlives the app.
enum FreshInstallLocalData {
    private static let installationMarkerKey = "vivid.installationMarker.v1"
    private static let earlierInstallKeys: Set<String> = [
        "serverUrl", "activeServerId", "profileId", "vivid.accounts.v1", "vivid.didCompleteProviderSetup",
    ]

    /// Call before anything reads a credential.
    static func prepare() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: installationMarkerKey) == nil else { return }
        let hasEarlierInstall = defaults.dictionaryRepresentation().keys.contains { key in
            key.hasPrefix("vivid.") || earlierInstallKeys.contains(key)
        }
        if !hasEarlierInstall {
            SharedKeychain(audience: .currentUser).deleteAllItems()
            #if os(tvOS)
            SharedKeychain(audience: .userIndependent).deleteAllItems()
            #endif
        }
        defaults.set(UUID().uuidString, forKey: installationMarkerKey)
    }
}
