import Foundation

/// A failed request reduced to a status code and a message people can read.
struct ErrorState: Equatable {
    let statusCode: Int?
    let message: String

    var isAuthFailure: Bool { statusCode == 401 || statusCode == 403 }
    var isNotFound: Bool { statusCode == 404 }
    /// Worth retrying: no status at all, a server fault, a timeout or rate limiting.
    var isTransient: Bool {
        guard let statusCode else { return true }
        return statusCode >= 500 || statusCode == 408 || statusCode == 429
    }

    init(_ error: Error) {
        if let httpError = error as? HTTPError {
            statusCode = httpError.statusCode
            message = Self.message(for: httpError)
        } else if let apiError = error as? APIError, case .httpError(let code) = apiError {
            statusCode = code
            message = Self.statusMessage(code)
        } else {
            statusCode = nil
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                message = description
            } else {
                message = error.localizedDescription
            }
        }
    }

    private static func message(for error: HTTPError) -> String {
        switch error {
        case .serverUrlNotConfigured:
            String(localized: "No server is configured.")
        case .requestIdentityChanged:
            String(localized: "The active server or profile changed. Try again.")
        case .invalidURL:
            String(localized: "The request URL was invalid.")
        case .invalidResponse:
            String(localized: "The server returned an unexpected response.")
        case .network:
            String(localized: "Can't reach the server. Check your connection and try again.")
        case .encodingFailed, .decodingFailed:
            String(localized: "The server response was in an unexpected format.")
        case .http(let statusCode, _):
            statusMessage(statusCode)
        }
    }

    private static func statusMessage(_ code: Int) -> String {
        switch code {
        case 401, 403:
            String(localized: "Your session has expired. Sign in again to continue.")
        case 404:
            String(localized: "We couldn't find what you were looking for. It may have been removed or moved.")
        case 408, 504:
            String(localized: "The server took too long to respond. Try again in a moment.")
        case 429:
            String(localized: "Too many requests. Please wait a moment and try again.")
        case 500...599:
            String(localized: "The server ran into a problem. Try again in a moment.")
        default:
            String(localized: "Something went wrong while talking to the server.")
        }
    }
}
