import Foundation

extension VividAPI {
    /// Whether the Silo server's media requests feature is on. Older servers
    /// answer 404, which callers read as off.
    func requestsStatus() async throws -> RequestsFeatureStatus {
        try await http.get("/api/v1/requests/status")
    }
}
