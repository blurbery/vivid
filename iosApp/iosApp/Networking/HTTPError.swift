import Foundation

/// How long a request may sit quiet. `.standard` (15 seconds between bytes)
/// finds a dead server quickly; `.extended` (90 seconds) is for endpoints
/// that hold the connection while the server works, such as subtitle
/// searches and playback planning.
enum HTTPTimeout {
    case standard
    case extended
}

/// A 2xx response handed back undecoded, for callers that also need the
/// status or a header. See `HTTPClient.requestData`.
struct HTTPRawResponse: Sendable {
    let data: Data
    let statusCode: Int
    /// Lowercased names, since HTTP header names are case-insensitive.
    let headers: [String: String]

    init(data: Data, statusCode: Int, headers: [AnyHashable: Any]) {
        self.data = data
        self.statusCode = statusCode
        var lowercased: [String: String] = [:]
        for (name, value) in headers {
            if let name = name as? String, let value = value as? String {
                lowercased[name.lowercased()] = value
            }
        }
        self.headers = lowercased
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

enum HTTPError: LocalizedError, CustomStringConvertible {
    case serverUrlNotConfigured
    case requestIdentityChanged
    case invalidURL(String)
    case invalidResponse
    case network(underlying: Error)
    case encodingFailed(underlying: Error)
    case decodingFailed(type: String, underlying: Error)
    case http(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .serverUrlNotConfigured:
            String(localized: "Server URL is not configured.")
        case .requestIdentityChanged:
            String(localized: "The active server or profile changed before the request could start.")
        case .invalidURL(let url):
            String(localized: "Invalid URL: \(url)")
        case .invalidResponse:
            String(localized: "Invalid server response.")
        case .network(let error):
            String(localized: "Network error: \(error.localizedDescription)")
        case .encodingFailed(let error):
            String(localized: "Failed to encode request body: \(error.localizedDescription)")
        case .decodingFailed(let type, let error):
            String(localized: "Failed to decode \(type): \(error.localizedDescription)")
        case .http(let statusCode, let body):
            Self.parseServerMessage(body) ?? String(localized: "Server returned status \(statusCode)")
        }
    }

    /// A log-safe form: never a URL, body, credential or an underlying
    /// error's text.
    var description: String {
        switch self {
        case .serverUrlNotConfigured: "server_url_not_configured"
        case .requestIdentityChanged: "request_identity_changed"
        case .invalidURL: "invalid_url"
        case .invalidResponse: "invalid_response"
        case .network: "network_error"
        case .encodingFailed: "encoding_failed"
        case .decodingFailed(let type, _): "decoding_failed(type: \(type))"
        case .http(let statusCode, _): "http_error(status: \(statusCode))"
        }
    }

    var statusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    /// The machine-readable code from the server's JSON error (such as
    /// `profile_limit_reached`): its `error` or `code`, or the last part of
    /// a Silo v2 problem type.
    var serverErrorCode: String? {
        guard case .http(_, let body) = self, let problem = Self.parseServerError(body) else { return nil }
        if let code = problem.error ?? problem.code { return code }
        guard let type = problem.type, type.hasPrefix("https://siloserver.org/docs/api/v2/problems/") else { return nil }
        return URL(string: type)?.lastPathComponent
    }

    /// The server's JSON error (v1's `error` and `message`, v2's problem
    /// fields). Every field is optional: some failures have no body, and
    /// some answer in plain text.
    private struct ServerError: Decodable {
        let error: String?
        let message: String?
        let code: String?
        let detail: String?
        let type: String?
    }

    private static func parseServerError(_ body: String?) -> ServerError? {
        guard let body, !body.isEmpty, let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ServerError.self, from: data)
    }

    private static func parseServerMessage(_ body: String?) -> String? {
        guard let parsed = parseServerError(body),
              let message = parsed.message ?? parsed.detail, !message.isEmpty
        else { return nil }
        return message
    }
}

extension HTTPError {
    /// The server answered and refused the request outright: a 4xx other
    /// than an expired sign-in (401), a timeout (408) or rate limiting (429).
    /// Sending it again won't change the answer.
    var isPermanentRejection: Bool {
        guard case .http(let statusCode, _) = self else { return false }
        return (400..<500).contains(statusCode) && ![401, 408, 429].contains(statusCode)
    }
}
