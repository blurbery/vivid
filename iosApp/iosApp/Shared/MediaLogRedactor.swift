import Foundation

/// Cleans text that playback code writes to the unified log as public:
/// credentials, URLs, file paths and media titles are replaced with
/// hyphenated markers. Stateless and safe on any thread.
enum MediaLogRedactor {
    static func sanitize(_ value: String, maxLength: Int = 1_024) -> String {
        bounded(redact(value), to: maxLength)
    }

    static func sanitize(_ error: any Error, maxLength: Int = 1_024) -> String {
        sanitize(String(describing: error), maxLength: maxLength)
    }

    /// Only the file-system and media-name rules, with no output bound.
    static func redactFileSystemOnly(_ value: String) -> String {
        Rules.fileSystem.reduce(prebounded(value)) { $1.apply(to: $0) }
    }

    /// True for a single name such as `Movie.mkv` that isn't a generic
    /// streaming file name such as `master.m3u8`.
    static func isMediaFileName(_ value: String) -> Bool {
        guard !value.contains(where: \.isNewline),
              let dot = value.lastIndex(of: "."), dot > value.startIndex,
              Rules.mediaExtensions.contains(value[value.index(after: dot)...].lowercased())
        else { return false }
        return Rules.genericFileName.firstMatch(in: value) == nil
    }

    // MARK: - Private

    private static let inputLimit = 16_384

    private static func prebounded(_ value: String) -> String {
        value.count > inputLimit ? String(value.prefix(inputLimit)) : value
    }

    private static func redact(_ value: String) -> String {
        Rules.all.reduce(prebounded(value)) { $1.apply(to: $0) }
    }

    private static func bounded(_ value: String, to maxLength: Int) -> String {
        let limit = max(0, maxLength)
        guard value.count > limit else { return value }
        guard limit > 3 else { return String(value.prefix(limit)) }
        return String(value.prefix(limit - 3)) + "..."
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // The patterns are fixed, so a failure here is a programming error.
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.template = template
        }

        func apply(to text: String) -> String {
            regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }

        func firstMatch(in text: String) -> NSTextCheckingResult? {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        }
    }

    private enum Rules {
        static let mediaExtensions: Set<String> = [
            "aac", "ac3", "alac", "ass", "avi", "eac3", "flac", "idx", "m2ts", "m3u8", "m4a", "m4s", "m4v",
            "mkv", "mov", "mp3", "mp4", "mpd", "mts", "ogg", "opus", "pgs", "srt", "ssa", "sub", "sup",
            "ts", "vtt", "wav", "webm", "wmv",
        ]
        static let extensionPattern = "(?:" + mediaExtensions.sorted().joined(separator: "|") + ")"
        static let genericStems = "(?:chunk|index|init|main|manifest|master|media|output|playlist|prog_index|segment|stream)"
        static let pathRoot = "(?:~|/(?:Applications|data|Developer|etc|home|Library|mnt|Network|opt|private|System|tmp|Users|usr|var|Volumes))/"
        static let credentialWord = "(?:api[-_]?key|auth|authorization|cookie|credential|secret|session|token)"
        static let nameRun = "\\b[A-Za-z0-9_-]*?" + credentialWord + "[A-Za-z0-9_-]*"
        static let opaqueValue = "[^\\s,;\\[\\]}\"'][^,\\]}\\r\\n]*"
        static let tokenCharacters = "[A-Za-z0-9+\\-./=_~]"
        static let mediaNameCharacter = "[A-Za-z0-9 &'()+,\\-.\\[\\]_%]"

        static let genericFileName = Rule("^" + genericStems + "\\." + extensionPattern + "$", "")

        static let credentials: [Rule] = [
            // C1: a credential name and its value.
            Rule("(" + nameRun + "['\"]?\\s*[:=]\\s*['\"]?)" + opaqueValue, "$1[redacted]"),
            // C2: well-known credential headers.
            Rule("\\b(api-key|authorization|cookie|proxy-authorization|set-cookie|x-api-key)\\b\\s*[:=]\\s*" + opaqueValue,
                 "$1=[redacted]"),
            // C3: bearer tokens.
            Rule("\\bBearer\\s+" + tokenCharacters + "{8,}", "Bearer [redacted]"),
            // C4: URLs with a scheme.
            Rule("\\b(?:file|https?|smb|wss?)://[^\\s\"'<>]*", "[redacted-url]"),
            // C5: a host and port followed by a path.
            Rule("(?:\\[[0-9a-f:]{2,}\\]|\\b\\d{1,3}(?:\\.\\d{1,3}){3}|\\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,})"
                 + ":\\d{1,5}/[^\\s\"'<>,;\\]}]*", "[redacted-url]"),
            // C6: a credential name followed by a space and a long value.
            Rule("(" + nameRun + ")\\s+(?:bearer\\s+)?(?=" + tokenCharacters + "*\\d)" + tokenCharacters + "{12,}(?!"
                 + tokenCharacters + ")", "$1 [redacted]"),
        ]

        static let fileSystem: [Rule] = [
            // F1: a quoted path.
            Rule("([\"'])" + pathRoot + "[^\\r\\n]*?\\1", "$1[redacted-path]$1"),
            // F2: a path ending in a media file.
            Rule(pathRoot + "[^\\r\\n,;\\]}]*?\\." + extensionPattern + "\\b", "[redacted-path]"),
            // F3: a path after a space, separator or quote.
            Rule("(^|[\\s=:\"'])" + pathRoot + "[^\\s,\"'\\]}]+", "$1[redacted-path]"),
            // F4: a network share.
            Rule("\\\\\\\\[A-Za-z0-9$._-]+\\\\[^\\s\"'<>,;]*", "[redacted-path]"),
            // F5: a bare media file name, with any words in front of it on the line.
            Rule("(?<![A-Za-z0-9._~-])(?!" + genericStems + "\\." + extensionPattern + "\\b)(?!redacted[A-Za-z0-9-]*\\])"
                 + "[A-Za-z0-9](?:(?!\\[redacted)" + mediaNameCharacter + "){0,240}\\." + extensionPattern + "\\b",
                 "[redacted-media-name]"),
        ]

        static let trailing: [Rule] = [
            // T1: credential query parameters.
            Rule("\\b(access_token|api_key|auth|authorization|credential|jwt|profile_token|refresh_token|sig|signature|st|token)"
                 + "\\s*=\\s*[^&\\s,;\\[\\]}][^&\\s,;\\]}]*", "$1=[redacted]"),
            // T2: tokens shaped like a JWT.
            Rule("\\b[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b", "[redacted-token]"),
        ]

        static let all = credentials + fileSystem + trailing
    }
}
