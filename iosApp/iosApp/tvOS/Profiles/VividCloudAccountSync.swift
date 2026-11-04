#if os(tvOS) || os(iOS)
import Foundation
import CloudKit
import OSLog

/// Keeps the saved profiles in step with the person's private iCloud
/// records, so a profile added, changed or deleted on one device follows on
/// their others.
@Observable
@MainActor
final class VividCloudAccountSync {
    static let shared = VividCloudAccountSync()

    private static let containerIdentifier = "iCloud.com.blurbery.vivid"
    private static let recordType = "VividAccountVault"
    private static let payloadKey = "payload"
    private static let recordID = CKRecord.ID(recordName: "account-vault-v1")
    /// Saved profiles bound to a Silo household member (see ``VividCloudVaultPartition``).
    private static let profileRecordID = CKRecord.ID(recordName: "account-vault-profiles-v1")
    private static let tombstoneDefaultsKey = "vivid.cloudAccountTombstones.v1"
    private static let serverTombstoneDefaultsKey = "vivid.cloudServerTombstones.v1"
    private static let resurrectionDefaultsKey = "vivid.cloudAccountResurrections.v1"
    /// Tries a save this many times when another device changed the record first.
    private static let saveAttempts = 3
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "CloudAccountSync"
    )

    private let container = CKContainer(identifier: containerIdentifier)
    private let defaults = UserDefaults.standard
    private(set) var bootstrapFailed = false
    private var isSynchronizing = false
    private var needsAnotherSynchronization = false
    private var pendingRouter: AppRouter?
    private var firstLaunchRestore: Task<Void, Never>?

    private var store: TVSavedAccountStore { .shared }
    private var preferences: VividCloudPreferences { .shared }

    private init() {}

    // MARK: Local deletion and sign-in records

    func noteDeletion(of account: TVSavedAccount) {
        try? preferences.removeAccountPreferences(account)
        let identity = VividCloudAccountIdentity.key(for: account)
        var tombstones = loadTombstones()
        tombstones[identity] = VividCloudAccountTombstone(deletedAt: Date())
        save(tombstones, key: Self.tombstoneDefaultsKey)

        var resurrections = loadResurrections()
        resurrections.removeValue(forKey: identity)
        save(resurrections, key: Self.resurrectionDefaultsKey)
    }

    func noteServerDeletion(_ serverID: String) {
        var deletions = loadServerTombstones()
        deletions[serverID] = VividCloudAccountTombstone(deletedAt: Date())
        save(deletions, key: Self.serverTombstoneDefaultsKey)
    }

    /// Only an explicit credential entry may revive an account identity that
    /// was previously deleted. Routine capture and stale-device uploads never
    /// create this marker.
    /// A sync reads deletions before it applies them. If this device signed in
    /// to the account after the deletion, even while the sync was running,
    /// the account is kept; the next sync retires the deletion.
    func signedInAfterDeletion(_ identity: String, in vault: VividCloudAccountVault) -> Bool {
        guard let deletedAt = vault.tombstones[identity]?.deletedAt,
              let signedInAt = loadResurrections()[identity] else { return false }
        return !VividCloudDeletionPolicy.tombstoneWins(deletedAt: deletedAt, explicitAuthenticationAt: signedInAt)
    }

    /// Sign-ins still to upload after a sync: anything recorded or updated
    /// while it ran. Unchanged entries were carried by the uploaded vault.
    static func resurrections(_ current: [String: Date], afterUploading synced: [String: Date]) -> [String: Date] {
        current.filter { identity, date in synced[identity] != date }
    }

    func noteExplicitAuthentication(_ account: TVSavedAccount) {
        noteExplicitAuthentication(serverID: account.serverID, userID: account.userID, siloProfileID: account.siloProfileID)
    }

    func noteExplicitAuthentication(serverID: String, userID: String, siloProfileID: String? = nil) {
        var resurrections = loadResurrections()
        resurrections[VividCloudAccountIdentity.key(serverID: serverID, userID: userID, siloProfileID: siloProfileID)] = Date()
        save(resurrections, key: Self.resurrectionDefaultsKey)
    }

    // MARK: Synchronising

    /// Runs a sync, or asks the running one to go round again and waits for
    /// it. The newest router given is the one the sync routes with.
    func synchronize(router: AppRouter? = nil) async {
        if let router {
            pendingRouter = router
        }
        guard !isSynchronizing else {
            needsAnotherSynchronization = true
            while isSynchronizing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return
        }

        isSynchronizing = true
        var routingContext = router
        repeat {
            needsAnotherSynchronization = false
            if let pendingRouter {
                routingContext = pendingRouter
                self.pendingRouter = nil
            }
            await synchronizeOnce(router: routingContext)
        } while needsAnotherSynchronization
        isSynchronizing = false
    }

    /// A new install's first launch waits for iCloud to restore saved
    /// profiles, but for no longer than `limit`: a slow or blocked iCloud
    /// must not keep the startup splash up. Returns false when the wait ran
    /// out. The sync carries on and still imports saved profiles, but holds
    /// back choosing one and restoring its session (see
    /// ``TVSavedAccountStore/holdsCloudRestore``), so it can't rebuild the
    /// setup screen the person is already using.
    func synchronizeForFirstLaunch(router: AppRouter, limit: Duration) async -> Bool {
        // Launch is still on the splash, so a hold left by an attempt that
        // never reached setup doesn't apply to this one.
        store.holdsCloudRestore = false
        if firstLaunchRestore == nil {
            // Unstructured, so it keeps going once launch stops waiting. A
            // retried launch waits on the same sync rather than starting one.
            firstLaunchRestore = Task {
                await self.synchronize(router: router)
                self.firstLaunchRestore = nil
            }
        }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while firstLaunchRestore != nil, !Task.isCancelled {
            // A session restore under way is local and quick. Let it finish
            // so launch routes with it, rather than showing setup over it.
            if ContinuousClock.now >= deadline, !store.isRestoringCloudSession {
                store.holdsCloudRestore = true
                Self.logger.notice("Private iCloud account restore is slow; continuing to setup.")
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return firstLaunchRestore == nil
    }

    private func synchronizeOnce(router: AppRouter?) async {
        // A Silo profile choice owns the live session; the commit syncs after it.
        guard store.pendingProfileChoice == nil else { return }
        do {
            bootstrapFailed = false
            let status = try await container.accountStatus()
            guard status == .available else {
                bootstrapFailed = status != .noAccount
                return
            }
            _ = try preferences.capture(accounts: store.accounts)
            // A media server outage must not block account restoration.
            try? await preferences.captureSharedSettings()
            var activeWasDeleted = false
            var activeSessionWasInvalidated = false
            // Sign-ins recorded before this sync started. Any recorded while it
            // runs stay local for the next sync.
            let syncedResurrections = loadResurrections()
            var savedSuccessfully = false

            for _ in 0..<Self.saveAttempts {
                let (record, existingPayload) = try await fetchRecord()
                // Without a readable household record, sync carries on but never
                // writes that record, so other devices' saved profiles survive.
                let profileState = await fetchProfileRecord()
                var vault = VividCloudVaultPartition.combined(
                    main: try decodeVault(existingPayload),
                    profiles: profileState?.vault ?? VividCloudAccountVault()
                )
                _ = try preferences.capture(accounts: store.accounts)
                let resurrections = vault.accounts.compactMapValues(\.authenticatedAt)
                    .merging(loadResurrections(), uniquingKeysWith: max)
                mergeDeletions(into: &vault, resurrections: resurrections)
                for account in store.accounts
                where vault.tombstones[VividCloudAccountIdentity.key(for: account)] != nil
                    && !signedInAfterDeletion(VividCloudAccountIdentity.key(for: account), in: vault) {
                    try preferences.removeAccountPreferences(account)
                }

                guard store.pendingProfileChoice == nil else { return }
                let applyResult = await store.applyCloudVault(vault)
                activeWasDeleted = activeWasDeleted || applyResult.activeAccountDeleted
                activeSessionWasInvalidated = activeSessionWasInvalidated || applyResult.activeSessionInvalidated

                mergeLocalProfiles(into: &vault, resurrections: resurrections)
                vault.preferences = try preferences.reconcile(vault.preferences ?? [:], accounts: store.accounts)
                applyOrder(from: vault.preferences)
                if try await upload(vault, record: record, existingPayload: existingPayload, profileState: profileState) {
                    savedSuccessfully = true
                    break
                }
            }

            guard savedSuccessfully else { bootstrapFailed = true; return }
            preferences.startObserving()
            retireUploadedRecords(syncedResurrections: syncedResurrections)
            // A profile choice that began during this sync keeps the live session.
            guard store.pendingProfileChoice == nil else { return }
            let restored = await store.restoreActiveCloudSessionIfNeeded()
            if restored { try? await preferences.applySharedSettings() }
            route(router, restored: restored, lostActiveSession: activeWasDeleted || activeSessionWasInvalidated)
        } catch {
            bootstrapFailed = true
            Self.logger.notice("Private iCloud account sync is temporarily unavailable.")
        }
    }

    /// Adds this device's server deletions and profile deletions to the
    /// vault, retires deletions that a later sign-in beat, and drops deleted
    /// profiles from it.
    private func mergeDeletions(into vault: inout VividCloudAccountVault, resurrections: [String: Date]) {
        for (serverID, deletion) in loadServerTombstones() {
            if vault.serverTombstones?[serverID].map({ $0.deletedAt >= deletion.deletedAt }) == true { continue }
            if vault.serverTombstones == nil { vault.serverTombstones = [:] }
            vault.serverTombstones?[serverID] = deletion
        }
        vault.applyServerDeletions(local: store.cloudSnapshot(), authentications: resurrections)

        for (identity, signedInAt) in resurrections {
            if let tombstone = vault.tombstones[identity],
               !VividCloudDeletionPolicy.tombstoneWins(deletedAt: tombstone.deletedAt, explicitAuthenticationAt: signedInAt) {
                vault.tombstones.removeValue(forKey: identity)
            }
        }
        for (identity, tombstone) in loadTombstones() {
            guard VividCloudDeletionPolicy.tombstoneWins(deletedAt: tombstone.deletedAt,
                                                        explicitAuthenticationAt: resurrections[identity]) else { continue }
            if let existing = vault.tombstones[identity], existing.deletedAt >= tombstone.deletedAt { continue }
            vault.tombstones[identity] = tombstone
        }
        for identity in vault.tombstones.keys {
            vault.accounts.removeValue(forKey: identity)
        }
    }

    /// Puts this device's profiles into the vault where they are newer or
    /// carry a newer sign-in than iCloud's copy.
    private func mergeLocalProfiles(into vault: inout VividCloudAccountVault, resurrections: [String: Date]) {
        for (identity, var envelope) in store.cloudSnapshot() where vault.tombstones[identity] == nil {
            let existing = vault.accounts[identity]
            envelope.authenticatedAt = [existing?.authenticatedAt, resurrections[identity]].compactMap { $0 }.max()
            if let existing, existing.updatedAt >= envelope.updatedAt,
               existing.authenticatedAt == envelope.authenticatedAt { continue }
            vault.accounts[identity] = envelope
        }
    }

    private func applyOrder(from preferences: [String: VividCloudPreference]?) {
        func order(_ key: String) -> [String]? {
            preferences?[key]?.value.flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        }
        let legacy = order(VividCloudAccountOrder.legacyKey)
        let full = order(VividCloudAccountOrder.fullKey)
        if legacy != nil || full != nil {
            store.applyCloudOrder(legacy: legacy, full: full)
        }
    }

    /// Saves whichever records changed. Returns false when another device
    /// saved a record first, so the sync should start again from a fresh read.
    private func upload(_ vault: VividCloudAccountVault, record: CKRecord, existingPayload: Data?,
                        profileState: (record: CKRecord, payload: Data?, vault: VividCloudAccountVault)?) async throws -> Bool {
        let parts = VividCloudVaultPartition.split(vault)
        let payload = try Self.encoder.encode(parts.main)
        let profilePayload = try Self.encoder.encode(parts.profiles)
        let savesMain = payload != existingPayload
        // The household record is created only once a member is saved.
        let savesProfiles = profileState.map {
            profilePayload != $0.payload && ($0.payload != nil || !parts.profiles.accounts.isEmpty)
        } ?? false
        guard savesMain || savesProfiles else { return true }
        do {
            if savesMain {
                record.encryptedValues[Self.payloadKey] = payload as NSData
                _ = try await container.privateCloudDatabase.save(record)
            }
            if savesProfiles, let profileRecord = profileState?.record {
                profileRecord.encryptedValues[Self.payloadKey] = profilePayload as NSData
                _ = try await container.privateCloudDatabase.save(profileRecord)
            }
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            return false
        }
    }

    /// After a successful upload, keeps only the local deletions no sign-in
    /// has since replaced, and the sign-ins recorded while the sync ran.
    private func retireUploadedRecords(syncedResurrections: [String: Date]) {
        var retainedTombstones = loadTombstones()
        for identity in loadResurrections().keys {
            retainedTombstones.removeValue(forKey: identity)
        }
        save(retainedTombstones, key: Self.tombstoneDefaultsKey)
        let pendingResurrections = Self.resurrections(loadResurrections(), afterUploading: syncedResurrections)
        if pendingResurrections.isEmpty {
            defaults.removeObject(forKey: Self.resurrectionDefaultsKey)
        } else {
            save(pendingResurrections, key: Self.resurrectionDefaultsKey)
        }
    }

    /// Moves the app on after a sync that lost or restored the active session.
    private func route(_ router: AppRouter?, restored: Bool, lostActiveSession: Bool) {
        if lostActiveSession {
            if restored {
                showSignedIn(router)
            } else if store.accounts.isEmpty {
                router?.resetToServerSetup()
            } else {
                store.showsSelector = true
                router?.resetToLogin()
            }
        } else if restored, let router,
                  router.authState == .needsLogin || router.authState == .needsServerSetup {
            showSignedIn(router)
        }
    }

    private func showSignedIn(_ router: AppRouter?) {
        if AuthService.shared.hasProfile { router?.resetToHome() } else { router?.showProfileSelection() }
    }

    // MARK: Records

    private func fetchRecord() async throws -> (CKRecord, Data?) {
        do {
            let record = try await container.privateCloudDatabase.record(for: Self.recordID)
            guard let payload = Self.payloadData(from: record) else { throw ServerRegistryError.persistenceFailed }
            return (record, payload)
        } catch let error as CKError where error.code == .unknownItem {
            return (CKRecord(recordType: Self.recordType, recordID: Self.recordID), nil)
        }
    }

    /// The household record, or nil when it can't be read or decoded. A
    /// record that doesn't exist yet reads as empty.
    private func fetchProfileRecord() async -> (record: CKRecord, payload: Data?, vault: VividCloudAccountVault)? {
        do {
            let record = try await container.privateCloudDatabase.record(for: Self.profileRecordID)
            guard let payload = Self.payloadData(from: record),
                  let vault = try? decodeVault(payload) else { return nil }
            return (record, payload, vault)
        } catch let error as CKError where error.code == .unknownItem {
            return (CKRecord(recordType: Self.recordType, recordID: Self.profileRecordID), nil, VividCloudAccountVault())
        } catch {
            return nil
        }
    }

    private func decodeVault(_ data: Data?) throws -> VividCloudAccountVault {
        guard let data else { return VividCloudAccountVault() }
        let vault = try Self.decoder.decode(VividCloudAccountVault.self, from: data)
        guard vault.schemaVersion == 1 else { throw ServerRegistryError.persistenceFailed }
        return vault
    }

    private static func payloadData(from record: CKRecord) -> Data? {
        if let data = record.encryptedValues[payloadKey] as? Data { return data }
        if let data = record.encryptedValues[payloadKey] as? NSData { return data as Data }
        return nil
    }

    // MARK: Local storage

    private func loadTombstones() -> [String: VividCloudAccountTombstone] {
        load([String: VividCloudAccountTombstone].self, key: Self.tombstoneDefaultsKey) ?? [:]
    }

    private func loadServerTombstones() -> [String: VividCloudAccountTombstone] {
        load([String: VividCloudAccountTombstone].self, key: Self.serverTombstoneDefaultsKey) ?? [:]
    }

    private func loadResurrections() -> [String: Date] {
        load([String: Date].self, key: Self.resurrectionDefaultsKey) ?? [:]
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? Self.encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
#endif
