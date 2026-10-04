#if os(iOS) || os(tvOS)
import AVFoundation
import Foundation
import UIKit

/// Keeps the latest playback session for Settings → Diagnostics → Send
/// Latest Playback. Each new play replaces the previous session.
///
/// Recording never adds work to the player's render path: inputs are values
/// the player already receives, plus a once-a-second read of a few counters.
/// The session lives in memory and is written to one small file when
/// playback stops, when the app goes to the background and once a minute.
@MainActor
final class PlaybackSessionRecorder {
    static let shared = PlaybackSessionRecorder()

    /// Raised when the saved session changes, so Diagnostics can refresh.
    static let didChange = Notification.Name("vivid.playbackSession.didChange")

    private var accumulator: PlaybackSessionAccumulator?
    private var report: PlaybackSessionReport?
    private var lastSave: TimeInterval = 0
    private var routeObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var inForeground = true
    private var pictureInPicture = false
    private static let saveInterval: TimeInterval = 60

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Launch with `-vividDisableSessionRecorder` to compare playback with
    /// and without recording. Normal launches always record.
    nonisolated static let isEnabled = !ProcessInfo.processInfo.arguments.contains("-vividDisableSessionRecorder")

    private init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let recorder = PlaybackSessionRecorder.shared
                recorder.inForeground = false
                recorder.updateVideoVisible()
                recorder.save()
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                PlaybackSessionRecorder.shared.inForeground = true
                PlaybackSessionRecorder.shared.updateVideoVisible()
            }
        }
    }

    /// Video counts while the app is on screen or in picture in picture.
    private func updateVideoVisible() {
        accumulator?.setVideoVisible(inForeground || pictureInPicture, at: now)
    }

    func setPictureInPicture(_ active: Bool) {
        pictureInPicture = active
        updateVideoVisible()
    }

    // MARK: Session lifecycle

    /// Starts a new session, replacing the previous one on disk.
    func begin(matchContentEnabled: Bool) {
        guard Self.isEnabled else { return }
        let started = Date()
        accumulator = PlaybackSessionAccumulator(startedAt: now)
        var setup = PlaybackSessionReport.Setup()
        setup.matchContentEnabled = matchContentEnabled
        setup.serverType = MediaServerProvider.active.rawValue
        Self.readEnvironment(into: &setup)
        report = PlaybackSessionReport(
            startedAt: started, updatedAt: started, app: .current, setup: setup,
            media: .init(), totals: .init(), timeline: [], notMeasured: []
        )
        observeAudioRoute()
        updateVideoVisible()
        save(force: true)
    }

    func end(reason: String) {
        guard accumulator != nil else { return }
        accumulator?.ended(reason: reason, at: now)
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        save(force: true)
        accumulator = nil
    }

    // MARK: Inputs from the player

    func updateMedia(_ change: (inout PlaybackSessionReport.Media) -> Void) {
        guard report != nil else { return }
        change(&report!.media)
    }

    func setPlayMethod(_ method: String?) {
        report?.setup.playMethod = AppHealthContextSnapshot.playMethodToken(method)
    }

    func setPlaying(_ playing: Bool) { accumulator?.setPlaying(playing, at: now) }
    func setBuffering(_ buffering: Bool) { accumulator?.setBuffering(buffering, at: now) }
    func seeked() { accumulator?.seeked(at: now) }
    func reloaded() { accumulator?.reloaded(at: now) }
    var isRecording: Bool { accumulator != nil }
    /// Starts a short warm-up for changes that briefly disturb playback:
    /// a display switch starting, a speed change or an audio track switch.
    func settling() { accumulator?.markWarmup(at: now) }

    func displaySwitched() {
        accumulator?.displaySwitched(at: now)
        if var setup = report?.setup {
            Self.readDisplay(into: &setup)
            report?.setup = setup
        }
    }
    func avSync(ms: Double?) { accumulator?.avSync(ms: ms, at: now) }
    func audioFault(_ token: String) { accumulator?.audioFault(token, at: now) }

    /// A once-a-second sample of the player's cumulative counters. Nil means
    /// the player didn't report that counter.
    func sample(dropped: Int?, decoderDropped: Int?, delayed: Int?, networkKbps: Int?, displayFps: Double?) {
        guard accumulator != nil else { return }
        let time = now
        accumulator?.counter(.dropped, value: dropped, at: time)
        accumulator?.counter(.decoderDropped, value: decoderDropped, at: time)
        accumulator?.counter(.delayed, value: delayed, at: time)
        accumulator?.networkKbps(networkKbps)
        if let displayFps, displayFps > 0 { report?.setup.displayRefreshHz = (displayFps * 1000).rounded() / 1000 }
        accumulator?.tick(at: time)
        if time - lastSave >= Self.saveInterval { save() }
    }

    // MARK: Reading back

    /// The latest session, from memory while it runs, otherwise from disk.
    func latest() -> PlaybackSessionReport? {
        if let report, let accumulator { return Self.finish(report, accumulator) }
        return Self.load()
    }

    /// The exact JSON that is sent.
    nonisolated static func encode(_ report: PlaybackSessionReport) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(report)
    }

    // MARK: Building the report

    /// The diagnostics relay accepts up to 128 KB; stay well inside it.
    static let maxEncodedBytes = 60 * 1024

    static func finish(_ report: PlaybackSessionReport, _ accumulator: PlaybackSessionAccumulator) -> PlaybackSessionReport {
        var result = report
        result.updatedAt = Date()
        result.totals = accumulator.totals
        result.timeline = accumulator.timeline
        result.notMeasured = notMeasured(result)
        return bounded(result)
    }

    /// Drops the oldest problem minutes until the record fits. Only a very
    /// long session with many kinds of fault every minute gets near this.
    static func bounded(_ report: PlaybackSessionReport) -> PlaybackSessionReport {
        var result = report
        while !result.timeline.isEmpty, (encode(result)?.count ?? 0) > maxEncodedBytes {
            result.timeline.removeFirst(max(1, result.timeline.count / 8))
        }
        return result
    }

    /// Everything the report couldn't measure, by name, so a missing value
    /// is never mistaken for zero.
    static func notMeasured(_ report: PlaybackSessionReport) -> [String] {
        var missing: [String] = []
        let checks: [(String, Bool)] = [
            ("audio_output", report.setup.audioOutput == nil),
            ("output_channels_available", report.setup.outputChannelsAvailable == nil),
            ("display_hdr", report.setup.displayHDR == nil),
            ("display_refresh_hz", report.setup.displayRefreshHz == nil),
            ("video_codec", report.media.videoCodec == nil),
            ("video_bitrate", report.media.videoBitrateKbps == nil),
            ("content_fps", report.media.contentFps == nil),
            ("audio_output_format", report.media.audioOutputFormat == nil),
            ("dropped_frames", report.totals.droppedFrames == nil),
            ("decoder_dropped_frames", report.totals.decoderDroppedFrames == nil),
            ("delayed_frames", report.totals.delayedFrames == nil),
            ("av_sync", report.totals.maxAvSyncMs == nil),
            ("network_speed", report.totals.lowestNetworkKbps == nil),
        ]
        for (name, isMissing) in checks where isMissing { missing.append(name) }
        if report.setup.audioOutput == "airplay" {
            // AirPlay receivers don't tell the sender which formats they decode.
            missing.append("airplay_receiver_formats")
        }
        return missing
    }

    // MARK: Environment

    private func observeAudioRoute() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in
                let recorder = PlaybackSessionRecorder.shared
                guard recorder.accumulator != nil, var setup = recorder.report?.setup else { return }
                // Category changes are Vivid's own; only count real output changes.
                if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .override {
                    recorder.accumulator?.audioOutputChanged(at: recorder.now)
                }
                Self.readAudio(into: &setup)
                recorder.report?.setup = setup
            }
        }
    }

    private static func readEnvironment(into setup: inout PlaybackSessionReport.Setup) {
        readAudio(into: &setup)
        readDisplay(into: &setup)
    }

    private static func readAudio(into setup: inout PlaybackSessionReport.Setup) {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map(\.portType)
        setup.audioOutput = ports.first.map(audioOutputToken)
        setup.outputChannelsAvailable = session.maximumOutputNumberOfChannels > 0
            ? session.maximumOutputNumberOfChannels : nil
        setup.multichannelSupported = session.supportsMultichannelContent
    }

    private static func readDisplay(into setup: inout PlaybackSessionReport.Setup) {
        let hdr = ApplePlaybackHDRAvailability.probe()
        setup.hdrPlaybackEligible = hdr.hdrPlaybackEligible
        var formats: [String] = []
        if hdr.supportsHDR10 { formats.append("hdr10") }
        if hdr.supportsDolbyVision { formats.append("dolby_vision") }
        if hdr.supportsHLG { formats.append("hlg") }
        setup.displayHDR = formats
        #if os(tvOS)
        setup.systemMatchingEnabled = VividDisplayContext.matchContentEnabled
        #endif
    }

    nonisolated static func audioOutputToken(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .HDMI: "hdmi"
        case .airPlay: "airplay"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: "bluetooth"
        case .builtInSpeaker, .builtInReceiver: "speaker"
        case .headphones: "headphones"
        case .usbAudio: "usb"
        case .carAudio: "car"
        default: "other"
        }
    }

    // MARK: Storage

    private func save(force: Bool = false) {
        guard let report else { return }
        let current = accumulator.map { Self.finish(report, $0) } ?? report
        if accumulator == nil, !force { return }
        lastSave = now
        guard let data = Self.encode(current) else { return }
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            Self.write(data, to: url)
            await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }

    nonisolated static var fileURL: URL {
        #if os(tvOS)
        // tvOS apps can only keep data in Caches.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("LatestPlayback.json")
    }

    nonisolated private static func write(_ data: Data, to url: URL) {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableFolder = folder
        try? mutableFolder.setResourceValues(values)
        #endif
        try? data.write(to: url, options: [.atomic])
    }

    nonisolated static func load() -> PlaybackSessionReport? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let report = try? decoder.decode(PlaybackSessionReport.self, from: data),
              report.format == PlaybackSessionReport.format else { return nil }
        return report
    }
}
#endif
