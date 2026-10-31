import Foundation

/// An artwork response outside 200 to 299.
struct VividImageHTTPError: Error {
    let statusCode: Int
}

/// Retry rules for artwork. `load` gives a dropped connection one more try;
/// `recover` lets a visible image ride out a short outage.
enum VividImageRetry {
    private static let transportRetryDelay: Duration = .milliseconds(500)
    private static let recoveryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
    private static let recoverableStatuses: Set<Int> = [408, 500, 502, 503, 504]
    private static let transientURLErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorNotConnectedToInternet,
    ]

    /// At most two calls. Only a transient transport failure is retried, after
    /// a short wait.
    static func load<Value>(operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch {
            try Task.checkCancellation()
            guard isTransientTransportError(error) else { throw error }
            try await Task.sleep(for: transportRetryDelay)
            try Task.checkCancellation()
            return try await operation()
        }
    }

    /// At most four calls, waiting longer before each retry. Only recoverable
    /// failures are retried.
    static func recover<Value>(operation: () async throws -> Value) async throws -> Value {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                try Task.checkCancellation()
                guard retries < recoveryDelays.count, isRecoverable(error) else { throw error }
                try await Task.sleep(for: recoveryDelays[retries])
                retries += 1
            }
        }
    }

    static func isRecoverable(_ error: Error) -> Bool {
        if let status = error as? VividImageHTTPError {
            return recoverableStatuses.contains(status.statusCode)
        }
        return isTransientTransportError(error)
    }

    private static func isTransientTransportError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && transientURLErrorCodes.contains(error.code)
    }
}
