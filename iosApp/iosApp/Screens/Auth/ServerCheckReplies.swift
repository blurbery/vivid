import Foundation

// Replies decode with the HTTP client's snake-case conversion, so the
// property names stand for `needs_setup`, `server_name` and so on.

/// Whether the server's administrator still has to finish setting it up.
struct SetupStatus: Codable {
    let needsSetup: Bool
}

/// The health reply. A reply without `status` fails to decode.
struct HealthStatus: Codable {
    let status: String
    let serverName: String?
}

/// The server's branding, of which only the name is read.
struct ServerBrandingStatus: Codable {
    let serverName: String?
}

/// A server that answered at `url`, found before anything is saved.
/// `id` is its server list id, prefixed for Emby and Jellyfin.
struct ServerProbe: Hashable {
    let provider: MediaServerProvider
    let url: String
    let id: String
    let fetchedName: String?
    let needsSetup: Bool
}
