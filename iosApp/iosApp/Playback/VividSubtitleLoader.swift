// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation
import Foundation


/// Refuses redirects for header-authenticated subtitle requests, so the
/// redirect response surfaces as a failed download instead.
private final class CredentialRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

enum VividSubtitleLoader {
    enum Document {
        case cues([SubtitleCue])
        case ass(String)
    }
    static func load(_ track: ExternalSubtitleTrack) async throws -> Document {
        document(try await text(of: track), track: track)
    }

    /// The file's text, as downloaded or read.
    static func text(of track: ExternalSubtitleTrack) async throws -> String {
        let data: Data
        if track.url.isFileURL {
            data = try Data(contentsOf: track.url, options: .mappedIfSafe)
        } else {
            var request = URLRequest(url: track.url)
            request.timeoutInterval = 20
            let headers = track.httpHeaders ?? [:]
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            // Media-server credentials must never follow a redirect elsewhere.
            let (bytes, response) = try await URLSession.shared.bytes(
                for: request,
                delegate: headers.isEmpty ? nil : CredentialRedirectGuard()
            )
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            var received = Data()
            for try await byte in bytes {
                guard received.count < 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                received.append(byte)
            }
            data = received
        }
        guard data.count <= 16 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw URLError(.cannotDecodeContentData) }
        return text
    }

    static func document(_ text: String, track: ExternalSubtitleTrack) -> Document {
        let leadingWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        let firstLine = text.trimmingCharacters(in: leadingWhitespace)
            .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces)
        let formatHint = track.formatHint?.lowercased() ?? ""
        let fileExtension = track.url.pathExtension.lowercased()
        let hasASSFormat = formatHint == "ass" || formatHint == "ssa"
            || fileExtension == "ass" || fileExtension == "ssa"
        if firstLine?.lowercased() == "[script info]" || hasASSFormat {
            return .ass(text)
        }
        return .cues(parse(text))
    }
    static func parse(_ text: String) -> [SubtitleCue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count && cues.count < 100_000 {
            let line = lines[index]
            if line.hasPrefix("Dialogue:") {
                let fields = line.dropFirst(9).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
                if fields.count == 10, let start = time(String(fields[1])), let end = time(String(fields[2])) {
                    let plain = String(fields[9]).replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                    cues.append(SubtitleCue(id: cues.count, startTime: start, endTime: end, body: .text(plain)))
                }
                index += 1; continue
            }
            let range = line.components(separatedBy: "-->")
            guard range.count == 2, let start = time(range[0]), let end = time(range[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]), end >= start else { index += 1; continue }
            index += 1
            var body: [String] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { body.append(lines[index]); index += 1 }
            let (cueBody, placement) = textCue(body.joined(separator: "\n"))
            cues.append(SubtitleCue(id: cues.count, startTime: start, endTime: end, body: cueBody, placement: placement))
        }
        return cues
    }
    /// SubRip and WebVTT styling, as FFmpeg hands it to libass for an
    /// embedded track: `<b>`, `<i>`, `<u>`, `<s>` and `<font color>`, and an
    /// ASS `{\anN}` alignment. Other tags (WebVTT classes, voices and
    /// timestamps) are dropped. Text without styling stays plain.
    static func textCue(_ raw: String) -> (SubtitleCue.Body, SubtitleTextPlacement?) {
        var placement: SubtitleTextPlacement?
        var text = raw
        while let block = text.range(of: #"\{\\[^}]*\}"#, options: .regularExpression) {
            if placement == nil,
               let tag = text[block].range(of: #"\\an[1-9]"#, options: .regularExpression),
               let digit = text[block][tag].last?.wholeNumberValue {
                placement = SubtitleTextPlacement(alignment: digit)
            }
            text.removeSubrange(block)
        }

        var runs: [SubtitleTextRun] = []
        var bold = 0, italic = 0, underline = 0, strike = 0
        var colours: [SubtitleColor?] = []
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            let run = SubtitleTextRun(text: decodeEntities(pending), color: colours.last ?? nil,
                                      isBold: bold > 0, isItalic: italic > 0,
                                      isUnderlined: underline > 0, isStruckThrough: strike > 0)
            pending = ""
            if let last = runs.last, last.sameStyle(as: run) {
                runs[runs.count - 1] = SubtitleTextRun(text: last.text + run.text, color: run.color, isBold: run.isBold,
                                                       isItalic: run.isItalic, isUnderlined: run.isUnderlined,
                                                       isStruckThrough: run.isStruckThrough)
            } else {
                runs.append(run)
            }
        }
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "<", let close = text[index...].firstIndex(of: ">") else {
                pending.append(text[index])
                index = text.index(after: index)
                continue
            }
            flush()
            let tag = text[text.index(after: index)..<close].trimmingCharacters(in: .whitespaces).lowercased()
            switch tag {
            case "b": bold += 1
            case "/b": bold = max(0, bold - 1)
            case "i": italic += 1
            case "/i": italic = max(0, italic - 1)
            case "u": underline += 1
            case "/u": underline = max(0, underline - 1)
            case "s": strike += 1
            case "/s": strike = max(0, strike - 1)
            case "/font": _ = colours.popLast()
            default:
                if tag.hasPrefix("font ") || tag == "font" {
                    colours.append(fontColour(tag) ?? colours.last ?? nil)
                }
            }
            index = text.index(after: close)
        }
        flush()
        guard runs.contains(where: { !$0.sameStyle(as: SubtitleTextRun(text: "")) }) else {
            return (.text(runs.map(\.text).joined()), placement)
        }
        return (.richText(runs), placement)
    }

    /// `&amp;` last, so an escaped entity such as `&amp;lt;` stays literal.
    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let colourNames: [String: UInt32] = [
        "white": 0xFFFFFF, "silver": 0xC0C0C0, "gray": 0x808080, "grey": 0x808080, "black": 0x000000,
        "red": 0xFF0000, "maroon": 0x800000, "yellow": 0xFFFF00, "olive": 0x808000, "lime": 0x00FF00,
        "green": 0x008000, "aqua": 0x00FFFF, "cyan": 0x00FFFF, "teal": 0x008080, "blue": 0x0000FF,
        "navy": 0x000080, "fuchsia": 0xFF00FF, "magenta": 0xFF00FF, "purple": 0x800080, "orange": 0xFFA500,
    ]

    /// `<font color="...">` as a hex value (with or without `#`, six or
    /// three digits) or a basic colour name.
    private static func fontColour(_ tag: String) -> SubtitleColor? {
        guard let attribute = tag.range(of: #"color\s*=\s*["']?[^"'\s>]+"#, options: .regularExpression) else { return nil }
        var value = String(tag[attribute].drop(while: { $0 != "=" }).dropFirst())
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let packed: UInt32
        if let named = colourNames[value] {
            packed = named
        } else {
            if value.hasPrefix("#") { value.removeFirst() }
            if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
            guard value.count == 6, let parsed = UInt32(value, radix: 16) else { return nil }
            packed = parsed
        }
        return SubtitleColor(r: UInt8(packed >> 16 & 0xFF), g: UInt8(packed >> 8 & 0xFF), b: UInt8(packed & 0xFF))
    }

    private static func time(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var result: Double = 0
        for part in parts { guard let value = Double(part), value >= 0, value.isFinite else { return nil }; result = result * 60 + value }
        return result
    }
}
@MainActor final class FrameExtractor {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    init(url: URL, headers: [String: String]) {
        asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
    }
    func thumbnail(at seconds: Double, maxWidth: Int) async -> CGImage? {
        // Lucid opens formats that AVFoundation cannot extract stills from.
        // Keep timeline scrubbing available without attempting unsupported previews.
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
    func shutdown() async { generator.cancelAllCGImageGeneration() }
}
