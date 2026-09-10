import Foundation

/// AE#495: fetches a remote origin on the engine's behalf and sends every URI a playlist
/// names back through the local server it is mounted on.
///
/// AVPlayer resolves a remote URL through its own networking. No delegate on the asset is
/// ever asked about the certificate, and an ATS exception does not cover it, so an origin
/// behind a self-signed or private CA certificate cannot play on the native remote HLS
/// route however a host has answered `EngineTLS.serverTrustEvaluator`. Pointing the player
/// at the local server instead moves the https request onto a URLSession the engine owns,
/// which is where that answer is read.
///
/// This is the second reason `HLSLocalServer` stands in front of a remote master, after
/// #316's subtitle renditions, and it composes with it: the rewritten master #316 builds
/// goes through the same rewriter, so a session with sidecars against a self-signed origin
/// gets both instead of choosing.
final class HLSOriginRelay: @unchecked Sendable {

    /// The single route the player is ever pointed at, under the server's session token.
    /// The origin rides in the query, so one route covers playlists, keys and segments.
    static let route = "/aether-origin-relay"
    private static let originQueryKey = "origin"

    /// What a relayed request produced, for the server to write.
    struct Response {
        let status: Int
        let body: Data
        let contentType: String
        /// Mirrored from upstream so a ranged fetch stays a ranged answer.
        let contentRange: String?
    }

    private let stateLock = NSLock()

    /// Origins this relay will fetch, as scheme://host:port. Seeded by `admit(_:)` and grown
    /// as playlists reveal where their own sub-resources live, so a stream split across hosts
    /// keeps working while a request naming somewhere nobody advertised is still refused.
    private var allowedOrigins = Set<String>()

    /// Sent upstream on every fetch. Origins that gate on Referer, User-Agent or
    /// Authorization need these, and they can no longer ride on the asset because the asset
    /// now points at the local server.
    private var upstreamHeaders: [String: String] = [:]

    /// The NSURLError code of the last upstream handshake this relay lost to system trust, if any.
    ///
    /// 6.69.0 classifies a refused certificate off the failed item's `NSUnderlyingErrorKey` chain,
    /// and behind a relay that chain no longer exists: the player's request went to loopback and
    /// came back a plain 502. So the refusal is remembered on the side the handshake actually
    /// happened on, and `NativeAVPlayerHost` reads it when it classifies the failure.
    var upstreamTrustRefusalCode: Int? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _upstreamTrustRefusalCode
    }
    private var _upstreamTrustRefusalCode: Int?

    /// Built in init rather than on first use: the server handles connections concurrently,
    /// and a lazy var raced by two of them can build two sessions where only one is ever
    /// invalidated.
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(
            configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    func stop() {
        session.invalidateAndCancel()
    }

    // MARK: - Whether a relay is wanted at all

    /// One handshake with `origin`, made the way AVPlayer would make it, answering whether system
    /// trust refuses it.
    ///
    /// Mounting the relay on every https origin a host with an evaluator ever plays would move every
    /// byte of every session through this process, for origins AVPlayer can open by itself. The
    /// evaluator cannot be asked instead: at load time there is no protection space and no
    /// `serverTrust`, so a host that reads either would be answering about nothing. The system can be
    /// asked, and its answer is exactly the question, because an origin it trusts is one the native
    /// route reaches unaided.
    ///
    /// A range of one byte rather than a HEAD: origins that serve media commonly answer the first and
    /// not the second, and either way the handshake is what is being read. Anything that is not a
    /// trust refusal, an unreachable host, a timeout, a 500, answers false: those fail the load on the
    /// direct route too, and a relay would not save them.
    static func systemTrustRefuses(_ origin: URL, headers: [String: String] = [:]) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = trustProbeSeconds
        config.timeoutIntervalForResource = trustProbeSeconds
        // No delegate on purpose. This session must answer the way AVPlayer's own networking does,
        // which is system trust and nothing else; handing it `EngineTLS.sessionDelegate` would ask
        // the host and get back the answer that hides what is being measured.
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: origin)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            _ = try await session.data(for: request)
            return false
        } catch {
            guard let code = TransportSecurityFailure.code(in: error) else { return false }
            EngineLog.emit(
                "[HLSOriginRelay] \(origin.host ?? "origin") is not trusted by the system "
                    + "(NSURLError \(code)); the relay makes the handshake so the evaluator is asked",
                category: .hlsServer)
            return true
        }
    }

    /// Long enough for a LAN server to finish a handshake and short enough that an origin which is
    /// simply down does not hold a load open. A timeout answers false, which is the direct route.
    private static let trustProbeSeconds: TimeInterval = 4

    // MARK: - Admission

    /// Lets this relay fetch `origin`, and adopts the headers a load carries. Returns the
    /// origin key, or nil for a URL with no host to fetch from.
    @discardableResult
    func admit(_ origin: URL, httpHeaders: [String: String] = [:]) -> String? {
        guard let key = Self.originKey(for: origin) else { return nil }
        stateLock.lock()
        allowedOrigins.insert(key)
        if !httpHeaders.isEmpty { upstreamHeaders = httpHeaders }
        stateLock.unlock()
        return key
    }

    /// scheme://host:port for `url`, which is the granularity the allow list works at.
    static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    // MARK: - Addressing

    /// The local address standing in for `origin`.
    static func localURL(
        for origin: URL, host: String = "127.0.0.1", port: UInt16, token: String
    ) -> URL? {
        // Encoding everything outside the alphanumerics keeps the origin's own query, which
        // on a Jellyfin stream carries the api key and the play session, from being read as
        // part of this URL's query.
        guard
            let encoded = origin.absoluteString.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: "http://\(host):\(port)/\(token)\(route)?\(originQueryKey)=\(encoded)")
    }

    /// The origin a relay request names, or nil when the query does not carry one.
    ///
    /// Every other field the client put on the URL is carried onto the origin's own query rather
    /// than dropped. AVPlayer appends `_HLS_msn` / `_HLS_part` / `_HLS_skip` to a playlist URL when
    /// the playlist advertises `CAN-BLOCK-RELOAD` (#441), and a reload that should have blocked
    /// until the next segment exists answers immediately without them, so the player asks again at
    /// once and the origin is polled as fast as the loopback can answer.
    static func originURL(fromQuery query: String) -> URL? {
        var origin: URL?
        var carried: [String] = []
        for field in query.split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == originQueryKey else {
                carried.append(String(field))
                continue
            }
            guard let decoded = String(pair[1]).removingPercentEncoding, !decoded.isEmpty else {
                return nil
            }
            origin = URL(string: decoded)
        }
        guard let origin else { return nil }
        guard !carried.isEmpty,
            var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        else { return origin }
        // percentEncoded, because both halves are already encoded: the origin's query came out of
        // the round trip through `localURL`, and the client's fields arrived off the wire.
        var fields: [String] = []
        if let existing = components.percentEncodedQuery, !existing.isEmpty { fields.append(existing) }
        fields.append(contentsOf: carried)
        components.percentEncodedQuery = fields.joined(separator: "&")
        return components.url ?? origin
    }

    /// The authority a rewritten playlist should point its sub-resources at: whatever the
    /// client used to reach the server, so a receiver that arrived on the LAN address keeps
    /// fetching from it rather than being sent to a loopback it resolves to itself (#86).
    /// Falls back to loopback when a request carries no usable Host.
    static func rewriteAuthority(host header: String?) -> String {
        guard let header, !header.isEmpty else { return "127.0.0.1" }
        // Host is "address" or "address:port". An IPv6 literal keeps its brackets, and its
        // colons are inside them.
        if header.hasPrefix("[") {
            guard let close = header.firstIndex(of: "]") else { return "127.0.0.1" }
            return String(header[...close])
        }
        let address = header.split(separator: ":", maxSplits: 1).first.map(String.init) ?? header
        return address.isEmpty ? "127.0.0.1" : address
    }

    // MARK: - Serving

    /// How a streamed answer reaches the socket. `head` is called once, then `body` for every chunk
    /// as it arrives off the wire. Both answer false when the write failed, which ends the transfer.
    struct Sink {
        let head: @Sendable (_ status: Int, _ contentType: String, _ contentRange: String?,
                             _ contentLength: Int) -> Bool
        let body: @Sendable (Data) -> Bool
    }

    /// What the relay did with one request.
    enum Outcome {
        /// A complete answer for the server to write.
        case answer(Response)
        /// Already written through the sink as it arrived. The flag is whether the writes held.
        case streamed(ok: Bool)
    }

    /// Answers one relay request. Nil when the query names no origin the relay could fetch.
    ///
    /// A body that has to be rewritten (a playlist) or read as a whole (anything the origin refused)
    /// is held and comes back as `.answer`. Everything else, which is every media byte, is handed to
    /// the sink as it arrives: buffering a segment would put its whole download time in front of the
    /// player's first byte, and hand AVPlayer's throughput estimate a loopback burst to size the next
    /// rendition from.
    func respond(query: String, host: String?, range: String?, port: UInt16, token: String,
                 sink: Sink) -> Outcome?
    {
        guard let origin = Self.originURL(fromQuery: query) else { return nil }
        guard let key = Self.originKey(for: origin) else { return nil }

        stateLock.lock()
        let permitted = allowedOrigins.contains(key)
        let headers = upstreamHeaders
        stateLock.unlock()
        guard permitted else {
            EngineLog.emit(
                "[HLSOriginRelay] -> 403 origin was never advertised: \(key)", category: .hlsServer)
            return .answer(
                Response(status: 403, body: Data(), contentType: "text/plain", contentRange: nil))
        }

        switch fetch(origin: origin, headers: headers, range: range, sink: sink) {
        case .failed:
            return .answer(
                Response(status: 502, body: Data(), contentType: "text/plain", contentRange: nil))
        case .streamed(let ok):
            return .streamed(ok: ok)
        case .held(let fetched):
            // A body is only rewritten when the origin said it served one AND it is a playlist. An
            // answer that is not a success is passed through as it stands: rewriting a 404 page and
            // framing it as a 200 playlist hands AVPlayer a parse error where the origin had said,
            // in the one word the player can act on, that the resource is gone. The playlist test is
            // asked again here rather than inferred from the hold, because a body of unstated length
            // is held too and a chunked segment is not text to rewrite.
            guard (200..<300).contains(fetched.status),
                Self.looksLikePlaylist(url: origin, contentType: fetched.contentType)
            else {
                return .answer(
                    Response(
                        status: fetched.status, body: fetched.body,
                        contentType: fetched.contentType ?? "application/octet-stream",
                        contentRange: fetched.contentRange))
            }
            let rewritten = rewritePlaylist(
                String(decoding: fetched.body, as: UTF8.self), relativeTo: origin,
                authority: Self.rewriteAuthority(host: host), port: port, token: token)
            // A rewritten body has a different length than the range that produced it, so the
            // partial framing cannot survive. Playlists are small and nothing ranges them.
            return .answer(
                Response(
                    status: 200, body: Data(rewritten.utf8),
                    contentType: "application/vnd.apple.mpegurl", contentRange: nil))
        }
    }

    private static func looksLikePlaylist(url: URL, contentType: String?) -> Bool {
        if let type = contentType?.lowercased(), type.contains("mpegurl") || type.contains("m3u") {
            return true
        }
        let path = url.path.lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".m3u")
    }

    // MARK: - Upstream

    private struct Fetched {
        let status: Int
        let body: Data
        let contentType: String?
        let contentRange: String?
    }

    private enum Upstream {
        /// Written through the sink already; the flag is whether the writes held.
        case streamed(ok: Bool)
        /// Read whole, because it has to be rewritten or because the origin refused.
        case held(Fetched)
        /// Never got a response head. The trust refusal, if that is what it was, is already recorded.
        case failed
    }

    /// The answers that mean "you are asking too often", which arm the pacer for this origin.
    private static let refusalStatuses: Set<Int> = [429, 503, 509]

    /// How long a relayed request waits for a slot against a metered origin. Short on purpose:
    /// `acquire` is fail-open and hands back an un-granted ticket rather than blocking forever,
    /// and AVPlayer abandons a segment whose first byte has not arrived in about 3.5 seconds
    /// (-12889), so waiting a pacer out past that trades a paced session for a failed one.
    private static let slotWaitSeconds: TimeInterval = 2.5

    /// Synchronous because the server answers a request on its own worker thread and the
    /// response has to be written before it returns. That thread does the writing too: the
    /// delegate queue is serial across every task on this session, so a socket the player has
    /// stopped reading would otherwise hold up the delivery of the other fetches in flight.
    ///
    /// The request is charged to `OriginRequestBudget` (#377, #465) like every other fetch the
    /// engine makes. Without that, an origin metering the reader would be paced on one path and
    /// asked freely on this one, and a 429 answered to the player would never arm the pacer that
    /// the reader and the subtitle prefetcher already read.
    private func fetch(origin: URL, headers: [String: String], range: String?, sink: Sink)
        -> Upstream
    {
        var request = URLRequest(url: origin)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        // Forwarded verbatim rather than parsed and rebuilt: the remote HLS path leans on byte
        // ranges, and normalising or coalescing one here would quietly undo the sizing the
        // caller asked for. What comes back is relayed with the same framing.
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }

        let ticket = OriginRequestBudget.shared.acquire(
            for: origin, label: "relay", timeout: Self.slotWaitSeconds)
        defer { OriginRequestBudget.shared.release(ticket) }

        let pump = UpstreamPump()
        let task = session.dataTask(with: request)
        task.delegate = pump
        task.resume()
        // abandon before cancel: a body parked at the high-water mark is waiting on a consumer, and
        // cancelling the task does not wake it.
        defer { pump.abandon(); task.cancel() }

        guard let http = pump.awaitHead() else {
            note(failure: pump.awaitFailure(), origin: origin)
            return .failed
        }
        // #388: a portal that redirects to the host serving the bytes is one origin as far
        // as requests are concerned, so the chain is folded rather than book-kept per hop.
        if let finalURL = http.url, finalURL != origin {
            OriginRequestBudget.shared.noteRedirect(from: origin, to: finalURL)
        }
        if Self.refusalStatuses.contains(http.statusCode) {
            OriginRequestBudget.shared.noteRefusal(
                for: http.url ?? origin, status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        // A length the origin did not state cannot be framed for the player without buffering the
        // body to measure it, and a playlist has to be read whole to be rewritten at all.
        let declaredLength = http.expectedContentLength
        let mustHold = declaredLength < 0
            || !(200..<300).contains(http.statusCode)
            || Self.looksLikePlaylist(url: origin, contentType: contentType)
        guard !mustHold else {
            let body = pump.awaitWholeBody()
            if let error = pump.awaitFailure() {
                // A playlist read halfway is not a playlist, and the framing of a held answer is its
                // own length, so there is nothing here worth passing on.
                note(failure: error, origin: origin)
                return .failed
            }
            return .held(
                Fetched(status: http.statusCode, body: body, contentType: contentType,
                        contentRange: contentRange))
        }

        guard sink.head(http.statusCode, contentType ?? "application/octet-stream", contentRange,
                        Int(declaredLength))
        else { return .streamed(ok: false) }
        let written = pump.drain(into: sink.body)
        // A transport error after the head is already out leaves the body short of the length that
        // was promised, so the answer cannot be finished; the server closes the connection on false.
        if let error = pump.awaitFailure() {
            note(failure: error, origin: origin)
            return .streamed(ok: false)
        }
        return .streamed(ok: written)
    }

    /// Remembers a lost handshake and says so. Everything else is one line and no state: a relay
    /// that could not reach its origin is a 502 either way, but a refused certificate is the one
    /// failure whose reason cannot be read anywhere else once the player is talking to loopback.
    private func note(failure: Error?, origin: URL) {
        guard let failure else { return }
        if let code = TransportSecurityFailure.code(in: failure) {
            stateLock.lock()
            _upstreamTrustRefusalCode = code
            stateLock.unlock()
            EngineLog.emit(
                "[HLSOriginRelay] upstream TLS refused for \(origin.host ?? "origin") "
                    + "(NSURLError \(code)): \(TransportSecurityFailure.sentence(for: code))",
                category: .hlsServer)
            return
        }
        EngineLog.emit(
            "[HLSOriginRelay] upstream failed for \(origin.host ?? "origin"): "
                + "\(failure.localizedDescription)", category: .hlsServer)
    }

    // MARK: - Playlist rewriting

    /// Sends every URI in the playlist back through the server. A relative URI is resolved
    /// against the playlist it came from first, so what the player sees is always absolute
    /// and always local.
    /// - Parameter absoluteOnly: leaves a relative URI alone instead of resolving it against
    ///   the origin. Set for the master #316 writes, whose injected subtitle renditions are the
    ///   local server's own and are named relatively: resolving those would send the player back
    ///   to the origin for a rendition only this engine has.
    func rewritePlaylist(
        _ playlist: String, relativeTo origin: URL, authority: String = "127.0.0.1",
        port: UInt16, token: String, absoluteOnly: Bool = false
    ) -> String {
        var discovered = Set<String>()
        let rewriteOne: (String) -> String = { raw in
            if absoluteOnly, URL(string: raw)?.host == nil { return raw }
            guard let resolved = URL(string: raw, relativeTo: origin)?.absoluteURL,
                let local = Self.localURL(
                    for: resolved, host: authority, port: port, token: token)
            else { return raw }
            if let key = Self.originKey(for: resolved) { discovered.insert(key) }
            return local.absoluteString
        }

        var output: [String] = []
        // Split on \n and drop a trailing \r rather than splitting on any newline, which
        // would read a CRLF playlist as having a blank line between every real one. The
        // output is \n throughout, which AVPlayer reads the same as what came in.
        for rawLine in playlist.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                output.append(line)
            } else if trimmed.hasPrefix("#") {
                output.append(Self.rewriteURIAttribute(in: line, using: rewriteOne))
            } else {
                output.append(rewriteOne(trimmed))
            }
        }

        if !discovered.isEmpty {
            stateLock.lock()
            allowedOrigins.formUnion(discovered)
            stateLock.unlock()
        }
        return output.joined(separator: "\n")
    }

    /// Rewrites the `URI="..."` value a tag carries, which is how keys, maps, renditions and
    /// i-frame variants name what they need. Tags without one come back untouched.
    private static func rewriteURIAttribute(in line: String, using rewrite: (String) -> String)
        -> String
    {
        guard let attr = line.range(of: "URI=\"") else { return line }
        let afterQuote = attr.upperBound
        guard let closing = line[afterQuote...].firstIndex(of: "\"") else { return line }
        let value = String(line[afterQuote..<closing])
        guard !value.isEmpty else { return line }
        return line.replacingCharacters(in: afterQuote..<closing, with: rewrite(value))
    }
}

/// AE#495: one upstream relay fetch, delivered to whoever is waiting on it rather than collected.
///
/// The server's worker thread is blocked for the whole of a relayed request anyway, so it is the
/// thread that writes: this only has to hand it the head as soon as it exists and the bytes as they
/// land. Holding them here instead, and writing from the delegate callback, would put a socket the
/// player has stopped reading in front of every other task on this session's serial delegate queue.
///
/// The bound is what makes the handoff backpressure rather than an unbounded copy of the body: the
/// producer waits once the consumer is that far behind, which is the same shape the direct route has
/// when a socket stops draining.
private final class UpstreamPump: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// One segment's worth of slack. Enough that a fast origin never waits on a loopback write, small
    /// enough that a stalled player cannot turn a session into a heap of parked segments.
    private static let highWaterBytes = 4 * 1024 * 1024

    private let condition = NSCondition()
    private var head: HTTPURLResponse?
    private var pending = Data()
    private var finished = false
    private var failure: Error?
    private var consumerGaveUp = false

    // MARK: - Consumer, on the server's worker thread

    /// The response head, or nil when the fetch failed before there was one.
    func awaitHead() -> HTTPURLResponse? {
        condition.lock()
        defer { condition.unlock() }
        while head == nil && !finished { condition.wait() }
        return head
    }

    /// Every byte of the body, for the answers that have to be read whole.
    func awaitWholeBody() -> Data {
        var body = Data()
        _ = drain { chunk in
            body.append(chunk)
            return true
        }
        return body
    }

    /// Hands each chunk to `write` as it arrives, until the body ends or a write fails. Returns
    /// whether every write held.
    ///
    /// Once `finished` is visible under the lock the producer has nothing more to add, because the
    /// completion callback is ordered behind every data callback on the delegate queue, so the copy
    /// taken with it is the tail of the body.
    func drain(into write: (Data) -> Bool) -> Bool {
        while true {
            condition.lock()
            while pending.isEmpty && !finished { condition.wait() }
            let chunk = pending
            pending.removeAll(keepingCapacity: true)
            let ended = finished
            condition.broadcast()
            condition.unlock()

            if !chunk.isEmpty, !write(chunk) {
                abandon()
                return false
            }
            if ended { return true }
        }
    }

    /// Stops the producer waiting on a consumer that is no longer there. Without it a body parked at
    /// the high-water mark holds the delegate queue for the life of the session.
    func abandon() {
        condition.lock()
        consumerGaveUp = true
        condition.broadcast()
        condition.unlock()
    }

    /// The transport error, once the fetch has finished. Only meaningful after a drain.
    func awaitFailure() -> Error? {
        condition.lock()
        defer { condition.unlock() }
        while !finished { condition.wait() }
        return failure
    }

    // MARK: - Producer, on the session's delegate queue

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        condition.lock()
        head = http
        condition.broadcast()
        condition.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        while pending.count >= Self.highWaterBytes && !consumerGaveUp { condition.wait() }
        let abandoned = consumerGaveUp
        if !abandoned {
            pending.append(data)
            condition.broadcast()
        }
        condition.unlock()
        if abandoned { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        failure = error
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// A task delegate answers for its own task, and a relay fetch is the one place the trust
    /// evaluator has to be reached on the player's behalf.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }
}
