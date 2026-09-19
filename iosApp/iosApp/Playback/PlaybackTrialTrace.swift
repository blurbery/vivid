// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation
import QuartzCore
import OSLog

/// Monotonic, source-free measurements. A ready player is never counted as a picture.
@MainActor
final class PlaybackTrialTrace {
    private static let log = Logger(subsystem: "com.blurbery.vivid", category: "PlaybackTrial")
    private static var pendingPlay: Double?
    private static weak var active: PlaybackTrialTrace?

    static func controlEvent(_ name: String, fields: String = "") {
        active?.event(name, fields: fields)
    }
    #if VIVID_P8_TRIAL
    private static let recording = P8TrialRecording()
    #endif
    static func requestPlay() { pendingPlay = CACurrentMediaTime() }

    let id = UUID().uuidString
    let started: Double
    private var milestones = Set<String>()
    private var seekStarted: Double?
    private var seekID = 0

    init() {
        started = Self.pendingPlay ?? CACurrentMediaTime()
        let origin = Self.pendingPlay == nil ? "engine_load" : "play_request"
        Self.pendingPlay = nil
        Self.active = self
        let backend = "mpv"
        event("start", fields: "origin=\(origin) engine=\(LucidCore.name) path=\(LucidCore.path) backend=\(backend)")
        mark(origin, at: started)
    }

    func mark(_ name: String, at time: Double = CACurrentMediaTime()) {
        guard time.isFinite, time >= started, milestones.insert(name).inserted else { return }
        event(name, fields: "elapsed_ms=\(Int((time - started) * 1000))")
    }

    func beginSeek(target: Double) {
        if seekStarted != nil { event("seek_superseded", fields: "seek=\(seekID)") }
        seekID += 1
        seekStarted = CACurrentMediaTime()
        event("seek_requested", fields: "seek=\(seekID) target=\(target)")
    }

    func seekPicture() {
        guard let start = seekStarted else { return }
        seekStarted = nil
        event("seek_picture_ready", fields: "seek=\(seekID) elapsed_ms=\(Int((CACurrentMediaTime() - start) * 1000))")
    }

    func endSeek(_ outcome: String) {
        guard seekStarted != nil else { return }
        seekStarted = nil
        event(outcome, fields: "seek=\(seekID)")
    }

    func event(_ name: String, fields: String = "") {
        let fields = "since_start_ms=\(Int((CACurrentMediaTime() - started) * 1000)) " + fields
        Self.log.info("trial session=\(self.id, privacy: .public) event=\(name, privacy: .public) \(fields, privacy: .public)")
        #if VIVID_P8_TRIAL
        Self.recording.append("trial session=\(id) event=\(name) \(fields)\n")
        #endif
    }
}

#if VIVID_P8_TRIAL
/// One bounded, source-free device log for the current test. No work on the media queues.
private final class P8TrialRecording: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.blurbery.vivid.p8-trace", qos: .utility)
    private var handle: FileHandle?
    private var byteCount = 0

    init() {
        Self.queue.async { [self] in
            guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let url = directory.appendingPathComponent("MPVTrial.log")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try FileHandle(forUpdating: url)
                try handle?.truncate(atOffset: 0)
            } catch { handle = nil }
        }
    }

    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        Self.queue.async { [self] in
            do {
                guard let handle else { return }
                if byteCount + data.count > 256 * 1024 {
                    // Keep recent complete lines across title changes without
                    // unbounded logs or I/O on the playback queue.
                    try handle.seek(toOffset: UInt64(max(0, byteCount - 128 * 1024)))
                    let tail = try handle.readToEnd() ?? Data()
                    let retained = tail.firstIndex(of: 10).map { Data(tail.suffix(from: tail.index(after: $0))) } ?? Data()
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: retained)
                    byteCount = retained.count
                }
                try handle.write(contentsOf: data)
                byteCount += data.count
            } catch { handle = nil }
        }
    }
}
#endif
