import Foundation

/// Host-facing playback diagnostics. Every value is projected from
/// VividEngine's public state or from immutable Silo session metadata.
/// A missing value means the active Vivid route cannot measure it.
struct PlaybackStats: Equatable {
    struct MediaStream: Equatable {
        var codec: String?
        var detail: String?
        var bitrateBps: Double?
    }

    var sampledAt: Date = Date()

    // Source/session identity supplied by Silo.
    var route: String?
    var source: String?
    var delivery: String?
    var container: String?

    // Static and selected media state supplied by Vivid.
    var video: MediaStream = .init()
    var audio: MediaStream = .init()
    var dynamicRange: String?
    var subtitles: String?
    var playbackRate: Double?

    // Vivid playback phase and route-appropriate live telemetry.
    var playbackStatus: String?
    var bufferedAheadSeconds: Double?
    var readAheadAvailableSeconds: Double?
    var displayCushionSeconds: Double?
    var readerWindowAheadBytes: Int64?
    var observedFrameRate: Double?
    var droppedVideoFrames: Int?
    var accumulatedFrameDelaySeconds: Double?
    var avSyncGapMilliseconds: Double?

    // Vivid source and network measurements.
    var instantReadBitrateBps: Double?
    var averageReadBitrateBps: Double?
    var audioBridgeBitrateBps: Double?
    var networkThroughputBps: Double?
    var bytesTransferred: Int64?
    var cachedBytes: Int64?
    var demuxerBytesFetched: Int64?

    // Small, cross-route engine health surface.
    var producerRestartCount: Int?
    var residentMemoryBytes: Int64?

    static let empty = PlaybackStats()
}

extension PlaybackStats {
    var allRows: [(String, String)] {
        sourceRows + mediaRows + bufferRows + networkRows + engineRows
    }

    /// The short set shown over iPhone video. It intentionally leaves the
    /// engine-health counters to the paged tvOS panel.
    var compactRows: [(String, String)] {
        let wanted = [
            "Route", "Source", "Delivery", "Container",
            "Video", "Audio", "Dynamic range", "Subtitles",
            "Playback status", "Forward buffer", "Display cushion",
            "Dropped frames", "Instant read bitrate", "Network throughput"
        ]
        let rows = allRows
        return wanted.compactMap { label in
            rows.first { $0.0 == label }
        }
    }

    var hasRows: Bool { !allRows.isEmpty }

    /// A row label in the app's language. Rows keep their English label as
    /// their identity (`compactRows` picks rows by it, and the panels use it
    /// as the row ID), so only the panels translate it.
    static func displayLabel(_ label: String) -> String {
        switch label {
        case "Route": return String(localized: "Route", comment: "Playback stats row")
        case "Source": return String(localized: "Source", comment: "Playback stats row")
        case "Delivery": return String(localized: "Delivery", comment: "Playback stats row")
        case "Container": return String(localized: "Container", comment: "Playback stats row")
        case "Video": return String(localized: "Video", comment: "Playback stats row")
        case "Audio": return String(localized: "Audio", comment: "Playback stats row")
        case "Dynamic range": return String(localized: "Dynamic range", comment: "Playback stats row")
        case "Subtitles": return String(localized: "Subtitles", comment: "Playback stats row")
        case "Playback rate": return String(localized: "Playback rate", comment: "Playback stats row")
        case "Playback status": return String(localized: "Playback status", comment: "Playback stats row")
        case "AVPlayer buffer": return String(localized: "AVPlayer buffer", comment: "Playback stats row")
        case "Forward buffer": return String(localized: "Forward buffer", comment: "Playback stats row")
        case "Read-ahead available": return String(localized: "Read-ahead available", comment: "Playback stats row")
        case "Display cushion": return String(localized: "Display cushion", comment: "Playback stats row")
        case "Reader runway": return String(localized: "Reader runway", comment: "Playback stats row")
        case "Observed frame rate": return String(localized: "Observed frame rate", comment: "Playback stats row")
        case "Dropped frames": return String(localized: "Dropped frames", comment: "Playback stats row")
        case "Accumulated frame delay": return String(localized: "Accumulated frame delay", comment: "Playback stats row")
        case "A/V sync gap": return String(localized: "A/V sync gap", comment: "Playback stats row")
        case "Instant read bitrate": return String(localized: "Instant read bitrate", comment: "Playback stats row")
        case "Average read bitrate": return String(localized: "Average read bitrate", comment: "Playback stats row")
        case "Audio bridge bitrate": return String(localized: "Audio bridge bitrate", comment: "Playback stats row")
        case "Network throughput": return String(localized: "Network throughput", comment: "Playback stats row")
        case "Network transferred": return String(localized: "Network transferred", comment: "Playback stats row")
        case "Vivid cache": return String(localized: "Vivid cache", comment: "Playback stats row")
        case "Demuxer read": return String(localized: "Demuxer read", comment: "Playback stats row")
        case "Producer restarts": return String(localized: "Producer restarts", comment: "Playback stats row")
        case "Resident memory": return String(localized: "Resident memory", comment: "Playback stats row")
        default: return label
        }
    }

    var sourceRows: [(String, String)] {
        stringRows([
            ("Route", route),
            ("Source", source),
            ("Delivery", delivery),
            ("Container", container)
        ])
    }

    var mediaRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let video = mediaDescription(video) {
            rows.append(("Video", video))
        }
        if let audio = mediaDescription(audio) {
            rows.append(("Audio", audio))
        }
        rows.append(contentsOf: stringRows([
            ("Dynamic range", dynamicRange),
            ("Subtitles", subtitles)
        ]))
        if let playbackRate, playbackRate.isFinite, playbackRate > 0 {
            let rate = String(format: "%.2f", locale: .current, playbackRate)
            rows.append(("Playback rate", String(localized: "\(rate)x", comment: "Playback rate in the stats, for example 1.00x")))
        }
        return rows
    }

    var bufferRows: [(String, String)] {
        var rows = stringRows([("Playback status", playbackStatus)])
        if let bufferedAheadSeconds, bufferedAheadSeconds.isFinite {
            #if os(tvOS)
            rows.append(("AVPlayer buffer", formatSeconds(bufferedAheadSeconds)))
            #else
            rows.append(("Forward buffer", formatSeconds(bufferedAheadSeconds)))
            #endif
        }
        if let readAheadAvailableSeconds, readAheadAvailableSeconds.isFinite {
            rows.append(("Read-ahead available", formatSeconds(readAheadAvailableSeconds)))
        }
        if let displayCushionSeconds, displayCushionSeconds.isFinite {
            rows.append(("Display cushion", formatSeconds(displayCushionSeconds)))
        }
        if let readerWindowAheadBytes, readerWindowAheadBytes >= 0 {
            rows.append(("Reader runway", formatBytes(readerWindowAheadBytes)))
        }
        if let observedFrameRate, observedFrameRate.isFinite, observedFrameRate > 0 {
            let fps = String(format: "%.2f", locale: .current, observedFrameRate)
            rows.append(("Observed frame rate", String(localized: "\(fps) fps", comment: "Frames per second")))
        }
        if let droppedVideoFrames, droppedVideoFrames >= 0 {
            rows.append(("Dropped frames", "\(droppedVideoFrames)"))
        }
        if let accumulatedFrameDelaySeconds,
           accumulatedFrameDelaySeconds.isFinite,
           accumulatedFrameDelaySeconds >= 0 {
            rows.append(("Accumulated frame delay", formatSeconds(accumulatedFrameDelaySeconds)))
        }
        if let avSyncGapMilliseconds, avSyncGapMilliseconds.isFinite {
            let gap = String(format: "%.1f", locale: .current, avSyncGapMilliseconds)
            rows.append(("A/V sync gap", String(localized: "\(gap) ms", comment: "Milliseconds, with a decimal")))
        }
        return rows
    }

    var networkRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let instantReadBitrateBps {
            rows.append(("Instant read bitrate", formatBitsPerSecond(instantReadBitrateBps)))
        }
        if let averageReadBitrateBps {
            rows.append(("Average read bitrate", formatBitsPerSecond(averageReadBitrateBps)))
        }
        if let audioBridgeBitrateBps {
            rows.append(("Audio bridge bitrate", formatBitsPerSecond(audioBridgeBitrateBps)))
        }
        if let networkThroughputBps {
            rows.append(("Network throughput", formatBitsPerSecond(networkThroughputBps)))
        }
        if let bytesTransferred, bytesTransferred >= 0 {
            rows.append(("Network transferred", formatBytes(bytesTransferred)))
        }
        if let cachedBytes, cachedBytes >= 0 {
            rows.append(("Vivid cache", formatBytes(cachedBytes)))
        }
        if let demuxerBytesFetched, demuxerBytesFetched >= 0 {
            rows.append(("Demuxer read", formatBytes(demuxerBytesFetched)))
        }
        return rows
    }

    var engineRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let producerRestartCount, producerRestartCount > 0 {
            rows.append(("Producer restarts", "\(producerRestartCount)"))
        }
        if let residentMemoryBytes, residentMemoryBytes >= 0 {
            rows.append(("Resident memory", formatBytes(residentMemoryBytes)))
        }
        return rows
    }

    private func mediaDescription(_ stream: MediaStream) -> String? {
        var parts: [String] = []
        if let codec = normalized(stream.codec) {
            parts.append(formatCodec(codec))
        }
        if let detail = normalized(stream.detail) {
            parts.append(detail)
        }
        if let bitrateBps = stream.bitrateBps,
           bitrateBps.isFinite,
           bitrateBps > 0 {
            parts.append(formatBitsPerSecond(bitrateBps))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func stringRows(_ candidates: [(String, String?)]) -> [(String, String)] {
        candidates.compactMap { label, value in
            normalized(value).map { (label, $0) }
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func formatCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "hevc", "hvc1", "hev1": return "HEVC"
        case "h264", "avc1", "avc3": return "H.264"
        case "truehd", "mlpa": return "TrueHD"
        case "eac3", "e-ac-3", "ec-3": return "E-AC-3"
        case "ac3", "ac-3": return "AC-3"
        case "aac", "mp4a", "mp4a.40.2": return "AAC"
        default: return codec
        }
    }

    private func formatBitsPerSecond(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0 else { return String(localized: "0 bps", comment: "Bitrate of zero bits per second") }
        if bps >= 1_000_000 {
            let value = String(format: "%.2f", locale: .current, bps / 1_000_000)
            return String(localized: "\(value) Mbps", comment: "Bitrate in megabits per second, with a decimal")
        }
        let value = String(format: "%.0f", locale: .current, bps / 1_000)
        return String(localized: "\(value) Kbps", comment: "Bitrate in kilobits per second")
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let value = String(format: "%.2f", locale: .current, max(0, seconds))
        return String(localized: "\(value) s", comment: "Seconds, abbreviated, with decimals")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
