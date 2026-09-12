import Foundation
import Darwin

@main
enum AetherSecurityChecks {
    static func main() throws {
        // A test failure must not leave a local or CI socket check running.
        alarm(20)
        defer { alarm(0) }
        try playlists()
        try headers()
        var connections = HLSConnectionRegistry(limit: 3)
        precondition(connections.insert(10) && connections.insert(11) && connections.insert(12))
        precondition(!connections.insert(13) && connections.count == 3)
        connections.remove(11)
        precondition(connections.insert(13))
        precondition(connections.removeAll() == Set([10, 12, 13]) && connections.count == 0)
        precondition(connections.insert(14))
        print("HLS security checks passed: sequence bounds, live cursor, encryption IVs, connection admission, header deadlines and keep-alive.")
    }

    static func playlist(_ sequence: String, key: String = "", count: Int = 2, lateSequence: Bool = false) -> String {
        let tag = "#EXT-X-MEDIA-SEQUENCE:\(sequence)\n"
        let segments = (0..<count).map { "#EXTINF:6,\n\($0).ts\n" }.joined()
        return "#EXTM3U\n#EXT-X-TARGETDURATION:6\n" + (lateSequence ? "" : tag) + key + segments + (lateSequence ? tag : "")
    }

    static func media(_ text: String) throws -> HLSMediaPlaylist {
        guard case .media(let parsed) = try HLSPlaylistParser.parse(text) else { preconditionFailure("Expected media playlist") }
        return parsed
    }

    static func playlists() throws {
        let keys = ["", "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n",
                    "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000001\n"]
        for key in keys {
            for sequence in ["-1", "invalid", String(Int.max), String(Int.max - 1), "18446744073709551615"] {
                do {
                    _ = try media(playlist(sequence, key: key))
                    preconditionFailure("Accepted an invalid sequence window")
                } catch HLSIngestError.playlistInvalid {} // The old parser traps for overflowing windows.
            }
            let highest = try media(playlist(String(Int.max - 1), key: key, count: 1))
            var edge = HLSPlaylistTracker()
            precondition(edge.newSegments(in: highest).count == 1 && edge.nextSequence == Int.max)
            precondition(edge.newSegments(in: highest).isEmpty)
        }
        do {
            _ = try media(playlist(String(Int.max), lateSequence: true))
            preconditionFailure("Accepted a late overflowing sequence tag")
        } catch HLSIngestError.playlistInvalid {}
        let plain = try media(playlist("42"))
        var tracker = HLSPlaylistTracker()
        precondition(tracker.newSegments(in: plain).map(\.uri) == ["0.ts", "1.ts"])
        precondition(tracker.newSegments(in: plain).isEmpty)
        let next = try media(playlist("43"))
        precondition(tracker.newSegments(in: next).map(\.uri) == ["1.ts"])
        let encrypted = try media(playlist("42", key: keys[1]))
        precondition(encrypted.segments[0].crypt?.iv == Data(repeating: 0, count: 15) + Data([42]))
        precondition(encrypted.segments[1].crypt?.iv == Data(repeating: 0, count: 15) + Data([43]))
        let explicit = try media(playlist("42", key: keys[2]))
        precondition(explicit.segments.allSatisfy { $0.crypt?.iv == Data(repeating: 0, count: 15) + Data([1]) })
    }

    static func sockets(_ body: (Int32, Int32) throws -> Void) throws {
        var pair = [Int32](repeating: -1, count: 2)
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        for fd in pair {
            var on: Int32 = 1
            precondition(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on))) == 0)
            var capacity: Int32 = 32_768
            precondition(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout.size(ofValue: capacity))) == 0)
        }
        try body(pair[0], pair[1])
    }

    static func sendText(_ text: String, to fd: Int32) {
        let data = Data(text.utf8)
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        precondition(sent == data.count)
    }

    static func headers() throws {
        let request = "GET /session-token/media.m3u8?_HLS_msn=42 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        try sockets { reader, writer in
            sendText(request, to: writer)
            precondition(HLSRequestReader.read(fd: reader, acceptedAt: ProcessInfo.processInfo.systemUptime) == Data(request.utf8))
            let group = DispatchGroup()
            let started = DispatchSemaphore(value: 0)
            group.enter()
            DispatchQueue.global().async {
                started.signal()
                Thread.sleep(forTimeInterval: 0.15)
                sendText(request, to: writer)
                group.leave()
            }
            precondition(started.wait(timeout: .now() + 5) == .success, "Writer did not start")
            let second = HLSRequestReader.read(fd: reader, acceptedAt: nil, headerTimeout: 0.08, idleTimeout: 1)
            precondition(group.wait(timeout: .now() + 5) == .success, "Writer did not finish")
            precondition(second == Data(request.utf8), "Authenticated idle allowance must exceed the partial-header timeout")
        }
        try sockets { reader, _ in
            let start = ProcessInfo.processInfo.systemUptime
            precondition(HLSRequestReader.read(fd: reader, acceptedAt: start, headerTimeout: 0.08) == nil)
            precondition(ProcessInfo.processInfo.systemUptime - start < 1)
        }
        for authenticated in [false, true] {
            try sockets { reader, writer in
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<12 {
                        sendText("x", to: writer)
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    group.leave()
                }
                let start = ProcessInfo.processInfo.systemUptime
                let result = HLSRequestReader.read(fd: reader, acceptedAt: authenticated ? nil : start,
                                                  headerTimeout: 0.1, idleTimeout: 1)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                group.wait()
                precondition(result == nil && elapsed < 1, "Trickled bytes must not reset the header deadline")
            }
        }
        try sockets { reader, writer in
            sendText(String(repeating: "x", count: 8192) + "\r\n\r\n", to: writer)
            precondition(HLSRequestReader.read(fd: reader, acceptedAt: ProcessInfo.processInfo.systemUptime) == nil)
        }
        try sockets { reader, writer in
            sendText("GET /", to: writer)
            shutdown(writer, SHUT_WR)
            precondition(HLSRequestReader.read(fd: reader, acceptedAt: ProcessInfo.processInfo.systemUptime) == nil)
        }
        try sockets { reader, writer in
            sendText(request, to: writer)
            precondition(HLSRequestReader.read(fd: reader, acceptedAt: ProcessInfo.processInfo.systemUptime - 20) == nil,
                         "Queued unauthenticated work must retain its original deadline")
        }
    }
}
