import Foundation
import Observation

// MARK: - Shared wire models

enum CardPosterSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    /// Artwork scale used by free-scrolling rails and standalone cards.
    /// Grids also adjust their column count so the selected size never causes
    /// overlapping focus frames.
    var scale: CGFloat {
        switch self {
        case .compact: return 0.86
        case .standard: return 1
        case .large: return 1.2
        }
    }
}

enum CardCaptionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case titleMetadata = "title_metadata"
    case title
    case artwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleMetadata:
            return "Title & Year"
        case .title: return "Title Only"
        case .artwork: return "Artwork Only"
        }
    }

    var showsTitle: Bool { self != .artwork }
    var showsMetadata: Bool { self == .titleMetadata }
}

struct CardPresentationPreference: Codable, Equatable, Sendable {
    var posterSize: CardPosterSize
    var caption: CardCaptionStyle

    enum CodingKeys: String, CodingKey {
        case posterSize = "poster_size"
        case caption
    }

    static let standard = CardPresentationPreference(
        posterSize: .standard,
        caption: .titleMetadata
    )

    var preset: CardPresentationPreset? {
        CardPresentationPreset.allCases.first(where: { $0.presentation == self })
    }
}

/// Friendly cross-client recipes over the two contract axes. The server keeps
/// the normalized size/caption object, so a user can start from a preset and
/// still fine-tune either control without inventing another wire format.
enum CardPresentationPreset: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case compact
    case cinema
    case artworkOnly = "artwork_only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .compact: return "Compact"
        case .cinema: return "Cinema"
        case .artworkOnly: return "Artwork Only"
        }
    }

    var presentation: CardPresentationPreference {
        switch self {
        case .balanced:
            return .standard
        case .compact:
            return .init(posterSize: .compact, caption: .title)
        case .cinema:
            return .init(posterSize: .large, caption: .title)
        case .artworkOnly:
            return .init(posterSize: .large, caption: .artwork)
        }
    }
}

enum PrimaryMenuBuiltin: String, Codable, CaseIterable, Identifiable, Sendable {
    case home
    case movies
    case series
    case forYou = "for_you"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .movies: return "Movies"
        case .series: return "Series"
        case .forYou: return "For You"
        }
    }

    var navigationIcon: String {
        switch self {
        case .home: return AppTab.home.icon
        case .movies: return "film.stack"
        case .series: return "tv"
        case .forYou: return AppTab.recommendations.icon
        }
    }
}

func appleDefaultPrimaryMenuItems() -> [PrimaryMenuItem] {
    [
        .builtin(.home),
        .builtin(.movies),
        .builtin(.series),
        .builtin(.forYou),
    ]
}

/// A server primary-menu item. Retired destinations are decoded only for compatibility.
///
/// The associated-value representation keeps impossible combinations out of
/// app state while custom coding preserves the contract's flat tagged object.
enum PrimaryMenuItem: Hashable, Identifiable, Sendable {
    case builtin(PrimaryMenuBuiltin)
    case library(libraryId: Int, label: String)
    case section(libraryId: Int, sectionId: String, label: String)
    case collection(collectionId: String, label: String, libraryId: Int?)

    var id: String {
        switch self {
        case .builtin(let destination):
            return "builtin:\(destination.rawValue)"
        case .library(let libraryId, _):
            return "library:\(libraryId)"
        case .section(let libraryId, let sectionId, _):
            return "section:\(libraryId):\(sectionId)"
        case .collection(let collectionId, _, let libraryId):
            let libraryValue = libraryId.map(String.init) ?? ""
            let libraryPresence = libraryId == nil ? "0" : "1"
            return "collection|\(libraryPresence)"
                + "|\(Self.identityComponent(libraryValue))"
                + "|\(Self.identityComponent(collectionId))"
        }
    }

    /// Pre-structured identity used by caches written before collection IDs
    /// became length-prefixed. It is accepted only while migrating an outbox;
    /// all live equality, deduplication, and focus identity uses ``id``.

    var title: String {
        switch self {
        case .builtin(let destination): return destination.title
        case .library(_, let label), .section(_, _, let label), .collection(_, let label, _):
            return label
        }
    }

    var isHome: Bool { self == .builtin(.home) }

    var navigationIcon: String {
        switch self {
        case .builtin(let destination): return destination.navigationIcon
        case .library, .section, .collection: return "rectangle.stack"
        }
    }

    var isContractValid: Bool {
        switch self {
        case .builtin:
            return true
        case .library(let libraryId, let label):
            return libraryId > 0 && Self.isValidLabel(label)
        case .section(let libraryId, let sectionId, let label):
            return libraryId > 0
                && Self.isValidTargetId(sectionId)
                && Self.isValidLabel(label)
        case .collection(let collectionId, let label, let libraryId):
            return (libraryId.map { $0 > 0 } ?? true)
                && Self.isValidTargetId(collectionId)
                && Self.isValidLabel(label)
        }
    }

    var libraryId: Int? {
        switch self {
        case .library(let id, _), .section(let id, _, _): return id
        case .collection(_, _, let id): return id
        case .builtin: return nil
        }
    }

    private static func isValidLabel(_ value: String) -> Bool {
        value.count <= 256
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidTargetId(_ value: String) -> Bool {
        value.count <= 128
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func identityComponent(_ value: String) -> String {
        "\(value.utf8.count)#\(value)"
    }
}

extension PrimaryMenuItem: Codable {
    private enum ItemType: String, Codable {
        case builtin
        case library
        case section
        case collection
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case destination
        case libraryId = "library_id"
        case sectionId = "section_id"
        case collectionId = "collection_id"
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ItemType.self, forKey: .type) {
        case .builtin:
            self = .builtin(try container.decode(PrimaryMenuBuiltin.self, forKey: .destination))
        case .library:
            self = .library(
                libraryId: try container.decode(Int.self, forKey: .libraryId),
                label: try container.decode(String.self, forKey: .label)
            )
        case .section:
            self = .section(
                libraryId: try container.decode(Int.self, forKey: .libraryId),
                sectionId: try container.decode(String.self, forKey: .sectionId),
                label: try container.decode(String.self, forKey: .label)
            )
        case .collection:
            self = .collection(
                collectionId: try container.decode(String.self, forKey: .collectionId),
                label: try container.decode(String.self, forKey: .label),
                libraryId: try container.decodeIfPresent(Int.self, forKey: .libraryId)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let destination):
            try container.encode(ItemType.builtin, forKey: .type)
            try container.encode(destination, forKey: .destination)
        case .library(let libraryId, let label):
            try container.encode(ItemType.library, forKey: .type)
            try container.encode(libraryId, forKey: .libraryId)
            try container.encode(label, forKey: .label)
        case .section(let libraryId, let sectionId, let label):
            try container.encode(ItemType.section, forKey: .type)
            try container.encode(libraryId, forKey: .libraryId)
            try container.encode(sectionId, forKey: .sectionId)
            try container.encode(label, forKey: .label)
        case .collection(let collectionId, let label, let libraryId):
            try container.encode(ItemType.collection, forKey: .type)
            try container.encode(collectionId, forKey: .collectionId)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(libraryId, forKey: .libraryId)
        }
    }
}

private struct RetainedMenuItem: Decodable {
    let item: PrimaryMenuItem?
    private enum CodingKeys: String, CodingKey { case type, destination }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .type) == "builtin" {
            guard let destination = try? container.decode(
                PrimaryMenuBuiltin.self,
                forKey: .destination
            ) else {
                item = nil
                return
            }
            item = .builtin(destination)
            return
        }
        item = try PrimaryMenuItem(from: decoder)
    }
}

struct PrimaryMenuPreference: Codable, Equatable, Sendable {
    var items: [PrimaryMenuItem]

    init(items: [PrimaryMenuItem]) {
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([RetainedMenuItem].self, forKey: .items).compactMap(\.item)
    }

    /// The server validates this too. Rechecking at the client boundary makes
    /// a corrupt offline cache harmless instead of rendering a focus graph
    /// with no Home anchor or duplicate identities.
    var isValid: Bool {
        items.count >= 1
            && items.count <= 64
            && items.allSatisfy(\.isContractValid)
            && items.filter(\.isHome).count == 1
            && Set(items.map(\.id)).count == items.count
    }
}

// MARK: - Transport

protocol UICustomizationTransport: AnyObject, Sendable {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult
    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse
    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws
    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws
}

extension UICustomizationTransport {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        .serverUpgradeRequired
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        throw URLError(.unsupportedURL)
    }
}

final class VividUICustomizationTransport: UICustomizationTransport {
    private let api: VividAPI

    init(api: VividAPI = .shared) {
        self.api = api
    }

    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        await api.getContractCapabilities(requestIdentity: requestIdentity)
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(
            keys: keys,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        _ = try await api.putValue(
            key: key,
            scope: scope,
            value: value,
            mutationId: mutationId,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.deleteValue(
            key: key,
            scope: scope,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }
}

enum UICustomizationCapabilityState: Equatable, Sendable {
    case checking
    case supported
    case serverUpgradeRequired
    case unavailable

    var allowsEditing: Bool { self == .supported }

    var userMessage: String? {
        switch self {
        case .checking:
            return "Checking whether this server supports synced interface settings…"
        case .supported:
            return nil
        case .serverUpgradeRequired:
            return "Update this Silo server to use synced interface settings."
        case .unavailable:
            return "Interface settings are read-only until server support can be verified."
        }
    }
}

/// Last authoritative compatibility conclusion for one server/profile/family
/// cache. Probe failures are deliberately not conclusions: offline clients can
/// keep rendering a previously valid cache, while an explicitly older server
/// must not keep revision-5 navigation or card presentation active.
enum UICustomizationSupportProjection: String, Codable, Equatable, Sendable {
    case unknown
    case supported
    case knownUnsupported = "known_unsupported"

    var projectsCachedValues: Bool { self != .knownUnsupported }
}

// MARK: - Observable preference store

/// Effective UI customization for the active profile and client family.
///
/// Server values are authoritative when reachable. A per-profile/family cache
/// is painted first and updated optimistically so navigation and poster layout
/// remain useful offline; a failed sync never erases the last working UI.
@MainActor
@Observable
final class UICustomizationPreferences {
    static let shared = UICustomizationPreferences()

    private var storedPrimaryMenu: PrimaryMenuPreference?
    private var storedCardPresentation: CardPresentationPreference = .standard
    private var storedPrimaryMenuSource: SettingSource?
    private var storedCardPresentationSource: SettingSource?
    private(set) var isRefreshing = false
    private(set) var isSaving = false
    private(set) var syncErrorMessage: String?
    private(set) var capabilityState: UICustomizationCapabilityState = .checking
    private(set) var supportProjection: UICustomizationSupportProjection = .unknown

    var primaryMenu: PrimaryMenuPreference? {
        supportProjection.projectsCachedValues ? storedPrimaryMenu : nil
    }
    var cardPresentation: CardPresentationPreference {
        supportProjection.projectsCachedValues ? storedCardPresentation : .standard
    }
    var primaryMenuSource: SettingSource? {
        supportProjection.projectsCachedValues ? storedPrimaryMenuSource : nil
    }
    var cardPresentationSource: SettingSource? {
        supportProjection.projectsCachedValues ? storedCardPresentationSource : nil
    }

    var allowsEditing: Bool { capabilityState.allowsEditing }
    var capabilityMessage: String? { capabilityState.userMessage }

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let transport: UICustomizationTransport
    @ObservationIgnored private let cacheKey: @MainActor () -> String?
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var localMutationRevision = 0
    @ObservationIgnored private var saveTail: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveCount = 0
    @ObservationIgnored private var syncErrorsByKey: [String: String] = [:]
    @ObservationIgnored private var refreshSyncErrorMessage: String?
    @ObservationIgnored private var loadedCacheKey: String?
    @ObservationIgnored private var pendingSyncWrites: [String: PendingSyncWrite] = [:]
    @ObservationIgnored private var pendingDeletes: [String: PendingDelete] = [:]

    private struct OperationContext {
        let cacheKey: String
        let requestIdentity: HTTPRequestIdentity
    }

    private struct PendingSyncWrite: Codable {
        let value: SettingJSONValue
        /// The settings API requires one stable idempotency key for the whole
        /// lifetime of a retry. A new user edit replaces this record and gets
        /// a new mutation id; connectivity retries reuse the existing one.
        let mutationId: String
    }

    private struct PendingDelete: Codable {
        let scope: SettingScope
        /// A local operation identity prevents an older queued DELETE from
        /// clearing a newer same-scope reset that still needs to be replayed.
        let operationId: String

        private enum CodingKeys: String, CodingKey {
            case scope
            case operationId
        }

        init(scope: SettingScope, operationId: String = newSettingMutationId()) {
            self.scope = scope
            self.operationId = operationId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try container.decode(SettingScope.self, forKey: .scope)
            operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
                ?? newSettingMutationId()
        }

        var scopeIdentity: SettingScopeIdentity? {
            switch scope {
            case .profileClient: return .profileClient
            case .profileDevice: return .profileDevice
            default: return nil
            }
        }
    }

    private struct Cache: Codable {
        let primaryMenu: PrimaryMenuPreference?
        let cardPresentation: CardPresentationPreference
        let primaryMenuSource: SettingSource?
        let cardPresentationSource: SettingSource?
        let supportProjection: UICustomizationSupportProjection?
        let pendingSyncWrites: [String: PendingSyncWrite]?
        let pendingDeletes: [String: PendingDelete]?
    }

    init(
        defaults: SharedDefaults = .shared,
        transport: UICustomizationTransport = VividUICustomizationTransport(),
        cacheKey: @escaping @MainActor () -> String? = UICustomizationPreferences.activeCacheKey,
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = UICustomizationPreferences.activeRequestIdentity,
        initialCapabilityState: UICustomizationCapabilityState = .checking
    ) {
        self.defaults = defaults
        self.transport = transport
        self.cacheKey = cacheKey
        self.requestIdentity = requestIdentity
        capabilityState = initialCapabilityState
        loadCache(for: cacheKey())
    }

    /// Repaint from the active identity's cache, then reconcile from the
    /// server. Transiently unknown servers retain the last compatible cache;
    /// explicitly older servers project the legacy/default presentation.
    func refresh() async {
        let targetCacheKey = cacheKey()
        loadCache(for: targetCacheKey)
        refreshSequence += 1
        let sequence = refreshSequence
        let mutationRevision = localMutationRevision
        isRefreshing = true
        defer {
            if refreshSequence == sequence {
                isRefreshing = false
            }
        }

        guard let identity = capturedIdentity(for: targetCacheKey) else {
            capabilityState = .unavailable
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            return
        }

        capabilityState = .checking
        // A new probe supersedes the prior probe/read failure. Per-key outbox
        // failures remain visible until their own retry succeeds.
        refreshSyncErrorMessage = nil
        updateSyncErrorMessage()
        let capabilities = await transport.contractCapabilities(requestIdentity: identity)
        guard refreshSequence == sequence,
              localMutationRevision == mutationRevision,
              cacheKey() == targetCacheKey,
              capturedIdentity(for: targetCacheKey) == identity else { return }

        switch capabilities {
        case .available(let capabilities) where capabilities.supportsUICustomizationRevision:
            capabilityState = .supported
            supportProjection = .supported
            saveCache(for: targetCacheKey)
        case .available, .serverUpgradeRequired:
            capabilityState = .serverUpgradeRequired
            supportProjection = .knownUnsupported
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            saveCache(for: targetCacheKey)
            return
        case .failed:
            capabilityState = .unavailable
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            return
        }

        do {
            guard await drainPendingWrites(
                targetCacheKey: targetCacheKey,
                requestIdentity: identity,
                sequence: sequence,
                mutationRevision: mutationRevision
            ) else { return }
            let response = try await transport.effectiveValues(
                keys: Self.keys,
                requestIdentity: identity
            )
            guard refreshSequence == sequence,
                  localMutationRevision == mutationRevision,
                  cacheKey() == targetCacheKey,
                  capturedIdentity(for: targetCacheKey) == identity else { return }
            let values = response.byKey
            var decodedEveryValue = true
            for key in Self.keys {
                guard let row = values[key] else {
                    setSyncError(Self.missingEffectiveValueMessage, for: key)
                    decodedEveryValue = false
                    continue
                }
                decodedEveryValue = applyEffectiveValue(row, for: key) && decodedEveryValue
            }

            if decodedEveryValue {
                clearReconciledSyncErrors()
            } else {
                refreshSyncErrorMessage = nil
                updateSyncErrorMessage()
            }
            saveCache(for: targetCacheKey)
        } catch {
            guard refreshSequence == sequence,
                  localMutationRevision == mutationRevision,
                  cacheKey() == targetCacheKey,
                  capturedIdentity(for: targetCacheKey) == identity else { return }
            refreshSyncErrorMessage = Self.message(for: error)
            updateSyncErrorMessage()
        }
    }

    func setCardPresentation(_ value: CardPresentationPreference) {
        guard !cardPresentationUsesDeviceOverride,
              let context = operationContext() else { return }
        localMutationRevision += 1
        storedCardPresentation = value
        storedCardPresentationSource = .scope(.profileClient)
        pendingDeletes.removeValue(
            forKey: Self.deleteIdentity(key: .uiCardPresentation, scope: .profileClient)
        )
        persist(
            key: .uiCardPresentation,
            scope: .profileClient,
            value: value,
            context: context
        )
    }

    func setPosterSize(_ value: CardPosterSize) {
        var updated = cardPresentation
        updated.posterSize = value
        setCardPresentation(updated)
    }

    func setCaptionStyle(_ value: CardCaptionStyle) {
        var updated = cardPresentation
        updated.caption = value
        setCardPresentation(updated)
    }

    func setPrimaryMenuItems(_ items: [PrimaryMenuItem]) {
        guard !primaryMenuUsesDeviceOverride,
              let context = operationContext() else { return }
        let normalized = Self.normalizedPrimaryMenuItems(items)
        guard normalized.count <= Self.maximumPrimaryMenuCount else {
            setSyncError(Self.primaryMenuLimitMessage, for: .navPrimaryMenu)
            return
        }
        let value = PrimaryMenuPreference(items: normalized)
        guard value.isValid else { return }
        localMutationRevision += 1
        storedPrimaryMenu = value
        storedPrimaryMenuSource = .scope(.profileClient)
        pendingDeletes.removeValue(
            forKey: Self.deleteIdentity(key: .navPrimaryMenu, scope: .profileClient)
        )
        persist(key: .navPrimaryMenu, scope: .profileClient, value: value, context: context)
    }

    func resolvedPrimaryMenuItems(availableLibraries _: [Library] = []) -> [PrimaryMenuItem] {
        guard let primaryMenu, primaryMenu.isValid else { return appleDefaultPrimaryMenuItems() }
        return Self.normalizedPrimaryMenuItems(primaryMenu.items)
    }

    var hasExplicitPrimaryMenu: Bool { primaryMenu != nil }
    var primaryMenuUsesDeviceOverride: Bool {
        primaryMenuSource == .scope(.profileDevice)
    }
    var cardPresentationUsesDeviceOverride: Bool {
        cardPresentationSource == .scope(.profileDevice)
    }
    var cardPresentationUsesFamilyOverride: Bool {
        cardPresentationSource == .scope(.profileClient)
    }
    var hasDeviceOverrides: Bool {
        primaryMenuUsesDeviceOverride || cardPresentationUsesDeviceOverride
    }

    /// Clear higher-precedence per-device rows so the family-scoped controls
    /// can truthfully represent and sync the effective value again.
    func useFamilySettings() {
        guard let context = operationContext() else { return }
        if primaryMenuUsesDeviceOverride {
            scheduleDelete(
                key: .navPrimaryMenu,
                scope: .profileDevice,
                context: context
            )
        }
        if cardPresentationUsesDeviceOverride {
            scheduleDelete(
                key: .uiCardPresentation,
                scope: .profileDevice,
                context: context
            )
        }
        let deletes = saveTail
        Task { @MainActor [weak self] in
            await deletes?.value
            guard let self,
                  self.contextIsCurrent(context),
                  self.syncErrorsByKey.isEmpty else { return }
            await self.refresh()
        }
    }

    /// Remove this family's explicit card row so resolution falls through to
    /// the profile-wide value or the contract default. This is distinct from
    /// clearing an older per-device row, which only exposes the family row.
    func resetCardPresentationToInherited() {
        guard let context = operationContext() else { return }
        localMutationRevision += 1
        pendingSyncWrites.removeValue(forKey: SettingKey.uiCardPresentation.rawValue)
        storedCardPresentationSource = nil
        scheduleDelete(
            key: .uiCardPresentation,
            scope: .profileClient,
            context: context
        )
        let delete = saveTail
        Task { @MainActor [weak self] in
            await delete?.value
            guard let self,
                  self.contextIsCurrent(context),
                  self.syncErrorsByKey[SettingKey.uiCardPresentation.rawValue] == nil else { return }
            await self.refresh()
        }
    }

    @discardableResult
    private func persist<T: Encodable>(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: T,
        context: OperationContext
    ) -> Bool {
        let encodedValue: SettingJSONValue
        do {
            encodedValue = try SettingJSONValue.encoding(value)
        } catch {
            setSyncError(Self.message(for: error), for: key)
            return false
        }
        let pendingWrite = PendingSyncWrite(
            value: encodedValue,
            mutationId: newSettingMutationId()
        )
        pendingSyncWrites[key.rawValue] = pendingWrite
        saveCache(for: context.cacheKey)
        enqueuePersist(
            key: key,
            scope: scope,
            write: pendingWrite,
            context: context
        )
        return true
    }

    private func enqueuePersist(
        key: SettingKey,
        scope: SettingScopeIdentity,
        write: PendingSyncWrite,
        context: OperationContext
    ) {
        let previousSave = saveTail
        pendingSaveCount += 1
        isSaving = true

        let save = Task { @MainActor [weak self] in
            await previousSave?.value
            guard let self else { return }
            defer { self.completeSave() }
            guard contextIsCurrent(context) else { return }
            do {
                try await transport.putValue(
                    key: key,
                    scope: scope,
                    value: write.value,
                    mutationId: write.mutationId,
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                if pendingSyncWrites[key.rawValue]?.mutationId == write.mutationId {
                    pendingSyncWrites.removeValue(forKey: key.rawValue)
                    saveCache(for: context.cacheKey)
                }
                setSyncError(nil, for: key)
            } catch {
                guard contextIsCurrent(context) else { return }
                // Keep the optimistic cache. A later refresh or another edit
                // retries against the server without making the app unusable
                // while offline.
                setSyncError(Self.message(for: error), for: key)
            }
        }
        saveTail = save
    }

    private func scheduleDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        context: OperationContext
    ) {
        if scope.scope == .profileClient {
            pendingSyncWrites.removeValue(forKey: key.rawValue)
        }
        let pendingDelete = PendingDelete(scope: scope.scope)
        pendingDeletes[Self.deleteIdentity(key: key, scope: scope.scope)] = pendingDelete
        saveCache(for: context.cacheKey)
        enqueueDelete(
            key: key,
            scope: scope,
            pendingDelete: pendingDelete,
            context: context
        )
    }

    private func enqueueDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        pendingDelete: PendingDelete,
        context: OperationContext
    ) {
        let previousSave = saveTail
        pendingSaveCount += 1
        isSaving = true

        let save = Task { @MainActor [weak self] in
            await previousSave?.value
            guard let self else { return }
            defer { self.completeSave() }
            guard contextIsCurrent(context) else { return }
            do {
                try await transport.deleteValue(
                    key: key,
                    scope: scope,
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                await finishAcceptedDelete(
                    key: key,
                    scope: scope,
                    pendingDelete: pendingDelete,
                    context: context
                )
            } catch {
                guard contextIsCurrent(context) else { return }
                if case .noValueAtScope = SettingsAPIError.from(error) {
                    await finishAcceptedDelete(
                        key: key,
                        scope: scope,
                        pendingDelete: pendingDelete,
                        context: context
                    )
                } else {
                    let identity = Self.deleteIdentity(key: key, scope: scope.scope)
                    guard pendingDeletes[identity]?.operationId == pendingDelete.operationId else {
                        return
                    }
                    setSyncError("Could not reset this setting to its inherited value.", for: key)
                }
            }
        }
        saveTail = save
    }

    /// A successful device-row delete changes the effective value immediately,
    /// even if another queued delete fails. Reconcile only this accepted key so
    /// a failed sibling remains durable for retry without blocking the value
    /// that the server has already exposed underneath the deleted override.
    private func finishAcceptedDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        pendingDelete: PendingDelete,
        context: OperationContext
    ) async {
        let identity = Self.deleteIdentity(key: key, scope: scope.scope)
        guard pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }

        guard scope.scope == .profileDevice else {
            pendingDeletes.removeValue(forKey: identity)
            saveCache(for: context.cacheKey)
            setSyncError(nil, for: key)
            return
        }

        do {
            let response = try await transport.effectiveValues(
                keys: [key],
                requestIdentity: context.requestIdentity
            )
            guard contextIsCurrent(context),
                  pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }
            guard let row = response.byKey[key] else {
                setSyncError(Self.missingEffectiveValueMessage, for: key)
                return
            }
            guard applyEffectiveValue(row, for: key) else { return }
            pendingDeletes.removeValue(forKey: identity)
            saveCache(for: context.cacheKey)
        } catch {
            guard contextIsCurrent(context),
                  pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }
            setSyncError(Self.message(for: error), for: key)
        }
    }

    /// Decode and apply one key atomically. A future value for one setting must
    /// not prevent compatible siblings from reconciling, and its source must
    /// never be paired with a stale value from an earlier successful read.
    @discardableResult
    private func applyEffectiveValue(
        _ row: EffectiveSettingValue,
        for key: SettingKey
    ) -> Bool {
        do {
            switch key {
            case .navPrimaryMenu:
                let menu: PrimaryMenuPreference?
                if row.value.isNull {
                    menu = nil
                } else {
                    let decoded = try row.value.decoded(as: PrimaryMenuPreference.self)
                    guard decoded.isValid else {
                        throw SettingsAPIError.invalidValue(
                            message: "The primary menu value is not valid for this client."
                        )
                    }
                    menu = decoded
                }
                storedPrimaryMenu = menu.map {
                    PrimaryMenuPreference(items: Self.normalizedPrimaryMenuItems($0.items))
                }
                storedPrimaryMenuSource = row.source
            case .uiCardPresentation:
                let presentation = try row.value.decoded(as: CardPresentationPreference.self)
                storedCardPresentation = presentation
                storedCardPresentationSource = row.source
            default:
                throw SettingsAPIError.unknownSetting(key: key.rawValue)
            }
            setSyncError(nil, for: key)
            return true
        } catch {
            setSyncError(Self.effectiveValueDecodeMessage, for: key)
            return false
        }
    }

    /// Durable optimistic writes are replayed before reading effective values.
    /// Otherwise an online refresh after an offline edit would replace the
    /// user's cached choice with the server's older value before retrying it.
    private func drainPendingWrites(
        targetCacheKey: String?,
        requestIdentity: HTTPRequestIdentity,
        sequence: Int,
        mutationRevision: Int
    ) async -> Bool {
        await saveTail?.value
        guard refreshSequence == sequence,
              localMutationRevision == mutationRevision,
              cacheKey() == targetCacheKey,
              capturedIdentity(for: targetCacheKey) == requestIdentity else { return false }

        guard let targetCacheKey else { return false }
        let context = OperationContext(
            cacheKey: targetCacheKey,
            requestIdentity: requestIdentity
        )
        let deletes = pendingDeletes.sorted(by: { $0.key < $1.key })
        let pending = Self.keys.compactMap { key -> (SettingKey, PendingSyncWrite)? in
            guard let write = pendingSyncWrites[key.rawValue],
                  Self.writeScope(for: key) != nil else { return nil }
            return (key, write)
        }
        guard !deletes.isEmpty || !pending.isEmpty else { return true }

        for (identity, delete) in deletes {
            guard let keyRaw = identity.split(separator: "|", maxSplits: 1).first,
                  let key = SettingKey(rawValue: String(keyRaw)),
                  let scope = delete.scopeIdentity else { continue }
            enqueueDelete(
                key: key,
                scope: scope,
                pendingDelete: delete,
                context: context
            )
        }
        for (key, write) in pending {
            guard let scope = Self.writeScope(for: key) else { continue }
            enqueuePersist(
                key: key,
                scope: scope,
                write: write,
                context: context
            )
        }
        let replayTail = saveTail
        await replayTail?.value
        guard refreshSequence == sequence,
              localMutationRevision == mutationRevision,
              cacheKey() == targetCacheKey,
              capturedIdentity(for: targetCacheKey) == requestIdentity else { return false }
        return pendingSyncWrites.isEmpty
            && pendingDeletes.isEmpty
    }

    private func completeSave() {
        pendingSaveCount = max(0, pendingSaveCount - 1)
        isSaving = pendingSaveCount > 0
    }

    private func loadCache(for key: String?) {
        if loadedCacheKey != key {
            if loadedCacheKey != nil {
                capabilityState = .checking
            }
            loadedCacheKey = key
            clearSyncErrors()
        }
        storedPrimaryMenu = nil
        storedCardPresentation = .standard
        storedPrimaryMenuSource = nil
        storedCardPresentationSource = nil
        supportProjection = .unknown
        pendingSyncWrites = [:]
        pendingDeletes = [:]
        guard let key,
              let data = defaults.data(forKey: key),
              let cached = try? SettingsWireCoding.makeDecoder().decode(Cache.self, from: data)
        else { return }
        storedPrimaryMenu = cached.primaryMenu.flatMap { menu in
            menu.isValid ? PrimaryMenuPreference(items: Self.normalizedPrimaryMenuItems(menu.items)) : nil
        }
        storedCardPresentation = cached.cardPresentation
        storedPrimaryMenuSource = cached.primaryMenuSource
        storedCardPresentationSource = cached.cardPresentationSource
        supportProjection = cached.supportProjection ?? .unknown
        // Retired shortcut outbox entries are not decoded or replayed.
        pendingSyncWrites = (cached.pendingSyncWrites ?? [:]).filter {
            Self.keys.map(\.rawValue).contains($0.key)
        }
        if let write = pendingSyncWrites[SettingKey.navPrimaryMenu.rawValue] {
            // Do not replay a retired destination from an older app's outbox.
            if let menu = try? write.value.decoded(as: PrimaryMenuPreference.self), menu.isValid,
               let value = try? SettingJSONValue.encoding(
                PrimaryMenuPreference(items: Self.normalizedPrimaryMenuItems(menu.items))
               ) {
                pendingSyncWrites[SettingKey.navPrimaryMenu.rawValue] = PendingSyncWrite(
                    value: value,
                    mutationId: value == write.value
                        ? write.mutationId : newSettingMutationId()
                )
            } else {
                pendingSyncWrites.removeValue(forKey: SettingKey.navPrimaryMenu.rawValue)
            }
        }
        pendingDeletes = Self.validPendingDeletes(cached.pendingDeletes ?? [:])
        saveCache(for: key)

    }

    private func saveCache(for key: String?) {
        guard let key,
              let data = try? SettingsWireCoding.makeEncoder().encode(Cache(
                primaryMenu: storedPrimaryMenu,
                cardPresentation: storedCardPresentation,
                primaryMenuSource: storedPrimaryMenuSource,
                cardPresentationSource: storedCardPresentationSource,
                supportProjection: supportProjection,
                pendingSyncWrites: pendingSyncWrites.isEmpty ? nil : pendingSyncWrites,
                pendingDeletes: pendingDeletes.isEmpty ? nil : pendingDeletes
              ))
        else { return }
        defaults.set(data, forKey: key)
    }

    /// A successful refresh reconciles errors across the active settings.
    private func setSyncError(_ message: String?, for key: SettingKey) {
        if let message {
            syncErrorsByKey[key.rawValue] = message
        } else {
            syncErrorsByKey.removeValue(forKey: key.rawValue)
        }
        updateSyncErrorMessage()
    }

    private func clearSyncErrors() {
        syncErrorsByKey.removeAll()
        refreshSyncErrorMessage = nil
        updateSyncErrorMessage()
    }

    private func clearReconciledSyncErrors() {
        syncErrorsByKey.removeAll()
        refreshSyncErrorMessage = nil
        updateSyncErrorMessage()
    }

    private func updateSyncErrorMessage() {
        syncErrorMessage = refreshSyncErrorMessage
            ?? Self.keys.lazy.compactMap { self.syncErrorsByKey[$0.rawValue] }.first
    }

    private func operationContext() -> OperationContext? {
        guard allowsEditing,
              let targetCacheKey = cacheKey(),
              let identity = capturedIdentity(for: targetCacheKey) else { return nil }
        return OperationContext(cacheKey: targetCacheKey, requestIdentity: identity)
    }

    private func contextIsCurrent(_ context: OperationContext) -> Bool {
        cacheKey() == context.cacheKey
            && capturedIdentity(for: context.cacheKey) == context.requestIdentity
    }

    private func capturedIdentity(for targetCacheKey: String?) -> HTTPRequestIdentity? {
        guard let targetCacheKey,
              let identity = requestIdentity(),
              Self.cacheKey(for: identity) == targetCacheKey else { return nil }
        return identity
    }

    private static func activeCacheKey() -> String? {
        guard let identity = activeRequestIdentity() else { return nil }
        return cacheKey(for: identity)
    }

    private static func activeRequestIdentity() -> HTTPRequestIdentity? {
        guard let server = ServerRegistry.shared.activeServer,
              ServerRegistry.shared.activeServerId == server.id,
              let profileId = AuthService.shared.profileId,
              !profileId.isEmpty else { return nil }
        return HTTPRequestIdentity(
            serverId: server.id,
            serverURL: server.url,
            profileId: profileId,
            clientFamily: AppleDeviceIdentity.current.clientFamily
        )
    }

    private static func cacheKey(for identity: HTTPRequestIdentity) -> String {
        "vivid.uiCustomization.\(identity.serverId).\(identity.profileId).\(identity.clientFamily)"
    }

    private static func deleteIdentity(key: SettingKey, scope: SettingScope) -> String {
        "\(key.rawValue)|\(scope.rawValue)"
    }

    private static let keys: [SettingKey] = [
        .navPrimaryMenu,
        .uiCardPresentation,
    ]

    private static let maximumPrimaryMenuCount = 64
    private static let primaryMenuLimitMessage = "You can show up to 64 top-menu destinations."
    private static let effectiveValueDecodeMessage =
        "Could not read this interface preference from the server."
    private static let missingEffectiveValueMessage =
        "The server did not return this interface preference."

    private static func writeScope(for key: SettingKey) -> SettingScopeIdentity? {
        switch key {
        case .navPrimaryMenu, .uiCardPresentation:
            return .profileClient
        default:
            return nil
        }
    }

    private static func validPendingDeletes(
        _ deletes: [String: PendingDelete]
    ) -> [String: PendingDelete] {
        deletes.filter { identity, delete in
            guard let keyRaw = identity.split(separator: "|", maxSplits: 1).first,
                  let key = SettingKey(rawValue: String(keyRaw)),
                  let scope = delete.scopeIdentity,
                  !delete.operationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return identity == deleteIdentity(key: key, scope: scope.scope)
                && (key == .navPrimaryMenu || key == .uiCardPresentation)
        }
    }

    private static func deduplicated(_ items: [PrimaryMenuItem]) -> [PrimaryMenuItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func normalizedPrimaryMenuItems(
        _ items: [PrimaryMenuItem]
    ) -> [PrimaryMenuItem] {
        var normalized = deduplicated(items).filter {
            if case .builtin = $0 { return true }
            return false
        }
        if !normalized.contains(where: \.isHome) {
            normalized.insert(.builtin(.home), at: 0)
        }
        return normalized
    }

    private static func message(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .serverUpgradeRequired, .unknownSetting:
            return "Update this Silo server to sync interface preferences."
        case .transport:
            return "Saved on this device. Sync will resume when the server is reachable."
        default:
            return "Saved on this device, but the server did not accept the change."
        }
    }

}

@MainActor
enum MobileProfilePreferenceKeys {
    static var scope: String? {
        #if os(iOS) || os(tvOS)
        guard let server = ServerRegistry.shared.activeServerId,
              let profile = AuthService.shared.profileId, !profile.isEmpty else { return nil }
        return Data("\(server)|\(profile)".utf8).base64EncodedString()
        #else
        return nil
        #endif
    }
    static func key(_ base: String) -> String {
        guard let scope else { return base }
        let scoped = "\(base).profile.\(scope)"
        // Global legacy choices have no account owner and must not be copied
        // into every newly selected profile.
        return scoped
    }
}
