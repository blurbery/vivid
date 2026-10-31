// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation

/// The note a person may add to a report, within the relay's rules.
enum DiagnosticsNote {
    /// Counted in Unicode scalars, as the relay counts them.
    static let maxCharacters = 500

    private static let directionControls: [ClosedRange<UInt32>] = [0x202A...0x202E, 0x2066...0x2069]

    static func limited(_ text: String) -> String {
        guard text.unicodeScalars.count > maxCharacters else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxCharacters)))
    }

    /// Line breaks and tabs kept, other control and direction characters
    /// removed, cut to the limit and trimmed. Nil when nothing is left.
    static func cleaned(_ text: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            if scalar.properties.generalCategory == .control, scalar != "\n", scalar != "\t" { continue }
            if directionControls.contains(where: { $0.contains(scalar.value) }) { continue }
            scalars.append(scalar)
        }
        let note = limited(String(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? nil : note
    }
}

/// Sends a report the person chose to share to Vivid's diagnostics relay.
enum DiagnosticsUploader {
    enum Kind: String {
        case playback
        case problems
    }

    enum Failure: Error, Equatable {
        case offline
        case rateLimited(retryAfter: Int)
        case unavailable
        case rejected

        var message: String {
            switch self {
            case .offline:
                String(localized: "Vivid couldn't reach the diagnostics service. Check the connection and try again.")
            case .rateLimited(let seconds):
                String(localized: "Too many reports were sent just now. Try again in \(Self.wholeMinutes(seconds)) min.")
            case .unavailable:
                String(localized: "The diagnostics service is busy. Try again later.")
            case .rejected:
                String(localized: "The diagnostics service couldn't accept this report.")
            }
        }

        var canRetry: Bool { self != .rejected }

        /// Minutes rounded up, at least one, without overflowing for any value.
        private static func wholeMinutes(_ seconds: Int) -> Int {
            guard seconds > 0 else { return 1 }
            let (minutes, remainder) = seconds.quotientAndRemainder(dividingBy: 60)
            return remainder == 0 ? minutes : minutes + 1
        }
    }

    static let baseURL = URL(string: "https://diagnostics.vividapp.co/v1/reports/")!

    private static let rejectedStatuses: Set<Int> = [400, 404, 405, 413, 415]
    private static let defaultRetryAfter = 60

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// The relay's reference for the report. Throws only `Failure`.
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
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        return try outcome(status: http.statusCode, body: body, retryAfter: retryAfter).get()
    }

    static func outcome(status: Int, body: Data, retryAfter: String?) -> Result<String, Failure> {
        switch status {
        case 200:
            guard let reply = try? JSONDecoder().decode(Reply.self, from: body), isReference(reply.reference) else {
                return .failure(.unavailable)
            }
            return .success(reply.reference)
        case 429:
            return .failure(.rateLimited(retryAfter: retryAfter.flatMap { Int($0) } ?? defaultRetryAfter))
        case _ where rejectedStatuses.contains(status):
            return .failure(.rejected)
        default:
            return .failure(.unavailable)
        }
    }

    private struct Reply: Decodable {
        let reference: String
    }

    /// `VR-` and six digits or capital letters, nothing else.
    private static func isReference(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 9, value.hasPrefix("VR-") else { return false }
        return scalars[3...].allSatisfy { ("0"..."9").contains($0) || ("A"..."Z").contains($0) }
    }
}

/// The state of a send button.
enum DiagnosticsSendStatus: Equatable {
    case idle
    case sending
    case sent(reference: String)
    case failed(DiagnosticsUploader.Failure)

    var isSending: Bool { self == .sending }

    var detail: String? {
        switch self {
        case .idle: nil
        case .sending: String(localized: "Sending\u{2026}")
        case .sent(let reference): String(localized: "Sent. Reference \(reference).")
        case .failed(let failure): failure.message
        }
    }
}
