// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS)
import Foundation
import QuartzCore
import OSLog

/// Monotonic, source-free measurements. A ready player is never counted as a picture.
@MainActor
final class PlaybackTrialTrace {
    private static let log = Logger(subsystem: "com.blurbery.vivid", category: "PlaybackTrial")
    private static var pendingPlay: Double?
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
        event("start", fields: "origin=\(origin) engine=\(LucidCore.name) path=\(LucidCore.path) backend=KSPlayerGPL")
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
        Self.log.info("trial session=\(self.id, privacy: .public) event=\(name, privacy: .public) \(fields, privacy: .public)")
    }
}
#endif
