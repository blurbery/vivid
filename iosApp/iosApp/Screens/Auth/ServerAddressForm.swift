import Foundation
import Network
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
    /// The running Connect or Find, so Cancel, Back and leaving the page
    /// can stop it.
    @ObservationIgnored private var attempt: Task<Void, Never>?
    #if os(iOS)
    /// The server Find located, shown as the next page.
    var foundServer: ServerProbe?
    #endif

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app", category: "ServerSetup")

    /// First run: saves and activates the first address that answers, then
    /// moves on to sign-in.
    func connect(router: AppRouter) {
        guard !isBusy, let candidates = checkedCandidates() else { return }
        let provider = provider
        isBusy = true
        message = nil
        attempt = Task {
            let status = await firstAnswer(from: candidates, provider: provider) { candidate in
                try await AuthService.shared.checkServer(url: candidate, provider: provider)
            }
            // A cancelled attempt leaves the page as Cancel left it.
            guard !Task.isCancelled else { return }
            if let status {
                #if os(iOS) || os(tvOS)
                TVSavedAccountStore.shared.noteChosenServer()
                #endif
                router.resetToLogin()
                if status.needsSetup { router.navigate(to: .serverNeedsSetup) }
            }
            isBusy = false
            attempt = nil
        }
    }

    #if os(iOS)
    /// Add Server: finds the server without saving anything.
    func find() {
        guard !isBusy, let candidates = checkedCandidates() else { return }
        let provider = provider
        isBusy = true
        message = nil
        attempt = Task {
            let server = await firstAnswer(from: candidates, provider: provider) { candidate in
                try await AuthService.shared.locateServer(at: candidate, provider: provider)
            }
            guard !Task.isCancelled else { return }
            if let server {
                if server.needsSetup {
                    message = String(localized: "This server still needs administrator setup.")
                } else {
                    foundServer = server
                }
            }
            isBusy = false
            attempt = nil
        }
    }
    #endif

    /// Stops a Connect or Find in progress. Nothing it was doing navigates
    /// or shows an error afterwards, and the form keeps what was typed. A
    /// server that answered just before this may already be saved.
    func cancel() {
        guard let attempt else { return }
        attempt.cancel()
        self.attempt = nil
        isBusy = false
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
    /// unreachable. Once cancelled it tries no more addresses and sets no
    /// message.
    private func firstAnswer<Answer>(
        from candidates: [String], provider: MediaServerProvider,
        check: (String) async throws -> Answer
    ) async -> Answer? {
        var errors: [Error] = []
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            do {
                let answer = try await check(candidate)
                guard !Task.isCancelled else { return nil }
                return answer
            } catch let error as ServerRegistryError {
                guard !Task.isCancelled else { return nil }
                message = error.localizedDescription
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                errors.append(error)
            }
        }
        let tried = candidates.joined(separator: ", ")
        let reason = errors.last?.localizedDescription ?? ""
        Self.log.error("No server answered at \(tried, privacy: .private): \(reason, privacy: .private)")
        switch Self.reachProblem(in: errors) {
        case .localNetworkDenied:
            message = String(localized: "Vivid can't use your local network. Turn on Local Network for Vivid in Settings, then try again.")
        case .insecureHTTPBlocked:
            message = String(localized: "Could not reach a \(provider.name) server at that address. Plain HTTP only works with local addresses, so use this server's HTTPS address.")
        case nil:
            message = String(localized: "Could not reach a \(provider.name) server at that address.")
        }
        return nil
    }

    /// Why no address answered, when the errors say more than that.
    enum ReachProblem: Equatable {
        /// Local Network access is turned off for Vivid.
        case localNetworkDenied
        /// App Transport Security refused plain HTTP to a public host name.
        case insecureHTTPBlocked
    }

    /// A refused Local Network permission comes first, since turning it on
    /// may be all that's needed. The HTTPS advice only applies when every
    /// address was plain HTTP that ATS blocked: Auto always adds plain HTTP
    /// addresses after HTTPS, so a public host that fails for any reason
    /// also collects ATS blocks. Anything else gives nil and the general
    /// message.
    nonisolated static func reachProblem(in errors: [Error]) -> ReachProblem? {
        let causes = errors.map(transportCauses(of:))
        if causes.contains(where: { $0.contains(where: isLocalNetworkDenied) }) { return .localNetworkDenied }
        let blockedByATS = { (chain: [Error]) in
            chain.contains { HTTPDiagnosticsErrorCode.classify(transport: $0) == "app_transport_security_blocked" }
        }
        if !causes.isEmpty, causes.allSatisfy(blockedByATS) { return .insecureHTTPBlocked }
        return nil
    }

    /// The error, what `HTTPError.network` wraps (Silo requests) and their
    /// underlying errors. Emby and Jellyfin throw the `URLError` itself.
    private nonisolated static func transportCauses(of error: Error) -> [Error] {
        var causes: [Error] = []
        var next: Error? = error
        while let current = next, causes.count < 6 {
            if let wrapped = current as? HTTPError, case .network(let underlying) = wrapped {
                next = underlying
                continue
            }
            causes.append(current)
            next = (current as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return causes
    }

    /// URLSession puts the network path it gave up on in the error, and its
    /// unsatisfied reason says when Local Network access was refused. The
    /// key isn't documented, so a missing or different value reads as no.
    private nonisolated static func isLocalNetworkDenied(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain,
              let path = error.userInfo["_NSURLErrorNWPathKey"] as? nw_path_t else { return false }
        return nw_path_get_unsatisfied_reason(path) == nw_path_unsatisfied_reason_local_network_denied
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
