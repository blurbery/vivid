import Foundation

/// The kind of server an account talks to. The raw values are persisted.
enum MediaServerProvider: String, Codable, Sendable {
    case silo, emby, jellyfin

    var name: String {
        switch self {
        case .silo: "Silo"
        case .emby: "Emby"
        case .jellyfin: "Jellyfin"
        }
    }

    /// Emby and Jellyfin sign in as the server's own user.
    var usesNativeUser: Bool { self == .emby || self == .jellyfin }

    /// Removing an item from Continue Watching is a Silo Home feature.
    var supportsContinueWatchingRemoval: Bool { self == .silo }

    var serverPlaceholder: String { rawValue + ".example.com" }

    /// The provider a saved server ID belongs to: `jellyfin:` and `emby:`
    /// prefixes mark native servers, anything else (or nil) is Silo.
    static func forServerID(_ id: String?) -> Self {
        guard let id else { return .silo }
        if id.hasPrefix("jellyfin:") { return .jellyfin }
        if id.hasPrefix("emby:") { return .emby }
        return .silo
    }

    static var active: Self { forServerID(ServerRegistry.activeServerIDSnapshot) }
}
