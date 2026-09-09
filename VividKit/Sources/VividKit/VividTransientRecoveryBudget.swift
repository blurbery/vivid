import Foundation

struct VividRangeValidator: Equatable {
    let field: String
    let value: String

    init?(_ response: HTTPURLResponse) {
        if let tag = response.value(forHTTPHeaderField: "ETag") {
            guard tag.count >= 2, tag.first == "\"", tag.last == "\"",
                  tag.dropFirst().dropLast().utf8.allSatisfy({ $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80 }) else { return nil }
            field = "ETag"; value = tag
        } else {
            // RFC 9110 8.8.2.2 permits a sufficiently separated Date and
            // Last-Modified pair. Use a conservative clock-skew margin.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let modified = response.value(forHTTPHeaderField: "Last-Modified"),
                  let date = response.value(forHTTPHeaderField: "Date"),
                  let modifiedDate = formatter.date(from: modified),
                  let responseDate = formatter.date(from: date),
                  responseDate.timeIntervalSince(modifiedDate) >= 60 else { return nil }
            field = "Last-Modified"; value = modified
        }
    }

    func matches(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: field) == value && VividRangeValidator(response) == self
    }
}

struct VividDeliveryStall {
    private var initialHeadroom: Double?
    private var since: TimeInterval?
    mutating func observe(headroom: Double, uptime: TimeInterval, lastDelivery: TimeInterval, eligible: Bool) -> Bool {
        guard eligible, headroom.isFinite, uptime.isFinite, lastDelivery.isFinite else {
            self = Self(); return false
        }
        if since == nil || lastDelivery > since! {
            since = uptime
            initialHeadroom = headroom
        }
        guard let since, let initialHeadroom, uptime - max(since, lastDelivery) >= 3,
              headroom < initialHeadroom - 0.1 else { return false }
        self = Self()
        return true
    }
}

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
