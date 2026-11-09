#if os(tvOS) || os(iOS)
import Foundation

/// A saved profile: one sign-in on one server, shown as a card in the
/// profile selector and in Settings. Saved in shared defaults as JSON, so the
/// stored property order and names are the saved format.
struct TVSavedAccount: Codable, Identifiable, Hashable {
    let id: String
    let serverID: String
    let userID: String
    var username: String
    var profile: UserProfile?
    var requiresLogin: Bool
    var pinEnabled: Bool? = nil
    /// The Silo viewing profile this saved profile always enters, for a
    /// household member other than the account's primary profile. Nil keeps
    /// the original behaviour (the primary, or only, profile) and the original
    /// identity, so existing saved profiles are unchanged.
    var siloProfileID: String? = nil
    /// The name this saved profile shows for its server, set from the Server
    /// row in Settings > Servers. Each profile keeps its own, so two profiles
    /// on one server can name it differently. Nil shows the server's own label.
    var serverName: String? = nil
    /// Whether this sign-in is an administrator on its server, as the server
    /// last reported it. Nil until a session for it is next saved, which
    /// shows the server label alone.
    var isAdmin: Bool? = nil

    /// "Admin" or "User", or nil while the role isn't known yet.
    var roleLabel: String? {
        isAdmin.map { $0 ? String(localized: "Admin", comment: "Role of a server administrator, shown with the server name on a saved profile") : String(localized: "User", comment: "Role of a server user who isn't an administrator, shown with the server name on a saved profile") }
    }

    /// The server label this profile shows: its own name for the server, or
    /// the server's.
    var serverLabel: String { serverName ?? defaultServerLabel }

    /// "Admin · Emby", or the server label alone while the role isn't known.
    var roleAndServerLabel: String {
        guard let roleLabel else { return serverLabel }
        return String(localized: "\(roleLabel) · \(serverLabel)", comment: "A saved profile's role and server, for example Admin · Emby")
    }

    /// The label under this saved profile when it has no server name: "Emby"
    /// or "Jellyfin", or the Silo server's own name.
    var defaultServerLabel: String {
        let provider = MediaServerProvider.forServerID(serverID)
        if provider.usesNativeUser { return provider.name }
        return ServerRegistry.shared.entry(with: serverID)?.displayName ?? String(localized: "Media server")
    }

    /// A typed server name without its surrounding spaces, or nil when it's
    /// blank, which shows the server's own label again.
    static func serverName(from input: String?) -> String? {
        let name = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// A Silo saved profile shows its viewing profile's name, the primary
    /// profile's included, since that name is chosen in Silo and isn't the
    /// sign-in username. An unbound card uses the name only while it holds
    /// the primary profile. Emby, Jellyfin and a Silo profile not loaded yet
    /// keep the username.
    var displayName: String { siloProfileName ?? username }

    /// The Silo viewing profile's name this saved profile shows, if any.
    var siloProfileName: String? {
        guard MediaServerProvider.forServerID(serverID) == .silo, let profile else { return nil }
        let ownsProfile = siloProfileID.map { profile.id == $0 } ?? profile.isPrimary
        guard ownsProfile else { return nil }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// Which Silo viewing profile a saved profile binds to.
enum SiloProfileBinding {
    /// Nil for the primary profile, or the account's only profile, so those
    /// keep the original saved-profile identity. Any other household member
    /// gets its own saved profile. Emby and Jellyfin never bind.
    static func binding(for profile: UserProfile, profileCount: Int, serverID: String) -> String? {
        guard MediaServerProvider.forServerID(serverID) == .silo,
              !profile.isPrimary, profileCount > 1 else { return nil }
        return profile.id
    }

    /// Whether `profileID` is a live profile the saved profile may capture.
    /// A bound saved profile only ever captures its own Silo profile.
    static func accepts(_ account: TVSavedAccount, profileID: String?) -> Bool {
        guard let bound = account.siloProfileID else { return true }
        return bound == profileID
    }
}

/// The credentials a saved profile keeps in the Keychain, as JSON.
struct TVSavedAccountSession: Codable {
    let accessToken: String
    let refreshToken: String
    let profile: UserProfile?
    let profileToken: String?
    var nativeUserID: String? = nil
}

/// A sign-in its server has already accepted. Adding a server checks the
/// password before Vivid starts switching to it, so a wrong one stays on the
/// sign-in screen.
enum VerifiedServerLogin {
    case silo(LoginResponse)
    case jellyfin(JellyfinLogin)
    case emby(EmbyLogin)

    /// Signs in at `serverURL` without saving anything or switching servers.
    static func signIn(serverURL: String, provider: MediaServerProvider,
                       username: String, password: String) async throws -> Self {
        switch provider {
        case .jellyfin:
            let session = try await JellyfinConnection.login(serverURL: serverURL, username: username, password: password)
            return .jellyfin(JellyfinLogin(token: session.token, userID: session.userID, username: username))
        case .emby:
            let session = try await EmbyConnection.login(serverURL: serverURL, username: username, password: password)
            return .emby(EmbyLogin(token: session.token, userID: session.userID, username: username))
        case .silo:
            return .silo(try await HTTPClient.shared.loginSavedAccount(serverURL: serverURL, username: username, password: password))
        }
    }

    /// The session to save, with the server's own user ID for Jellyfin and Emby.
    var response: (login: LoginResponse, nativeUserID: String?) {
        switch self {
        case .silo(let login):
            return (login, nil)
        case .jellyfin(let result):
            return (Self.nativeResponse(token: result.token, numberID: JellyfinAdapter.numberID(result.userID),
                                        username: result.username), result.userID)
        case .emby(let result):
            return (Self.nativeResponse(token: result.token, numberID: EmbyAdapter.numberID(result.userID),
                                        username: result.username), result.userID)
        }
    }

    /// Emby and Jellyfin sessions have no refresh token or expiry, and their
    /// user stands in as an ordinary Silo user under a numeric ID.
    private static func nativeResponse(token: String, numberID: Int, username: String) -> LoginResponse {
        LoginResponse(accessToken: token, refreshToken: "", expiresIn: 0,
                      user: AuthUser(id: numberID, username: username, email: "", role: "user",
                                     downloadAllowed: false, impersonation: nil))
    }
}

enum TVAccountRoute: Hashable {
    case editor(String?)
    /// Settings > Profiles: every saved profile as a row.
    case profiles
}

/// The Silo viewing profile login preparation should enter.
enum SiloProfileTarget: Equatable {
    /// A saved profile bound to this household member.
    case bound(String)
    /// The account's primary (or only) profile, as before.
    case primary
    /// A new saved profile: the member is chosen when there is more than one.
    case choose
}

/// A sign-in that becomes a new saved profile once its Silo viewing profile
/// is chosen. While it is pending, no saved profile owns the live session, so
/// routine capture and iCloud sync wait instead of saving or replacing it.
struct PendingSiloProfileChoice: Equatable {
    let serverID: String
    /// The viewing profile that was entered, once there is one.
    var profile: UserProfile? = nil
    /// The saved-profile binding for `profile` (see ``SiloProfileBinding``).
    var binding: String? = nil
}
#endif
