import Foundation
import Observation

enum UICustomizationCapabilityState: Equatable, Sendable {
    case checking
    case supported
    case unavailable
}

/// What the interface preferences store needs from the settings service.
/// The live one is `VividUICustomizationTransport`; tests supply their own.
protocol InterfaceSettingsTransport {
    func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult
    func effectiveValues(for keys: [SettingKey], requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse
    func putValue(_ value: SettingJSONValue, for key: SettingKey, scope: SettingScopeIdentity, mutationId: String, requestIdentity: HTTPRequestIdentity) async throws
    func deleteValue(for key: SettingKey, scope: SettingScopeIdentity, requestIdentity: HTTPRequestIdentity) async throws
}

final class VividUICustomizationTransport: InterfaceSettingsTransport, Sendable {
    private let api: VividAPI

    init(api: VividAPI = .shared) {
        self.api = api
    }

    /// Silo keeps interface settings on the device, so it never needs asking.
    func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        if SiloLocalInterfaceSettings.applies(toServerID: requestIdentity.serverId) {
            return .available(SiloLocalInterfaceSettings.capabilities)
        }
        return await api.getContractCapabilities(requestIdentity: requestIdentity)
    }

    func effectiveValues(for keys: [SettingKey], requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(keys: keys, profileId: requestIdentity.profileId, requestIdentity: requestIdentity)
    }

    func putValue(_ value: SettingJSONValue, for key: SettingKey, scope: SettingScopeIdentity, mutationId: String, requestIdentity: HTTPRequestIdentity) async throws {
        _ = try await api.putValue(
            key: key, scope: scope, value: value, mutationId: mutationId,
            profileId: requestIdentity.profileId, requestIdentity: requestIdentity
        )
    }

    func deleteValue(for key: SettingKey, scope: SettingScopeIdentity, requestIdentity: HTTPRequestIdentity) async throws {
        try await api.deleteValue(key: key, scope: scope, profileId: requestIdentity.profileId, requestIdentity: requestIdentity)
    }
}

/// The top menu and card style for the active server, profile and kind of
/// device. They're cached on the device so they paint at launch, synced
/// through the settings service, and edits made offline are kept in an
/// outbox and sent on the next refresh before anything is read back.
@MainActor @Observable
final class UICustomizationPreferences {
    static let shared: UICustomizationPreferences = {
        forgetSiloMenuCaches()
        return UICustomizationPreferences(
            storage: .shared,
            transport: VividUICustomizationTransport(),
            activeCacheKey: { liveIdentity().map(cacheKey(for:)) },
            activeIdentity: { liveIdentity() }
        )
    }()

    // MARK: Observed state

    private var storedMenu: PrimaryMenuPreference?
    private var storedCard = CardPresentationPreference.standard
    private var storedMenuSource: SettingSource?
    private var storedCardSource: SettingSource?
    private var projection = SupportProjection.unknown
    private(set) var capabilityState: UICustomizationCapabilityState
    private(set) var isSaving = false
    private(set) var syncErrorMessage: String?

    // MARK: Not observed

    @ObservationIgnored private let storage: SharedDefaults
    @ObservationIgnored private let transport: any InterfaceSettingsTransport
    @ObservationIgnored private let activeCacheKey: @MainActor () -> String?
    @ObservationIgnored private let activeIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var editCount = 0
    @ObservationIgnored private var queueTail: Task<Void, Never>?
    @ObservationIgnored private var queuedOperations = 0
    @ObservationIgnored private var keyErrors: [String: String] = [:]
    @ObservationIgnored private var refreshError: String?
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var pendingWrites: [String: PendingWrite] = [:]
    @ObservationIgnored private var pendingDeletes: [String: PendingDelete] = [:]

    init(
        storage: SharedDefaults,
        transport: any InterfaceSettingsTransport,
        activeCacheKey: @escaping @MainActor () -> String?,
        activeIdentity: @escaping @MainActor () -> HTTPRequestIdentity?,
        capabilityState: UICustomizationCapabilityState = .checking
    ) {
        self.storage = storage
        self.transport = transport
        self.activeCacheKey = activeCacheKey
        self.activeIdentity = activeIdentity
        self.capabilityState = capabilityState
        loadDocument(for: activeCacheKey())
    }

    // MARK: What screens read

    /// A server once recorded as unable to sync shows the defaults until a
    /// refresh finds it can.
    var primaryMenu: PrimaryMenuPreference? { projection == .knownUnsupported ? nil : storedMenu }
    var cardPresentation: CardPresentationPreference { projection == .knownUnsupported ? .standard : storedCard }
    private var menuSource: SettingSource? { projection == .knownUnsupported ? nil : storedMenuSource }
    private var cardSource: SettingSource? { projection == .knownUnsupported ? nil : storedCardSource }

    var allowsEditing: Bool { capabilityState == .supported }

    var capabilityMessage: String? {
        switch capabilityState {
        case .checking: String(localized: "Checking whether this server supports synced interface settings…")
        case .unavailable: Self.unavailableMessage
        case .supported: nil
        }
    }

    var primaryMenuUsesDeviceOverride: Bool { menuSource == .scope(.profileDevice) }
    var cardPresentationUsesDeviceOverride: Bool { cardSource == .scope(.profileDevice) }
    var cardPresentationUsesFamilyOverride: Bool { cardSource == .scope(.profileClient) }
    var hasDeviceOverrides: Bool { primaryMenuUsesDeviceOverride || cardPresentationUsesDeviceOverride }

    /// The tabs to show: the stored menu, or the default list when there's
    /// none or it holds only Home.
    func resolvedPrimaryMenuItems(availableLibraries: [Library] = []) -> [PrimaryMenuItem] {
        guard let menu = primaryMenu, menu.isValid else { return appleDefaultPrimaryMenuItems() }
        let items = menu.normalised.items
        return items == [.builtin(.home)] ? appleDefaultPrimaryMenuItems() : items
    }

    // MARK: Loading

    /// Repaints from the device cache, with no network.
    func restoreCachedPreferences() {
        refreshGeneration += 1
        loadDocument(for: activeCacheKey())
    }

    func refresh() async {
        let target = activeCacheKey()
        loadDocument(for: target)
        refreshGeneration += 1
        let generation = refreshGeneration
        let edits = editCount
        let startIdentity = target.flatMap(validIdentity(for:))
        let isStale = { [self] in
            generation != refreshGeneration || edits != editCount || activeCacheKey() != target
                || target.flatMap(validIdentity(for:)) != startIdentity
        }

        guard let target, let identity = startIdentity else {
            capabilityState = .unavailable
            setRefreshError(Self.unavailableMessage)
            return
        }

        capabilityState = .checking
        setRefreshError(nil)
        let answer = await transport.contractCapabilities(requestIdentity: identity)
        guard !isStale() else { return }
        guard case .available(let capabilities) = answer, capabilities.supportsUICustomizationRevision else {
            capabilityState = .unavailable
            setRefreshError(Self.unavailableMessage)
            return
        }
        capabilityState = .supported
        projection = .supported
        writeDocument()

        // Edits made offline go first, so the server's values can't overwrite them.
        guard await replayOutbox(context: EditContext(key: target, identity: identity), isStale: isStale) else { return }

        let keys: [SettingKey] = [.navPrimaryMenu, .uiCardPresentation]
        do {
            let rows = try await transport.effectiveValues(for: keys, requestIdentity: identity).byKey
            guard !isStale() else { return }
            var applied = 0
            for key in keys {
                if let row = rows[key] {
                    if apply(row, for: key) { applied += 1 }
                } else {
                    setKeyError(key, Self.missingRowMessage)
                }
            }
            if applied == keys.count { keyErrors = [:] }
            setRefreshError(nil)
            writeDocument()
        } catch {
            guard !isStale() else { return }
            setRefreshError(Self.message(for: error))
        }
    }

    /// Replaces what's on screen with the cached document for `key`, cleaned
    /// of anything this build doesn't use, and writes the cleaned copy back.
    private func loadDocument(for key: String?) {
        if key != loadedKey {
            if loadedKey != nil { capabilityState = .checking }
            loadedKey = key
            keyErrors = [:]
            refreshError = nil
            publishErrors()
        }
        storedMenu = nil
        storedCard = .standard
        storedMenuSource = nil
        storedCardSource = nil
        projection = .unknown
        pendingWrites = [:]
        pendingDeletes = [:]

        guard let key, let data = storage.data(forKey: key),
              let document = try? SettingsWireCoding.makeDecoder().decode(CacheDocument.self, from: data) else { return }

        if let menu = document.primaryMenu, menu.isValid { storedMenu = menu.normalised }
        storedCard = document.cardPresentation
        storedMenuSource = document.primaryMenuSource
        storedCardSource = document.cardPresentationSource
        projection = document.supportProjection

        for (rawKey, write) in document.pendingSyncWrites {
            switch rawKey {
            case SettingKey.uiCardPresentation.rawValue:
                pendingWrites[rawKey] = write
            case SettingKey.navPrimaryMenu.rawValue:
                guard let menu = try? write.value.decoded(as: PrimaryMenuPreference.self), menu.isValid,
                      let value = try? SettingJSONValue.encoding(menu.normalised) else { continue }
                let mutationId = value == write.value ? write.mutationId : newSettingMutationId()
                pendingWrites[rawKey] = PendingWrite(mutationId: mutationId, value: value)
            default:
                continue
            }
        }

        let syncedKeys = [SettingKey.navPrimaryMenu.rawValue, SettingKey.uiCardPresentation.rawValue]
        for (identity, delete) in document.pendingDeletes {
            let rawKey = identity.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? identity
            guard syncedKeys.contains(rawKey),
                  delete.scope == .profileClient || delete.scope == .profileDevice,
                  !delete.operationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  identity == Self.deleteIdentity(rawKey, delete.scope) else { continue }
            pendingDeletes[identity] = delete
        }

        writeDocument()
    }

    private func writeDocument() {
        guard let key = loadedKey else { return }
        let document = CacheDocument(
            cardPresentation: storedCard,
            primaryMenu: storedMenu,
            primaryMenuSource: storedMenuSource,
            cardPresentationSource: storedCardSource,
            supportProjection: projection,
            pendingSyncWrites: pendingWrites,
            pendingDeletes: pendingDeletes
        )
        guard let data = try? SettingsWireCoding.makeEncoder().encode(document) else { return }
        storage.set(data, forKey: key)
    }

    /// Takes one row from the server. Nothing changes for a row this build
    /// can't use.
    @discardableResult
    private func apply(_ row: EffectiveSettingValue, for key: SettingKey) -> Bool {
        switch key {
        case .navPrimaryMenu:
            if row.value.isNull {
                storedMenu = nil
            } else {
                guard let menu = try? row.value.decoded(as: PrimaryMenuPreference.self), menu.isValid else {
                    setKeyError(key, Self.unreadableRowMessage)
                    return false
                }
                storedMenu = menu.normalised
            }
            storedMenuSource = row.source
        case .uiCardPresentation:
            guard let card = try? row.value.decoded(as: CardPresentationPreference.self) else {
                setKeyError(key, Self.unreadableRowMessage)
                return false
            }
            storedCard = card
            storedCardSource = row.source
        default:
            return false
        }
        setKeyError(key, nil)
        return true
    }

    // MARK: Editing

    func setCardPresentation(_ value: CardPresentationPreference) {
        guard !cardPresentationUsesDeviceOverride, let context = editingContext() else { return }
        editCount += 1
        storedCard = value
        storedCardSource = .scope(.profileClient)
        pendingDeletes[Self.deleteIdentity(SettingKey.uiCardPresentation.rawValue, .profileClient)] = nil
        send(value, for: .uiCardPresentation, context: context)
    }

    func setPosterSize(_ value: CardPosterSize) {
        var card = cardPresentation
        card.posterSize = value
        setCardPresentation(card)
    }

    func setCaptionStyle(_ value: CardCaptionStyle) {
        var card = cardPresentation
        card.caption = value
        setCardPresentation(card)
    }

    func setPrimaryMenuItems(_ items: [PrimaryMenuItem]) {
        guard !primaryMenuUsesDeviceOverride, let context = editingContext() else { return }
        let menu = PrimaryMenuPreference(items: items).normalised
        editCount += 1
        storedMenu = menu
        storedMenuSource = .scope(.profileClient)
        pendingDeletes[Self.deleteIdentity(SettingKey.navPrimaryMenu.rawValue, .profileClient)] = nil
        send(menu, for: .navPrimaryMenu, context: context)
    }

    /// Drops this device's own choices so it follows the profile's.
    func useFamilySettings() {
        guard let context = editingContext() else { return }
        if primaryMenuUsesDeviceOverride { deleteRow(.navPrimaryMenu, scope: .profileDevice, context: context) }
        if cardPresentationUsesDeviceOverride { deleteRow(.uiCardPresentation, scope: .profileDevice, context: context) }
        let queued = queueTail
        Task { [weak self] in
            await queued?.value
            guard let self, isCurrent(context), keyErrors.isEmpty else { return }
            await refresh()
        }
    }

    /// Drops this kind of device's card choice so it follows the profile's.
    func resetCardPresentationToInherited() {
        guard let context = editingContext() else { return }
        editCount += 1
        pendingWrites[SettingKey.uiCardPresentation.rawValue] = nil
        storedCardSource = nil
        deleteRow(.uiCardPresentation, scope: .profileClient, context: context)
        let queued = queueTail
        Task { [weak self] in
            await queued?.value
            guard let self, isCurrent(context), keyErrors[SettingKey.uiCardPresentation.rawValue] == nil else { return }
            await refresh()
        }
    }

    // MARK: Sending

    /// The server and profile an edit was made for. Work for an earlier
    /// account never reaches a later one.
    private struct EditContext {
        let key: String
        let identity: HTTPRequestIdentity
    }

    private func editingContext() -> EditContext? {
        guard allowsEditing, let key = activeCacheKey(), let identity = validIdentity(for: key) else { return nil }
        return EditContext(key: key, identity: identity)
    }

    private func isCurrent(_ context: EditContext) -> Bool {
        activeCacheKey() == context.key && validIdentity(for: context.key) == context.identity
    }

    private func validIdentity(for key: String) -> HTTPRequestIdentity? {
        guard let identity = activeIdentity(), Self.cacheKey(for: identity) == key else { return nil }
        return identity
    }

    private func send(_ value: some Encodable, for key: SettingKey, context: EditContext) {
        let json: SettingJSONValue
        do {
            json = try SettingJSONValue.encoding(value)
        } catch {
            setKeyError(key, Self.message(for: error))
            return
        }
        let write = PendingWrite(mutationId: newSettingMutationId(), value: json)
        pendingWrites[key.rawValue] = write
        writeDocument()
        queuePut(write, for: key, context: context)
    }

    private func queuePut(_ write: PendingWrite, for key: SettingKey, context: EditContext) {
        enqueue { store in
            guard store.isCurrent(context) else { return }
            do {
                try await store.transport.putValue(
                    write.value, for: key, scope: .profileClient,
                    mutationId: write.mutationId, requestIdentity: context.identity
                )
                guard store.isCurrent(context) else { return }
                if store.pendingWrites[key.rawValue]?.mutationId == write.mutationId {
                    store.pendingWrites[key.rawValue] = nil
                    store.writeDocument()
                }
                store.setKeyError(key, nil)
            } catch {
                guard store.isCurrent(context) else { return }
                if Self.isPermanentRejection(error) {
                    await store.settleRejectedWrite(write, for: key, context: context)
                } else {
                    // The edit stays on screen and is resent with the same id.
                    store.setKeyError(key, Self.message(for: error))
                }
            }
        }
    }

    /// The server refused the edit for good: show what it holds instead.
    private func settleRejectedWrite(_ write: PendingWrite, for key: SettingKey, context: EditContext) async {
        guard pendingWrites[key.rawValue]?.mutationId == write.mutationId else { return }
        pendingWrites[key.rawValue] = nil
        writeDocument()
        let stillApplies = { [self] in isCurrent(context) && pendingWrites[key.rawValue] == nil }
        do {
            let rows = try await transport.effectiveValues(for: [key], requestIdentity: context.identity).byKey
            guard stillApplies() else { return }
            guard let row = rows[key] else {
                setKeyError(key, Self.missingRowMessage)
                return
            }
            if apply(row, for: key) { writeDocument() }
        } catch {
            guard stillApplies() else { return }
            setKeyError(key, Self.message(for: error))
        }
    }

    private func deleteRow(_ key: SettingKey, scope: SettingScopeIdentity, context: EditContext) {
        let identity = Self.deleteIdentity(key.rawValue, scope.scope)
        let delete = PendingDelete(operationId: UUID().uuidString, scope: scope.scope)
        pendingDeletes[identity] = delete
        if scope == .profileClient { pendingWrites[key.rawValue] = nil }
        writeDocument()
        queueDelete(delete, identity: identity, for: key, context: context)
    }

    private func queueDelete(_ delete: PendingDelete, identity: String, for key: SettingKey, context: EditContext) {
        let scope: SettingScopeIdentity = delete.scope == .profileClient ? .profileClient : .profileDevice
        enqueue { store in
            guard store.isCurrent(context) else { return }
            do {
                try await store.transport.deleteValue(for: key, scope: scope, requestIdentity: context.identity)
                guard store.isCurrent(context) else { return }
                await store.settleAcceptedDelete(delete, identity: identity, for: key, scope: scope, context: context)
            } catch {
                guard store.isCurrent(context) else { return }
                if SettingsAPIError.from(error) == .noValueAtScope {
                    // Already gone, which is what was asked for.
                    await store.settleAcceptedDelete(delete, identity: identity, for: key, scope: scope, context: context)
                } else if store.pendingDeletes[identity]?.operationId == delete.operationId {
                    store.setKeyError(key, String(localized: "Could not reset this setting to its inherited value."))
                }
            }
        }
    }

    private func settleAcceptedDelete(
        _ delete: PendingDelete, identity: String, for key: SettingKey,
        scope: SettingScopeIdentity, context: EditContext
    ) async {
        guard pendingDeletes[identity]?.operationId == delete.operationId else { return }
        guard scope == .profileDevice else {
            pendingDeletes[identity] = nil
            writeDocument()
            setKeyError(key, nil)
            return
        }
        // A device row went: read what the key falls back to.
        let stillApplies = { [self] in isCurrent(context) && pendingDeletes[identity]?.operationId == delete.operationId }
        do {
            let rows = try await transport.effectiveValues(for: [key], requestIdentity: context.identity).byKey
            guard stillApplies() else { return }
            guard let row = rows[key] else {
                setKeyError(key, Self.missingRowMessage)
                return
            }
            if apply(row, for: key) {
                pendingDeletes[identity] = nil
                writeDocument()
            }
        } catch {
            guard stillApplies() else { return }
            setKeyError(key, Self.message(for: error))
        }
    }

    /// Sends what was edited offline, deletes first. True when nothing is
    /// left waiting.
    private func replayOutbox(context: EditContext, isStale: () -> Bool) async -> Bool {
        await waitForQueue()
        guard !isStale() else { return false }
        let deletes = pendingDeletes.sorted { $0.key < $1.key }
        let writes = [SettingKey.navPrimaryMenu, .uiCardPresentation].compactMap { key in
            pendingWrites[key.rawValue].map { (key, $0) }
        }
        guard !deletes.isEmpty || !writes.isEmpty else { return true }
        for (identity, delete) in deletes {
            let rawKey = String(identity.prefix { $0 != "|" })
            guard let key = SettingKey(rawValue: rawKey) else { continue }
            queueDelete(delete, identity: identity, for: key, context: context)
        }
        for (key, write) in writes {
            queuePut(write, for: key, context: context)
        }
        await waitForQueue()
        guard !isStale() else { return false }
        return pendingWrites.isEmpty && pendingDeletes.isEmpty
    }

    // MARK: Save queue

    /// Runs writes and deletes one at a time, in order.
    private func enqueue(_ operation: @escaping @MainActor (UICustomizationPreferences) async -> Void) {
        queuedOperations += 1
        isSaving = true
        let previous = queueTail
        queueTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
            queuedOperations = max(0, queuedOperations - 1)
            isSaving = queuedOperations > 0
        }
    }

    private func waitForQueue() async {
        while let tail = queueTail {
            await tail.value
            if queueTail == tail { return }
        }
    }

    // MARK: Errors

    private func setKeyError(_ key: SettingKey, _ message: String?) {
        keyErrors[key.rawValue] = message
        publishErrors()
    }

    private func setRefreshError(_ message: String?) {
        refreshError = message
        publishErrors()
    }

    private func publishErrors() {
        syncErrorMessage = refreshError
            ?? keyErrors[SettingKey.navPrimaryMenu.rawValue]
            ?? keyErrors[SettingKey.uiCardPresentation.rawValue]
    }

    private static var unavailableMessage: String {
        String(localized: "Interface settings are read-only until server support can be verified.")
    }

    private static var unreadableRowMessage: String {
        String(localized: "Could not read this interface preference from the server.")
    }

    private static var missingRowMessage: String {
        String(localized: "The server did not return this interface preference.")
    }

    private static func message(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .serverUpgradeRequired, .unknownSetting:
            String(localized: "Update this Silo server to sync interface preferences.")
        case .transport:
            String(localized: "Saved on this device. Sync will resume when the server is reachable.")
        default:
            String(localized: "Saved on this device, but the server did not accept the change.")
        }
    }

    /// Errors that will never succeed on a retry, so the edit isn't resent.
    nonisolated static func isPermanentRejection(_ error: Error) -> Bool {
        switch SettingsAPIError.from(error) {
        case .unknownSetting, .clientLocalSetting, .scopeNotAllowed, .invalidValue:
            true
        case .server(let status, _, _):
            [400, 410, 413, 415, 422].contains(status)
        default:
            false
        }
    }

    // MARK: Session and storage

    private static func liveIdentity() -> HTTPRequestIdentity? {
        let registry = ServerRegistry.shared
        guard let entry = registry.activeServer, registry.activeServerId == entry.id,
              let profileId = AuthService.shared.profileId, !profileId.isEmpty else { return nil }
        return HTTPRequestIdentity(
            serverId: entry.id, serverURL: entry.url, profileId: profileId,
            clientFamily: AppleDeviceIdentity.current.clientFamily
        )
    }

    static func cacheKey(for identity: HTTPRequestIdentity) -> String {
        "\(cachePrefix)\(identity.serverId).\(identity.profileId).\(identity.clientFamily)"
    }

    private static let cachePrefix = "vivid.uiCustomization."
    private static let siloCacheClearedKey = "vivid.siloMenuCacheCleared.v1"

    private static func deleteIdentity(_ rawKey: String, _ scope: SettingScope) -> String {
        "\(rawKey)|\(scope.rawValue)"
    }

    /// Silo now keeps its interface settings on the device, so menus cached
    /// from Silo servers before that are dropped, once per device. Emby and
    /// Jellyfin caches stay.
    static func forgetSiloMenuCaches(suite: UserDefaults = SharedStorage.suite, standard: UserDefaults = .standard) {
        guard !suite.bool(forKey: siloCacheClearedKey), !standard.bool(forKey: siloCacheClearedKey) else { return }
        for defaults in [suite, standard] {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(cachePrefix) {
                let serverId = key.dropFirst(cachePrefix.count).split(separator: ".").first.map(String.init)
                if MediaServerProvider.forServerID(serverId) == .silo {
                    defaults.removeObject(forKey: key)
                }
            }
            defaults.set(true, forKey: siloCacheClearedKey)
        }
    }
}

// MARK: - Cache document

private enum SupportProjection: String, Codable {
    case unknown
    case supported
    case knownUnsupported = "known_unsupported"
}

private struct PendingWrite: Codable {
    let mutationId: String
    let value: SettingJSONValue
}

private struct PendingDelete: Codable {
    let operationId: String
    let scope: SettingScope

    init(operationId: String, scope: SettingScope) {
        self.operationId = operationId
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey { case operationId, scope }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try container.decodeIfPresent(String.self, forKey: .operationId) ?? UUID().uuidString
        scope = try container.decode(SettingScope.self, forKey: .scope)
    }
}

/// What the device keeps for one server, profile and kind of device. Read
/// all or nothing: one field this build can't read discards the document.
private struct CacheDocument: Codable {
    var cardPresentation: CardPresentationPreference
    var primaryMenu: PrimaryMenuPreference?
    var primaryMenuSource: SettingSource?
    var cardPresentationSource: SettingSource?
    var supportProjection: SupportProjection
    var pendingSyncWrites: [String: PendingWrite]
    var pendingDeletes: [String: PendingDelete]

    init(
        cardPresentation: CardPresentationPreference, primaryMenu: PrimaryMenuPreference?,
        primaryMenuSource: SettingSource?, cardPresentationSource: SettingSource?,
        supportProjection: SupportProjection,
        pendingSyncWrites: [String: PendingWrite], pendingDeletes: [String: PendingDelete]
    ) {
        self.cardPresentation = cardPresentation
        self.primaryMenu = primaryMenu
        self.primaryMenuSource = primaryMenuSource
        self.cardPresentationSource = cardPresentationSource
        self.supportProjection = supportProjection
        self.pendingSyncWrites = pendingSyncWrites
        self.pendingDeletes = pendingDeletes
    }

    private enum CodingKeys: String, CodingKey {
        case cardPresentation, primaryMenu, primaryMenuSource, cardPresentationSource
        case supportProjection, pendingSyncWrites, pendingDeletes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardPresentation = try container.decode(CardPresentationPreference.self, forKey: .cardPresentation)
        primaryMenu = try container.decodeIfPresent(PrimaryMenuPreference.self, forKey: .primaryMenu)
        primaryMenuSource = try container.decodeIfPresent(SettingSource.self, forKey: .primaryMenuSource)
        cardPresentationSource = try container.decodeIfPresent(SettingSource.self, forKey: .cardPresentationSource)
        supportProjection = try container.decodeIfPresent(SupportProjection.self, forKey: .supportProjection) ?? .unknown
        pendingSyncWrites = try container.decodeIfPresent([String: PendingWrite].self, forKey: .pendingSyncWrites) ?? [:]
        pendingDeletes = try container.decodeIfPresent([String: PendingDelete].self, forKey: .pendingDeletes) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cardPresentation, forKey: .cardPresentation)
        try container.encodeIfPresent(primaryMenu, forKey: .primaryMenu)
        try container.encodeIfPresent(primaryMenuSource, forKey: .primaryMenuSource)
        try container.encodeIfPresent(cardPresentationSource, forKey: .cardPresentationSource)
        try container.encode(supportProjection, forKey: .supportProjection)
        if !pendingSyncWrites.isEmpty { try container.encode(pendingSyncWrites, forKey: .pendingSyncWrites) }
        if !pendingDeletes.isEmpty { try container.encode(pendingDeletes, forKey: .pendingDeletes) }
    }
}
