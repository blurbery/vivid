import Foundation

/// A media URL and its request headers, as the session hands them to the player.
struct StreamRequest {
    let url: URL
    let headers: [String: String]
    let serverUrl: String

    /// Resolves a server's media URL without letting the account credential
    /// cross to another origin. Nil rejects the URL.
    ///
    /// - A `file://` URL is a local file with no headers, refused when the
    ///   media must be header-authenticated.
    /// - Native v2 (`nativeApiMajor == 2`) takes only a relative
    ///   `/api/v2/` stream path carrying a session-scoped signed reference.
    ///   The bearer stays a header and never leaves the API origin.
    /// - Header-authenticated V3 takes only the two API-relative route
    ///   families the contract promises (`/stream/` and
    ///   `/playback/transcode/`). An absolute URL is a contract breach even
    ///   on the same host, with one negotiated exception: an attempt that
    ///   opted into `authorized_media_origins_v1` (a non-empty
    ///   `authorizedMediaOriginSessionId`) may get an absolute
    ///   `/stream/v3/{session}` URL on a server-designated proxy origin,
    ///   pinned to exactly that session and qualified only by `seek`.
    /// - Otherwise an absolute URL must be on the server's origin, and a
    ///   relative one resolves under `/api/v1` unless it already starts with
    ///   `/api/`.
    ///
    /// Any `Authorization` header in `additionalHeaders` is replaced by the
    /// bearer for `accessToken`, when there is one.
    static func resolve(
        rawURL: String,
        serverURL: String,
        additionalHeaders: [String: String],
        accessToken: String?,
        requiresHeaderAuthenticatedMedia: Bool,
        authorizedMediaOriginSessionId: String? = nil,
        nativeApiMajor: Int? = nil
    ) -> StreamRequest? {
        let raw = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let server = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if raw.hasPrefix("file://") {
            guard !requiresHeaderAuthenticatedMedia, let fileURL = URL(string: raw) else { return nil }
            return StreamRequest(url: fileURL, headers: [:], serverUrl: server)
        }

        guard let baseURL = URL(string: server),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil else {
            return nil
        }

        let pinnedSessionId = authorizedMediaOriginSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAbsoluteHTTP = raw.hasPrefix("http://") || raw.hasPrefix("https://")
        let resolved: URL?
        // A proxy-origin URL is the one result allowed off the API origin; its
        // own checks are stricter in exchange.
        var isAuthorizedMediaOrigin = false

        if nativeApiMajor == 2 {
            resolved = nativeV2URL(raw, server: server)
        } else if requiresHeaderAuthenticatedMedia, let sessionId = pinnedSessionId, !sessionId.isEmpty, isAbsoluteHTTP {
            resolved = authorizedMediaOriginURL(raw, sessionId: sessionId,
                                                serverScheme: baseURL.scheme?.lowercased() ?? "")
            isAuthorizedMediaOrigin = true
        } else if requiresHeaderAuthenticatedMedia {
            resolved = headerAuthenticatedURL(raw, server: server)
        } else if isAbsoluteHTTP {
            resolved = URL(string: raw).flatMap { hasSameOrigin($0, baseURL) ? $0 : nil }
        } else {
            resolved = legacyRelativeURL(raw, server: server)
        }

        guard let url = resolved, isAuthorizedMediaOrigin || hasSameOrigin(url, baseURL) else { return nil }
        var headers = additionalHeaders.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
        if let accessToken, !accessToken.isEmpty {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        return StreamRequest(url: url, headers: headers, serverUrl: server)
    }

    // MARK: - Route families

    /// A relative `/api/v2/` media path, with its native v2 query.
    private static func nativeV2URL(_ raw: String, server: String) -> URL? {
        guard !raw.contains("://"), !raw.hasPrefix("//"),
              let components = URLComponents(string: raw), components.fragment == nil,
              components.percentEncodedPath.hasPrefix("/api/v2/") else { return nil }
        let path = String(components.percentEncodedPath.dropFirst("/api/v2".count))
        guard isAllowedHeaderAuthenticatedMediaPath(path),
              hasAllowedNativeV2Query(path: path, items: components.queryItems ?? []) else { return nil }
        return URL(string: server + raw)
    }

    /// A relative V3 media path, resolved under `/api/v1`.
    private static func headerAuthenticatedURL(_ raw: String, server: String) -> URL? {
        guard !raw.contains("://"), !raw.hasPrefix("//"),
              let components = URLComponents(string: raw),
              components.scheme == nil,
              components.host == nil,
              isAllowedHeaderAuthenticatedMediaPath(components.percentEncodedPath),
              hasAllowedHeaderAuthenticatedMediaQuery(path: components.percentEncodedPath,
                                                      items: components.queryItems ?? []),
              components.fragment == nil else { return nil }
        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        return URL(string: server + "/api/v1" + path)
    }

    /// A relative path without header authentication: under `/api/v1`
    /// unless it already names an `/api/` route.
    private static func legacyRelativeURL(_ raw: String, server: String) -> URL? {
        guard !raw.hasPrefix("//") else { return nil }
        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        return URL(string: path.hasPrefix("/api/") ? server + path : server + "/api/v1" + path)
    }

    /// The absolute form `authorized_media_origins_v1` permits. The server may
    /// name any origin, so the host is only checked to be a credential-free
    /// `http(s)` origin: the path, query and session carry the contract, and
    /// the bearer only goes to a URL the current plan named for the current
    /// session.
    ///
    /// `https` is always accepted, `http` only when the API server is `http`
    /// too. A plain-http deployment already sends the bearer over http, but an
    /// https one must never drop to a cleartext proxy.
    private static func authorizedMediaOriginURL(_ raw: String, sessionId: String, serverScheme: String) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && serverScheme == "http"),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              isAllowedAuthorizedMediaOriginPath(components.percentEncodedPath, sessionId: sessionId),
              hasAllowedAuthorizedMediaOriginQuery(components.queryItems ?? []) else { return nil }
        return components.url
    }

    // MARK: - Paths

    /// `/stream/v3/{session}`, `/stream/v3/{session}/master.m3u8` and
    /// `/stream/v3/{session}/segment/{name}`, for the attempt's own session
    /// only.
    private static func isAllowedAuthorizedMediaOriginPath(_ path: String, sessionId: String) -> Bool {
        guard !hasEncodedSeparator(path) else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 4, segments[0].isEmpty else { return false }
        let decoded = segments.map { $0.removingPercentEncoding ?? $0 }
        guard decoded.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              decoded[1] == "stream", decoded[2] == "v3", decoded[3] == sessionId else { return false }
        switch segments.count {
        case 4: return true
        case 5: return decoded[4] == "master.m3u8"
        case 6: return decoded[4] == "segment"
        default: return false
        }
    }

    /// A `/stream/` or `/playback/transcode/` path with no encoded slashes or
    /// backslashes and no dot segments.
    private static func isAllowedHeaderAuthenticatedMediaPath(_ path: String) -> Bool {
        guard path.hasPrefix("/stream/") || path.hasPrefix("/playback/transcode/"),
              !hasEncodedSeparator(path) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            let decoded = String(segment).removingPercentEncoding ?? String(segment)
            return decoded != "." && decoded != ".."
        }
    }

    private static func hasEncodedSeparator(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains("%2f") || lowered.contains("%5c") || path.contains("\\")
    }

    /// The server's subtitle artefact shapes,
    /// `/stream/<session>/subtitles/<index><ext>` and
    /// `/stream/<session>/subtitles/<index>/fonts`.
    private static func isSubtitleArtifactPath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 5 else { return false }
        return segments[0].isEmpty
            && segments[1] == "stream"
            && !segments[2].isEmpty
            && segments[3] == "subtitles"
            && !segments[4].isEmpty
    }

    // MARK: - Queries

    /// A proxy URL may carry `seek` alone. Subtitle artefact identifiers
    /// aren't allowed, as proxies never serve subtitles.
    private static func hasAllowedAuthorizedMediaOriginQuery(_ items: [URLQueryItem]) -> Bool {
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.name).inserted, item.name == "seek",
                  let value = item.value, isSeekValue(value) else { return false }
        }
        return true
    }

    /// Native v2 queries: the signed `st` reference, `seek`, numeric
    /// `file_id` and `downloaded_subtitle_id`, and `external_subtitle_key` on
    /// subtitle artefact paths. Each at most once and never empty.
    private static func hasAllowedNativeV2Query(path: String, items: [URLQueryItem]) -> Bool {
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.name).inserted, let value = item.value, !value.isEmpty else { return false }
            switch item.name {
            case "st": break
            case "seek": guard isSeekValue(value) else { return false }
            case "file_id", "downloaded_subtitle_id": guard value.allSatisfy({ $0.isNumber }) else { return false }
            case "external_subtitle_key": guard isSubtitleArtifactPath(path), isExternalSubtitleKey(value) else { return false }
            default: return false
            }
        }
        return hasSingleSubtitleIdentity(seen)
    }

    /// V3 media routes take one non-secret `seek`. Subtitle artefact routes
    /// also take `file_id`, `downloaded_subtitle_id` (catalogue row ids the
    /// caller can already read) and `external_subtitle_key`. Anything else,
    /// and any repeat, is refused, so an old or compromised server can't
    /// slip a signed media credential into the source URL.
    private static func hasAllowedHeaderAuthenticatedMediaQuery(path: String, items: [URLQueryItem]) -> Bool {
        let isSubtitleArtifact = isSubtitleArtifactPath(path)
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.name).inserted, let value = item.value else { return false }
            switch item.name {
            case "seek":
                guard isSeekValue(value) else { return false }
            case "file_id", "downloaded_subtitle_id":
                guard isSubtitleArtifact, isNonNegativeInteger(value) else { return false }
            case "external_subtitle_key":
                guard isSubtitleArtifact, isExternalSubtitleKey(value) else { return false }
            default:
                return false
            }
        }
        return hasSingleSubtitleIdentity(seen)
    }

    private static func isSeekValue(_ value: String) -> Bool {
        guard let seconds = Double(value) else { return false }
        return seconds.isFinite && seconds >= 0
    }

    /// Silo names an external subtitle file by the SHA-256 hex of its path:
    /// an identifier, never a credential.
    private static func isExternalSubtitleKey(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A subtitle artefact names a stored or an external file, never both.
    private static func hasSingleSubtitleIdentity(_ names: Set<String>) -> Bool {
        !(names.contains("external_subtitle_key") && names.contains("downloaded_subtitle_id"))
    }

    private static func isNonNegativeInteger(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber } && Int(value) != nil
    }

    // MARK: - Origins

    static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
