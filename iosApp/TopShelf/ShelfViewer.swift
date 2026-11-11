import Foundation

/// Everything shared storage says about who is watching, read in one go. Two
/// of these are compared to notice the viewer changing during a load.
struct ShelfViewer: Equatable, Sendable {
    var access: TopShelfAccess.Snapshot
    var serverURL: String?

    /// Whether `other` is the same viewer, ignoring when Vivid last left the
    /// screen. The app stamps that as it asks for a reload, so it can change
    /// mid-load, and the access rules check the away lock anyway.
    func isSameViewer(as other: ShelfViewer) -> Bool {
        var mine = self
        var theirs = other
        mine.access.launchState.backgroundedAt = nil
        theirs.access.launchState.backgroundedAt = nil
        return mine == theirs
    }
}

/// The extension's view of what the app keeps in the App Group defaults and
/// the shared Keychain. It only ever writes the two diagnostics values.
///
/// Unchecked because `SharedKeychain` isn't marked Sendable: both members
/// are immutable, and defaults and Keychain reads are safe on any thread.
struct ShelfStorage: @unchecked Sendable {
    let defaults: SharedDefaults
    let keychain: SharedKeychain

    init(defaults: SharedDefaults = .shared, keychain: SharedKeychain = SharedKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    private var accountKeychain: SharedKeychain {
        keychain.withAudience(SharedStorage.accountCredentialAudience)
    }

    private var personalKeychain: SharedKeychain {
        keychain.withAudience(.currentUser)
    }

    // MARK: - The viewer

    func viewer() -> ShelfViewer {
        let serverID = filled(defaults.string(forKey: SharedStorage.activeServerIdKey))
        let access = TopShelfAccess.Snapshot(
            serverID: serverID,
            activeProfileID: defaults.string(forKey: SharedStorage.profileIdKey),
            activeSavedAccountID: defaults.string(forKey: SharedStorage.activeSavedAccountKey),
            accountEpoch: serverID.flatMap { accountKeychain.get(SharedStorage.accountEpochAccount(for: $0)) },
            savedAccountsData: defaults.data(forKey: SharedStorage.savedAccountsKey),
            viewingProfilesData: defaults.data(forKey: SharedStorage.topShelfViewingProfilesKey),
            launchState: ProfileLaunchState.load(from: defaults)
        )
        return ShelfViewer(access: access, serverURL: filled(defaults.string(forKey: SharedStorage.serverUrlKey)))
    }

    func refusal(for viewer: ShelfViewer, now: Date) -> TopShelfAccess.Refusal? {
        let pins = personalKeychain
        return TopShelfAccess.refusal(for: viewer.access, hasStoredPIN: { accountID in
            // A Keychain that can't answer might be hiding a PIN, so a failed
            // read counts as one.
            (try? pins.getChecked("vivid.account.\(accountID).pin.v1") != nil) ?? true
        }, now: now)
    }

    // MARK: - Credentials (read only, and never logged)

    func accessToken(for serverID: String) -> String? {
        filled(accountKeychain.get(SharedStorage.accessTokenAccount(for: serverID)))
    }

    func refreshToken(for serverID: String) -> String? {
        filled(accountKeychain.get(SharedStorage.refreshTokenAccount(for: serverID)))
    }

    func profileToken(for serverID: String) -> String? {
        filled(personalKeychain.get(SharedStorage.profileTokenAccount(for: serverID)))
    }

    /// The Emby or Jellyfin user the stored access token belongs to.
    func nativeUserID(for serverID: String) -> String? {
        filled(accountKeychain.get("vivid.nativeUserID.\(serverID)"))
    }

    // MARK: - Diagnostics

    func noteRun(at date: Date) {
        defaults.set(ISO8601DateFormatter().string(from: date), forKey: SharedStorage.topShelfLastRunAtKey)
    }

    func note(_ outcome: ShelfOutcome) {
        defaults.set(outcome.status, forKey: SharedStorage.topShelfLastStatusKey)
    }

    private func filled(_ value: String?) -> String? {
        value?.isEmpty == false ? value : nil
    }
}
