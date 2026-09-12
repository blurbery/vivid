// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS)
import Foundation
import Network

final class VividDTSLoopbackServer: @unchecked Sendable {
    private let directory: URL
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "com.blurbery.vivid.dts.http")
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    private var startCompleted = false

    init(directory: URL) throws {
        self.directory = directory
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startCompleted else { return }
                switch state {
                case .ready:
                    self.startCompleted = true
                    guard let port = self.listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/index.m3u8") else {
                        continuation.resume(throwing: VividPlaybackError.invalidSource); return
                    }
                    continuation.resume(returning: url)
                case .failed(let error): self.startCompleted = true; continuation.resume(throwing: error)
                case .cancelled: self.startCompleted = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.startCompleted == false { self?.listener.cancel() }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections[id] = nil }
            if case .failed = state { self?.connections[id] = nil; connection.cancel() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak connection] in connection?.cancel() }
        readRequest(connection, accumulated: Data())
    }

    private func readRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count <= 8192, error == nil else { connection.cancel(); return }
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: bytes[..<end.lowerBound], encoding: .utf8) {
                self.respond(connection, header: header)
            } else if !complete { self.readRequest(connection, accumulated: bytes) }
            else { connection.cancel() }
        }
    }

    static func resourceName(path: String, token: String) -> String? {
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        if name == "index.m3u8" || name == "init.mp4" { return name }
        guard name.hasPrefix("segment"), name.hasSuffix(".m4s") else { return nil }
        let number = name.dropFirst(7).dropLast(4)
        return !number.isEmpty && number.count <= 10 && number.allSatisfy { $0.isASCII && $0.isNumber } ? name : nil
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[0] == "GET" || request[0] == "HEAD",
              let name = Self.resourceName(path: String(request[1]), token: token) else {
            sendError(connection, status: "404 Not Found"); return
        }
        let file = directory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 0, let handle = try? FileHandle(forReadingFrom: file) else {
            sendError(connection, status: "404 Not Found"); return
        }
        var lower: Int64 = 0, upper = size - 1, partial = false
        if let range = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = range.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let parts = value.hasPrefix("bytes=") ? value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false) : []
            guard parts.count == 2, !parts[0].isEmpty, let start = Int64(parts[0]),
                  start >= 0, start < size, parts[1].isEmpty || Int64(parts[1]) != nil else {
                try? handle.close(); sendError(connection, status: "416 Range Not Satisfiable"); return
            }
            lower = start
            if let end = Int64(parts[1]) { upper = min(size - 1, end) }
            guard upper >= lower else { try? handle.close(); sendError(connection, status: "416 Range Not Satisfiable"); return }
            partial = true
        }
        let type = name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"
        let rangeHeader = partial ? "Content-Range: bytes \(lower)-\(upper)/\(size)\r\n" : ""
        let response = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(type)\r\nContent-Length: \(upper - lower + 1)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\(rangeHeader)\r\n"
        do { try handle.seek(toOffset: UInt64(lower)) }
        catch { try? handle.close(); connection.cancel(); return }
        let count = request[0] == "HEAD" ? 0 : upper - lower + 1
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { try? handle.close(); connection.cancel(); return }
            self.sendFile(connection, handle: handle, remaining: count)
        })
    }

    private func sendFile(_ connection: NWConnection, handle: FileHandle, remaining: Int64) {
        guard remaining > 0 else { try? handle.close(); connection.cancel(); return }
        guard let bytes = try? handle.read(upToCount: Int(min(65_536, remaining))), !bytes.isEmpty else {
            try? handle.close(); connection.cancel(); return
        }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); connection.cancel(); return }
            self.sendFile(connection, handle: handle, remaining: remaining - Int64(bytes.count))
        })
    }

    private func sendError(_ connection: NWConnection, status: String) {
        connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
