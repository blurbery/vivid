import Foundation

/// AE#495: a TLS handshake the system refused, told apart from a source that is merely unreadable.
///
/// A server behind a self-signed or private CA certificate fails every fetch before a byte arrives.
/// On the FFmpeg path the demuxer then reports `AVERROR_INVALIDDATA` and the session surfaces
/// "Invalid data found when processing input", which reads as a corrupt file; on the native path the
/// item error is AVFoundation's own, with the URL error one level down where nothing looked. The
/// reporter's word for the result is the right one: a split state, where the host's own API layer
/// browses the library fine and every engine fetch fails, with nothing in either message naming a
/// certificate.
///
/// Same shape as the HTTP-status classification (`PlaybackErrorKind.sourceRefused`), for the same
/// reason: the origin gave a verdict, and folding it into "unreadable" throws the verdict away.
enum TransportSecurityFailure {

    /// `NSURLErrorDomain` codes that mean the transport was refused over trust rather than over
    /// anything about the media. Client-certificate codes are in here too: the origin asked for
    /// something the process cannot present, which is the same class of answer and equally invisible
    /// as "invalid data".
    static let codes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,          // -1200
        NSURLErrorServerCertificateHasBadDate,     // -1201
        NSURLErrorServerCertificateUntrusted,      // -1202
        NSURLErrorServerCertificateHasUnknownRoot, // -1203
        NSURLErrorServerCertificateNotYetValid,    // -1204
        NSURLErrorClientCertificateRejected,       // -1205
        NSURLErrorClientCertificateRequired,       // -1206
    ]

    /// The trust code inside an error, or nil when there is none.
    ///
    /// Walks `NSUnderlyingErrorKey` rather than reading the top error alone, because on the native
    /// path the top error is AVFoundation's (`-11800` and friends) and the URL error that actually
    /// says what happened rides one or two levels below it. Depth-bounded: an error chain is authored
    /// by whoever built it, and this runs on a failure path where a cycle must not become a hang.
    static func code(in error: Error?) -> Int? {
        var current = error as NSError?
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSURLErrorDomain, codes.contains(nsError.code) {
                return nsError.code
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }

    /// Whether an error carries a trust refusal anywhere in its chain.
    static func isTrustFailure(_ error: Error?) -> Bool {
        code(in: error) != nil
    }

    /// The engine's own sentence for one, in English and independent of the OS locale, so a report
    /// pasted from any device says the same thing. Deliberately names the host's options rather than
    /// only the fault: the whole point of the classification is that the reader can act on it.
    static func sentence(for code: Int) -> String {
        switch code {
        case NSURLErrorClientCertificateRejected:
            return "The origin rejected the client certificate offered for this connection"
        case NSURLErrorClientCertificateRequired:
            return "The origin requires a client certificate this process cannot present"
        case NSURLErrorServerCertificateHasBadDate:
            return "The origin's certificate has expired or is dated in the future"
        case NSURLErrorServerCertificateNotYetValid:
            return "The origin's certificate is not valid yet"
        case NSURLErrorServerCertificateHasUnknownRoot:
            return "The origin's certificate is signed by a root the system does not trust"
        case NSURLErrorServerCertificateUntrusted:
            return "The system does not trust the origin's certificate (self-signed, or a private CA)"
        default:
            return "The secure connection to the origin could not be established"
        }
    }
}
