import Foundation

/// Normalized error payload for UI. Wraps `Error` with a humanized message
/// and — when the source is an `HTTPError` / `APIError` — the HTTP status
/// code so `ErrorView` can pick recovery actions without the UI needing to
/// know about networking error types.
struct ErrorState: Equatable {
    let statusCode: Int?
    let message: String

    /// Refresh flow has given up; user must re-authenticate.
    var isAuthFailure: Bool {
        guard let statusCode else { return false }
        return statusCode == 401 || statusCode == 403
    }

    var isNotFound: Bool { statusCode == 404 }

    /// A retry might succeed without user action. `nil` status means a
    /// network-layer error (no HTTP response), which is also transient.
    var isTransient: Bool {
        guard let statusCode else { return true }
        return statusCode >= 500 || statusCode == 408 || statusCode == 429
    }

    init(statusCode: Int?, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    init(_ error: Error) {
        if let httpError = error as? HTTPError {
            self.statusCode = httpError.statusCode
            self.message = Self.humanize(httpError: httpError)
            return
        }
        if let apiError = error as? APIError, case .httpError(let code) = apiError {
            self.statusCode = code
            self.message = Self.humanize(statusCode: code)
            return
        }
        self.statusCode = nil
        self.message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }

    private static func humanize(httpError: HTTPError) -> String {
        switch httpError {
        case .serverUrlNotConfigured:
            return String(localized: "No server is configured.")
        case .requestIdentityChanged:
            return String(localized: "The active server or profile changed. Try again.")
        case .invalidURL:
            return String(localized: "The request URL was invalid.")
        case .invalidResponse:
            return String(localized: "The server returned an unexpected response.")
        case .network:
            return String(localized: "Can't reach the server. Check your connection and try again.")
        case .encodingFailed, .decodingFailed:
            return String(localized: "The server response was in an unexpected format.")
        case .http(let code, _):
            return humanize(statusCode: code)
        }
    }

    private static func humanize(statusCode code: Int) -> String {
        switch code {
        case 401, 403:
            return String(localized: "Your session has expired. Sign in again to continue.")
        case 404:
            return String(localized: "We couldn't find what you were looking for. It may have been removed or moved.")
        case 408, 504:
            return String(localized: "The server took too long to respond. Try again in a moment.")
        case 429:
            return String(localized: "Too many requests. Please wait a moment and try again.")
        case 500...599:
            return String(localized: "The server ran into a problem. Try again in a moment.")
        default:
            return String(localized: "Something went wrong while talking to the server.")
        }
    }
}
