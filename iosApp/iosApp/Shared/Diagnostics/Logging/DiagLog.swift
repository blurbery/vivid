import Foundation
import OSLog

/// Turns a log call into one redacted JSON line, for the debug build's local
/// log and for the recent-events trail. Nothing here sends anything anywhere.
enum DiagLog {
    /// Identifies this process's lines. Made on first use.
    static let captureSessionID = UUID().uuidString.lowercased()

    // MARK: - Sensitive hosts

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
    private static let hostLock = NSLock()
    nonisolated(unsafe) private static var sensitiveHosts: [String] = []

    /// Hashes this host wherever it appears in later lines, even outside a URL.
    static func registerSensitiveHost(_ host: String) {
        let normalised = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalised.isEmpty, !loopbackHosts.contains(normalised) else { return }
        hostLock.withLock {
            guard !sensitiveHosts.contains(normalised) else { return }
            sensitiveHosts.append(normalised)
            sensitiveHosts.sort { $0.count > $1.count }
        }
    }

    static func resetSensitiveHostsForTesting() {
        hostLock.withLock { sensitiveHosts.removeAll() }
    }

    private static func hostToken(_ host: String) -> String {
        "[host:" + DiagnosticsSHA256.shortHex(data: Data(host.lowercased().utf8), count: 12) + "]"
    }

    // MARK: - Sanitising

    static func sanitizedText(_ value: String, maxLength: Int) -> String {
        var text = redactURLs(in: value)
        for rule in Rules.textRules {
            text = rule.apply(to: text)
        }
        text = replaceSensitiveHosts(in: text)
        text = MediaLogRedactor.redactFileSystemOnly(text)
            .replacingOccurrences(of: "[redacted-path]", with: "[redacted_path]")
            .replacingOccurrences(of: "[redacted-media-name]", with: "[redacted_media_name]")
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }

    /// The scheme, a hashed host and the path with identifiers and media names
    /// replaced. User, password, port, query and fragment are left out.
    static func normalisedURL(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme
        else { return "[redacted_url]" }
        let host = components.host.map { loopbackHosts.contains($0.lowercased()) ? $0 : hostToken($0) } ?? ""
        return scheme + "://" + host + redactedPath(components.percentEncodedPath)
    }

    private static func redactedPath(_ path: String) -> String {
        guard path.contains("/") else { return path }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { piece -> String in
            let piece = String(piece)
            if MediaLogRedactor.isMediaFileName(piece) { return "[redacted_media_name]" }
            if piece.count >= 22, piece.allSatisfy(isIdentifierCharacter) { return "[redacted_id]" }
            return piece
        }.joined(separator: "/")
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    static func errorText(_ error: any Error) -> String {
        let raw: String
        if let error = error as? HTTPError {
            raw = error.description
        } else {
            let description = (error as NSError).localizedDescription
            raw = description.isEmpty ? String(describing: error) : description
        }
        return sanitizedText(String(reflecting: type(of: error)) + ": " + raw, maxLength: 512)
    }

    private static func redactURLs(in text: String) -> String {
        Rules.url.replacingMatches(in: text) { match in
            var candidate = Substring(match)
            var trailing = ""
            while let last = candidate.last, ".,)]".contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                candidate.removeLast()
            }
            guard let url = URL(string: String(candidate)) else { return "[redacted_url]" + trailing }
            return normalisedURL(url) + trailing
        }
    }

    /// One pass from left to right. Replacements are never scanned again.
    private static func replaceSensitiveHosts(in text: String) -> String {
        let hosts = hostLock.withLock { sensitiveHosts }
        guard !hosts.isEmpty else { return text }
        let characters = Array(text)
        let lowered = characters.map { $0.lowercased() }
        let patterns = hosts.map { (characters: Array($0).map(String.init), token: hostToken($0)) }
        var result = ""
        var index = 0
        scan: while index < characters.count {
            for pattern in patterns where index + pattern.characters.count <= characters.count {
                if lowered[index..<(index + pattern.characters.count)].elementsEqual(pattern.characters) {
                    result += pattern.token
                    index += pattern.characters.count
                    continue scan
                }
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    // MARK: - Lines

    static func renderedLine(
        level: DiagnosticsLogLevel,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date(),
        captureSessionID: String = DiagLog.captureSessionID
    ) -> String? {
        var rendered: [String: DiagnosticsJSONValue] = [:]
        for (key, value) in attrs {
            guard let value = DiagnosticsAttributeRegistry.accepted(value, key: key, category: category) else { continue }
            switch value {
            case .string(let text): rendered[key] = .string(sanitizedText(text, maxLength: 512))
            case .url(let url): rendered[key] = .string(normalisedURL(url))
            case .error(let error): rendered[key] = .string(errorText(error))
            case .int(let number): rendered[key] = .int(number)
            case .double, .bool: continue
            }
        }
        let line = DiagnosticsLogLine(
            ts: timestampText(timestamp),
            run: captureSessionID,
            lvl: level,
            cat: category,
            tag: sanitizedText(tag, maxLength: 128),
            msg: sanitizedText(message, maxLength: 2_048),
            attrs: rendered
        )
        guard line.isComplete else {
            assertionFailure("Diagnostics line is missing its time, run, tag or message")
            return nil
        }
        guard let data = try? encoder.encode(line), let text = String(data: data, encoding: .utf8) else {
            assertionFailure("Diagnostics line could not be encoded")
            return nil
        }
        return text
    }

    /// Builds the line now and writes it to the debug build's local log.
    @discardableResult
    static func write(
        level: DiagnosticsLogLevel,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date()
    ) -> Bool {
        guard let line = renderedLine(
            level: level, category: category, tag: tag, message: message, attrs: attrs, timestamp: timestamp)
        else { return false }
        writeLocally(line)
        return true
    }

    static func debug(
        _ category: DiagnosticsLogCategory,
        tag: String,
        message: @autoclosure () -> String,
        attrs: @autoclosure () -> [String: DiagLogAttributeValue] = [:]
    ) {
        #if DEBUG
        write(level: .debug, category: category, tag: tag, message: message(), attrs: attrs())
        #endif
    }

    static func writeLocally(_ line: String) {
        #if DEBUG
        developmentLog.debug("\(line, privacy: .private)")
        #endif
    }

    #if DEBUG
    private static let developmentLog = Logger(subsystem: "com.blurbery.vivid", category: "Development")
    #endif

    private static let encoder = DiagnosticsLogLine.makeEncoder()

    private static let timestampLock = NSLock()
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private static func timestampText(_ date: Date) -> String {
        timestampLock.withLock { timestampFormatter.string(from: date) }
    }

    // MARK: - Rules

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String = "") {
            // The patterns are fixed, so a failure here is a programming error.
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.template = template
        }

        func apply(to text: String) -> String {
            regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }

        func replacingMatches(in text: String, with replacement: (String) -> String) -> String {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard !matches.isEmpty else { return text }
            var result = ""
            var cursor = text.startIndex
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                result += text[cursor..<range.lowerBound]
                result += replacement(String(text[range]))
                cursor = range.upperBound
            }
            result += text[cursor...]
            return result
        }
    }

    private enum Rules {
        static let tokenCharacters = "[A-Za-z0-9+\\-./=_~]"

        // L1: a URL, wherever its scheme starts.
        static let url = Rule("(?:https?|wss?)://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+")

        static let textRules: [Rule] = [
            // L2: an authorisation header and its credential.
            Rule("\\bAuthorization\\s*[:=]\\s*(?:(?:Bearer|Basic)\\s*)?" + tokenCharacters + "+", "Authorization: [redacted]"),
            // L3: cookies, to the end of the line.
            Rule("\\b(?:Set-)?Cookie\\s*[:=]\\s*[^\\r\\n]+", "Cookie: [redacted]"),
            // L4: bearer tokens.
            Rule("\\bBearer\\s+" + tokenCharacters + "{8,}", "Bearer [redacted]"),
            // L5: tokens shaped like a JWT.
            Rule("\\b[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b", "[redacted_token]"),
            // L6: email addresses.
            Rule("\\b[A-Za-z0-9%+\\-._]+@[A-Za-z0-9\\-.]+\\.[A-Za-z]{2,}\\b", "[redacted_email]"),
            // L7: secret keys and their values, quoted or bare.
            Rule("(?:\\\\?['\"])?\\b(access_token|accessToken|api_key|apikey|email|jwt|key|login|profile_id|profileId|"
                 + "profile_token|profileToken|refresh_token|refreshToken|sig|signature|token|user|user_name|username)\\b"
                 + "(?:\\\\?['\"])?\\s*[:=]\\s*"
                 + "(?:\"(?:\\\\.|[^\"\\\\\\r\\n])*\"|\\\\\".*\\\\\"|'[^'\\r\\n]*'|[^\\s&;,\\]}]+)",
                 "$1=[redacted]"),
            // L8: shortened credentials in debug headers, such as `auth(…abc)`.
            Rule("\\b(access_token|accessToken|auth|profile_token|profileToken|refresh_token|refreshToken)"
                 + "\\(\u{2026}?[^)\\r\\n]*\\)", "$1(\u{2026}[redacted])"),
        ]
    }
}
