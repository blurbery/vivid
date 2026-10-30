#if os(tvOS)
import Foundation
import os
import QuartzCore

/// Reports late frames, and a summary every ten seconds, to the unified log
/// and standard error. Runs only when the app is launched with
/// `-perfHitchLog`.
@MainActor
final class TVFrameHitchMonitor {
    private static var running: TVFrameHitchMonitor?
    private static let logger = Logger(subsystem: "com.vivid.app", category: "perf.hitch")

    private let createdAt = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var lateTotal: CFTimeInterval = 0
    private var worstLateness: CFTimeInterval = 0

    private init() {}

    static func installIfRequested() {
        guard CommandLine.arguments.contains("-perfHitchLog") else { return }
        let monitor = running ?? TVFrameHitchMonitor()
        running = monitor
        monitor.start()
    }

    private func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: FrameTarget { [unowned self] in self.frameArrived($0) },
                                 selector: #selector(FrameTarget.fire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        emit("monitor started")
    }

    private func frameArrived(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { self.previousTimestamp = now }
        guard let previous = previousTimestamp else {
            windowStart = now
            return
        }
        let target = link.targetTimestamp
        let period = target - now > 0 ? target - now : 1.0 / 60
        let interval = now - previous
        frames += 1
        let lateness = max(interval - period, CACurrentMediaTime() - target)
        if lateness > period / 2 {
            hitches += 1
            lateTotal += lateness
            worstLateness = max(worstLateness, lateness)
            emit("hitch \(Self.decimal(lateness * 1000)) ms late (interval \(Self.decimal(interval * 1000)) ms)")
        }
        if now - windowStart >= 10 {
            let seconds = Int(now - windowStart)
            emit("summary \(seconds)s: \(frames) frames, \(hitches) hitches, "
                + "\(Self.decimal(lateTotal * 1000)) ms late total, worst \(Self.decimal(worstLateness * 1000)) ms")
            windowStart = now
            frames = 0
            hitches = 0
            lateTotal = 0
            worstLateness = 0
        }
    }

    private func emit(_ message: String) {
        let line = "t+\(Self.decimal(CACurrentMediaTime() - createdAt))s " + message
        Self.logger.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data("[perf.hitch] \(line)\n".utf8))
    }

    /// One decimal place with a full stop, whatever the locale.
    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// The display link's target, so the monitor itself needn't be an
    /// Objective-C class.
    @MainActor
    private final class FrameTarget: NSObject {
        private let onFrame: @MainActor (CADisplayLink) -> Void

        init(_ onFrame: @escaping @MainActor (CADisplayLink) -> Void) {
            self.onFrame = onFrame
        }

        @objc func fire(_ link: CADisplayLink) {
            onFrame(link)
        }
    }
}
#endif
