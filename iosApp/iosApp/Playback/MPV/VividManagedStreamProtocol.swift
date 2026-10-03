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
}

private func reader(_ cookie: UnsafeMutableRawPointer?) -> VividManagedStreamReader? {
    cookie.map { Unmanaged<VividManagedStreamReader>.fromOpaque($0).takeUnretainedValue() }
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
    info.pointee.cookie = Unmanaged.passRetained(stream).toOpaque()
    info.pointee.read_fn = { cookie, buffer, count in
        guard let buffer, let stream = reader(cookie) else { return -1 }
        return stream.read(into: buffer, count: Int(min(count, UInt64(Int32.max))))
    }
    info.pointee.seek_fn = { cookie, offset in
        reader(cookie)?.seek(to: offset) ?? Int64(MPV_ERROR_GENERIC.rawValue)
    }
    info.pointee.size_fn = { cookie in
        reader(cookie)?.size ?? Int64(MPV_ERROR_UNSUPPORTED.rawValue)
    }
    info.pointee.cancel_fn = { cookie in reader(cookie)?.cancel() }
    info.pointee.close_fn = { cookie in
        guard let cookie else { return }
        let stream = Unmanaged<VividManagedStreamReader>.fromOpaque(cookie)
        stream.takeUnretainedValue().cancel()
        stream.release()
    }
    return 0
}
#endif
