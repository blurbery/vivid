import Foundation

/// The typed settings endpoints (`/api/v1/settings/contract/*` and
/// `/api/v1/settings/values/*`). Unlike the older string settings calls on
/// `VividAPI`, values here are typed JSON, every write names its scope, and
/// only keys in the generated `SettingKey` contract can be named.
///
/// Everything goes through `SettingsWireCoding`, not the shared `HTTPClient`
/// coders, so a value's own object keys never meet a key strategy (see
/// SettingValueModels.swift).
///
/// On Silo, the `ui.*` and `nav.*` keys are answered by
/// `SiloLocalInterfaceSettings` on the device and never reach the server.
extension VividAPI {
    // MARK: - Contract

    /// What the server's settings contract supports. A server too old for
    /// the contract, or behind this build's revision, comes back as
    /// `.serverUpgradeRequired` rather than an error, so the UI can say so.
    /// Needs no profile, so it can run before a profile is chosen.
    func getContractCapabilities(
        requestIdentity: HTTPRequestIdentity? = nil
    ) async -> SettingsCapabilitiesResult {
        do {
            let response = try await http.requestData(
                method: "GET",
                path: "/api/v1/settings/contract/capabilities",
                // 404 is how an older server says it has no contract.
                quietStatuses: [404],
                requestIdentity: requestIdentity
            )
            let capabilities = try SettingsWireCoding.makeDecoder()
                .decode(SettingsContractCapabilities.self, from: response.data)
            return capabilities.contractIsAheadOfServer ? .serverUpgradeRequired : .available(capabilities)
        } catch {
            let mapped = SettingsAPIError.from(error)
            return mapped == .serverUpgradeRequired ? .serverUpgradeRequired : .failed(mapped)
        }
    }

    // MARK: - Read

    /// Resolves settings as the server does, with the scope each answer came
    /// from. No `keys` means every key. `libraryIds` and `seriesIds` add
    /// those library and series scopes to the resolution; the profile and
    /// device come from the session.
    func getEffectiveValues(
        keys: [SettingKey] = [],
        libraryIds: [Int] = [],
        seriesIds: [String] = [],
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> EffectiveSettingValuesResponse {
        let serverId = await settingsServerId(requestIdentity)
        guard SiloLocalInterfaceSettings.applies(toServerID: serverId) else {
            return try await serverEffectiveValues(
                keys: keys, libraryIds: libraryIds, seriesIds: seriesIds,
                profileId: profileId, requestIdentity: requestIdentity
            )
        }

        // Interface keys come from the device and only the rest from the
        // server, so a call for interface keys alone never reaches it.
        let owned = { (key: SettingKey) in SiloLocalInterfaceSettings.owns(key) }
        let localKeys = keys.isEmpty ? SettingKey.allCases.filter(owned) : keys.filter(owned)
        let serverKeys = keys.filter { !owned($0) }

        var serverRows: [EffectiveSettingValue] = []
        var revision = SettingKey.revision
        if keys.isEmpty || !serverKeys.isEmpty {
            let response = try await serverEffectiveValues(
                keys: serverKeys, libraryIds: libraryIds, seriesIds: seriesIds,
                profileId: profileId, requestIdentity: requestIdentity
            )
            serverRows = response.settings.filter { !SiloLocalInterfaceSettings.owns($0.key) }
            revision = response.revision
        }
        let profile = try await settingsProfileId(explicit: profileId, requestIdentity: requestIdentity)
        let localRows = await localInterfaceSettings.effectiveValues(
            keys: localKeys, serverId: serverId, profileId: profile
        )
        return EffectiveSettingValuesResponse(settings: serverRows + localRows, revision: revision)
    }

    private func serverEffectiveValues(
        keys: [SettingKey],
        libraryIds: [Int],
        seriesIds: [String],
        profileId: String?,
        requestIdentity: HTTPRequestIdentity?
    ) async throws -> EffectiveSettingValuesResponse {
        let headers = try await profileHeaders(explicit: profileId)
        var query: [String: String] = [:]
        if !keys.isEmpty { query["keys"] = keys.map(\.rawValue).joined(separator: ",") }
        if !libraryIds.isEmpty { query["library_ids"] = libraryIds.map(String.init).joined(separator: ",") }
        if !seriesIds.isEmpty { query["series_ids"] = seriesIds.joined(separator: ",") }

        do {
            let response = try await http.requestData(
                method: "GET",
                path: "/api/v1/settings/values/effective",
                query: query,
                headers: headers,
                requestIdentity: requestIdentity
            )
            let decoded = try SettingsWireCoding.makeDecoder()
                .decode(EffectiveSettingValuesResponse.self, from: response.data)
            guard !decoded.contractIsAheadOfServer else { throw SettingsAPIError.serverUpgradeRequired }
            return decoded
        } catch {
            throw SettingsAPIError.from(error)
        }
    }

    // MARK: - Write

    /// Writes one value at one scope.
    ///
    /// `mutationId` (sent as `X-Silo-Mutation-Id`) makes retries safe: make
    /// one per write with `newSettingMutationId()` and reuse it for that
    /// write's retries. A retry the server already applied comes back with
    /// `isIdempotentReplay`; reusing an ID for different content throws
    /// `.mutationIdConflict`. A value past a policy limit is stored, not
    /// refused, so read the effective value to see what applies.
    @discardableResult
    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> SettingValueWriteReceipt {
        let mutationId = mutationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mutationId.isEmpty else {
            throw SettingsAPIError.invalidValue(message: String(localized: "Mutation ID must not be blank."))
        }
        if let local = try await localInterfaceTarget(for: key, profileId: profileId, requestIdentity: requestIdentity) {
            let stored = try await localInterfaceSettings.put(
                key: key, scope: scope, value: value, serverId: local.serverId, profileId: local.profileId
            )
            return SettingValueWriteReceipt(value: stored, isIdempotentReplay: false)
        }

        var headers = try await profileHeaders(explicit: profileId)
        headers["X-Silo-Mutation-Id"] = mutationId
        do {
            let body = try SettingsWireCoding.makeEncoder().encode(SettingValueWriteRequest(value: value))
            let response = try await http.requestData(
                method: "PUT",
                path: "/api/v1/settings/values/\(key.rawValue)",
                query: scope.queryItems,
                body: body,
                headers: headers,
                requestIdentity: requestIdentity
            )
            let stored = try SettingsWireCoding.makeDecoder().decode(StoredSettingValue.self, from: response.data)
            return SettingValueWriteReceipt(
                value: stored,
                isIdempotentReplay: response.header("X-Silo-Idempotent-Replay") == "true"
            )
        } catch {
            throw SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope)
        }
    }

    /// Clears the value at one scope so the setting inherits again. When the
    /// server has nothing stored there it throws `.noValueAtScope` (its 404),
    /// which a retry can treat as done.
    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        profileId: String? = nil,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws {
        if let local = try await localInterfaceTarget(for: key, profileId: profileId, requestIdentity: requestIdentity) {
            try await localInterfaceSettings.delete(
                key: key, scope: scope, serverId: local.serverId, profileId: local.profileId
            )
            return
        }

        let headers = try await profileHeaders(explicit: profileId)
        do {
            _ = try await http.requestData(
                method: "DELETE",
                path: "/api/v1/settings/values/\(key.rawValue)",
                query: scope.queryItems,
                headers: headers,
                quietStatuses: [404],
                requestIdentity: requestIdentity
            )
        } catch {
            throw SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope)
        }
    }

    // MARK: - Scope

    /// Where an interface key is kept on the device, or nil when the server
    /// answers it (any other key, or a server that isn't Silo).
    private func localInterfaceTarget(
        for key: SettingKey,
        profileId: String?,
        requestIdentity: HTTPRequestIdentity?
    ) async throws -> (serverId: String, profileId: String)? {
        guard SiloLocalInterfaceSettings.owns(key) else { return nil }
        let serverId = await settingsServerId(requestIdentity)
        guard SiloLocalInterfaceSettings.applies(toServerID: serverId) else { return nil }
        let profile = try await settingsProfileId(explicit: profileId, requestIdentity: requestIdentity)
        return (serverId, profile)
    }

    /// The captured identity's server when there is one, otherwise the
    /// session's.
    private func settingsServerId(_ requestIdentity: HTTPRequestIdentity?) async -> String {
        if let serverId = requestIdentity?.serverId, !serverId.isEmpty { return serverId }
        let current = await currentServerId()
        return current.isEmpty ? ServerRegistry.activeServerIDSnapshot ?? "" : current
    }

    /// The profile whose on-device interface settings a call uses: the
    /// caller's, then the captured identity's, then the session's.
    private func settingsProfileId(
        explicit profileId: String?,
        requestIdentity: HTTPRequestIdentity?
    ) async throws -> String {
        for candidate in [profileId, requestIdentity?.profileId] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        guard let current = await currentProfileId(), !current.isEmpty else {
            throw SettingsAPIError.profileRequired
        }
        return current
    }

    /// The `X-Profile-Id` header every values route needs. The server puts
    /// these routes behind its profile requirement, and the profile device,
    /// library and series scopes take their profile from this header, so a
    /// call with no profile fails here with a named error instead of an
    /// unexplained 400. An explicit profile lets a parent edit a child's
    /// settings.
    private func profileHeaders(explicit profileId: String?) async throws -> [String: String] {
        let explicit = profileId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let profile = explicit.isEmpty ? await currentProfileId() : explicit
        guard let profile, !profile.isEmpty else { throw SettingsAPIError.profileRequired }
        return ["X-Profile-Id": profile]
    }
}
