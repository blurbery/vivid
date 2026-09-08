// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CVividMedia
import Foundation

public final class VividASSRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.blurbery.vivid.ass", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var image: CGImage?
    public init?(data: Data, document: Bool = true) {
        handle = data.withUnsafeBytes { bytes in
            vv_ass_create(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(bytes.count), document ? 1 : 0)
        }
        if handle == nil { return nil }
    }
    func append(data: UnsafePointer<UInt8>, size: Int32, start: Double, duration: Double) {
        lock.lock(); defer { lock.unlock() }
        vv_ass_chunk(handle, data, size, start, duration)
    }
    func flush() { lock.lock(); defer { lock.unlock() }; vv_ass_flush(handle); image = nil }
    public func render(at seconds: Double, width: Int, height: Int) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        var changed: Int32 = 0
        let output = vv_ass_render(handle, seconds, Int32(width), Int32(height), &changed)?.takeRetainedValue()
        if changed != 0 { image = output }
        return image
    }
    public func image(at seconds: Double, width: Int = 1920, height: Int = 1080) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: render(at: seconds, width: width, height: height)) }
        }
    }
    deinit { vv_ass_free(&handle) }
}
