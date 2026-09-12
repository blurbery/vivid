import Foundation
import Darwin

/// Access is serialised by the listener's state lock.
struct HLSConnectionRegistry {
    private var descriptors = Set<Int32>()
    let limit: Int
    init(limit: Int = 32) { self.limit = limit }
    var count: Int { descriptors.count }

    mutating func insert(_ fd: Int32) -> Bool {
        guard descriptors.count < limit else { return false }
        return descriptors.insert(fd).inserted
    }

    mutating func remove(_ fd: Int32) { descriptors.remove(fd) }
    mutating func removeAll() -> Set<Int32> {
        let result = descriptors
        descriptors.removeAll()
        return result
    }
}

/// Bounds incomplete headers by elapsed time, even when a peer trickles bytes.
/// Authenticated keep-alive connections retain their longer idle allowance.
enum HLSRequestReader {
    static func read(
        fd: Int32, acceptedAt: TimeInterval?,
        headerTimeout: TimeInterval = 10, idleTimeout: TimeInterval = 60,
        maximumBytes: Int = 8192
    ) -> Data? {
        let now = { ProcessInfo.processInfo.systemUptime }
        var deadline = acceptedAt.map { $0 + headerTimeout } ?? (now() + idleTimeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let terminator = Data([13, 10, 13, 10])
        while true {
            let remaining = deadline - now()
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, now() < deadline else { return nil }
            // Nonblocking recv keeps the absolute deadline authoritative even
            // if a readiness notification no longer has readable bytes.
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count > 0 else { return nil }
            if buffer.isEmpty, acceptedAt == nil { deadline = now() + headerTimeout }
            buffer.append(contentsOf: chunk.prefix(count))
            if let range = buffer.range(of: terminator) {
                guard range.upperBound <= maximumBytes else { return nil }
                return buffer.prefix(range.upperBound)
            }
            guard buffer.count < maximumBytes else { return nil }
        }
    }
}
