// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation
import Foundation


enum VividSubtitleLoader {
    enum Document {
        case cues([SubtitleCue])
        case ass(String)
    }
    static func load(_ track: ExternalSubtitleTrack) async throws -> Document {
        let data: Data
        if track.url.isFileURL {
            data = try Data(contentsOf: track.url, options: .mappedIfSafe)
        } else {
            var request = URLRequest(url: track.url)
            request.timeoutInterval = 20
            for (key, value) in track.httpHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
        if text.range(of: "[Script Info]", options: .caseInsensitive) != nil
            || ["ass", "ssa"].contains(track.formatHint?.lowercased() ?? track.url.pathExtension.lowercased()) {
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
            let plain = body.joined(separator: "\n").replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            cues.append(SubtitleCue(id: cues.count, startTime: start, endTime: end, body: .text(plain)))
        }
        return cues
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
