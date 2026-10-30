import Foundation
import os

/// How the address form reaches the server. Auto tries HTTPS, then HTTP.
enum ServerProtocolChoice: CaseIterable, Hashable {
    case auto, https, http

    var title: String {
        switch self {
        case .auto: String(localized: "Auto", comment: "Server protocol choice that tries HTTPS, then HTTP")
        case .https: "HTTPS"
        case .http: "HTTP"
        }
    }

    var forcedScheme: String? {
        switch self {
        case .auto: nil
        case .https: "https"
        case .http: "http"
        }
    }
}

/// The server address form on iPhone, iPad and Apple TV: turns what was
/// typed into the addresses to try, then tries them in order.
@MainActor @Observable
final class ServerAddressForm {
    enum AddressProblem: Error {
        case missingHost, invalidHost, invalidPort

        var message: String {
            switch self {
            case .missingHost: String(localized: "Please enter a server host.")
            case .invalidHost: String(localized: "Please enter a valid server host.")
            case .invalidPort: String(localized: "Port must be a number between 1 and 65535.")
            }
        }
    }

    var provider: MediaServerProvider = .silo
    var address = ""
    var protocolChoice: ServerProtocolChoice = .auto
    var port = ""
    var showsAdvanced = false
    private(set) var isBusy = false
    var message: String?
    /// The server Find located, shown as the next page.
    var foundServer: ServerProbe?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app", category: "ServerSetup")

    /// First run: saves and activates the first address that answers, then
    /// moves on to sign-in.
    func connect(router: AppRouter) {
        guard !isBusy, let candidates = checkedCandidates() else { return }
        let provider = provider
        isBusy = true
        message = nil
        Task {
            let status = await firstAnswer(from: candidates, provider: provider) { candidate in
                try await AuthService.shared.checkServer(url: candidate, provider: provider)
            }
            if let status {
                TVSavedAccountStore.shared.noteChosenServer()
                router.resetToLogin()
                if status.needsSetup { router.navigate(to: .serverNeedsSetup) }
            }
            isBusy = false
        }
    }

    /// Add Server: finds the server without saving anything.
    func find() {
        guard !isBusy, let candidates = checkedCandidates() else { return }
        let provider = provider
        isBusy = true
        message = nil
        Task {
            let server = await firstAnswer(from: candidates, provider: provider) { candidate in
                try await AuthService.shared.locateServer(at: candidate, provider: provider)
            }
            if let server {
                if server.needsSetup {
                    message = String(localized: "This server still needs administrator setup.")
                } else {
                    foundServer = server
                }
            }
            isBusy = false
        }
    }

    private func checkedCandidates() -> [String]? {
        let result = Self.candidates(
            typed: address, portField: port, choice: protocolChoice, provider: provider,
            spelling: { ServerRegistry.shared.normalizedUserAddress($0) }
        )
        switch result {
        case .success(let candidates):
            return candidates
        case .failure(let problem):
            message = problem.message
            return nil
        }
    }

    /// Tries each address in turn. A server that answered but couldn't be
    /// saved stops the search with that error rather than counting as
    /// unreachable.
    private func firstAnswer<Answer>(
        from candidates: [String], provider: MediaServerProvider,
        check: (String) async throws -> Answer
    ) async -> Answer? {
        var lastError: Error?
        for candidate in candidates {
            do {
                return try await check(candidate)
            } catch let error as ServerRegistryError {
                message = error.localizedDescription
                return nil
            } catch {
                lastError = error
            }
        }
        let tried = candidates.joined(separator: ", ")
        let reason = lastError?.localizedDescription ?? ""
        Self.log.error("No server answered at \(tried, privacy: .private): \(reason, privacy: .private)")
        message = String(localized: "Could not reach a \(provider.name) server at that address.")
        return nil
    }

    /// The addresses to try for what was typed, in order, without
    /// duplicates. `spelling` gives each address the form the server list
    /// uses.
    static func candidates(
        typed: String, portField: String, choice: ServerProtocolChoice, provider: MediaServerProvider,
        spelling: (String) -> String
    ) -> Result<[String], AddressProblem> {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingHost) }
        let text = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !text.isEmpty else { return .failure(.missingHost) }

        let typedScheme = text.contains("://")
        guard let parts = URLComponents(string: typedScheme ? text : "https://" + text),
              let host = parts.percentEncodedHost, !host.isEmpty else { return .failure(.invalidHost) }

        let port: Int?
        if let typedPort = parts.port {
            port = typedPort
        } else {
            let field = portField.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.isEmpty {
                port = nil
            } else if field.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let value = Int(field) {
                port = value
            } else {
                return .failure(.invalidPort)
            }
        }
        if let port, !(1...65535).contains(port) { return .failure(.invalidPort) }

        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }

        func address(scheme: String, port: Int?) -> String? {
            var components = URLComponents()
            components.scheme = scheme
            components.percentEncodedHost = host
            if let port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) {
                components.port = port
            }
            components.percentEncodedPath = path
            return components.string
        }

        let scheme = typedScheme ? parts.scheme?.lowercased() : nil
        let schemes = choice.forcedScheme.map { [$0] } ?? scheme.map { [$0] } ?? ["https", "http"]
        var addresses: [String] = []
        for scheme in schemes {
            guard let built = address(scheme: scheme, port: port) else { return .failure(.invalidHost) }
            addresses.append(built)
        }
        if choice == .auto, port == nil, provider == .silo || scheme == nil {
            guard let fallback = address(scheme: "http", port: provider == .silo ? 8090 : 8096) else { return .failure(.invalidHost) }
            addresses.append(fallback)
        }

        var seen = Set<String>()
        return .success(addresses.map(spelling).filter { seen.insert($0).inserted })
    }
}
