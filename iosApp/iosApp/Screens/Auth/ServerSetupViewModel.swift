import Foundation
import OSLog

enum ServerSetupScheme: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case https = "HTTPS"
    case http = "HTTP"

    var id: String { rawValue }

    /// The segment's label. Only Auto is a word to translate.
    var title: String {
        switch self {
        case .auto: String(localized: "Auto", comment: "Server protocol choice that tries HTTPS, then HTTP")
        case .https, .http: rawValue
        }
    }

    var urlScheme: String? {
        switch self {
        case .auto: nil
        case .https: "https"
        case .http: "http"
        }
    }
}

@Observable
class ServerSetupViewModel {
    var provider: MediaServerProvider = .silo
    var host: String = ""
    var selectedScheme: ServerSetupScheme = .auto
    var port: String = ""
    var showsAdvancedOptions: Bool = false
    var isLoading: Bool = false
    var error: String?

    private let auth = AuthService.shared
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "ServerSetup"
    )

    /// Validate the server URL and determine whether setup or login is needed.
    func connect(router: AppRouter) async {
        guard let status = await firstReachable({ try await auth.checkServer(url: $0, provider: provider) }) else { return }
        // Keeps this sign-in when the person leaves Vivid to fetch a
        // password: iCloud sync on return won't restore the saved
        // profile they were using before.
        await TVSavedAccountStore.shared.noteChosenServer()
        router.resetToLogin()
        if status.needsSetup {
            router.navigate(to: .serverNeedsSetup)
        }
    }

    /// Finds the server without saving it or switching to it, for adding a
    /// server from Settings. The sign-in that follows saves it.
    func probe() async -> ServerProbe? {
        guard let server = await firstReachable({ try await auth.probeServer(url: $0, provider: provider) }) else { return nil }
        guard !server.needsSetup else {
            error = String(localized: "This server still needs administrator setup.")
            return nil
        }
        return server
    }

    /// Tries each candidate address in turn and returns the first answer, or
    /// sets `error` when none answers.
    private func firstReachable<Result>(_ attempt: (String) async throws -> Result) async -> Result? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = String(localized: "Please enter a server host.")
            return nil
        }

        let candidates: [String]
        do {
            candidates = try buildCandidateURLs()
        } catch let validationError as ServerSetupValidationError {
            error = validationError.localizedDescription
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        var attempted: [String] = []
        var lastError: Error?
        for candidate in candidates {
            attempted.append(candidate)
            do {
                return try await attempt(candidate)
            } catch let connectError {
                lastError = connectError
            }
        }

        Self.logger.error(
            "Server autodiscovery failed candidates=\(attempted.joined(separator: ", "), privacy: .public) lastError=\(String(describing: lastError), privacy: .public)"
        )
        self.error = String(localized: "Could not reach a \(provider.name) server at that address.")
        return nil
    }

    func buildCandidateURLs() throws -> [String] {
        let parsed = try parseInput()
        let explicitPort = try normalizedPort(parsed.portOverride ?? port)
        let schemes = candidateSchemes(parsedScheme: parsed.schemeOverride)

        var candidates: [String] = []
        for scheme in schemes {
            candidates.append(try makeURL(scheme: scheme, host: parsed.host, port: explicitPort, path: parsed.path))
        }

        if selectedScheme == .auto, (!provider.usesNativeUser || parsed.schemeOverride == nil), explicitPort == nil {
            candidates.append(try makeURL(scheme: "http", host: parsed.host, port: provider.usesNativeUser ? "8096" : "8090", path: parsed.path))
        }

        return unique(candidates)
    }

    private func candidateSchemes(parsedScheme: String?) -> [String] {
        if let explicit = selectedScheme.urlScheme {
            return [explicit]
        }
        if let parsedScheme {
            return [parsedScheme]
        }
        return ["https", "http"]
    }

    private func parseInput() throws -> ParsedServerInput {
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rawHost.isEmpty else {
            throw ServerSetupValidationError.missingHost
        }

        let parseValue = rawHost.contains("://") ? rawHost : "https://\(rawHost)"
        if let components = URLComponents(string: parseValue),
           let parsedHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsedHost.isEmpty {
            let parsedScheme = rawHost.contains("://") ? components.scheme?.lowercased() : nil
            let parsedPort = components.port.map(String.init)
            return ParsedServerInput(
                schemeOverride: parsedScheme,
                host: parsedHost,
                portOverride: parsedPort,
                path: normalizedPath(components.percentEncodedPath)
            )
        }

        throw ServerSetupValidationError.invalidHost
    }

    private func normalizedPort(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.allSatisfy(\.isNumber),
              let intValue = Int(trimmed),
              (1...65535).contains(intValue) else {
            throw ServerSetupValidationError.invalidPort
        }
        return String(intValue)
    }

    private func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty, path != "/" else { return "" }
        var normalized = path
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    private func makeURL(scheme: String, host: String, port: String?, path: String) throws -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port, !isDefaultPort(port, for: scheme) {
            components.port = Int(port)
        }
        components.percentEncodedPath = path
        guard let url = components.url?.absoluteString else {
            throw ServerSetupValidationError.invalidHost
        }
        return ServerRegistry.shared.normalizedUserAddress(url)
    }

    private func isDefaultPort(_ port: String, for scheme: String) -> Bool {
        (scheme == "https" && port == "443") || (scheme == "http" && port == "80")
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct ParsedServerInput {
    let schemeOverride: String?
    let host: String
    let portOverride: String?
    let path: String
}

private enum ServerSetupValidationError: LocalizedError {
    case missingHost
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return String(localized: "Please enter a server host.")
        case .invalidHost:
            return String(localized: "Please enter a valid server host.")
        case .invalidPort:
            return String(localized: "Port must be a number between 1 and 65535.")
        }
    }
}
