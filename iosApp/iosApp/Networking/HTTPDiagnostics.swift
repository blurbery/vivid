import Foundation

#if os(iOS) || os(tvOS)

// The closed vocabulary `HTTPClient` writes into diagnostics lines. Nothing
// here ever sees a host, query string, header or response body: paths are
// templated and every outcome and error code is a fixed literal.

/// Request paths for diagnostics: templated, then every segment that isn't a
/// plain token replaced with the placeholder.
enum HTTPDiagnosticsPath {
    static func attribute(for url: URL?) -> String {
        guard let url else { return DiagnosticsPathTemplate.placeholder }
        return hardened(DiagnosticsPathTemplate.templatedPath(for: url))
    }

    /// For a route the caller supplied as text. The template stops at the
    /// first `?` or `#`, so a query string can't get through.
    static func attribute(forRawPath rawPath: String) -> String {
        hardened(DiagnosticsPathTemplate.templatedPath(forRawPath: rawPath))
    }

    private static func hardened(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map { segment in
            let candidate = String(segment)
            return isSafeSegment(candidate) ? candidate : DiagnosticsPathTemplate.placeholder
        }
        return "/" + segments.joined(separator: "/")
    }

    /// A letter-initial ASCII token of letters, digits, `_` and `-` that the
    /// template doesn't treat as private. The private check runs again here
    /// because a caller can assemble a segment itself.
    private static func isSafeSegment(_ value: String) -> Bool {
        if value == DiagnosticsPathTemplate.placeholder { return true }
        guard let first = value.first, first.isASCII, first.isLetter else { return false }
        let isPlainToken = value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return isPlainToken && !DiagnosticsPathTemplate.isEmissionPrivateSegment(value)
    }
}

enum HTTPDiagnosticsOutcome {
    /// 2xx.
    static let success = "success"
    /// A non-2xx the caller expected (`quietStatuses`, such as an existence
    /// probe's 404), so a reader doesn't triage it as a fault.
    static let quiet = "quiet"
    /// A non-2xx the caller didn't expect.
    static let httpError = "http_error"
    /// No HTTP response at all: refused, DNS, TLS or a timeout.
    static let transportError = "transport_error"
    /// A URLSession cancellation, which says nothing about the server.
    static let cancelled = "cancelled"
    /// Rejected because the active server or profile changed around it.
    static let identityChanged = "identity_changed"
    /// The response wasn't an `HTTPURLResponse`.
    static let invalidResponse = "invalid_response"
    /// The bytes arrived but didn't match the Swift model.
    static let decodeFailed = "decode_failed"
    /// A 401 was retried with a refreshed credential.
    static let retried = "retried"
    /// A 401 refresh didn't run or produced no usable credential, so the 401
    /// stands.
    static let notRetried = "not_retried"
    /// Reachability changes.
    static let reachable = "reachable"
    static let unreachable = "unreachable"
    static let online = "online"
    static let offline = "offline"
}

enum HTTPDiagnosticsErrorCode {
    /// A stable literal for a transport failure. Anything other than a
    /// `URLError` is `transport_other`, since its text isn't safe to log;
    /// unmapped `URLError` codes read `urlerror_<n>` (a documented constant
    /// with no user data in it).
    static func classify(transport error: Error) -> String {
        guard let urlError = error as? URLError else { return "transport_other" }
        switch urlError.code {
        case .cancelled: return "cancelled"
        case .timedOut: return "timed_out"
        case .cannotConnectToHost: return "cannot_connect_to_host"
        case .cannotFindHost: return "cannot_find_host"
        case .dnsLookupFailed: return "dns_lookup_failed"
        case .notConnectedToInternet: return "not_connected_to_internet"
        case .networkConnectionLost: return "network_connection_lost"
        case .secureConnectionFailed: return "tls_handshake_failed"
        case .serverCertificateUntrusted: return "tls_certificate_untrusted"
        case .serverCertificateHasBadDate: return "tls_certificate_expired"
        case .serverCertificateNotYetValid: return "tls_certificate_not_yet_valid"
        case .serverCertificateHasUnknownRoot: return "tls_certificate_unknown_root"
        case .clientCertificateRejected: return "tls_client_certificate_rejected"
        case .appTransportSecurityRequiresSecureConnection: return "app_transport_security_blocked"
        case .internationalRoamingOff: return "international_roaming_off"
        case .dataNotAllowed: return "data_not_allowed"
        case .callIsActive: return "call_is_active"
        case .badServerResponse: return "malformed_reply"
        case .httpTooManyRedirects: return "http_too_many_redirects"
        case .resourceUnavailable: return "resource_unavailable"
        case .cannotLoadFromNetwork: return "cannot_load_from_network"
        default: return "urlerror_\(urlError.code.rawValue)"
        }
    }

    /// The `DecodingError` case only. The failing value, the body and the
    /// debug description can all hold server data, so none is used.
    static func classify(decoding error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "decoding_other" }
        switch decodingError {
        case .keyNotFound: return "key_not_found"
        case .typeMismatch: return "type_mismatch"
        case .valueNotFound: return "value_not_found"
        case .dataCorrupted: return "data_corrupted"
        @unknown default: return "decoding_other"
        }
    }

    /// `http_<status>`, so a report can be grouped by status.
    static func http(status: Int) -> String {
        "http_\(status)"
    }
}

enum HTTPDecodingDiagnostics {
    /// Shown when the error has no coding path (a top-level failure). The
    /// angle brackets stop it reading as a real key.
    static let rootCodingPath = "<root>"
    /// Shown when nothing usable is left of a type name.
    static let unknownType = "unknown"

    /// The decoded Swift type without dots or other punctuation: its
    /// letter-initial alphanumeric runs joined with `_` (`Vivid.MediaItem`
    /// reads `Vivid_MediaItem`, `Array<MediaItem>` reads `Array_MediaItem`).
    /// A dotted token in text is scanned as a host or path and rejected.
    static func typeName(_ rawType: String) -> String {
        var tokens: [String] = []
        var current = ""
        for character in rawType {
            if character.isASCII, character.isLetter {
                current.append(character)
            } else if character.isASCII, character.isNumber, !current.isEmpty {
                // A digit only continues a token that began with a letter.
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return unknownType }
        let joined = String(tokens.joined(separator: "_").prefix(96))
        // Joining can make a private-looking shape neither token had
        // ("Session" + "Abcdefgh"), so the finished name is checked and
        // fails closed.
        return isTextPrivate(joined) ? unknownType : joined
    }

    /// `items > 0 > title`. The spaced `>` is inert in every text rule,
    /// where a dotted key path would be scanned as a host or route.
    static func codingPath(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return rootCodingPath }
        return path.map(rendered(key:)).joined(separator: " > ")
    }

    /// An index up to 999,999, or a plain identifier that doesn't look
    /// private. Anything else is a server-supplied key and is templated.
    private static func rendered(key: CodingKey) -> String {
        if let index = key.intValue {
            return (0...999_999).contains(index) ? String(index) : DiagnosticsPathTemplate.placeholder
        }
        let value = key.stringValue
        guard isPlainIdentifier(value), !isTextPrivate(value) else { return DiagnosticsPathTemplate.placeholder }
        return value
    }

    private static func isPlainIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private static func isTextPrivate(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return textPrivateRegexes.contains { $0.firstMatch(in: value, range: range) != nil }
    }

    private static let textPrivateRegexes: [NSRegularExpression] = [
        // PRIVATE_ID_IN_TEXT
        try! NSRegularExpression(
            pattern: #"(?i)(?:^|[^A-Za-z0-9])(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-](?:[0-9]+|[A-Za-z0-9][A-Za-z0-9_-]{7,})(?=$|[^A-Za-z0-9_-])"#
        ),
        // UUID_VALUE (unanchored, any version)
        try! NSRegularExpression(pattern: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#),
        // COMPACT_UUID_VALUE
        try! NSRegularExpression(pattern: #"(?i)(?:^|[^0-9a-f])[0-9a-f]{32}(?=$|[^0-9a-f])"#),
        // MAC_ADDRESS, bare-hex arm
        try! NSRegularExpression(pattern: #"(?i)(?:^|[^0-9a-f-])[0-9a-f]{12}(?=$|[^0-9a-f-])"#),
        // HEX_ID_SEGMENT
        try! NSRegularExpression(pattern: #"(?i)^[0-9a-f]{16,}$"#),
    ]
}
#endif
