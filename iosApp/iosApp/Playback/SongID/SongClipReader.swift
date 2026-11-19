import Foundation
import os
import VividAudioClipC

/// A few seconds of a file's sound, mixed to mono at 48 kHz.
struct SongClip: Sendable {
    static let sampleRate = Double(VIVID_AUDIO_CLIP_SAMPLE_RATE)

    /// Every channel mixed to one.
    let mix: [Float]
    /// The same without the centre channel, where a film keeps its
    /// dialogue. Nil when the sound has no centre channel.
    let music: [Float]?
    /// When the first sample plays, on the player's clock.
    let startSeconds: Double

    var duration: Double { Double(mix.count) / Self.sampleRate }
}

/// Why a clip couldn't be read.
enum SongClipError: Error, Equatable, Sendable {
    /// `cancel()` stopped it.
    case cancelled
    /// The server or the device didn't give the bytes just now.
    case unreachable
    /// Reading the clip would have taken more than its budget.
    case tooCostly
    /// The file, its container, its sound stream or its codec can't be
    /// read for a clip.
    case unreadable
    /// There is no sound at the time asked for.
    case noSound
}

/// Reads clips of sound from one file, one request at a time, on its own
/// queue at utility priority: the reads block, and must never hold up the
/// player or the shared thread pool.
final class SongClipReader: @unchecked Sendable {
    /// The most opening the file may read, and one clip may read.
    static let openByteLimit: Int64 = 16 * 1024 * 1024
    static let clipByteLimit: Int64 = 128 * 1024 * 1024

    private let source: StillByteSource
    private let streamIndex: Int?
    private let queue = DispatchQueue(label: "vivid.song-clip-reader", qos: .utility)
    private let link: CallbackLink
    /// Only touched on `queue`.
    private var handle: OpaquePointer?
    private var openFailure: SongClipError?

    /// - Parameter streamIndex: the container's index of the sound stream
    ///   to read, as mpv's `ff-index` gives it, or nil for the file's
    ///   default sound.
    init(source: StillByteSource, streamIndex: Int?) {
        self.source = source
        self.streamIndex = streamIndex
        link = CallbackLink(source: source)
    }

    deinit {
        // Nothing else can be using the handle once the last reference
        // has gone.
        if let handle { vivid_audio_clip_close(handle) }
    }

    /// Bytes read so far, in total.
    var bytesRead: Int { link.bytes.withLock { $0 } }

    /// Stops the read in flight at once, and every read after it.
    func cancel() {
        link.isAborted.withLock { $0 = true }
        source.cancel()
    }

    /// `duration` seconds of sound from `start` on the player's clock. A
    /// clip that starts where the last one ended carries on from there.
    func clip(from start: Double, duration: Double) async throws -> SongClip {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try readClip(from: start, duration: duration) })
            }
        }
    }

    // MARK: - On the queue

    private func readClip(from start: Double, duration: Double) throws -> SongClip {
        if link.isAborted.withLock({ $0 }) { throw SongClipError.cancelled }
        let opened = try openIfNeeded()
        var samples = VividAudioClipSamples()
        let code = vivid_audio_clip_read(opened, max(start, 0), duration, Self.clipByteLimit, &samples)
        defer { vivid_audio_clip_samples_free(&samples) }
        guard code == VIVID_AUDIO_CLIP_OK else { throw failure(for: code) }
        let count = Int(samples.count)
        guard count > 0, let mix = samples.mix else { throw SongClipError.noSound }
        return SongClip(mix: Array(UnsafeBufferPointer(start: mix, count: count)),
                        music: samples.music.map { Array(UnsafeBufferPointer(start: $0, count: count)) },
                        startSeconds: samples.start_seconds)
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let handle { return handle }
        // A file that can't be read for a clip won't become readable.
        if let openFailure { throw openFailure }
        var callbacks = VividAudioClipCallbacks(context: Unmanaged.passUnretained(link).toOpaque(), read: readCallback,
                                                size: sizeCallback, aborted: abortedCallback)
        var opened: OpaquePointer?
        let code = vivid_audio_clip_open(&callbacks, Self.openByteLimit, Int32(streamIndex ?? -1), &opened)
        guard code == VIVID_AUDIO_CLIP_OK, let opened else {
            let error = failure(for: code)
            if error == .unreadable { openFailure = error }
            throw error
        }
        handle = opened
        return opened
    }

    private func failure(for code: Int32) -> SongClipError {
        if link.isAborted.withLock({ $0 }) { return .cancelled }
        switch Int(code) {
        case VIVID_AUDIO_CLIP_ERROR_ABORTED: return .cancelled
        case VIVID_AUDIO_CLIP_ERROR_READ, VIVID_AUDIO_CLIP_ERROR_MEMORY:
            // A server that won't serve ranges never will.
            return source.isPermanentlyUnusable ? .unreadable : .unreachable
        case VIVID_AUDIO_CLIP_ERROR_OPEN_TOO_COSTLY, VIVID_AUDIO_CLIP_ERROR_OVER_BYTE_LIMIT: return .tooCostly
        case VIVID_AUDIO_CLIP_ERROR_DATA, VIVID_AUDIO_CLIP_ERROR_SEEK: return .noSound
        default: return .unreadable
        }
    }
}

/// What the C callbacks reach through their context pointer. Reads only
/// happen on the reader's queue; the abort flag is set from anywhere.
private final class CallbackLink: @unchecked Sendable {
    let source: StillByteSource
    let isAborted = OSAllocatedUnfairLock(initialState: false)
    let bytes = OSAllocatedUnfairLock(initialState: 0)

    init(source: StillByteSource) {
        self.source = source
    }
}

private let readCallback: VividAudioClipReadCallback = { context, buffer, size, offset in
    guard let context, let buffer, size > 0 else { return -1 }
    let link = Unmanaged<CallbackLink>.fromOpaque(context).takeUnretainedValue()
    do {
        let count = try link.source.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: Int(size)), offset: offset)
        guard count >= 0, count <= Int(size) else { return -1 }
        link.bytes.withLock { $0 += count }
        return Int32(count)
    } catch {
        return -1
    }
}

private let sizeCallback: VividAudioClipSizeCallback = { context in
    guard let context else { return -1 }
    return Unmanaged<CallbackLink>.fromOpaque(context).takeUnretainedValue().source.size ?? -1
}

private let abortedCallback: VividAudioClipAbortedCallback = { context in
    guard let context else { return 1 }
    return Unmanaged<CallbackLink>.fromOpaque(context).takeUnretainedValue().isAborted.withLock { $0 } ? 1 : 0
}
