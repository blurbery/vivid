import Foundation

/// Why a load stopped before it had rows. Thrown by the sources and turned
/// into an outcome by the loader.
enum ShelfFailure: Error, Equatable {
    /// The viewer in shared storage changed, or stopped being allowed, while
    /// the load was running.
    case viewerChanged
    /// The stored Emby or Jellyfin sign-in isn't the active profile's.
    case nativeIdentity
    case signedOut
    case refreshRefused
    case http(Int)
    case badAddress
    case badResponse
}

/// How one Top Shelf run ended. Its `status` is saved for diagnostics, so it
/// is built only from fixed words and numbers: never an address, a token or
/// anything a server said.
enum ShelfOutcome: Equatable {
    case refused(TopShelfAccess.Refusal)
    case nativeIdentity
    case changedDuringLoad
    case failed(reason: String)
    case loaded(ShelfFeed)

    init(error: Error) {
        switch error {
        case ShelfFailure.viewerChanged: self = .changedDuringLoad
        case ShelfFailure.nativeIdentity: self = .nativeIdentity
        default: self = .failed(reason: Self.reason(for: error))
        }
    }

    var status: String {
        switch self {
        case .refused(let refusal): return "blocked: " + refusal.rawValue
        case .nativeIdentity: return "blocked: native-identity"
        case .changedDuringLoad: return "blocked: changed-during-load"
        case .failed(let reason): return "failed: " + reason
        case .loaded(let feed): return "ok: resume=\(feed.resume.count) upnext=\(feed.upNext.count)"
        }
    }

    /// A short fixed word for an error. Errors are matched by type and code
    /// only; their descriptions can carry the server's address.
    static func reason(for error: Error) -> String {
        switch error {
        case let failure as ShelfFailure:
            switch failure {
            case .signedOut: return "signed-out"
            case .refreshRefused: return "refresh-refused"
            case .http(let code): return "http-\(code)"
            case .badAddress: return "bad-address"
            case .badResponse, .viewerChanged, .nativeIdentity: return "bad-response"
            }
        case is CancellationError:
            return "cancelled"
        case let failure as URLError:
            switch failure.code {
            case .cancelled: return "cancelled"
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .networkConnectionLost:
                return "offline"
            // The Apple TV is online but the server can't be found or reached.
            case .cannotFindHost, .cannotConnectToHost:
                return "unreachable"
            case .badURL, .unsupportedURL: return "bad-address"
            default: return "network"
            }
        case let failure as TopShelfNativeClient.Failure:
            switch failure {
            case .invalidURL: return "bad-address"
            case .invalidItem: return "bad-response"
            // The native client reports a reply that isn't HTTP as status 0.
            case .status(let code): return code > 0 ? "http-\(code)" : "bad-response"
            }
        case SiloAPICompatibility.Failure.unsupportedStatus(let code):
            return "http-\(code)"
        default:
            // What's left is decoding and JSON errors.
            return "bad-response"
        }
    }
}
