import Foundation

/// A download that failed for good, as a diagnostics problem report. Every
/// field is a token or a number: no titles, item or download IDs, file names,
/// server addresses or error text, which can carry any of those.
struct DownloadFailureReport: Equatable {
    enum Stage: String {
        /// The server, or the Emby/Jellyfin adapter, refused to register it.
        case registration
        /// Fetching the offline manifest or building the transfer request.
        case preparing
        /// The background transfer of the media file.
        case transfer
        /// Moving the finished file into the downloads folder.
        case saving
        /// The server reported its preparation or conversion failed.
        case conversion
    }

    let stage: Stage
    let server: String
    let status: Int?
    let urlErrorCode: Int?
    let error: String
    let quality: String?
    let batch: Bool
    let retries: Int

    init(stage: Stage, server: String, status: Int? = nil, urlErrorCode: Int? = nil, error: String,
         quality: String?, batch: Bool, retries: Int) {
        self.stage = stage
        self.server = server
        self.status = status
        self.urlErrorCode = urlErrorCode
        self.error = Self.token(error)
        // Only the app's own presets; anything else the server sent is "other".
        self.quality = quality.map { DownloadFormat(rawValue: $0)?.rawValue ?? "other" }
        self.batch = batch
        self.retries = max(retries, 0)
    }

    /// Classifies a thrown error. Nil when it isn't a fault worth reporting:
    /// cancellation, an account or profile switch, a request already in
    /// progress, or a batch with nothing left to download.
    init?(stage: Stage, error: Error, server: String, quality: String?, batch: Bool, retries: Int) {
        guard let classified = Self.classify(error) else { return nil }
        self.init(stage: stage, server: server, status: classified.status, urlErrorCode: classified.urlErrorCode,
                  error: classified.token, quality: quality, batch: batch, retries: retries)
    }

    /// A network failure, which isn't the app's fault while the device is
    /// offline or the server is unreachable.
    var isNetwork: Bool { urlErrorCode != nil }

    /// Connectivity, timeouts and TLS failures point at the network or the
    /// server, not the app, as for app errors. Background transfers can't
    /// tell whether the server was reachable, so these are never recorded.
    var isConnectivity: Bool {
        guard let urlErrorCode else { return false }
        let codes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .timedOut, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed,
            .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
        ]
        return codes.contains(URLError.Code(rawValue: urlErrorCode))
    }

    var details: [String: DiagnosticsJSONValue] {
        var details: [String: DiagnosticsJSONValue] = [
            "stage": .string(stage.rawValue),
            "server": .string(Self.token(server)),
            "error": .string(error),
            "batch": .bool(batch),
            "retries": .int(retries),
        ]
        if let status { details["status"] = .int(status) }
        if let urlErrorCode { details["url_error"] = .int(urlErrorCode) }
        if let quality { details["quality"] = .string(quality) }
        return details
    }

    static func classify(_ error: Error) -> (status: Int?, urlErrorCode: Int?, token: String)? {
        switch error {
        case is CancellationError:
            return nil
        case let error as URLError:
            return error.code == .cancelled ? nil : (nil, error.code.rawValue, "network")
        case let error as HTTPError:
            switch error {
            case .requestIdentityChanged: return nil
            case .http(let status, _): return (status, nil, "http")
            case .network(let underlying): return classify(underlying)
            case .serverUrlNotConfigured: return (nil, nil, "server_url_missing")
            case .invalidURL: return (nil, nil, "invalid_url")
            case .invalidResponse: return (nil, nil, "invalid_response")
            case .encodingFailed: return (nil, nil, "encoding_failed")
            case .decodingFailed: return (nil, nil, "decode")
            }
        case let error as DownloadError:
            switch error {
            case .registrationAlreadyInFlight, .scopeChangedDuringRegistration, .unavailable: return nil
            case .fileURLUnavailable: return (nil, nil, "file_url_unavailable")
            case .emptyRegistrationResponse: return (nil, nil, "empty_registration")
            }
        case is EmbyDownloads.BatchError, is JellyfinDownloads.BatchError:
            return nil
        case let error as EmbyError:
            switch error {
            case .invalidResponse: return (nil, nil, "invalid_response")
            case .invalidURL: return (nil, nil, "invalid_url")
            case .unsupportedFeature: return (nil, nil, "unsupported_feature")
            case .signInRequired: return (nil, nil, "sign_in_required")
            case .playbackUnavailable: return (nil, nil, "media_source_unavailable")
            case .filterRequestFailed(_, let status): return (status, nil, "http")
            }
        case let error as JellyfinError:
            switch error {
            case .invalidResponse: return (nil, nil, "invalid_response")
            case .invalidURL: return (nil, nil, "invalid_url")
            case .unsupportedFeature: return (nil, nil, "unsupported_feature")
            case .signInRequired: return (nil, nil, "sign_in_required")
            case .playbackUnavailable: return (nil, nil, "media_source_unavailable")
            case .filterRequestFailed(_, let status): return (status, nil, "http")
            }
        case is DecodingError:
            return (nil, nil, "decode")
        default:
            return (nil, nil, "other")
        }
    }

    /// Lowercase letters, digits and underscores only, at most 32 long.
    private static func token(_ raw: String) -> String {
        let cleaned = String(raw.lowercased().unicodeScalars.map { scalar -> Character in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) ? Character(scalar) : "_"
        })
        let trimmed = String(cleaned.prefix(32))
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}
