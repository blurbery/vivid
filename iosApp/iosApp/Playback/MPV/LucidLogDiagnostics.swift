// SPDX-License-Identifier: GPL-3.0-only
// Additional permission applies to Vivid's adapter only: LICENSE-APPLE-EXCEPTION.
#if os(iOS) || os(tvOS)
import Foundation

/// Turns Lucid's log lines into fault labels for the latest-playback report
/// and fields for the trial trace.
///
/// Raw mpv messages can carry authenticated URLs, so only fixed labels and
/// strictly numeric values taken from known lines ever leave this type. The
/// lines, their wording and the order they are checked in are part of the
/// engine's interface (engine 2.8 and 2.9).
enum LucidLogDiagnostics {
    /// The fields for a `log-message` event's payload, or nil when the line
    /// isn't one Vivid records. Faults start with `fault=`.
    static func fields(from data: [String: Any]?) -> String? {
        guard let prefix = data?["prefix"] as? String, let text = data?["text"] as? String else { return nil }
        return fields(prefix: prefix, message: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let audioOutput = "ao/avfoundation"

    private static func fields(prefix: String, message: String) -> String? {
        if message.hasPrefix("Too many packets in the demuxer packet queues:") {
            return "fault=packet_queue_limit"
        }
        if prefix == audioOutput, message == "resuming compressed feed after audio EOF" {
            return "event=compressed_feed_resumed_after_eof"
        }
        if isDemuxerPrefix(prefix) {
            return demuxerFaults.first { message.contains($0.text) }.map { "fault=\($0.label)" }
        }
        guard prefix == audioOutput else { return nil }
        if let label = exactAudioLines[message] {
            return label
        }
        if message.hasPrefix("notification name: ") {
            if message.contains("AVSampleBufferAudioRendererWasFlushedAutomatically") {
                return "event=audio_system_flush"
            }
            if message.contains("AVSampleBufferAudioRendererOutputConfigurationDidChange") {
                return "event=audio_output_configuration_changed"
            }
        }
        for line in numericAudioLines {
            if let fields = line.fields(in: message) { return fields }
        }
        return audioFaults.first { message.contains($0.text) }.map { "fault=\($0.label)" }
    }

    private static func isDemuxerPrefix(_ prefix: String) -> Bool {
        ["demux", "demuxer", "cplayer", "ad", "ffmpeg"].contains(prefix)
            || prefix.hasPrefix("ffmpeg/") || prefix.hasPrefix("demux/")
    }

    private static let demuxerFaults: [(text: String, label: String)] = [
        ("Too many packets", "packet_queue_limit"),
        ("queue overflow", "packet_queue_limit"),
        ("EOF", "eof_message"),
        ("End of file", "eof_message"),
        ("timed out", "input_timeout"),
        ("Connection reset", "connection_reset"),
        ("Error decoding", "decode_error"),
        ("Invalid data", "invalid_data"),
    ]

    private static let exactAudioLines: [String: String] = [
        "restarting due to system notification; this will cause desync": "fault=audio_system_restart",
        "pcm fresh sink after reset": "event=pcm_fresh_sink_after_reset",
        "pcm fresh sink failed; requesting audio reload": "fault=pcm_fresh_sink_failed",
        "pcm renderer failed; requesting audio reload": "fault=pcm_renderer_failed",
    ]

    /// An anchored line whose captures are numbers or fixed words, recorded
    /// as `event=<event> name=value ...` (or without an event name).
    private struct NumericLine {
        let event: String?
        let regex: NSRegularExpression?
        let names: [String]

        init(event: String?, pattern: String, names: [String]) {
            self.event = event
            self.regex = try? NSRegularExpression(pattern: pattern)
            self.names = names
        }

        /// Optional captures that didn't take part are left out.
        func fields(in message: String) -> String? {
            guard let regex,
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
            else { return nil }
            let values = names.enumerated().compactMap { index, name -> String? in
                guard let range = Range(match.range(at: index + 1), in: message) else { return nil }
                return "\(name)=\(message[range])"
            }
            return (event.map { "event=\($0) " } ?? "") + values.joined(separator: " ")
        }
    }

    /// Checked in this order, after the exact lines.
    private static let numericAudioLines: [NumericLine] = [
        NumericLine(
            event: "pcm_transport",
            pattern: #"\Apcm: clock (-?[0-9]+\.[0-9]+), fed (-?[0-9]+\.[0-9]+), ahead (-?[0-9]+\.[0-9]+), rate (-?[0-9]+\.[0-9]+), status ([0-9]+)(?:, latency (-?[0-9]+\.[0-9]+), sufficient (-?[0-9]+))?\z"#,
            names: ["clock_s", "fed_s", "ahead_s", "rate", "status", "latency_s", "sufficient"]),
        NumericLine(
            event: "audio_edge",
            pattern: #"\Atrace edge (start|start-fresh|pause|resume|reset|restart): clock (-?[0-9]+\.[0-9]+), fed (-?[0-9]+\.[0-9]+), latency (-?[0-9]+\.[0-9]+)\z"#,
            names: ["edge", "clock_s", "fed_s", "latency_s"]),
        NumericLine(
            event: "compressed_clock_engaged",
            pattern: #"\Acompressed clock engaged after (-?[0-9]+\.[0-9]+) s, seeked ([01]), anchors ([0-9]+)\z"#,
            names: ["after_s", "seeked", "anchors"]),
        NumericLine(
            event: "compressed_clock_resumed",
            pattern: #"\Acompressed clock resumed after (-?[0-9]+\.[0-9]+) s, anchors ([0-9]+)\z"#,
            names: ["after_s", "anchors"]),
        NumericLine(
            event: "audio_system_flush_time",
            pattern: #"\Anotification flush time (-?[0-9]+\.[0-9]+|nan), current ([01])\z"#,
            names: ["flush_s", "current"]),
        // The heartbeat is recorded without an event name.
        NumericLine(
            event: nil,
            pattern: #"\Aheartbeat: raw pos (-?[0-9]+\.[0-9]+)s, clamped (-?[0-9]+\.[0-9]+)s, fed (-?[0-9]+\.[0-9]+)s, status ([0-9]+), tc ([0-9]+)(?:, reader gap (-?[0-9]+) B)?\z"#,
            names: ["raw_s", "clock_s", "fed_s", "status", "time_control", "reader_gap_bytes"]),
        NumericLine(
            event: "audio_transport",
            pattern: #"\Aitem status (-?[0-9]+) -> (-?[0-9]+), time control (-?[0-9]+) -> (-?[0-9]+), pos (-?[0-9]+\.[0-9]+)s, fed (-?[0-9]+\.[0-9]+)s\z"#,
            names: ["old_status", "status", "old_time_control", "time_control", "clock_s", "fed_s"]),
    ]

    private static let audioFaults: [(text: String, label: String)] = [
        ("elementary stream window overflow", "window_overflow"),
        ("discarding burst with odd payload length", "odd_payload"),
        ("discarding burst without syncframe", "missing_syncframe"),
        ("skipping unexpected IEC 61937 data type", "unexpected_burst_type"),
        ("skipping burst with invalid payload length", "invalid_payload"),
        ("no IEC 61937 sync found", "missing_iec_sync"),
        ("loader requested offset", "loader_offset"),
        ("playback did not engage", "playback_not_engaged"),
        ("native compressed playback did not start", "compressed_start_failed"),
        ("player rejected the compressed stream", "apple_rejected_stream"),
        ("falling back to PCM", "pcm_fallback"),
    ]
}
#endif
