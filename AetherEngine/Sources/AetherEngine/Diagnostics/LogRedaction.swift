import Foundation

/// Strips credentials out of a diagnostic line before `EngineLog` emits it.
///
/// The engine logs whole URLs on purpose (`[AetherEngine] load url=`, `[NativeAVPlayerHost] load
/// url=`, `asset.url=`): host, path and query are what a playback report is diagnosed from. But media
/// servers routinely put the access token in that query, Jellyfin's `api_key=` being the case this was
/// written for, so those lines carry a live credential into `os.Logger` (a Console.app capture, a
/// sysdiagnose) and into whatever handler the host installed for its own in-app log.
///
/// A credential does not always arrive next to a name, and that half was reported from the field: some
/// debrid and proxy add-ons carry the account token in a PATH segment, as base64url-encoded JSON, where
/// nothing in the URL names it. The list of names cannot be extended to reach that one, because the
/// names live inside the payload, so the encoding itself has to be the signal (`encodedPayloadRange`).
///
/// That makes it the engine's problem rather than each host's: the engine composes the line, it reaches
/// three sinks a host does not control, and a host-side scrub only ever covers the one sink it owns.
///
/// Redacts at the `EngineLog` funnel, never at the call sites, so a URL logged by code added later is
/// covered without its author knowing this type exists. Over-redaction is the safe failure here;
/// under-redaction ships a credential. The value goes whole rather than truncated to a prefix: a prefix
/// still narrows a brute-force and answers no question a playback bug asks.
enum LogRedaction {

    static let placeholder = "<redacted>"

    /// Generic credential parameter and header names; the engine is not tied to one server product.
    /// Held as lowercase ASCII bytes and matched longest first, so `x-mediabrowser-token` wins over its
    /// `token` suffix. `token` alone is deliberately broad and only fires on a boundary, so identifiers
    /// such as `hasToken` and `refreshTokenAt` are left alone.
    private static let keys: [[UInt8]] = [
        "x-mediabrowser-token", "x-emby-token", "access_token", "accesstoken", "connect.sid",
        "signature", "password", "api_key", "apikey", "secret", "token",
    ].map { Array($0.utf8) }

    private static let placeholderBytes = Array(placeholder.utf8)

    /// Works on UTF-8 bytes, not Characters, and allocates the output only once something actually
    /// matches. That is not premature: a Character-level pass building a lowercased String per position
    /// cost enough on this hot path to shift the request timing in `ServedFromMemoryProgressTests`,
    /// which is how the first version of this file was caught. `emit` is called from the demuxer and the
    /// segment producer, so anything per-line here is per-line everywhere.
    static func redact(_ line: String) -> String {
        let bytes = Array(line.utf8)
        var out: [UInt8]?
        var copiedUpTo = 0
        var i = 0

        while i < bytes.count {
            // Three shapes, because a credential does not always arrive next to a name. The key
            // matcher covers `api_key=…`, `X-Emby-Token: …` and the cookie; the payload matcher covers
            // an encoded blob that no name points at, which is how a path segment carries one; the
            // userinfo matcher covers `smb://user:secret@host`, where it sits in the authority.
            guard let value = matchedKeyLength(in: bytes, at: i)
                    .flatMap({ valueRange(in: bytes, after: i + $0) })
                    ?? encodedPayloadRange(in: bytes, at: i)
                    ?? userInfoSecretRange(in: bytes, at: i) else {
                i += 1
                continue
            }
            if out == nil {
                out = []
                out?.reserveCapacity(bytes.count)
            }
            out?.append(contentsOf: bytes[copiedUpTo ..< value.lowerBound])
            out?.append(contentsOf: placeholderBytes)
            copiedUpTo = value.upperBound
            i = value.upperBound
        }

        guard var out else { return line }
        out.append(contentsOf: bytes[copiedUpTo...])
        return String(decoding: out, as: UTF8.self)
    }

    /// Length of the key starting here, or nil. The key must start on a boundary, else `token` would
    /// fire inside `hasToken`. A separator such as the `-` in `X-Emby-Token` or the `_` in `api_key` is
    /// a boundary; an ASCII letter or digit is not.
    private static func matchedKeyLength(in bytes: [UInt8], at index: Int) -> Int? {
        if index > 0, isLetterOrDigit(bytes[index - 1]) { return nil }
        for key in keys where index + key.count <= bytes.count {
            var matched = true
            for offset in 0 ..< key.count where lowercased(bytes[index + offset]) != key[offset] {
                matched = false
                break
            }
            if matched { return key.count }
        }
        return nil
    }

    /// The span holding the secret, given the index just past the key. Covers the query form
    /// (`api_key=abc&next=1`), both header forms (`Token="abc"`, `X-Emby-Token: abc`) and the cookie
    /// form (`connect.sid=abc; Path=/`). Nil when there is no assignment or the value is empty, so
    /// `api_key=` and a bare mention in prose are left alone.
    private static func valueRange(in bytes: [UInt8], after keyEnd: Int) -> Range<Int>? {
        var i = keyEnd
        while i < bytes.count, bytes[i] == UInt8(ascii: " ") { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "=") || bytes[i] == UInt8(ascii: ":") else {
            return nil
        }
        let isHeaderSeparator = bytes[i] == UInt8(ascii: ":")
        i += 1

        // Only a header separator may be followed by spaces. After `=` the value starts immediately:
        // a URL query and a cookie never space it out, and skipping here would let prose such as
        // "api_key= (missing)" read as a credential and swallow the rest of the line.
        var afterSpaces = i
        while afterSpaces < bytes.count, bytes[afterSpaces] == UInt8(ascii: " ") { afterSpaces += 1 }
        var quote: UInt8?
        if afterSpaces < bytes.count,
           bytes[afterSpaces] == UInt8(ascii: "\"") || bytes[afterSpaces] == UInt8(ascii: "'") {
            quote = bytes[afterSpaces]
            i = afterSpaces + 1
        } else if isHeaderSeparator {
            i = afterSpaces
        }
        let start = i

        if let quote {
            while i < bytes.count, bytes[i] != quote { i += 1 }
        } else {
            while i < bytes.count, !isValueTerminator(bytes[i]) { i += 1 }
        }
        return start < i ? start ..< i : nil
    }

    /// The secret inside a URL's userinfo, given an index that may start `://`. `smb://user:pw@host`
    /// and `https://user:pw@host` put the credential in the authority, where no key precedes it, so the
    /// key matcher cannot see it and `load url=` logs `absoluteString` whole. The user name is left
    /// readable: it identifies the account a line is about, and a diagnostic log that cannot say which
    /// account failed is worth less. Nil unless an `@` really terminates an authority, so prose such as
    /// "see http://a.test and foo@bar" is untouched: the scan stops at the first character that cannot
    /// appear in userinfo.
    private static func userInfoSecretRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard index + 3 <= bytes.count,
              bytes[index] == UInt8(ascii: ":"),
              bytes[index + 1] == UInt8(ascii: "/"),
              bytes[index + 2] == UInt8(ascii: "/") else { return nil }
        let start = index + 3
        var i = start
        var colon: Int?
        while i < bytes.count, bytes[i] != UInt8(ascii: "@"), !isAuthorityTerminator(bytes[i]) {
            if bytes[i] == UInt8(ascii: ":"), colon == nil { colon = i }
            i += 1
        }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "@") else { return nil }
        // With a colon the password is everything after it; without one the whole userinfo is the
        // secret (a bare token in the authority), and then the user name cannot be spared.
        let secretStart = colon.map { $0 + 1 } ?? start
        return secretStart < i ? secretStart ..< i : nil
    }

    /// Ends an authority component. `@` is deliberately absent: it is what the scan is looking for.
    private static func isAuthorityTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#"), UInt8(ascii: "\""),
             UInt8(ascii: "'"), UInt8(ascii: ","), UInt8(ascii: ")"), UInt8(ascii: ">"),
             UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    /// Shortest encoded run worth decoding. `{"a":"b"}` is nine bytes, so twelve characters; anything
    /// shorter cannot be a JSON object and a credential blob is far longer than either.
    private static let minimumEncodedLength = 12

    /// The span of an encoded payload starting here, or nil.
    ///
    /// A path segment or a query value holding base64url-encoded JSON carries structure the URL never
    /// declares. No name precedes it, so `matchedKeyLength` cannot see it, and the list of names cannot
    /// be extended to reach it either: the names are INSIDE the payload and belong to whoever wrote it.
    /// The case this was reported for decodes to the keys `stores`, `c` and `t`, so even matching known
    /// names against the decoded JSON would walk past it. The encoding is the only honest signal, and an
    /// opaque blob answers no question a playback report asks, so the whole run goes.
    ///
    /// Gated hard before it allocates, because this runs per line on the demuxer and segment-producer
    /// paths: base64url of `{` always starts `e` and of `[` always `W`, so one byte comparison rejects
    /// very nearly every position, and only a run that survives that is ever decoded.
    private static func encodedPayloadRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "W") else { return nil }
        if index > 0, isBase64URL(bytes[index - 1]) { return nil }

        var end = index
        while end < bytes.count, isBase64URL(bytes[end]) { end += 1 }
        guard end - index >= minimumEncodedLength, decodesToJSON(bytes[index ..< end]) else { return nil }

        // A JSON web token is three of these joined by dots, and the signature at the end is the part
        // worth stealing, so the whole token goes rather than the header that happened to match. A
        // header alone proves nothing: `{"alg":"HS256","typ":"JWT"}` is reconstructable by anyone.
        var extended = end
        while extended < bytes.count, bytes[extended] == UInt8(ascii: ".") {
            var run = extended + 1
            while run < bytes.count, isBase64URL(bytes[run]) { run += 1 }
            guard run > extended + 1 else { break }
            extended = run
        }
        return index ..< extended
    }

    /// Whether the run decodes as base64url into a JSON object or array. `JSONSerialization` without
    /// `.fragmentsAllowed` is the test rather than a resemblance check: a bare number or string would
    /// otherwise let ordinary text through as a payload, and an episode file named `Eyewitness…` gets
    /// as far as the decode and no further.
    private static func decodesToJSON(_ run: ArraySlice<UInt8>) -> Bool {
        var encoded = String(decoding: run, as: UTF8.self)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isBase64URL(_ b: UInt8) -> Bool {
        isLetterOrDigit(b) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
    }

    /// `:` counts, so `…&api_key=abc: timeout` gives the token back and keeps the error text. None of
    /// the credential shapes here (hex, base64url, percent-encoded cookie) contain a literal colon.
    private static func isValueTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "&"), UInt8(ascii: ";"), UInt8(ascii: ","), UInt8(ascii: ")"),
             UInt8(ascii: ">"), UInt8(ascii: ":"), UInt8(ascii: "\""), UInt8(ascii: "'"),
             UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    private static func isLetterOrDigit(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
    }

    private static func lowercased(_ b: UInt8) -> UInt8 {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ? b + 32 : b
    }
}
