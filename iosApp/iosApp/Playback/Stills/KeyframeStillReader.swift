import CoreGraphics
import Foundation
import os
import VividStillC

/// One keyframe in the container's index.
struct KeyframeIndexEntry: Equatable, Sendable {
    /// Seconds from the start of the stream. MP4 records decode times, so
    /// with reordered frames this can be a few frames before the still's
    /// own time.
    let time: Double
    let bytePosition: Int64
    /// Nil when the container doesn't record it (Matroska).
    let size: Int?
}

/// What the file says about its video, for callers deciding whether to
/// make stills from it at all.
struct KeyframeStillInfo: Equatable, Sendable {
    enum Transfer: Sendable { case unknown, sdr, pq, hlg }
    enum Primaries: Sendable { case unknown, bt709, bt601, bt2020, p3 }
    enum Matrix: Sendable { case unknown, bt709, bt601, bt2020, other }
    enum Range: Sendable { case unknown, limited, full }

    /// Nil when the container doesn't say.
    let duration: Double?
    /// The stream's first timestamp. Still and index times count from it.
    let startTime: Double
    let codedWidth: Int
    let codedHeight: Int
    let sampleAspectNumerator: Int
    let sampleAspectDenominator: Int
    /// Clockwise quarter turns for display: 0, 90, 180 or 270. Stills come
    /// back already turned.
    let rotationDegrees: Int
    let codecName: String
    let bitDepth: Int?
    let transfer: Transfer
    let primaries: Primaries
    let matrix: Matrix
    let range: Range
    let dolbyVisionProfile: Int?
    /// 0 means the picture only makes sense with the Dolby Vision metadata
    /// applied, as in profile 5.
    let dolbyVisionCompatibility: Int
    /// True when the container's keyframe index covers the file.
    let hasKeyframeIndex: Bool
    let keyframeCount: Int
    /// Bytes read to open the file and its index.
    let bytesReadToOpen: Int

    /// False for Dolby Vision with no HDR10, HLG or SDR base picture: its
    /// colours can't be shown without the metadata, so no still is made.
    var canProduceStills: Bool {
        dolbyVisionProfile == nil || dolbyVisionCompatibility != 0
    }
}

struct KeyframeStill: @unchecked Sendable {
    let image: CGImage
    /// The keyframe's own time, in seconds from the start of the stream.
    let time: Double
    /// What the demuxer read for this still, and in how many reads.
    let bytesRead: Int
    let readCount: Int
    /// The size of the keyframe itself.
    let keyframeBytes: Int
    /// 1 unless the keyframe alone didn't give a picture.
    let packetsDecoded: Int
    let elapsed: TimeInterval
}

/// Makes stills from a file's keyframes: one small read and one frame
/// decoded for each.
///
/// All the work happens on the reader's own thread, one job at a time, at
/// utility priority unless a job is marked urgent. A thread rather than a
/// dispatch queue, so the priority is the app's choice and a blocking read
/// never ties up a shared pool.
final class KeyframeStillReader: Sendable {
    private let worker: Worker

    /// - Parameters:
    ///   - nameHint: a bare file name such as `film.mkv`, used only
    ///     to help recognise the container. Never a whole address.
    ///   - stillByteLimit: the most one still may read before it is given
    ///     up. A keyframe is far smaller, but the last keyframe in a
    ///     Matroska index makes the demuxer read to the end of the file.
    init(source: StillByteSource, nameHint: String? = nil, stillByteLimit: Int = 6 * 1024 * 1024) {
        worker = Worker(source: source, nameHint: nameHint, stillByteLimit: stillByteLimit)
    }

    deinit {
        worker.requestShutdown()
    }

    /// Set once the file has been opened.
    var info: KeyframeStillInfo? { worker.published.info }
    /// The container's keyframes in time order. Empty until the file has
    /// been opened, and for containers without an index.
    var index: [KeyframeIndexEntry] { worker.published.index }

    /// Opens the file if it isn't open. Nil when it can't be read.
    func prepare() async -> KeyframeStillInfo? {
        await worker.prepare()
    }

    /// The keyframe at or before `seconds`, no wider than `maxWidth`. Only
    /// one request waits at a time: a newer one replaces it, and the older
    /// caller gets nil.
    func still(at seconds: Double, maxWidth: Int, urgent: Bool = false) async -> KeyframeStill? {
        await worker.still(at: seconds, maxWidth: maxWidth, urgent: urgent)
    }

    /// Stops the job that is running now, which then returns nil. A job
    /// that is waiting still runs.
    func cancelCurrent() {
        worker.cancelCurrent()
    }

    /// Frees the decoder once the reader is idle. The file and its index
    /// stay open, and the next still makes the decoder again.
    func closeDecoder() {
        worker.closeDecoder()
    }

    /// Stops everything and closes the file. Stills asked for afterwards
    /// return nil.
    func shutdown() async {
        await worker.shutdown()
    }
}

/// What the C callbacks reach through their context pointer.
private final class CallbackLink: @unchecked Sendable {
    let source: StillByteSource
    let isAborted = OSAllocatedUnfairLock(initialState: false)
    /// Only touched on the reader's thread.
    var bytes = 0
    var reads = 0

    init(source: StillByteSource) {
        self.source = source
    }
}

private let readCallback: VividStillReadCallback = { context, buffer, size, offset in
    guard let context, let buffer, size > 0 else { return -1 }
    let link = Unmanaged<CallbackLink>.fromOpaque(context).takeUnretainedValue()
    do {
        let count = try link.source.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: Int(size)), offset: offset)
        guard count >= 0, count <= Int(size) else { return -1 }
        link.bytes += count
        link.reads += 1
        return Int32(count)
    } catch {
        return -1
    }
}

private let sizeCallback: VividStillSizeCallback = { context in
    guard let context else { return -1 }
    return Unmanaged<CallbackLink>.fromOpaque(context).takeUnretainedValue().source.size ?? -1
}

private let abortedCallback: VividStillAbortedCallback = { context in
    guard let context else { return 1 }
    return Unmanaged<CallbackLink>.fromOpaque(context).takeUnretainedValue().isAborted.withLock { $0 } ? 1 : 0
}

private final class Worker: @unchecked Sendable {
    struct Published {
        var info: KeyframeStillInfo?
        var index: [KeyframeIndexEntry] = []
    }

    private struct StillJob {
        let seconds: Double
        let maxWidth: Int
        let urgent: Bool
        let continuation: CheckedContinuation<KeyframeStill?, Never>
    }

    private let link: CallbackLink
    private let nameHint: String?
    private let stillByteLimit: Int

    /// Guards everything down to `raisedPriority`.
    private let state = NSCondition()
    private var thread: Thread?
    private var threadHandle: pthread_t?
    private var waiting: StillJob?
    private var opening: [CheckedContinuation<KeyframeStillInfo?, Never>] = []
    private var closing: [CheckedContinuation<Void, Never>] = []
    private var wantsDecoderClosed = false
    private var isShuttingDown = false
    private var hasShutDown = false
    private var isRunningJob = false
    private var runningIsUrgent = false
    private var shared = Published()
    /// Held while an urgent still waits or runs, so the thread works at the
    /// viewer's priority for exactly that long.
    private var raisedPriority: pthread_override_t?

    /// Only touched on the reader's thread.
    private var handle: OpaquePointer?
    private var info: KeyframeStillInfo?
    /// Set when the file turned out not to be readable, so it isn't opened
    /// again for every still.
    private var cannotOpen = false

    init(source: StillByteSource, nameHint: String?, stillByteLimit: Int) {
        link = CallbackLink(source: source)
        self.nameHint = nameHint
        self.stillByteLimit = stillByteLimit
    }

    var published: Published {
        state.withLock { shared }
    }

    // MARK: - Requests

    func prepare() async -> KeyframeStillInfo? {
        await withCheckedContinuation { continuation in
            state.lock()
            if isShuttingDown || hasShutDown {
                state.unlock()
                continuation.resume(returning: nil)
                return
            }
            opening.append(continuation)
            startThreadIfNeeded()
            state.signal()
            state.unlock()
        }
    }

    func still(at seconds: Double, maxWidth: Int, urgent: Bool) async -> KeyframeStill? {
        guard seconds.isFinite, maxWidth > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            state.lock()
            if isShuttingDown || hasShutDown {
                state.unlock()
                continuation.resume(returning: nil)
                return
            }
            let replaced = waiting
            waiting = StillJob(seconds: seconds, maxWidth: maxWidth, urgent: urgent, continuation: continuation)
            startThreadIfNeeded()
            matchPriority()
            state.signal()
            state.unlock()
            replaced?.continuation.resume(returning: nil)
        }
    }

    func cancelCurrent() {
        state.withLock {
            guard isRunningJob else { return }
            link.isAborted.withLock { $0 = true }
            link.source.cancel()
        }
    }

    func closeDecoder() {
        state.withLock {
            guard thread != nil, !isShuttingDown else { return }
            wantsDecoderClosed = true
            state.signal()
        }
    }

    func shutdown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.lock()
            if hasShutDown || thread == nil {
                hasShutDown = true
                state.unlock()
                continuation.resume()
                return
            }
            closing.append(continuation)
            beginShutdown()
            state.unlock()
        }
    }

    /// Shutdown without waiting, for when the reader is simply let go.
    func requestShutdown() {
        state.withLock {
            guard !hasShutDown else { return }
            if thread == nil {
                hasShutDown = true
            } else {
                beginShutdown()
            }
        }
    }

    /// Call with `state` held.
    private func beginShutdown() {
        isShuttingDown = true
        if isRunningJob {
            link.isAborted.withLock { $0 = true }
            link.source.cancel()
        }
        state.signal()
    }

    /// Call with `state` held.
    private func startThreadIfNeeded() {
        guard thread == nil else { return }
        let thread = Thread { [self] in run() }
        thread.name = "Vivid still reader"
        thread.qualityOfService = .utility
        // Software decoders want more than a secondary thread's default
        // half megabyte.
        thread.stackSize = 2 * 1024 * 1024
        self.thread = thread
        thread.start()
    }

    /// Call with `state` held. Raises the thread while an urgent still
    /// waits or runs and lets it drop back afterwards.
    private func matchPriority() {
        let wanted = waiting?.urgent == true || (isRunningJob && runningIsUrgent)
        if wanted, raisedPriority == nil, let threadHandle {
            raisedPriority = pthread_override_qos_class_start_np(threadHandle, QOS_CLASS_USER_INITIATED, 0)
        } else if !wanted, let raised = raisedPriority {
            pthread_override_qos_class_end_np(raised)
            raisedPriority = nil
        }
    }

    // MARK: - The reader's thread

    private func run() {
        state.lock()
        threadHandle = pthread_self()
        matchPriority()
        while !isShuttingDown {
            if !opening.isEmpty {
                let waiters = opening
                opening = []
                beginJob(urgent: false)
                state.unlock()
                let info = openIfNeeded()
                state.lock()
                endJob()
                waiters.forEach { $0.resume(returning: info) }
            } else if let job = waiting {
                waiting = nil
                beginJob(urgent: job.urgent)
                state.unlock()
                let still = makeStill(job)
                state.lock()
                endJob()
                job.continuation.resume(returning: still)
            } else if wantsDecoderClosed {
                wantsDecoderClosed = false
                state.unlock()
                if let handle { vivid_still_close_decoder(handle) }
                state.lock()
            } else {
                state.wait()
            }
        }
        let stale = waiting
        waiting = nil
        let openers = opening
        opening = []
        matchPriority()
        state.unlock()

        stale?.continuation.resume(returning: nil)
        openers.forEach { $0.resume(returning: nil) }
        if let handle { vivid_still_close(handle) }
        handle = nil

        state.lock()
        hasShutDown = true
        threadHandle = nil
        thread = nil
        let waiters = closing
        closing = []
        state.unlock()
        waiters.forEach { $0.resume() }
    }

    /// Call with `state` held.
    private func beginJob(urgent: Bool) {
        isRunningJob = true
        runningIsUrgent = urgent
        // A cancel is for the job that was running when it was asked for,
        // never the next one.
        link.isAborted.withLock { $0 = false }
        link.source.resume()
        matchPriority()
    }

    /// Call with `state` held.
    private func endJob() {
        isRunningJob = false
        runningIsUrgent = false
        matchPriority()
    }

    private func openIfNeeded() -> KeyframeStillInfo? {
        if let info { return info }
        guard !cannotOpen else { return nil }
        link.bytes = 0
        link.reads = 0
        var callbacks = VividStillCallbacks(context: Unmanaged.passUnretained(link).toOpaque(), read: readCallback,
                                            size: sizeCallback, aborted: abortedCallback)
        var opened: OpaquePointer?
        let code = if let nameHint {
            nameHint.withCString { vivid_still_open(&callbacks, $0, &opened) }
        } else {
            vivid_still_open(&callbacks, nil, &opened)
        }
        guard code == VIVID_STILL_OK, let opened else {
            // A cancelled open can be tried again. Anything else can't get
            // better.
            if code != VIVID_STILL_ERROR_ABORTED { cannotOpen = true }
            return nil
        }
        var raw = VividStillInfo()
        guard vivid_still_get_info(opened, &raw) == VIVID_STILL_OK else {
            vivid_still_close(opened)
            cannotOpen = true
            return nil
        }
        let count = Int(vivid_still_index_count(opened))
        var entries: [KeyframeIndexEntry] = []
        entries.reserveCapacity(count)
        for position in 0..<count {
            var entry = VividStillIndexEntry()
            guard vivid_still_index_entry(opened, Int32(position), &entry) == VIVID_STILL_OK else { break }
            entries.append(KeyframeIndexEntry(time: entry.time_seconds, bytePosition: entry.byte_position,
                                              size: entry.size > 0 ? Int(entry.size) : nil))
        }
        let read = Self.info(from: raw, codecName: String(cString: vivid_still_codec_name(opened)), bytesRead: link.bytes)
        handle = opened
        info = read
        state.withLock { shared = Published(info: read, index: entries) }
        return read
    }

    private func makeStill(_ job: StillJob) -> KeyframeStill? {
        let started = ProcessInfo.processInfo.systemUptime
        guard let info = openIfNeeded(), let handle, info.canProduceStills else { return nil }
        link.bytes = 0
        link.reads = 0
        var picture = VividStillPicture()
        defer { vivid_still_picture_free(&picture) }
        let width = Int32(clamping: job.maxWidth)
        guard vivid_still_decode(handle, job.seconds, width, Int32(VIVID_STILL_LAYOUT_AUTO), Int64(stillByteLimit), &picture) == VIVID_STILL_OK,
              let image = Self.image(from: picture, rotation: info.rotationDegrees)
        else { return nil }
        link.source.noteKeyframeSize(Int(picture.packet_bytes))
        return KeyframeStill(image: image, time: picture.time_seconds, bytesRead: link.bytes, readCount: link.reads,
                             keyframeBytes: Int(picture.packet_bytes), packetsDecoded: Int(picture.packets_decoded),
                             elapsed: ProcessInfo.processInfo.systemUptime - started)
    }

    // MARK: - Conversions

    private static func info(from raw: VividStillInfo, codecName: String, bytesRead: Int) -> KeyframeStillInfo {
        let transfer: KeyframeStillInfo.Transfer = switch Int(raw.transfer) {
        case Int(VIVID_STILL_TRANSFER_SDR): .sdr
        case Int(VIVID_STILL_TRANSFER_PQ): .pq
        case Int(VIVID_STILL_TRANSFER_HLG): .hlg
        default: .unknown
        }
        let primaries: KeyframeStillInfo.Primaries = switch Int(raw.primaries) {
        case Int(VIVID_STILL_PRIMARIES_BT709): .bt709
        case Int(VIVID_STILL_PRIMARIES_BT601): .bt601
        case Int(VIVID_STILL_PRIMARIES_BT2020): .bt2020
        case Int(VIVID_STILL_PRIMARIES_P3): .p3
        default: .unknown
        }
        let matrix: KeyframeStillInfo.Matrix = switch Int(raw.matrix) {
        case Int(VIVID_STILL_MATRIX_BT709): .bt709
        case Int(VIVID_STILL_MATRIX_BT601): .bt601
        case Int(VIVID_STILL_MATRIX_BT2020): .bt2020
        case Int(VIVID_STILL_MATRIX_OTHER): .other
        default: .unknown
        }
        let range: KeyframeStillInfo.Range = switch Int(raw.range) {
        case Int(VIVID_STILL_RANGE_LIMITED): .limited
        case Int(VIVID_STILL_RANGE_FULL): .full
        default: .unknown
        }
        return KeyframeStillInfo(
            duration: raw.duration_seconds > 0 ? raw.duration_seconds : nil,
            startTime: raw.start_seconds,
            codedWidth: Int(raw.width), codedHeight: Int(raw.height),
            sampleAspectNumerator: Int(raw.sample_aspect_numerator),
            sampleAspectDenominator: Int(raw.sample_aspect_denominator),
            rotationDegrees: Int(raw.rotation_degrees),
            codecName: codecName,
            bitDepth: raw.bit_depth > 0 ? Int(raw.bit_depth) : nil,
            transfer: transfer, primaries: primaries, matrix: matrix, range: range,
            dolbyVisionProfile: raw.dolby_vision_profile > 0 ? Int(raw.dolby_vision_profile) : nil,
            dolbyVisionCompatibility: Int(raw.dolby_vision_compatibility),
            hasKeyframeIndex: raw.has_index != 0, keyframeCount: Int(raw.index_count),
            bytesReadToOpen: bytesRead)
    }

    private static func image(from picture: VividStillPicture, rotation: Int) -> CGImage? {
        let width = Int(picture.width), height = Int(picture.height), stride = Int(picture.stride)
        guard let pixels = picture.pixels, width > 0, height > 0, stride > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let bytes: Data
        let bytesPerRow: Int
        let layout: CGBitmapInfo
        if Int(picture.layout) == Int(VIVID_STILL_LAYOUT_RGBA16) {
            let transfer: StillToneMapper.Transfer = switch Int(picture.transfer) {
            case Int(VIVID_STILL_TRANSFER_PQ): .pq
            case Int(VIVID_STILL_TRANSFER_HLG): .hlg
            default: .sdr
            }
            // HDR video without a primaries tag is BT.2020 in practice.
            let primaries: StillToneMapper.Primaries = switch Int(picture.primaries) {
            case Int(VIVID_STILL_PRIMARIES_BT709), Int(VIVID_STILL_PRIMARIES_BT601): .bt709
            case Int(VIVID_STILL_PRIMARIES_P3): .p3
            default: transfer == .sdr ? .bt709 : .bt2020
            }
            let source = UnsafeRawBufferPointer(start: pixels, count: stride * height)
            guard let mapped = StillToneMapper.map(rgba16: source, width: width, height: height, bytesPerRow: stride,
                                                   transfer: transfer, primaries: primaries)
            else { return nil }
            bytes = Data(mapped)
            bytesPerRow = width * 4
            layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        } else {
            guard stride >= width * 4 else { return nil }
            bytes = Data(bytes: pixels, count: stride * height)
            bytesPerRow = stride
            // Blue, green, red, unused: a little-endian 32-bit pixel with
            // the unused byte first.
            layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: space, bitmapInfo: layout, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return turned(image, clockwise: rotation, space: space) ?? image
    }

    /// Redraws a picture turned by quarter turns, as phone footage asks.
    /// Nil when no turn is needed or the drawing can't be made.
    private static func turned(_ image: CGImage, clockwise degrees: Int, space: CGColorSpace) -> CGImage? {
        guard [90, 180, 270].contains(degrees) else { return nil }
        let sideways = degrees != 180
        let width = sideways ? image.height : image.width
        let height = sideways ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // The drawing space has y pointing up, where a positive angle turns
        // anticlockwise.
        context.rotate(by: -CGFloat(degrees) * .pi / 180)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }
}
