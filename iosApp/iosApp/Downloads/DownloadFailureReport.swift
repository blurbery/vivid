import Foundation

/// A download that failed for good, as a diagnostics problem report. Every
/// field is a token or a number: no titles, item or download IDs, file names,
/// server addresses or error text, since any of those can turn up in a
/// message.
struct DownloadFailureReport: Equatable {
    enum Stage: String {
        /// The server, or the Emby or Jellyfin adapter, refused to register it.
        case registration
        /// Fetching the offline manifest or building the transfer request.
        case preparing
        /// The background transfer of the media file.
        case transfer
        /// Moving the finished file into the downloads folder.
        case saving
        /// The server said its preparation or conversion failed.
        case conversion
    }

    /// What a thrown error says, in report terms.
    typealias Classification = (status: Int?, urlErrorCode: Int?, token: String)

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
        // Only the app's own presets are named; anything else is "other".
        self.quality = quality.map { DownloadFormat(rawValue: $0)?.rawValue ?? "other" }
        self.batch = batch
        self.retries = max(retries, 0)
    }

    /// A report for a thrown error, or nil when it isn't a fault worth
    /// reporting: a cancellation, an account or profile switch, a request
    /// already in progress, or a batch with nothing left to download.
    init?(stage: Stage, error: Error, server: String, quality: String?, batch: Bool, retries: Int) {
        guard let classified = Self.classify(error) else { return nil }
        self.init(stage: stage, server: server, status: classified.status, urlErrorCode: classified.urlErrorCode,
                  error: classified.token, quality: quality, batch: batch, retries: retries)
    }

    // MARK: Network faults

    /// A network failure, which isn't the app's fault while the device is
    /// offline or the server can't be reached.
    var isNetwork: Bool { urlErrorCode != nil }

    /// Connectivity, timeout and TLS failures point at the network or the
    /// server rather than the app. A background transfer can't tell whether
    /// the server was reachable, so these are never recorded.
    var isConnectivity: Bool {
        guard let urlErrorCode else { return false }
        return Self.connectivityCodes.contains(URLError.Code(rawValue: urlErrorCode))
    }

    private static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .timedOut, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed,
        .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
    ]

    // MARK: Report fields

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

    // MARK: Classifying errors

    /// The status, URL error code and token for an error, or nil when it
    /// isn't a fault (see the failable initialiser).
    static func classify(_ error: Error) -> Classification? {
        switch error {
        case is CancellationError:
            return nil
        case let error as URLError:
            return error.code == .cancelled ? nil : (nil, error.code.rawValue, "network")
        case let error as HTTPError:
            return classify(error)
        case let error as DownloadError:
            return classify(error)
        case is EmbyDownloads.BatchError, is JellyfinDownloads.BatchError:
            return nil
        case let error as EmbyError:
            return classify(error)
        case let error as JellyfinError:
            return classify(error)
        case is DecodingError:
            return named("decode")
        default:
            return named("other")
        }
    }

    private static func classify(_ error: HTTPError) -> Classification? {
        switch error {
        case .requestIdentityChanged: nil
        case .http(let status, _): (status, nil, "http")
        case .network(let underlying): classify(underlying)
        case .serverUrlNotConfigured: named("server_url_missing")
        case .invalidURL: named("invalid_url")
        case .invalidResponse: named("invalid_response")
        case .encodingFailed: named("encoding_failed")
        case .decodingFailed: named("decode")
        }
    }

    private static func classify(_ error: DownloadError) -> Classification? {
        switch error {
        case .registrationAlreadyInFlight, .scopeChangedDuringRegistration, .unavailable: nil
        case .fileURLUnavailable: named("file_url_unavailable")
        case .emptyRegistrationResponse: named("empty_registration")
        }
    }

    private static func classify(_ error: EmbyError) -> Classification {
        switch error {
        case .invalidResponse: named("invalid_response")
        case .invalidURL: named("invalid_url")
        case .unsupportedFeature: named("unsupported_feature")
        case .signInRequired: named("sign_in_required")
        case .playbackUnavailable: named("media_source_unavailable")
        case .filterRequestFailed(_, let status): (status, nil, "http")
        case .connectUnavailable, .connectPINExpired, .connectServerNotLinked: named("other")
        }
    }

    private static func classify(_ error: JellyfinError) -> Classification {
        switch error {
        case .invalidResponse: named("invalid_response")
        case .invalidURL: named("invalid_url")
        case .unsupportedFeature: named("unsupported_feature")
        case .signInRequired: named("sign_in_required")
        case .playbackUnavailable: named("media_source_unavailable")
        case .filterRequestFailed(_, let status): (status, nil, "http")
        case .quickConnectDisabled, .quickConnectExpired, .quickConnectUnavailable: named("other")
        }
    }

    /// A classification that carries only a token.
    private static func named(_ token: String) -> Classification { (nil, nil, token) }

    /// Whether a fetch that failed this way could work later: a cancellation,
    /// an account switch, a network failure, an expired sign-in, or the
    /// server being busy or failing. A refusal such as 403 or 404 isn't.
    static func isRetryable(_ error: Error) -> Bool {
        guard let classified = classify(error) else { return true }
        if classified.urlErrorCode != nil || classified.token == "sign_in_required" { return true }
        guard let status = classified.status else { return false }
        return [401, 408, 429].contains(status) || (500...599).contains(status)
    }

    /// Lowercase letters, digits and underscores only, at most 32 long.
    private static func token(_ raw: String) -> String {
        let characters = raw.lowercased().unicodeScalars.map { scalar -> Character in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) ? Character(scalar) : "_"
        }
        let token = String(characters.prefix(32))
        return token.isEmpty ? "unknown" : token
    }
}
