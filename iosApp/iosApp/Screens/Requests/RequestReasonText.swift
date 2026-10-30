import Foundation

/// Words for the reason a title can't be requested or a request stopped.
enum RequestReasonText {
    /// Known tokens get catalog text; any other token is shown with each of
    /// its words capitalised. Nil or empty tokens give nil.
    static func text(for token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        switch token {
        case "already_requested":
            return String(localized: "Already requested")
        case "already_available":
            return String(localized: "Already in your library")
        case "quota_exceeded", "limit_reached":
            return String(localized: "Request limit reached")
        case "requests_disabled":
            return String(localized: "Requests are turned off")
        case "requesting_blocked", "blocked":
            return String(localized: "You can't request media right now")
        case "validation_failed":
            return String(localized: "That request couldn't be submitted")
        case "invalid_state":
            return String(localized: "This request can no longer be changed")
        case "not_found":
            return String(localized: "This title is no longer available")
        default:
            return humanised(token)
        }
    }

    private static func humanised(_ token: String) -> String {
        token
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }
}
