// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation

/// One reload for a transient source failure, shared by every source
/// instance of one playback episode, including reloads.
public final class VividTransientRecoveryBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var reloadAttempts = 0
    private var cancelled = false

    public init() {}

    /// Server errors and lost or refused connections a reload may recover from.
    public static func recognises(_ code: Int) -> Bool {
        [500, 502, 503, 504, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
         NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
         NSURLErrorNotConnectedToInternet].contains(code)
    }

    /// True once per episode, until cancelled.
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
