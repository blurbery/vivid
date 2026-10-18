// SPDX-License-Identifier: GPL-3.0-only
// Additional permission applies to Vivid's adapter only: LICENSE-APPLE-EXCEPTION.
#if (os(tvOS) || os(iOS))
import Foundation
import Libmpv

/// Lucid's `vividstream://` protocol. Each load registers its source under a
/// random identifier; Lucid opens it through these callbacks, which must never
/// call back into libmpv.
enum VividManagedStreamProtocol {
    static let scheme = "vividstream"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sources: [String: VividManagedStreamSource] = [:]

    /// Experimental: on unless explicitly turned off, so a build can fall
    /// back to Lucid's own HTTP reader without code changes.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "vivid.experiment.managedStreamReader") as? Bool ?? true
    }

    static func register(on mpv: OpaquePointer) -> Bool {
        mpv_stream_cb_add_ro(mpv, scheme, nil, openStream) >= 0
    }

    static func add(_ source: VividManagedStreamSource) -> URL? {
        let id = UUID().uuidString.lowercased()
        lock.lock(); sources[id] = source; lock.unlock()
        let ext = source.url.pathExtension
        let name = !ext.isEmpty && ext.allSatisfy { $0.isLetter || $0.isNumber } ? "media.\(ext)" : "media"
        return URL(string: "\(scheme)://\(id)/\(name)")
    }

    static func remove(_ url: URL?) {
        guard let id = url?.host else { return }
        lock.lock(); sources[id] = nil; lock.unlock()
    }

    fileprivate static func source(for uri: String) -> VividManagedStreamSource? {
        guard let id = URL(string: uri)?.host else { return nil }
        lock.lock(); defer { lock.unlock() }
        return sources[id]
    }

    // MARK: Open streams

    /// Open readers by the cookie Lucid passes to the stream callbacks. Lucid
    /// detaches a stream's cancel callback only after `close_fn` returns, so a
    /// player teardown on another thread can still cancel a stream it has
    /// just closed. The cookie is therefore a number that is never reused,
    /// not the reader's address, and a late cancel finds nothing.
    nonisolated(unsafe) private static var readers: [UInt: VividManagedStreamReader] = [:]
    nonisolated(unsafe) private static var lastCookie: UInt = 0

    /// Keeps `reader` until `close` and returns its cookie.
    static func track(_ reader: VividManagedStreamReader) -> UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        lastCookie += 1
        readers[lastCookie] = reader
        return UnsafeMutableRawPointer(bitPattern: lastCookie)
    }

    /// The reader for `cookie`, or nil once it is closed.
    static func reader(for cookie: UnsafeMutableRawPointer?) -> VividManagedStreamReader? {
        lock.lock(); defer { lock.unlock() }
        return readers[UInt(bitPattern: cookie)]
    }

    /// Ends the reader for `cookie` and lets it go.
    static func close(_ cookie: UnsafeMutableRawPointer?) {
        lock.lock()
        let reader = readers.removeValue(forKey: UInt(bitPattern: cookie))
        lock.unlock()
        reader?.cancel()
    }
}

private let openStream: mpv_stream_cb_open_ro_fn = { _, uri, info in
    guard let uri, let info, let source = VividManagedStreamProtocol.source(for: String(cString: uri)) else {
        return MPV_ERROR_LOADING_FAILED.rawValue
    }
    let stream = VividManagedStreamReader(source: source)
    guard stream.open() else {
        stream.cancel()
        return MPV_ERROR_LOADING_FAILED.rawValue
    }
    info.pointee.cookie = VividManagedStreamProtocol.track(stream)
    info.pointee.read_fn = { cookie, buffer, count in
        guard let buffer, let stream = VividManagedStreamProtocol.reader(for: cookie) else { return -1 }
        return stream.read(into: buffer, count: Int(min(count, UInt64(Int32.max))))
    }
    info.pointee.seek_fn = { cookie, offset in
        VividManagedStreamProtocol.reader(for: cookie)?.seek(to: offset) ?? Int64(MPV_ERROR_GENERIC.rawValue)
    }
    info.pointee.size_fn = { cookie in
        VividManagedStreamProtocol.reader(for: cookie)?.size ?? Int64(MPV_ERROR_UNSUPPORTED.rawValue)
    }
    info.pointee.cancel_fn = { cookie in VividManagedStreamProtocol.reader(for: cookie)?.cancel() }
    info.pointee.close_fn = { cookie in VividManagedStreamProtocol.close(cookie) }
    return 0
}
#endif
