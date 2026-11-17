import Foundation

/// The hosts App Transport Security's local networking rule covered: an IP
/// address, a `.local` name or a single-label name.
enum LocalNetworkHost {
    static func contains(_ host: String) -> Bool {
        var name = host.removingPercentEncoding ?? host
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if let zone = name.firstIndex(of: "%") { name = String(name[..<zone]) }
        while name.hasSuffix(".") { name.removeLast() }
        name = name.lowercased()
        guard !name.isEmpty else { return false }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, name, &v4) == 1 || inet_pton(AF_INET6, name, &v6) == 1 { return true }
        return !name.contains(".") || name.hasSuffix(".local")
    }
}

/// Plain HTTP to any host is allowed (App Transport Security sets
/// `NSAllowsArbitraryLoads`). Before that, ATS refused a redirect from HTTPS
/// down to plain HTTP on a public host, so an HTTPS server couldn't send a
/// request, and the credentials it carries, back out over the internet in
/// the clear. This keeps exactly that refusal where it's used: `HTTPClient`'s
/// sessions (Silo's API), the image pipeline, signed storage artwork and
/// Silo's playback WebSocket. Everything ATS allowed before still follows.
/// Background download sessions never ask their delegate about redirects, so
/// it can't cover media file transfers.
enum PlainHTTPRedirectGuard {
    /// False when a redirect would move from HTTPS (or `wss`) to plain HTTP
    /// (or `ws`) on a host that isn't local.
    static func allows(from previous: URL?, to next: URL?) -> Bool {
        guard ["https", "wss"].contains(previous?.scheme?.lowercased() ?? ""),
              ["http", "ws"].contains(next?.scheme?.lowercased() ?? "") else { return true }
        return LocalNetworkHost.contains(next?.host(percentEncoded: true) ?? "")
    }

    /// Session or task delegate for requests that otherwise follow every
    /// redirect.
    /// A refused redirect ends the task with the redirect response itself.
    final class SessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = SessionDelegate()

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(PlainHTTPRedirectGuard.allows(from: response.url, to: request.url) ? request : nil)
        }
    }
}
