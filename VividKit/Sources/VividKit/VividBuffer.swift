// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation
import CVividMedia

final class VividPacket: @unchecked Sendable {
    var pointer: UnsafeMutablePointer<AVPacket>?
    var byteCount: Int { Int(pointer?.pointee.size ?? 0) }
    var presentationTime: Double?
    var duration: Double = 0
    init(_ pointer: UnsafeMutablePointer<AVPacket>) { self.pointer = pointer }
    deinit { av_packet_free(&pointer) }
}

final class VividBuffer: @unchecked Sendable {
    private static let maximumTargetSeconds: Double = 40
    private let condition = NSCondition()
    private var packets: [VividPacket] = []
    private var bytes = 0
    private var closed = false
    private var ended = false
    private let byteLimit: Int
    private var targetSeconds: Double
    init(byteLimit: Int, targetSeconds: Double = 10) {
        self.byteLimit = max(1, byteLimit)
        self.targetSeconds = targetSeconds.isFinite ? max(1, min(Self.maximumTargetSeconds, targetSeconds)) : 10
    }
    func setTarget(seconds: Double) {
        guard seconds.isFinite else { return }
        condition.lock(); targetSeconds = max(1, min(Self.maximumTargetSeconds, seconds)); condition.broadcast(); condition.unlock()
    }
    private var span: Double {
        guard let first = packets.first?.presentationTime, let last = packets.last,
              let end = last.presentationTime else { return 0 }
        return max(0, end + last.duration - first)
    }
    var bufferedSeconds: Double {
        condition.lock(); defer { condition.unlock() }
        return span
    }
    func put(_ packet: VividPacket) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while !closed && !ended && !packets.isEmpty &&
                (bytes + packet.byteCount > byteLimit || packets.count >= 2048 || span >= targetSeconds) {
            condition.wait()
        }
        guard !closed, !ended else { return false }
        packets.append(packet)
        bytes += packet.byteCount
        condition.broadcast()
        return true
    }
    func take() -> VividPacket? {
        condition.lock(); defer { condition.unlock() }
        while packets.isEmpty && !closed && !ended { condition.wait() }
        guard !closed, !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        bytes -= packet.byteCount
        condition.broadcast()
        return packet
    }
    func finish() {
        condition.lock(); ended = true; condition.broadcast(); condition.unlock()
    }
    func cancel() {
        condition.lock()
        closed = true
        packets.removeAll()
        bytes = 0
        condition.broadcast()
        condition.unlock()
    }
    func reset() {
        condition.lock()
        packets.removeAll(); bytes = 0; closed = false; ended = false
        condition.broadcast(); condition.unlock()
    }
}
