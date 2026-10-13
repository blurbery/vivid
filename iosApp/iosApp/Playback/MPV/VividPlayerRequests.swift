// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
import Foundation

/// Asynchronous mpv requests waiting for their reply. Each core numbers its
/// requests from 1, and every completion leaves the table exactly once: with
/// its reply, a rejected submission or disposal.
final class VividPlayerRequestTable {
    enum Request {
        case set((Result<Void, Error>) -> Void)
        case get((Result<String?, Error>) -> Void)
        case command((Result<Int64?, Error>) -> Void)

        func fail(with error: Error) {
            switch self {
            case .set(let completion): completion(.failure(error))
            case .get(let completion): completion(.failure(error))
            case .command(let completion): completion(.failure(error))
            }
        }
    }

    private let lock = NSLock()
    private var nextNumber: UInt64 = 1
    private var pending: [UInt64: Request] = [:]

    /// The number to submit the request with, which mpv returns as its reply userdata.
    func register(_ request: Request) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let number = nextNumber
        nextNumber &+= 1
        pending[number] = request
        return number
    }

    func take(_ number: UInt64) -> Request? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: number)
    }

    /// Every pending request, oldest first, leaving the table empty.
    func takeAll() -> [Request] {
        lock.lock(); defer { lock.unlock() }
        let taken = pending.sorted { $0.key < $1.key }.map(\.value)
        pending = [:]
        return taken
    }
}

/// The pause state the viewer sees. It follows Vivid's own `pause` requests
/// straight away and falls back to what mpv confirms, so iOS scene activation
/// knows whether a paused frame needs redrawing.
final class VividPlayerPauseTracker {
    private let lock = NSLock()
    private var displayed = true
    private var confirmed = true
    /// One clock orders requests and observations, so a reply can tell whether
    /// mpv reported a state after the request was made.
    private var clock: UInt64 = 0
    private var lastObservation: UInt64 = 0
    private var outstanding: [(ticket: UInt64, paused: Bool)] = []

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return displayed
    }

    static func isPausedValue(_ value: String) -> Bool {
        ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    /// Records a request and returns the ticket its completion resolves.
    func begin(paused: Bool) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        clock &+= 1
        outstanding.append((clock, paused))
        displayed = paused
        return clock
    }

    /// A request's completion, whatever its result. A reply that arrives after
    /// a newer request has resolved changes nothing.
    func resolve(_ ticket: UInt64, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let index = outstanding.firstIndex(where: { $0.ticket == ticket }) else { return }
        let request = outstanding[index]
        // Older requests still in flight retire with this one.
        outstanding.removeSubrange(...index)
        if succeeded, lastObservation < ticket {
            confirmed = request.paused
        }
        displayed = outstanding.last?.paused ?? confirmed
    }

    func observe(paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        clock &+= 1
        lastObservation = clock
        confirmed = paused
        if outstanding.isEmpty { displayed = paused }
    }
}
#endif
