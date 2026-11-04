import Foundation

/// Opt-in image pipeline accounting for the Apple TV Home capture. It only
/// counts: it never cancels, reprioritises or holds on to image work. Flight
/// and waiter ids stay in memory, and the output is aggregate counts and
/// durations only.
final class VividImageDiagnostics: @unchecked Sendable {
    static let shared = VividImageDiagnostics()

    #if os(tvOS)
    let enabled = ProcessInfo.processInfo.arguments.contains("--home-scroll-diagnostics")
        && ProcessInfo.processInfo.arguments.contains("--home-image-diagnostics")
    #else
    let enabled = false
    #endif

    private static let flightKinds = ["flight", "dataFlight"]
    private static let thresholdStep = 32
    private static let thresholdLimit = 16
    private static let samplesPerTiming = 512

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
    /// The last multiple of `thresholdStep` the active flight count reached.
    private var flightBucket = 0

    var timestamp: TimeInterval? { enabled ? ProcessInfo.processInfo.systemUptime : nil }

    /// Starts a capture. Flights already running stay tracked.
    func begin() {
        guard enabled else { return }
        withLock {
            recording = true
            clearSamples()
        }
    }

    func end() {
        withLock { recording = false }
    }

    func count(_ name: String) {
        guard enabled else { return }
        withLock { increment(name) }
    }

    func duration(_ name: String, since start: TimeInterval?) {
        guard let start else { return }
        milliseconds(name, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    func milliseconds(_ name: String, _ value: Double) {
        guard enabled, value.isFinite, value >= 0 else { return }
        withLock {
            guard recording else { return }
            // Bounded, even if a pathological workload floods one interval.
            if timings[name, default: []].count < Self.samplesPerTiming {
                timings[name, default: []].append(value)
            } else {
                counters["timing.samplesDropped", default: 0] += 1
            }
        }
    }

    // MARK: Flights

    func created(_ id: UUID, kind: String, utility: Bool) {
        guard enabled else { return }
        withLock {
            flights[id] = Flight(kind: kind, utility: utility)
            increment("\(kind).created")
            let bucket = flights.count / Self.thresholdStep
            if recording, bucket > flightBucket, thresholds.count < Self.thresholdLimit {
                thresholds.append(("image.threshold.activeFlights", [Double(flights.count)]))
            }
            flightBucket = bucket
        }
    }

    func completed(_ id: UUID, cancelled: Bool) {
        guard enabled else { return }
        withLock {
            guard let flight = flights.removeValue(forKey: id) else { return }
            flightBucket = flights.count / Self.thresholdStep
            increment("\(flight.kind).completed")
            if flight.waiters.isEmpty { increment("\(flight.kind).completedAbandoned") }
            if cancelled { increment("\(flight.kind).cancelled") }
        }
    }

    /// Registers a waiter on a flight and returns its single-use token.
    func join(_ id: UUID, utility: Bool) -> UUID? {
        guard enabled else { return nil }
        return withLock {
            guard var flight = flights[id] else { return nil }
            let token = UUID()
            flight.waiters.insert(token)
            flights[id] = flight
            increment("\(flight.kind).awaitersJoined")
            if !utility, flight.utility { increment("\(flight.kind).demandJoinedUtility") }
            return token
        }
    }

    /// Awaits a shared task on behalf of one waiter. Cancelling the caller
    /// only retires the waiter's token; the task itself is left alone.
    func value<T: Sendable>(of task: Task<T, Error>, id: UUID, token: UUID?) async throws -> T {
        guard enabled else { return try await task.value }
        defer { leave(id, token: token, cancelled: false) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            self.leave(id, token: token, cancelled: true)
        }
    }

    private func leave(_ id: UUID, token: UUID?, cancelled: Bool) {
        guard enabled, let token else { return }
        withLock {
            guard var flight = flights[id], flight.waiters.remove(token) != nil else { return }
            flights[id] = flight
            if cancelled { increment("\(flight.kind).awaitersCancelled") }
        }
    }

    // MARK: Output

    /// Everything recorded since the last drain: counters, timing summaries
    /// (count, p50, p95), the active flights of each kind and any threshold
    /// crossings. Counters, timings and thresholds start again afterwards.
    func drain() -> [(String, [Double])] {
        guard enabled else { return [] }
        return withLock {
            var output = counters.map { ("image." + $0.key, [Double($0.value)]) }
            for (name, values) in timings where !values.isEmpty {
                let sorted = values.sorted()
                let last = Double(sorted.count - 1)
                let p50 = sorted[Int(last * 0.5)]
                let p95 = sorted[Int(ceil(last * 0.95))]
                output.append(("image.timing." + name, [Double(sorted.count), p50, p95]))
            }
            for kind in Self.flightKinds {
                let active = flights.values.filter { $0.kind == kind }
                output.append(("image.\(kind).active", [
                    Double(active.count),
                    Double(active.reduce(0) { $0 + $1.waiters.count }),
                    Double(active.filter(\.waiters.isEmpty).count),
                ]))
            }
            output += thresholds
            clearSamples()
            return output
        }
    }

    // MARK: Locked helpers

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Call with the lock held. Counts only while recording.
    private func increment(_ name: String) {
        if recording { counters[name, default: 0] += 1 }
    }

    /// Call with the lock held.
    private func clearSamples() {
        counters.removeAll(keepingCapacity: true)
        timings.removeAll(keepingCapacity: true)
        thresholds.removeAll(keepingCapacity: true)
    }
}

/// Splits URLSession's transport timings into queueing and connection setup
/// versus the response. Records no URLs, headers or account data.
final class VividImageMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = VividImageMetricsDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let diagnostics = VividImageDiagnostics.shared
        guard diagnostics.enabled else { return }
        for transaction in metrics.transactionMetrics {
            let source = transaction.resourceFetchType == .localCache ? "cache" : "network"
            diagnostics.count("transport.\(source)")
            if source == "network" {
                diagnostics.count(Self.protocolCounter(transaction.networkProtocolName))
            }
            func record(_ name: String, from start: Date?, to end: Date?) {
                guard let start, let end else { return }
                diagnostics.milliseconds("\(source).\(name)", end.timeIntervalSince(start) * 1000)
            }
            record("taskToRequest", from: metrics.taskInterval.start, to: transaction.requestStartDate)
            record("fetchToRequest", from: transaction.fetchStartDate, to: transaction.requestStartDate)
            record("requestToResponseEnd", from: transaction.requestStartDate, to: transaction.responseEndDate)
            record("dns", from: transaction.domainLookupStartDate, to: transaction.domainLookupEndDate)
            record("connect", from: transaction.connectStartDate, to: transaction.connectEndDate)
        }
    }

    private static func protocolCounter(_ name: String?) -> String {
        switch name {
        case "http/1.1": "transport.http1"
        case "h2": "transport.http2"
        default: "transport.otherProtocol"
        }
    }
}
