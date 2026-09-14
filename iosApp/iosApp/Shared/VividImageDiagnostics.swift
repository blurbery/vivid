import Foundation

/// Opt-in accounting only. Never cancels, reprioritises or retains image work.
/// UUIDs stay in memory; output contains aggregate counts and durations only.
final class VividImageDiagnostics: @unchecked Sendable {
    static let shared = VividImageDiagnostics()
    #if os(tvOS)
    let enabled = ProcessInfo.processInfo.arguments.contains("--home-scroll-diagnostics")
        && ProcessInfo.processInfo.arguments.contains("--home-image-diagnostics")
    #else
    let enabled = false
    #endif
    private struct Flight {
        let kind: String
        let utility: Bool
        var waiters: Set<UUID> = []
    }
    private let lock = NSLock()
    private var recording = false
    private var flights: [UUID: Flight] = [:]
    private var counters: [String: Int] = [:]
    private var timings: [String: [Double]] = [:]
    private var thresholds: [(String, [Double])] = []
    private var flightBucket = 0

    func begin() {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        recording = true
        counters.removeAll(keepingCapacity: true)
        timings.removeAll(keepingCapacity: true)
        thresholds.removeAll(keepingCapacity: true)
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        recording = false
    }

    func count(_ name: String) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        if recording { counters[name, default: 0] += 1 }
    }

    func duration(_ name: String, since start: TimeInterval?) {
        guard let start else { return }
        milliseconds(name, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    func milliseconds(_ name: String, _ value: Double) {
        guard enabled, value.isFinite, value >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        // Bound storage even if a pathological workload overwhelms a sample.
        if timings[name, default: []].count < 512 { timings[name, default: []].append(value) }
        else { counters["timing.samplesDropped", default: 0] += 1 }
    }

    var timestamp: TimeInterval? { enabled ? ProcessInfo.processInfo.systemUptime : nil }

    func created(_ id: UUID, kind: String, utility: Bool) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        flights[id] = Flight(kind: kind, utility: utility)
        if recording { counters["\(kind).created", default: 0] += 1 }
        let bucket = flights.count / 32
        if recording, bucket > flightBucket, thresholds.count < 16 {
            thresholds.append(("image.threshold.activeFlights", [Double(flights.count)]))
        }
        flightBucket = bucket
    }

    func completed(_ id: UUID, cancelled: Bool) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard let flight = flights.removeValue(forKey: id) else { return }
        flightBucket = flights.count / 32
        guard recording else { return }
        counters["\(flight.kind).completed", default: 0] += 1
        if flight.waiters.isEmpty { counters["\(flight.kind).completedAbandoned", default: 0] += 1 }
        if cancelled { counters["\(flight.kind).cancelled", default: 0] += 1 }
    }

    func join(_ id: UUID, utility: Bool) -> UUID? {
        guard enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard var flight = flights[id] else { return nil }
        let token = UUID()
        flight.waiters.insert(token)
        flights[id] = flight
        if recording {
            counters["\(flight.kind).awaitersJoined", default: 0] += 1
            if !utility && flight.utility {
                counters["\(flight.kind).demandJoinedUtility", default: 0] += 1
            }
        }
        return token
    }

    private func leave(_ id: UUID, token: UUID?, cancelled: Bool) {
        guard enabled, let token else { return }
        lock.lock(); defer { lock.unlock() }
        guard var flight = flights[id], flight.waiters.remove(token) != nil else { return }
        flights[id] = flight
        if recording && cancelled { counters["\(flight.kind).awaitersCancelled", default: 0] += 1 }
    }

    func value<T: Sendable>(of task: Task<T, Error>, id: UUID, token: UUID?) async throws -> T {
        guard enabled else { return try await task.value }
        defer { leave(id, token: token, cancelled: false) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // Single-use diagnostic token only. The underlying task is unchanged.
            self.leave(id, token: token, cancelled: true)
        }
    }

    func drain() -> [(String, [Double])] {
        guard enabled else { return [] }
        lock.lock(); defer { lock.unlock() }
        var output = counters.map { ("image." + $0.key, [Double($0.value)]) }
        for (name, values) in timings where !values.isEmpty {
            let sorted = values.sorted()
            let p50 = sorted[Int(Double(sorted.count - 1) * 0.5)]
            let p95 = sorted[Int(ceil(Double(sorted.count - 1) * 0.95))]
            output.append(("image.timing." + name, [Double(sorted.count), p50, p95]))
        }
        for kind in ["flight", "dataFlight"] {
            let active = flights.values.filter { $0.kind == kind }
            output.append(("image.\(kind).active", [
                Double(active.count), Double(active.reduce(0) { $0 + $1.waiters.count }),
                Double(active.filter { $0.waiters.isEmpty }.count)
            ]))
        }
        output += thresholds
        counters.removeAll(keepingCapacity: true)
        timings.removeAll(keepingCapacity: true)
        thresholds.removeAll(keepingCapacity: true)
        return output
    }
}

/// URLSession's transport timestamps distinguish queued/connection setup time
/// from response time. No request URLs, headers or account data are recorded.
final class VividImageMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = VividImageMetricsDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        let diagnostics = VividImageDiagnostics.shared
        guard diagnostics.enabled else { return }
        for transaction in metrics.transactionMetrics {
            let source = transaction.resourceFetchType == .localCache ? "cache" : "network"
            diagnostics.count("transport.\(source)")
            if source == "network" {
                let protocolName = transaction.networkProtocolName
                diagnostics.count(protocolName == "http/1.1" ? "transport.http1"
                    : protocolName == "h2" ? "transport.http2" : "transport.otherProtocol")
            }
            func duration(_ name: String, _ start: Date?, _ end: Date?) {
                if let start, let end {
                    diagnostics.milliseconds("\(source).\(name)", end.timeIntervalSince(start) * 1000)
                }
            }
            duration("taskToRequest", metrics.taskInterval.start, transaction.requestStartDate)
            duration("fetchToRequest", transaction.fetchStartDate, transaction.requestStartDate)
            duration("requestToResponseEnd", transaction.requestStartDate, transaction.responseEndDate)
            duration("dns", transaction.domainLookupStartDate, transaction.domainLookupEndDate)
            duration("connect", transaction.connectStartDate, transaction.connectEndDate)
        }
    }
}
