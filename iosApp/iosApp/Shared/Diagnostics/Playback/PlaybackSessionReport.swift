#if os(iOS) || os(tvOS)
import Foundation

/// The latest playback session, for Settings → Diagnostics → Send Latest
/// Playback. Built only from fixed tokens and numbers: no titles, item IDs,
/// server addresses, URLs or account details.
///
/// A value that couldn't be measured is left out and its name is listed in
/// `notMeasured`, so a missing counter never reads as zero.
struct PlaybackSessionReport: Codable, Equatable {
    static let format = 1

    var format = PlaybackSessionReport.format
    var startedAt: Date
    var updatedAt: Date
    var app: AppHealthAppInfo
    var setup: Setup
    var media: Media
    var totals: Totals
    /// One entry per minute of playback that had a problem. Quiet minutes
    /// are left out to keep the report small.
    var timeline: [Minute]
    var notMeasured: [String]

    struct Setup: Codable, Equatable {
        /// hdmi, airplay, bluetooth, speaker, headphones, usb, car or other.
        var audioOutput: String?
        /// Channels the current output accepts.
        var outputChannelsAvailable: Int?
        var multichannelSupported: Bool?
        /// HDR formats the display reports: hdr10, dolby_vision, hlg.
        var displayHDR: [String]?
        var hdrPlaybackEligible: Bool?
        /// Whether the user has Match Content turned on in Vivid.
        var matchContentEnabled: Bool?
        /// tvOS: whether the system's Match Dynamic Range / Frame Rate is on.
        var systemMatchingEnabled: Bool?
        var displayRefreshHz: Double?
        var serverType: String?
        var playMethod: String?
    }

    struct Media: Codable, Equatable {
        var videoCodec: String?
        var width: Int?
        var height: Int?
        /// sdr, hdr10, hlg or dolby_vision as decoded.
        var sourceDynamicRange: String?
        /// What was sent to the display after any tone mapping.
        var outputDynamicRange: String?
        var dolbyVisionProfile: Int?
        var contentFps: Double?
        var hardwareDecoding: String?
        var videoBitrateKbps: Int?
        var audioCodec: String?
        var audioSourceChannels: Int?
        /// The format mpv sent to the audio output, for example a passthrough
        /// format (spdif-eac3) or PCM (floatp).
        var audioOutputFormat: String?
        var audioOutputChannels: Int?
        var audioPassthrough: Bool?
    }

    struct Totals: Codable, Equatable {
        var playedSeconds: Double = 0
        var warmupSeconds: Double = 0
        /// Frames the video output dropped outside warm-up.
        var droppedFrames: Int?
        /// Frames the decoder dropped because it fell behind.
        var decoderDroppedFrames: Int?
        /// Frames shown later than their due time.
        var delayedFrames: Int?
        /// Drops during start, seek, resume and display switches, which are
        /// normal and not counted above.
        var warmupDroppedFrames: Int?
        var maxAvSyncMs: Double?
        /// Seconds with audio/video drift over 100 ms outside warm-up.
        var avSyncOver100msSeconds: Double = 0
        var rebuffers = 0
        var rebufferSeconds: Double = 0
        var seeks = 0
        var displaySwitches = 0
        /// Same-video reloads, for example to recover audio or after a
        /// sign-in refresh.
        var reloads = 0
        var audioOutputChanges = 0
        /// Fault token → count, for example decode_error or audio_system_restart.
        var audioFaults: [String: Int] = [:]
        var lowestNetworkKbps: Int?
        var endReason: String?
    }

    struct Minute: Codable, Equatable {
        /// Minutes since playback started.
        var minute: Int
        var droppedFrames = 0
        var decoderDroppedFrames = 0
        var delayedFrames = 0
        var maxAvSyncMs: Double?
        var rebufferSeconds: Double = 0
        var faults: [String: Int] = [:]

        var isQuiet: Bool {
            droppedFrames == 0 && decoderDroppedFrames == 0 && delayedFrames == 0
                && (maxAvSyncMs ?? 0) <= 100 && rebufferSeconds == 0 && faults.isEmpty
        }
    }
}

extension PlaybackSessionReport {
    /// A short headline for the Diagnostics list and the email subject.
    var headline: String {
        var parts: [String] = []
        if let output = setup.audioOutput { parts.append(output.uppercased() == "HDMI" ? "HDMI" : output.capitalized) }
        if let height = media.height { parts.append(height >= 2000 ? "4K" : "\(height)p") }
        if let range = media.sourceDynamicRange, range != "sdr" { parts.append(Self.dynamicRangeLabel(range)) }
        if let dropped = totals.droppedFrames, dropped > 0 { parts.append("\(dropped) dropped frames") }
        if totals.rebuffers > 0 { parts.append("\(totals.rebuffers) rebuffers") }
        let faults = totals.audioFaults.values.reduce(0, +)
        if faults > 0 { parts.append("\(faults) audio faults") }
        return parts.joined(separator: " · ")
    }

    /// Plain-language rows for the preview. Values that weren't measured
    /// say so rather than showing zero.
    var summaryRows: [(label: String, value: String)] {
        let missing = "Not measured"
        func count(_ value: Int?) -> String { value.map { "\($0)" } ?? missing }
        var rows: [(String, String)] = []
        var output = setup.audioOutput.map { $0 == "hdmi" ? "HDMI" : $0 == "airplay" ? "AirPlay" : $0.capitalized } ?? missing
        if let channels = setup.outputChannelsAvailable { output += " · up to \(channels) channels" }
        rows.append(("Audio output", output))
        let hdr = setup.displayHDR.map { $0.isEmpty ? "SDR only" : $0.map(Self.dynamicRangeLabel).joined(separator: ", ") } ?? missing
        rows.append(("Display HDR", hdr))
        if let refresh = setup.displayRefreshHz { rows.append(("Display refresh", String(format: "%.3g Hz", refresh))) }
        if let matching = setup.systemMatchingEnabled { rows.append(("Match content (Apple TV)", matching ? "On" : "Off")) }
        var video = [media.videoCodec?.uppercased(), media.height.map { "\($0)p" },
                     media.sourceDynamicRange.map(Self.dynamicRangeLabel),
                     media.contentFps.map { String(format: "%.3g fps", $0) }].compactMap { $0 }.joined(separator: " · ")
        if let out = media.outputDynamicRange, out != media.sourceDynamicRange { video += " → shown as \(Self.dynamicRangeLabel(out))" }
        rows.append(("Video", video.isEmpty ? missing : video))
        var audio = [media.audioCodec?.uppercased(), media.audioSourceChannels.map { "\($0) ch" }].compactMap { $0 }.joined(separator: " · ")
        if let passthrough = media.audioPassthrough { audio += passthrough ? " · passthrough" : " · decoded" }
        rows.append(("Audio", audio.isEmpty ? missing : audio))
        if let method = setup.playMethod { rows.append(("Play method", method)) }
        rows.append(("Played", Duration.seconds(totals.playedSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))))
        rows.append(("Ended", Self.endReasonLabel(totals.endReason)))
        rows.append(("Dropped frames", count(totals.droppedFrames)))
        rows.append(("Decoder dropped frames", count(totals.decoderDroppedFrames)))
        rows.append(("Late frames", count(totals.delayedFrames)))
        rows.append(("Worst A/V sync", totals.maxAvSyncMs.map { "\(Int($0)) ms" } ?? missing))
        rows.append(("Rebuffering", totals.rebuffers == 0 ? "None" : "\(totals.rebuffers) times, \(Int(totals.rebufferSeconds)) s"))
        let faults = totals.audioFaults.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
        rows.append(("Audio faults", faults.isEmpty ? "None" : faults.joined(separator: ", ")))
        if !notMeasured.isEmpty { rows.append(("Not measured", notMeasured.joined(separator: ", "))) }
        return rows
    }

    /// "failed_<kind>" comes from the player's error kind, for example
    /// failed_sourceRefused becomes "Failed (source refused)".
    static func endReasonLabel(_ reason: String?) -> String {
        switch reason {
        case nil: return "Still playing or closed unexpectedly"
        case "ended": return "Finished"
        case "stopped": return "Stopped"
        case "replaced": return "Another video started"
        case let reason?:
            guard reason.hasPrefix("failed_") else { return reason }
            let words = reason.dropFirst("failed_".count).reduce(into: "") { text, character in
                if character.isUppercase { text += " " }
                text += character == "_" ? " " : String(character).lowercased()
            }
            return "Failed (\(words))"
        }
    }

    static func dynamicRangeLabel(_ token: String) -> String {
        switch token {
        case "dolby_vision": return "Dolby Vision"
        case "hdr10": return "HDR10"
        case "hdr10_plus": return "HDR10+"
        case "hlg": return "HLG"
        default: return "SDR"
        }
    }
}
#endif
