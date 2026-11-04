import Foundation

// Wire types for Silo's canonical settings API, mirroring the server's
// `settings_values.go`:
//
//   GET    /api/v1/settings/contract/capabilities  feature detection
//   GET    /api/v1/settings/values/effective       batched resolution
//   PUT    /api/v1/settings/values/{key}           write one scope
//   DELETE /api/v1/settings/values/{key}           clear one scope
//
// Values are typed JSON, every value names the scope it lives at, and a key
// outside the manifest can't be named because `SettingKey` is generated from it.
//
// Read before adding a call site: these types spell their snake_case wire
// names out in `CodingKeys` and must be coded through `SettingsWireCoding`,
// never `HTTPClient.get`/`put`. The shared coders convert keys, and
// `.convertFromSnakeCase` turns `profile_id` into `profileId` before matching,
// misses the explicit `"profile_id"` key and decodes nil without throwing
// (SettingValuesAPITests pins this). Setting values themselves are opaque JSON
// whose object keys must survive byte for byte: `playback.subtitle_appearance`
// is camelCase on the wire, other schemas are snake_case.

// MARK: - Coding boundary

/// JSON coders for the canonical settings API, with no key strategy either
/// way. Use them for anything that touches a setting value, including a
/// caller decoding an object-valued setting into its own model.
enum SettingsWireCoding {
    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Stable output keeps a re-encoded value byte-comparable and the
        // server's mutation-id request hash stable across retries.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - Values

/// One setting value, exactly as the contract defines it: bool, int, double,
/// string, array, object or null.
enum SettingJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SettingJSONValue])
    case object([String: SettingJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SettingJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SettingJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension SettingJSONValue {
    /// Structural equality that treats `1` and `1.0` as the same JSON number,
    /// at any depth. Other types stay distinct.
    func isSemanticallyEquivalent(to other: SettingJSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null):
            return true
        case (.bool(let left), .bool(let right)):
            return left == right
        case (.int(let left), .int(let right)):
            return left == right
        case (.double(let left), .double(let right)):
            return left == right
        case (.int(let left), .double(let right)):
            return Int(exactly: right) == left
        case (.double(let left), .int(let right)):
            return Int(exactly: left) == right
        case (.string(let left), .string(let right)):
            return left == right
        case (.array(let left), .array(let right)):
            return left.count == right.count
                && zip(left, right).allSatisfy { $0.isSemanticallyEquivalent(to: $1) }
        case (.object(let left), .object(let right)):
            return left.count == right.count && left.allSatisfy { key, value in
                right[key].map { value.isSemanticallyEquivalent(to: $0) } ?? false
            }
        default:
            return false
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// An int, or a whole-number double (`1` re-serialised as `1.0`).
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [SettingJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: SettingJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Decodes an object- or array-valued setting into a caller model, keeping
    /// the value's own key casing.
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try SettingsWireCoding.makeEncoder().encode(self)
        return try SettingsWireCoding.makeDecoder().decode(T.self, from: data)
    }

    /// Builds a value from a caller model, without key rewriting.
    static func encoding<T: Encodable>(_ value: T) throws -> SettingJSONValue {
        let data = try SettingsWireCoding.makeEncoder().encode(value)
        return try SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: data)
    }
}

/// Literals, so a call site can write `"2160p"` rather than `.string("2160p")`.
///
/// Deliberately not `ExpressibleByNilLiteral`: `nil` would then type-check as
/// `.null` wherever a `SettingJSONValue?` is expected, erasing the difference
/// between an absent field and an authored JSON null. Write `.null`.
extension SettingJSONValue: ExpressibleByBooleanLiteral,
                            ExpressibleByIntegerLiteral,
                            ExpressibleByFloatLiteral,
                            ExpressibleByStringLiteral,
                            ExpressibleByArrayLiteral,
                            ExpressibleByDictionaryLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: SettingJSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, SettingJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Scopes

/// The scopes a value can be stored at. `other` keeps a scope from a newer
/// server readable, so one unfamiliar row never fails a whole batch.
enum SettingScope: RawRepresentable, Hashable, Sendable {
    case account
    case profile
    case profileClient
    case profileDevice
    case profileLibrary
    case profileSeries
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "account": self = .account
        case "profile": self = .profile
        case "profile_client": self = .profileClient
        case "profile_device": self = .profileDevice
        case "profile_library": self = .profileLibrary
        case "profile_series": self = .profileSeries
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .account: return "account"
        case .profile: return "profile"
        case .profileClient: return "profile_client"
        case .profileDevice: return "profile_device"
        case .profileLibrary: return "profile_library"
        case .profileSeries: return "profile_series"
        case .other(let raw): return raw
        }
    }
}

/// Where a resolved value came from: a scope, or the contract default.
enum SettingSource: RawRepresentable, Hashable, Sendable {
    case scope(SettingScope)
    case contractDefault

    init(rawValue: String) {
        self = rawValue == "default" ? .contractDefault : .scope(SettingScope(rawValue: rawValue))
    }

    var rawValue: String {
        switch self {
        case .scope(let scope): return scope.rawValue
        case .contractDefault: return "default"
        }
    }
}

/// How policy narrowed a value at resolution time.
enum SettingConstraintKind: RawRepresentable, Hashable, Sendable {
    case ceiling
    case floor
    case allowlist
    case locked
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "ceiling": self = .ceiling
        case "floor": self = .floor
        case "allowlist": self = .allowlist
        case "locked": self = .locked
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .ceiling: return "ceiling"
        case .floor: return "floor"
        case .allowlist: return "allowlist"
        case .locked: return "locked"
        case .other(let raw): return raw
        }
    }
}

// The three open enums above code as one bare string, and an unfamiliar member
// decodes to `.other` rather than throwing. Written per type: synthesis would
// nest the associated value (`{"other":{"_0":"x"}}`), and a blanket
// `RawRepresentable` extension would replace the coding of every string enum
// in the app.

extension SettingScope: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension SettingSource: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension SettingConstraintKind: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A scope plus the ids it needs, so an identity the server would reject
/// (`profile_library` without a library) can't be built. The profile and
/// device come from the session headers, never from here, so one profile
/// can't write another's settings by naming it in the query.
enum SettingScopeIdentity: Hashable, Sendable {
    case account
    case profile
    case profileClient
    case profileDevice
    case profileLibrary(libraryId: Int)
    case profileSeries(seriesId: String)

    var scope: SettingScope {
        switch self {
        case .account: return .account
        case .profile: return .profile
        case .profileClient: return .profileClient
        case .profileDevice: return .profileDevice
        case .profileLibrary: return .profileLibrary
        case .profileSeries: return .profileSeries
        }
    }

    /// The query the scope travels in, so one route serves every scope.
    var queryItems: [String: String] {
        var query = ["scope": scope.rawValue]
        switch self {
        case .profileLibrary(let libraryId):
            query["library_id"] = String(libraryId)
        case .profileSeries(let seriesId):
            query["series_id"] = seriesId
        case .account, .profile, .profileClient, .profileDevice:
            break
        }
        return query
    }
}

// MARK: - Responses

/// One explicitly stored value, as a write returns it.
struct StoredSettingValue: Codable, Hashable, Sendable {
    let key: String
    let scope: SettingScope
    let profileId: String?
    let clientFamily: String?
    let deviceId: String?
    let libraryId: Int?
    let seriesId: String?
    let value: SettingJSONValue
    /// Goes up on every write to the row. A replayed receipt carries `0`.
    let revision: Int
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case key
        case scope
        case profileId = "profile_id"
        case clientFamily = "client_family"
        case deviceId = "device_id"
        case libraryId = "library_id"
        case seriesId = "series_id"
        case value
        case revision
        case updatedAt = "updated_at"
    }

    var settingKey: SettingKey? {
        SettingKey(rawValue: key)
    }
}

/// One resolved value plus where it came from.
struct EffectiveSettingValue: Codable, Hashable, Sendable {
    let key: String
    let value: SettingJSONValue
    let source: SettingSource
    /// What the user authored, sent only when policy narrowed the answer.
    /// `nil` means the field was absent and `.null` an authored JSON null.
    let storedValue: SettingJSONValue?
    let constrained: Bool
    let constraintKind: SettingConstraintKind?
    /// Advisory picker values for an open setting. They never constrain writes.
    let suggestedValues: [String]?
    /// The row holding the value, so a reset can target it. Absent for a
    /// contract default.
    let scope: SettingScope?
    let profileId: String?
    let clientFamily: String?
    let deviceId: String?
    let libraryId: Int?
    let seriesId: String?

    enum CodingKeys: String, CodingKey {
        case key
        case value
        case source
        case storedValue = "stored_value"
        case constrained
        case constraintKind = "constraint_kind"
        case suggestedValues = "suggested_values"
        case scope
        case profileId = "profile_id"
        case clientFamily = "client_family"
        case deviceId = "device_id"
        case libraryId = "library_id"
        case seriesId = "series_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decode(SettingJSONValue.self, forKey: .value)
        source = try container.decode(SettingSource.self, forKey: .source)
        // `decodeIfPresent` would read an authored null as absent.
        if container.contains(.storedValue) {
            storedValue = try container.decode(SettingJSONValue.self, forKey: .storedValue)
        } else {
            storedValue = nil
        }
        constrained = try container.decodeIfPresent(Bool.self, forKey: .constrained) ?? false
        constraintKind = try container.decodeIfPresent(SettingConstraintKind.self, forKey: .constraintKind)
        suggestedValues = try container.decodeIfPresent([String].self, forKey: .suggestedValues)
        scope = try container.decodeIfPresent(SettingScope.self, forKey: .scope)
        profileId = try container.decodeIfPresent(String.self, forKey: .profileId)
        clientFamily = try container.decodeIfPresent(String.self, forKey: .clientFamily)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        libraryId = try container.decodeIfPresent(Int.self, forKey: .libraryId)
        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
    }

    init(
        key: String,
        value: SettingJSONValue,
        source: SettingSource,
        storedValue: SettingJSONValue? = nil,
        constrained: Bool = false,
        constraintKind: SettingConstraintKind? = nil,
        suggestedValues: [String]? = nil,
        scope: SettingScope? = nil,
        profileId: String? = nil,
        clientFamily: String? = nil,
        deviceId: String? = nil,
        libraryId: Int? = nil,
        seriesId: String? = nil
    ) {
        self.key = key
        self.value = value
        self.source = source
        self.storedValue = storedValue
        self.constrained = constrained
        self.constraintKind = constraintKind
        self.suggestedValues = suggestedValues
        self.scope = scope
        self.profileId = profileId
        self.clientFamily = clientFamily
        self.deviceId = deviceId
        self.libraryId = libraryId
        self.seriesId = seriesId
    }

    var settingKey: SettingKey? {
        SettingKey(rawValue: key)
    }

    /// The identity a reset should target, or nil when there's nothing to
    /// clear (a contract default, or a scope this build can't address).
    var storedAt: SettingScopeIdentity? {
        switch scope {
        case nil, .other: return nil
        case .account: return .account
        case .profile: return .profile
        case .profileClient: return .profileClient
        case .profileDevice: return .profileDevice
        case .profileLibrary: return libraryId.map { .profileLibrary(libraryId: $0) }
        case .profileSeries: return seriesId.map { .profileSeries(seriesId: $0) }
        }
    }
}

/// A batched resolution plus the contract revision it was computed at.
struct EffectiveSettingValuesResponse: Codable, Hashable, Sendable {
    let settings: [EffectiveSettingValue]
    let revision: Int

    enum CodingKeys: String, CodingKey {
        case settings
        case revision
    }

    /// Values by generated key. Keys this build doesn't know are left out
    /// here but stay in ``settings``.
    var byKey: [SettingKey: EffectiveSettingValue] {
        var map: [SettingKey: EffectiveSettingValue] = [:]
        for setting in settings {
            if let key = setting.settingKey {
                map[key] = setting
            }
        }
        return map
    }

    func value(for key: SettingKey) -> EffectiveSettingValue? {
        settings.first { $0.key == key.rawValue }
    }

    /// True when this build's manifest is newer than the one the server
    /// resolved with: applying the response would fill missing rows with this
    /// build's defaults.
    var contractIsAheadOfServer: Bool {
        SettingKey.revision > revision
    }
}

/// What the connected server's settings contract supports. `scopes` stays a
/// raw string list so a scope added after this build still reads back.
struct SettingsContractCapabilities: Codable, Hashable, Sendable {
    let apiVersion: Int
    let revision: Int
    let contractEtag: String
    let definitionCount: Int
    let scopes: [String]
    let supportsBatchedEffective: Bool
    let supportsIdempotentWrites: Bool
    /// Revision 5 shortcut mutations. Whole-document shortcut writes aren't a
    /// safe fallback: concurrent clients would replace each other's pins.
    let supportsAtomicShortcuts: Bool

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case revision
        case contractEtag = "contract_etag"
        case definitionCount = "definition_count"
        case scopes
        case supportsBatchedEffective = "supports_batched_effective"
        case supportsIdempotentWrites = "supports_idempotent_writes"
        case supportsAtomicShortcuts = "supports_atomic_shortcuts"
    }

    init(
        apiVersion: Int,
        revision: Int,
        contractEtag: String,
        definitionCount: Int,
        scopes: [String],
        supportsBatchedEffective: Bool,
        supportsIdempotentWrites: Bool,
        supportsAtomicShortcuts: Bool
    ) {
        self.apiVersion = apiVersion
        self.revision = revision
        self.contractEtag = contractEtag
        self.definitionCount = definitionCount
        self.scopes = scopes
        self.supportsBatchedEffective = supportsBatchedEffective
        self.supportsIdempotentWrites = supportsIdempotentWrites
        self.supportsAtomicShortcuts = supportsAtomicShortcuts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        revision = try container.decode(Int.self, forKey: .revision)
        contractEtag = try container.decode(String.self, forKey: .contractEtag)
        definitionCount = try container.decode(Int.self, forKey: .definitionCount)
        scopes = try container.decode([String].self, forKey: .scopes)
        supportsBatchedEffective = try container.decode(Bool.self, forKey: .supportsBatchedEffective)
        supportsIdempotentWrites = try container.decode(Bool.self, forKey: .supportsIdempotentWrites)
        // Older payloads predate the flag, and missing must fail closed.
        supportsAtomicShortcuts = try container.decodeIfPresent(Bool.self, forKey: .supportsAtomicShortcuts) ?? false
    }

    /// True when this build's manifest is newer than the server's, so
    /// definitions the server doesn't know must be hidden.
    var contractIsAheadOfServer: Bool {
        SettingKey.revision > revision
    }

    var supportsUICustomizationRevision: Bool {
        revision >= 5 && supportsBatchedEffective && supportsIdempotentWrites
    }
}

/// The result of probing the settings contract. A server too old for the
/// canonical API (or for this build's manifest) is its own case, so the UI
/// can ask for a server upgrade instead of showing an empty screen.
enum SettingsCapabilitiesResult: Equatable, Sendable {
    case available(SettingsContractCapabilities)
    case serverUpgradeRequired
    case failed(SettingsAPIError)

    var capabilities: SettingsContractCapabilities? {
        if case .available(let capabilities) = self { return capabilities }
        return nil
    }
}

/// The outcome of one write.
struct SettingValueWriteReceipt: Equatable, Sendable {
    let value: StoredSettingValue
    /// True when the server replayed the receipt it recorded for this
    /// mutation id instead of writing again. `revision` means nothing then.
    let isIdempotentReplay: Bool
}

// MARK: - Request body

/// The body of `PUT /settings/values/{key}`: `{"value": ...}`.
struct SettingValueWriteRequest: Encodable, Sendable {
    let value: SettingJSONValue

    enum CodingKeys: String, CodingKey {
        case value
    }
}

// MARK: - Errors

/// The settings API's failures, named so callers can act on them.
enum SettingsAPIError: Error, Equatable, Sendable {
    /// The server doesn't serve the canonical settings routes.
    case serverUpgradeRequired
    /// A profile-scoped call with no profile selected, caught before the
    /// request instead of the server's generic 400.
    case profileRequired
    /// The key isn't in the server's contract.
    case unknownSetting(key: String)
    /// The key is device-local and never stored by the server.
    case clientLocalSetting(key: String)
    /// The contract doesn't allow this key at this scope.
    case scopeNotAllowed(key: String, scope: SettingScope)
    /// The value failed the contract's schema.
    case invalidValue(message: String)
    /// The mutation id was already used for a different write. Don't retry
    /// with a fresh id: work out which write landed first.
    case mutationIdConflict
    /// Nothing is stored at the addressed scope.
    case noValueAtScope
    /// Any other HTTP failure, with the server's error envelope when present.
    case server(status: Int, code: String?, message: String?)
    /// The request never reached the server, or the reply didn't parse.
    case transport(description: String)

    /// Maps any error onto the contract's vocabulary.
    ///
    /// For a 404 the envelope decides, not the status: Silo's handlers always
    /// answer with `{"error":...,"message":...}`, so a 404 with one came from
    /// a mounted route (unknown key, nothing stored). A 404 without one is the
    /// router saying the route doesn't exist, which here means the server
    /// predates the canonical settings API.
    static func from(_ error: Error, key: String? = nil, scope: SettingScope? = nil) -> SettingsAPIError {
        if let settingsError = error as? SettingsAPIError {
            return settingsError
        }
        guard let httpError = error as? HTTPError else {
            return .transport(description: String(describing: error))
        }
        guard case .http(let status, _) = httpError else {
            return .transport(description: httpError.description)
        }
        let code = httpError.serverErrorCode
        let message = httpError.errorDescription
        switch (status, code) {
        case (404, "unknown_setting"):
            return .unknownSetting(key: key ?? "")
        case (404, "not_found"):
            return .noValueAtScope
        case (404, nil):
            return .serverUpgradeRequired
        case (400, "client_local_setting"):
            return .clientLocalSetting(key: key ?? "")
        case (400, "scope_not_allowed"):
            return .scopeNotAllowed(key: key ?? "", scope: scope ?? .other(""))
        case (400, "invalid_value"):
            return .invalidValue(message: message ?? "")
        case (409, "mutation_id_conflict"):
            return .mutationIdConflict
        default:
            return .server(status: status, code: code, message: message)
        }
    }
}

// MARK: - Idempotency

/// A fresh idempotency key for one logical settings write. Keep it across
/// retries: the server replays the receipt for a repeated id with the same
/// content and answers 409 `mutation_id_conflict` for different content.
func newSettingMutationId() -> String {
    UUID().uuidString
}
