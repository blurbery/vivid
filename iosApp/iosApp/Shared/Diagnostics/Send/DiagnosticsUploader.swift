// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
import Foundation

/// The optional "What happened?" text a tester adds before sending. It goes
/// out as written, apart from trimming, removing control and text-direction
/// characters, and the relay's limit of 500 characters (Unicode scalars, which
/// the relay counts as code points).
enum DiagnosticsNote {
    static let maxCharacters = 500

    /// Keeps typing within the limit.
    static func limited(_ text: String) -> String {
        guard text.unicodeScalars.count > maxCharacters else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxCharacters)))
    }

    /// The note as sent, or nil when there's nothing to send.
    static func cleaned(_ text: String) -> String? {
        let scalars = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            if scalar.properties.generalCategory == .control { return false }
            return !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
        }
        let trimmed = limited(String(String.UnicodeScalarView(scalars))).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Sends a diagnostics file the person chose to send to Vivid's diagnostics
/// relay, which keeps a copy for 30 days and emails it to
/// diagnostics@vividapp.co. The body is exactly the JSON shown as "what is
/// sent", plus any note the person wrote; nothing else about the device or
/// account is added.
enum DiagnosticsUploader {
    enum Kind: String {
        case playback, problems
    }

    enum Failure: Error, Equatable {
        /// No connection, or the relay couldn't be reached.
        case offline
        /// Too many sends; try again after this many seconds.
        case rateLimited(retryAfter: Int)
        /// The relay is busy or unavailable; try again later.
        case unavailable
        /// The relay refused the file. Retrying won't help.
        case rejected

        var message: String {
            switch self {
            case .offline: return "Vivid couldn't reach the diagnostics service. Check the connection and try again."
            case .rateLimited(let seconds): return "Too many reports were sent just now. Try again in \(max(1, (seconds + 59) / 60)) min."
            case .unavailable: return "The diagnostics service is busy. Try again later."
            case .rejected: return "The diagnostics service couldn't accept this report."
            }
        }

        var canRetry: Bool { self != .rejected }
    }

    static let baseURL = URL(string: "https://diagnostics.vividapp.co/v1/reports/")!

    /// No cookies, cache or stored credentials.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Sends the file and returns the relay's reference, such as VR-7K2M9Q.
    /// Throws a `Failure`.
    static func send(_ data: Data, kind: Kind) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent(kind.rawValue))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            throw Failure.offline
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        switch outcome(status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
        case .success(let reference): return reference
        case .failure(let failure): throw failure
        }
    }

    /// The relay's reply as a reference or a failure. Only a 200 with a
    /// well-formed reference counts as sent.
    static func outcome(status: Int, body: Data, retryAfter: String?) -> Result<String, Failure> {
        switch status {
        case 200:
            struct Reply: Decodable { let reference: String }
            guard let reference = try? JSONDecoder().decode(Reply.self, from: body).reference,
                  reference.range(of: #"^VR-[0-9A-Z]{6}$"#, options: .regularExpression) != nil else {
                return .failure(.unavailable)
            }
            return .success(reference)
        case 429:
            return .failure(.rateLimited(retryAfter: retryAfter.flatMap(Int.init) ?? 60))
        case 400, 404, 405, 413, 415:
            return .failure(.rejected)
        default:
            return .failure(.unavailable)
        }
    }
}

/// Where a send stands, for the Send buttons.
enum DiagnosticsSendStatus: Equatable {
    case idle
    case sending
    case sent(reference: String)
    case failed(DiagnosticsUploader.Failure)

    var isSending: Bool { self == .sending }

    var detail: String? {
        switch self {
        case .idle: return nil
        case .sending: return "Sending…"
        case .sent(let reference): return "Sent. Reference \(reference)."
        case .failed(let failure): return failure.message
        }
    }
}
#endif
