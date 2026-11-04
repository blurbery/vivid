import Foundation

/// Hands one cancellation-shielded request's outcome to exactly one owner.
///
/// Either the caller takes the result or the shielded request keeps it, never
/// both; otherwise a cancelled start could return a session and also delete
/// it. A lock rather than an actor, because `withTaskCancellationHandler`'s
/// cancellation handler is synchronous and can't `await`.
final class PlaybackCancellationShieldGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var bufferedOutcome: Result<Value, Error>?
    private var callerSettled = false

    /// Suspends the caller until the outcome arrives, or resumes it at once
    /// when the outcome (or a cancellation) has already landed.
    func attachCaller(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let bufferedOutcome {
            self.bufferedOutcome = nil
            lock.unlock()
            continuation.resume(with: bufferedOutcome)
            return
        }
        if callerSettled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// True when the caller took the outcome, false when it gave up first and
    /// the shielded request now owns the clean-up.
    func deliver(_ outcome: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !callerSettled else {
            lock.unlock()
            return false
        }
        callerSettled = true
        guard let waiting = continuation else {
            // The caller hasn't suspended yet; `attachCaller` collects this.
            bufferedOutcome = outcome
            lock.unlock()
            return true
        }
        continuation = nil
        lock.unlock()
        waiting.resume(with: outcome)
        return true
    }

    /// The caller was cancelled. It stops waiting now; the request carries on.
    func abandon() {
        lock.lock()
        guard !callerSettled else {
            lock.unlock()
            return
        }
        callerSettled = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
    }
}

enum PlaybackCancellationShield {
    /// Runs a request that allocates something on the server so the caller's
    /// cancellation can't orphan what it allocated.
    ///
    /// `URLSession` aborts when its task is cancelled, and `POST /playback/start`
    /// has no way to take a start back: a request cancelled after it reached
    /// the server leaves a session nothing on this device will ever stop. So
    /// the request runs in an unstructured task that doesn't inherit
    /// cancellation (an `async let` or task group child would, and would abort
    /// it again). The caller still sees its own cancellation and throws
    /// straight away, because the autoplay start timeout has to fire on time;
    /// the request then hands what it allocated to `reclaim`.
    static func run<Value>(
        operation: @escaping @Sendable () async throws -> Value,
        reclaim: @escaping @Sendable (Value) async -> Void
    ) async throws -> Value {
        let gate = PlaybackCancellationShieldGate<Value>()
        Task {
            let outcome: Result<Value, Error>
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
            // Only the abandoned path reclaims, so there's one owner and the
            // allocation is never retired twice.
            guard !gate.deliver(outcome), case .success(let value) = outcome else { return }
            await reclaim(value)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.attachCaller(continuation)
            }
        } onCancel: {
            gate.abandon()
        }
    }
}
