import Foundation

/// Reads the display name a Silo server advertises.
///
/// The branding endpoint owns the name. Health is the fallback when branding
/// has no name or returns 404 (a server older than that endpoint). Any other
/// branding failure returns nil, so the stored name stays as it is.
struct ServerIdentityResolver {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchServerName(serverURL: String) async -> String? {
        do {
            let branding: ServerBrandingStatus = try await httpClient.getUnauthenticated(
                serverURL: serverURL,
                path: "/api/v1/theme/branding",
                quietStatuses: [404]
            )
            if let name = Self.usableName(branding.serverName) {
                return name
            }
        } catch HTTPError.http(let statusCode, _) where statusCode == 404 {
            // Older servers have no branding endpoint.
        } catch {
            return nil
        }

        guard let health: HealthStatus = try? await httpClient.getUnauthenticated(
            serverURL: serverURL,
            path: "/api/v1/health"
        ) else { return nil }
        return Self.usableName(health.serverName)
    }

    /// The name without surrounding whitespace, or nil when that leaves nothing.
    private static func usableName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return name
    }
}
