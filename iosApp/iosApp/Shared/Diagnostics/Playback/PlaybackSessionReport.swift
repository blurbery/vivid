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
    /// One entry per minute of playback with the app's memory use, plus
    /// anything that went wrong in it. Records saved before memory was
    /// recorded list only the minutes that had a problem.
    var timeline: [Minute]
    var notMeasured: [String]
    /// The tester's own "What happened?" text, added only to the copy being
    /// sent. The saved record never carries it.
    var note: String?

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
        /// The audio route's reported output latency. AirPlay speakers
        /// report about 2 s; Apple's audio clocks already allow for it.
        var outputLatencyMs: Int?
        /// Apple's reported rendering mode: not_applicable, mono_stereo,
        /// surround, spatial_audio, dolby_audio or dolby_atmos. A read-only
        /// result; not_applicable has been seen while Atmos was audible.
        var renderingMode: String?
        /// Channels the active output port negotiated.
        var routeOutputChannels: Int?
        /// iPhone and iPad: Vivid has an external-display scene (AirPlay
        /// video or a cable), where these frame counts are the phone's own.
        /// Plain screen mirroring without that scene isn't detected.
        var externalScreen: Bool?
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
        /// Frames the video output dropped during start, seek, resume and
        /// display switches, which are normal and not counted above. Late
        /// and decoder drops during warm-up aren't kept.
        var warmupDroppedFrames: Int?
        var maxAvSyncMs: Double?
        /// Seconds with audio/video drift over 100 ms outside warm-up.
        var avSyncOver100msSeconds: Double = 0
        var rebuffers = 0
        var rebufferSeconds: Double = 0
        /// The playhead stopping for 2 s or more in steady playback without
        /// buffering, such as a stalled audio clock.
        var stalls = 0
        var stallSeconds: Double = 0
        /// Seconds from opening to the first frame on screen, and to the
        /// playhead first moving. The gap is the audio output starting; on
        /// AirPlay, the speakers engaging.
        var firstFrameSeconds: Double?
        var playbackStartSeconds: Double?
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
        /// Seconds paused after playback started. Optional so records saved
        /// before these fields existed still load.
        var pausedSeconds: Double?
        /// Seconds waiting for the player to load after opening, seeking or
        /// resuming. That isn't a rebuffer, but a long wait is how playback
        /// stuck after a seek shows.
        var waitSeconds: Double?
        /// The longest single wait of that kind.
        var longestWaitSeconds: Double?
        /// iPhone and iPad only: how many times the player controls appeared,
        /// and the shortest time they stayed. Optional so older records load.
        var controlsShown: Int?
        var shortestControlsVisibleMs: Int?
        /// The controls going away within `earlyControlsHideSeconds` of
        /// appearing, as "shown_by>hidden_by" → count, for example
        /// "video_tap>background_tap".
        var controlsHiddenEarly: [String: Int]?
        /// The latest of those, oldest first, with how long the controls
        /// stayed, for example "video_tap>background_tap 120 ms".
        var recentEarlyControlsHides: [String]?
    }

    struct Minute: Codable, Equatable {
        /// Minutes since playback started.
        var minute: Int
        var droppedFrames = 0
        var decoderDroppedFrames = 0
        var delayedFrames = 0
        var maxAvSyncMs: Double?
        var rebufferSeconds: Double = 0
        var stallSeconds: Double = 0
        var faults: [String: Int] = [:]
        /// The app's highest memory use in this minute, in MB, as the system
        /// counts it against the app's limit. Past the 240-minute cap the last
        /// entry keeps the highest reading of all the time after it. Optional
        /// so older records load.
        var memoryMB: Int?

        /// Nothing went wrong in this minute. Memory use isn't a problem.
        var isQuiet: Bool {
            droppedFrames == 0 && decoderDroppedFrames == 0 && delayedFrames == 0
                && (maxAvSyncMs ?? 0) <= 100 && rebufferSeconds == 0 && stallSeconds == 0 && faults.isEmpty
        }
    }
}

extension PlaybackSessionReport {
    /// A wait to load this long gets a mention in the headline.
    static let longWaitSeconds: Double = 10

    /// A short headline for the Diagnostics list and the email subject.
    var headline: String {
        var parts: [String] = []
        if let output = setup.audioOutput { parts.append(output.uppercased() == "HDMI" ? "HDMI" : output.capitalized) }
        if let height = media.height { parts.append(height >= 2000 ? "4K" : "\(height)p") }
        if let range = media.sourceDynamicRange, range != "sdr" { parts.append(Self.dynamicRangeLabel(range)) }
        if let dropped = totals.droppedFrames, dropped > 0 { parts.append("\(dropped) dropped frames") }
        if totals.rebuffers > 0 { parts.append("\(totals.rebuffers) rebuffers") }
        if totals.stalls > 0 { parts.append("\(totals.stalls) stalls") }
        if let wait = totals.longestWaitSeconds, wait >= Self.longWaitSeconds { parts.append("waited \(Int(wait)) s to load") }
        let faults = totals.audioFaults.values.reduce(0, +)
        if faults > 0 { parts.append("\(faults) audio faults") }
        let earlyHides = totals.controlsHiddenEarly?.values.reduce(0, +) ?? 0
        if earlyHides > 0 { parts.append("controls hid early \(earlyHides)×") }
        return parts.joined(separator: " · ")
    }

    /// Whether the display refresh is a whole multiple of the video's frame
    /// rate. If not, frames are shown for uneven times, which looks like
    /// judder even with nothing dropped. Nil when either rate is unknown.
    var frameRateMatched: Bool? {
        guard let fps = media.contentFps, fps > 1, let refresh = setup.displayRefreshHz, refresh > 1 else { return nil }
        let ratio = refresh / fps
        return abs(ratio - ratio.rounded()) < 0.01 && ratio.rounded() >= 1
    }

    /// Plain-language rows for the preview. Values that weren't measured
    /// say so rather than showing zero.
    var summaryRows: [(label: String, value: String)] {
        let missing = "Not measured"
        func count(_ value: Int?) -> String { value.map { "\($0)" } ?? missing }
        var rows: [(String, String)] = []
        var output = setup.audioOutput.map { $0 == "hdmi" ? "HDMI" : $0 == "airplay" ? "AirPlay" : $0.capitalized } ?? missing
        if let channels = setup.routeOutputChannels ?? setup.outputChannelsAvailable { output += " · \(channels) channels" }
        if let latency = setup.outputLatencyMs { output += " · \(String(format: "%.2g", Double(latency) / 1000)) s latency" }
        rows.append(("Audio output", output))
        if let mode = setup.renderingMode { rows.append(("Apple rendering", Self.renderingModeLabel(mode))) }
        if setup.externalScreen == true { rows.append(("External screen", "Yes")) }
        let hdr = setup.displayHDR.map { $0.isEmpty ? "SDR only" : $0.map(Self.dynamicRangeLabel).joined(separator: ", ") } ?? missing
        rows.append(("Display HDR", hdr))
        if let refresh = setup.displayRefreshHz { rows.append(("Display refresh", String(format: "%.5g Hz", refresh))) }
        if let matched = frameRateMatched, let fps = media.contentFps, let refresh = setup.displayRefreshHz {
            rows.append(("Frame rate matched", (matched ? "Yes" : "No") + String(format: " (%.5g fps on %.5g Hz)", fps, refresh)))
        }
        if let matching = setup.systemMatchingEnabled { rows.append(("Match content (Apple TV)", matching ? "On" : "Off")) }
        var video = [media.videoCodec?.uppercased(), media.height.map { "\($0)p" },
                     media.sourceDynamicRange.map(Self.dynamicRangeLabel),
                     media.contentFps.map { String(format: "%.5g fps", $0) }].compactMap { $0 }.joined(separator: " · ")
        if let out = media.outputDynamicRange, out != media.sourceDynamicRange { video += " → shown as \(Self.dynamicRangeLabel(out))" }
        rows.append(("Video", video.isEmpty ? missing : video))
        var audio = [media.audioCodec?.uppercased(), media.audioSourceChannels.map { "\($0) ch" }].compactMap { $0 }.joined(separator: " · ")
        if let passthrough = media.audioPassthrough { audio += passthrough ? " · passthrough" : " · decoded" }
        rows.append(("Audio", audio.isEmpty ? missing : audio))
        if let method = setup.playMethod { rows.append(("Play method", method)) }
        rows.append(("Played", Duration.seconds(totals.playedSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))))
        rows.append(("Ended", Self.endReasonLabel(totals.endReason)))
        if let memory = memorySummary { rows.append(("Memory", memory)) }
        rows.append(("Dropped frames", count(totals.droppedFrames)))
        rows.append(("Decoder dropped frames", count(totals.decoderDroppedFrames)))
        rows.append(("Late frames", count(totals.delayedFrames)))
        rows.append(("Worst A/V sync", totals.maxAvSyncMs.map { "\(Int($0)) ms" } ?? missing))
        rows.append(("Rebuffering", totals.rebuffers == 0 ? "None" : "\(totals.rebuffers) times, \(Int(totals.rebufferSeconds)) s"))
        rows.append(("Stalls", totals.stalls == 0 ? "None" : "\(totals.stalls) times, \(Int(totals.stallSeconds)) s"))
        if let wait = totals.waitSeconds {
            let longest = totals.longestWaitSeconds.map { ", longest \(Int($0)) s" } ?? ""
            rows.append(("Waiting to load", wait < 1 ? "None" : "\(Int(wait)) s\(longest)"))
        }
        if let paused = totals.pausedSeconds {
            rows.append(("Paused", paused < 1 ? "None" : Duration.seconds(paused).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))))
        }
        let startup = [totals.firstFrameSeconds.map { "first frame \($0) s" }, totals.playbackStartSeconds.map { "playing \($0) s" }]
            .compactMap { $0 }.joined(separator: ", ")
        rows.append(("Startup", startup.isEmpty ? missing : startup))
        let faults = totals.audioFaults.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
        rows.append(("Audio faults", faults.isEmpty ? "None" : faults.joined(separator: ", ")))
        if let shown = totals.controlsShown {
            let shortest = totals.shortestControlsVisibleMs.map { ", shortest \($0) ms" } ?? ""
            rows.append(("Player controls", "Shown \(shown) times\(shortest)"))
            let early = totals.recentEarlyControlsHides ?? []
            rows.append(("Controls hid early", early.isEmpty ? "None" : early.joined(separator: ", ")))
        }
        if !notMeasured.isEmpty { rows.append(("Not measured", notMeasured.joined(separator: ", "))) }
        return rows
    }

    /// The first and highest memory readings, for example "640 MB in minute 0,
    /// highest 1690 MB in minute 9". Nil for records without readings.
    var memorySummary: String? {
        let readings = timeline.compactMap { minute in minute.memoryMB.map { (minute: minute.minute, mb: $0) } }
        guard let first = readings.first, let highest = readings.max(by: { $0.mb < $1.mb }) else { return nil }
        let start = "\(first.mb) MB in minute \(first.minute)"
        guard highest.mb > first.mb else { return start }
        return start + ", highest \(highest.mb) MB in minute \(highest.minute)"
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

    static func renderingModeLabel(_ token: String) -> String {
        switch token {
        case "mono_stereo": return "Stereo"
        case "surround": return "Surround"
        case "spatial_audio": return "Spatial Audio"
        case "dolby_audio": return "Dolby Audio"
        case "dolby_atmos": return "Dolby Atmos"
        default: return "Not reported"
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
