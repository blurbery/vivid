import Foundation

/// Labels each background transfer with the scope and record it belongs to.
/// The system keeps the text form on the task across relaunches, and task
/// identifiers repeat across sessions and scopes, so a transfer is matched to
/// its record by this tag rather than by its identifier alone.
struct DownloadTaskTag: Hashable, Sendable {
    let serverId: String
    let profileId: String
    let recordId: String

    private static let prefix = "vivid-download-v1"

    init(serverId: String, profileId: String, recordId: String) {
        self.serverId = serverId
        self.profileId = profileId
        self.recordId = recordId
    }

    /// Nil for anything but the four-part text form, including tasks an
    /// older build started without a description.
    init?(taskDescription: String?) {
        guard let parts = taskDescription?.split(separator: "\n", omittingEmptySubsequences: false),
              parts.count == 4, parts[0] == Self.prefix,
              !parts[1].isEmpty, !parts[2].isEmpty, !parts[3].isEmpty else { return nil }
        serverId = String(parts[1])
        profileId = String(parts[2])
        recordId = String(parts[3])
    }

    var taskDescription: String {
        [Self.prefix, serverId, profileId, recordId].joined(separator: "\n")
    }

    func isScope(serverId: String, profileId: String) -> Bool {
        self.serverId == serverId && self.profileId == profileId
    }
}

/// The background session's delegate. Callbacks arrive on the session's own
/// serial queue and become events on a stream the manager drains.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// The system keeps transfers under this name across launches: never change it.
    static let sessionIdentifier = "com.blurbery.vivid.downloads"

    private let continuation: AsyncStream<DownloadEngine.TransferEvent>.Continuation

    init(continuation: AsyncStream<DownloadEngine.TransferEvent>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        continuation.yield(.progress(
            task: downloadTask.taskIdentifier, written: totalBytesWritten, expected: totalBytesExpectedToWrite,
            tag: DownloadTaskTag(taskDescription: downloadTask.taskDescription)
        ))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let task = downloadTask.taskIdentifier
        let tag = DownloadTaskTag(taskDescription: downloadTask.taskDescription)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // The body is an error page, not media.
            DownloadEngine.log.error("A download transfer ended with HTTP \(status)")
            continuation.yield(.failed(task: task, status: status, resumeData: nil, message: "HTTP \(status)", urlErrorCode: nil, tag: tag))
            return
        }
        // The temporary file only exists during this callback.
        let staged = DownloadEngine.Disk.stagedFile(taskIdentifier: task)
        do {
            try DownloadEngine.Disk.move(location, to: staged)
        } catch {
            DownloadEngine.log.error("Couldn't stage a finished download: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.failed(task: task, status: status, resumeData: nil, message: "stage_failed", urlErrorCode: nil, tag: tag))
            return
        }
        continuation.yield(.finished(task: task, staged: staged, status: status, tag: tag))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        continuation.yield(.failed(
            task: task.taskIdentifier,
            status: (task.response as? HTTPURLResponse)?.statusCode,
            resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
            message: error.localizedDescription,
            urlErrorCode: nsError.domain == NSURLErrorDomain ? nsError.code : nil,
            tag: DownloadTaskTag(taskDescription: task.taskDescription)
        ))
    }

    /// Emby's token header must not follow a redirect to another host, so an
    /// Emby transfer ends at the redirect instead. Everything else follows.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if task.originalRequest?.value(forHTTPHeaderField: "X-Emby-Token") != nil {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.endOfDelivery)
    }
}

extension DownloadEngine {
    enum TransferEvent: Sendable {
        case progress(task: Int, written: Int64, expected: Int64, tag: DownloadTaskTag?)
        case finished(task: Int, staged: URL, status: Int, tag: DownloadTaskTag?)
        case failed(task: Int, status: Int?, resumeData: Data?, message: String, urlErrorCode: Int?, tag: DownloadTaskTag?)
        case endOfDelivery
    }

    /// The one background session of the process.
    final class Transfers: Sendable {
        let events: AsyncStream<TransferEvent>
        private let session: URLSession

        init() {
            let (events, continuation) = AsyncStream.makeStream(of: TransferEvent.self, bufferingPolicy: .unbounded)
            self.events = events
            let configuration = URLSessionConfiguration.background(withIdentifier: DownloadSessionDelegate.sessionIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.allowsCellularAccess = true
            configuration.httpMaximumConnectionsPerHost = 4
            session = URLSession(
                configuration: configuration,
                delegate: DownloadSessionDelegate(continuation: continuation),
                delegateQueue: nil
            )
        }

        /// Starts a transfer and returns its identifier.
        func start(_ request: URLRequest, description: String?) -> Int {
            let task = session.downloadTask(with: request)
            task.taskDescription = description
            task.resume()
            return task.taskIdentifier
        }

        func resume(from data: Data, description: String?) -> Int {
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = description
            task.resume()
            return task.taskIdentifier
        }

        func cancel(_ identifier: Int) async {
            await session.allTasks.first { $0.taskIdentifier == identifier }?.cancel()
        }

        /// Stops a transfer keeping what it has. Nil when the task is gone or
        /// the server can't resume, which means starting again from zero.
        func pause(_ identifier: Int) async -> Data? {
            guard let task = await session.allTasks.first(where: { $0.taskIdentifier == identifier }) as? URLSessionDownloadTask else {
                return nil
            }
            return await task.cancelByProducingResumeData()
        }

        func liveIdentifiers() async -> Set<Int> {
            Set(await session.allTasks.map(\.taskIdentifier))
        }
    }

    /// The request a background transfer sends: the account's own origin and
    /// the credentials its server expects.
    enum TransferRequest {
        /// Re-reads the token store for the same account first, so a profile,
        /// profile proof or account change since the identity was captured
        /// stops the transfer. A newer access token for the account is used.
        static func make(
            url: URL, allowsCellular: Bool, expected: CapturedOrdinaryRequestAuth, tokenStore: TokenStore = .shared
        ) async throws -> URLRequest {
            guard let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: expected) else {
                throw HTTPError.requestIdentityChanged
            }
            try Task.checkCancellation()
            return try build(url: url, allowsCellular: allowsCellular, identity: current)
        }

        static func build(url: URL, allowsCellular: Bool, identity: CapturedOrdinaryRequestAuth) throws -> URLRequest {
            let account = identity.account
            _ = try AssetLocation(url.absoluteString, serverURL: account.serverURL)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.allowsCellularAccess = allowsCellular
            switch MediaServerProvider.forServerID(account.serverId) {
            case .jellyfin:
                let connection = JellyfinConnection(
                    serverURL: account.serverURL, token: identity.accessToken, userID: nil, identity: identity
                )
                for (field, value) in connection.headers { request.setValue(value, forHTTPHeaderField: field) }
            case .emby:
                let connection = EmbyConnection(
                    serverURL: account.serverURL, token: identity.accessToken, userID: nil, identity: identity
                )
                for (field, value) in connection.headers { request.setValue(value, forHTTPHeaderField: field) }
            case .silo:
                if let token = identity.accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                if let profileId = identity.profileId { request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id") }
                if let proof = identity.profileToken { request.setValue(proof, forHTTPHeaderField: "X-Profile-Token") }
                AppleDeviceIdentity.current.applyHeaders(to: &request)
            }
            return request
        }
    }
}
