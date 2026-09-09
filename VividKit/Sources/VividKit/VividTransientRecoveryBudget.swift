import Foundation

/// Shared by source instances for one playback episode, including reloads.
public final class VividTransientRecoveryBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var networkAttempts = 0
    private var reloadAttempts = 0
    private var cancelled = false

    public init() {}

    public static func recognises(_ code: Int) -> Bool {
        [500, 502, 503, 504, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
         NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
         NSURLErrorNotConnectedToInternet].contains(code)
    }

    public func beginNetworkRetry() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, networkAttempts < 2 else { return false }
        networkAttempts += 1
        return true
    }

    public func beginReload() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, reloadAttempts == 0 else { return false }
        reloadAttempts += 1
        return true
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}
