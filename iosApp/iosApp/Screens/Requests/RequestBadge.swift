import SwiftUI

/// The request state shown on card ribbons and the detail page's button.
enum RequestBadge: Equatable {
    case pending
    case onTheWay
    case inLibrary
    case needsAttention(reason: String?)
    case unavailable(reason: String?)

    /// The state of a request record. A terminal outcome wins over the status,
    /// and an unknown status counts as in progress.
    static func forRecord(status: RequestStatus, outcome: RequestOutcome, reason: String?) -> RequestBadge {
        switch outcome {
        case .declined, .failed:
            return .needsAttention(reason: reason)
        case .cancelled:
            return .unavailable(reason: reason)
        case .active, .unknown:
            switch status {
            case .pending: return .pending
            case .approved, .queued, .downloading, .unknown: return .onTheWay
            case .completed: return .inLibrary
            case .failed: return .needsAttention(reason: reason)
            }
        }
    }

    /// The state of a title on a card, or nil when it can still be requested.
    static func forCard(availability: RequestAvailability, request: RequestState) -> RequestBadge? {
        if availability == .available { return .inLibrary }
        if let status = request.status {
            return forRecord(status: status, outcome: .active, reason: request.reason)
        }
        if request.requestable { return nil }
        return .unavailable(reason: request.reason)
    }

    var label: String {
        switch self {
        case .pending: String(localized: "Pending")
        case .onTheWay: String(localized: "On the way")
        case .inLibrary: String(localized: "In library")
        case .needsAttention: String(localized: "Needs attention")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    var tint: Color {
        switch self {
        case .pending: .requestAmber
        case .onTheWay: .requestSky
        case .inLibrary: .requestEmerald
        case .needsAttention: .requestRose
        case .unavailable: .vividSecondaryText
        }
    }
}
