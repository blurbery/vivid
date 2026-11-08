// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UIKit

// MARK: - Requests

/// One piece of artwork at one decoded size, owned by one cache scope.
/// Priority only orders the work, so it isn't part of equality or the key.
struct VividImageRequest: Hashable, Sendable {
    enum Priority: Sendable { case low, normal, high }

    /// The decoded size. Fill covers the box; otherwise the image fits inside it.
    struct ThumbnailOptions: Hashable, Sendable {
        enum Unit { case pixels }
        enum ContentMode { case aspectFill, aspectFit }

        let width: Int
        let height: Int
        let fill: Bool

        init(maxPixelSize: Float) {
            width = Int(maxPixelSize)
            height = Int(maxPixelSize)
            fill = false
        }

        init(size: CGSize, unit: Unit, contentMode: ContentMode) {
            width = max(1, Int(size.width.rounded(.up)))
            height = max(1, Int(size.height.rounded(.up)))
            fill = contentMode == .aspectFill
        }
    }

    let url: URL
    let cacheScope: String
    var priority: Priority
    var thumbnail: ThumbnailOptions?
    /// Gaussian blur applied once at decode, as a fraction of the decoded
    /// width, so the cached image is already soft and nothing runs per frame.
    var softening: Float?
    /// Crops transparent margins at decode, so a logo's visible edge sits
    /// where the layout puts the image.
    var trimsTransparentEdges = false

    init(url: URL, priority: Priority = .normal, cacheScope: String = VividCacheScope.artwork) {
        self.url = url
        self.priority = priority
        self.cacheScope = cacheScope
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url
            && lhs.cacheScope == rhs.cacheScope
            && lhs.thumbnail == rhs.thumbnail
            && lhs.softening == rhs.softening
            && lhs.trimsTransparentEdges == rhs.trimsTransparentEdges
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(cacheScope)
        hasher.combine(thumbnail)
        hasher.combine(softening)
        hasher.combine(trimsTransparentEdges)
    }

    /// The memory cache key.
    var key: NSString {
        let size = "\(thumbnail?.width ?? 0)x\(thumbnail?.height ?? 0)"
        return "\(cacheScope)|\(url.absoluteString)|\(size)|\(thumbnail?.fill ?? false)|\(softening ?? 0)|\(trimsTransparentEdges ? "trim" : "")" as NSString
    }
}

final class VividImageContainer: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

// MARK: - Cache

/// Decoded images in memory, and downloaded bytes on disk in one URL cache
/// per scope.
final class VividImageCache: @unchecked Sendable {
    enum Caches { case memory }

    private static let diskCapacityLimit = 256 * 1024 * 1024
    private static let folder = "com.vivid.app.artwork/v2/"

    private let memory = NSCache<NSString, VividImageContainer>()
    private let diskCapacity: Int
    private let responseLock = NSLock()
    private var responseCaches: [String: URLCache] = [:]
    /// Bumped whenever memory is cleared, so a decode that started before the
    /// clear can't put its image back.
    private let generationLock = NSLock()
    private var generation = 0

    init(costLimit: Int, countLimit: Int, diskCapacity: Int) {
        memory.totalCostLimit = costLimit
        memory.countLimit = countLimit
        self.diskCapacity = diskCapacity
    }

    /// The scope's disk cache. Pre-login (`unowned-`) scopes get none.
    func responses(for scope: String) -> URLCache {
        responseLock.lock()
        defer { responseLock.unlock() }
        if let cache = responseCaches[scope] { return cache }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.folder + scope, isDirectory: true)
        let cache = URLCache(
            memoryCapacity: 0,
            diskCapacity: scope.hasPrefix("unowned-") ? 0 : min(diskCapacity, Self.diskCapacityLimit),
            directory: directory
        )
        responseCaches[scope] = cache
        return cache
    }

    subscript(request: VividImageRequest) -> VividImageContainer? {
        get { memory.object(forKey: request.key) }
        set {
            guard let newValue else {
                memory.removeObject(forKey: request.key)
                return
            }
            let cost = newValue.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
            memory.setObject(newValue, forKey: request.key, cost: cost)
        }
    }

    #if os(tvOS)
    func setMemoryLimits(cost: Int, count: Int) {
        memory.totalCostLimit = cost
        memory.countLimit = count
    }
    #endif

    var currentGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    /// Stores the image only if memory hasn't been cleared since `expected`.
    func store(_ image: VividImageContainer, for request: VividImageRequest, generation expected: Int) {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == expected else { return }
        self[request] = image
    }

    func removeAll(caches: Caches) {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation &+= 1
        memory.removeAllObjects()
    }

    func containsData(for request: VividImageRequest) -> Bool {
        responses(for: request.cacheScope).cachedResponse(for: URLRequest(url: request.url)) != nil
    }

    func removeCachedData(for request: VividImageRequest) {
        responses(for: request.cacheScope).removeCachedResponse(for: URLRequest(url: request.url))
    }

    func removeCachedImage(for request: VividImageRequest, caches: Caches) {
        memory.removeObject(forKey: request.key)
    }
}

// MARK: - Transfer priority

/// On-screen artwork shares two connections per host with prefetching. Each
/// shared transfer holds one priority, taken from its first request and
/// raised when a more urgent request joins, so a poster that was being
/// prefetched is promoted once it's visible. Also forwards diagnostics metrics.
final class VividTransferPriority: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private(set) var value: Float

    init(_ priority: VividImageRequest.Priority) {
        value = Self.value(for: priority)
    }

    static func value(for priority: VividImageRequest.Priority) -> Float {
        switch priority {
        case .low: URLSessionTask.lowPriority
        case .normal: URLSessionTask.defaultPriority
        case .high: URLSessionTask.highPriority
        }
    }

    /// Never lowers the priority.
    func raise(to priority: VividImageRequest.Priority) {
        let wanted = Self.value(for: priority)
        lock.lock()
        defer { lock.unlock() }
        guard wanted > value else { return }
        value = wanted
        task?.priority = wanted
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        task.priority = value
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        VividImageMetricsDelegate.shared.urlSession(session, task: task, didFinishCollecting: metrics)
    }
}

// MARK: - Pipeline

final class VividImagePipeline: @unchecked Sendable {
    static var shared = VividImagePipeline()

    private static let maxDownloadBytes = 32 * 1024 * 1024
    private static let maxDecodedEdge = 4096.0

    let cache: VividImageCache
    private let sessionConfiguration: () -> URLSessionConfiguration
    private let sessionLock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private let decoding = OperationQueue()
    private let flights = VividImageFlights()
    private let dataFlights = VividImageDataFlights()

    init(
        costLimit: Int = 96 * 1024 * 1024,
        countLimit: Int = 180,
        diskCapacity: Int = 1_024 * 1024 * 1024,
        sessionConfiguration: @escaping () -> URLSessionConfiguration = { .default }
    ) {
        self.sessionConfiguration = sessionConfiguration
        cache = VividImageCache(costLimit: costLimit, countLimit: countLimit, diskCapacity: diskCapacity)
        decoding.maxConcurrentOperationCount = 2
        #if os(tvOS)
        decoding.qualityOfService = .utility
        #else
        decoding.qualityOfService = .userInitiated
        #endif
    }

    // MARK: Images

    func image(for request: VividImageRequest) async throws -> UIImage {
        let diagnostics = VividImageDiagnostics.shared
        if let cached = cache[request] {
            diagnostics.count("memory.hit")
            return cached.image
        }
        diagnostics.count("memory.miss")
        let generation = cache.currentGeneration
        let result = try await flights.load(request) { [self] in
            let dataStart = diagnostics.timestamp
            let data = try await data(for: request)
            diagnostics.duration("dataWait", since: dataStart)
            try Task.checkCancellation()
            return try await decoded(data, for: request, generation: generation)
        }
        try Task.checkCancellation()
        return result.image
    }

    /// Decodes on the decode queue and stores the result in memory.
    private func decoded(_ data: Data, for request: VividImageRequest, generation: Int) async throws -> VividImageContainer {
        let diagnostics = VividImageDiagnostics.shared
        let queuedAt = diagnostics.timestamp
        let qos = request.priority == .low ? "utility" : "demand"
        let cancellation = VividImageDecodeCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operation = BlockOperation { [self] in
                    diagnostics.duration("decodeQueue.\(qos)", since: queuedAt)
                    let decodeStart = diagnostics.timestamp
                    defer { diagnostics.duration("decode.\(qos)", since: decodeStart) }
                    do {
                        // A cancelled operation still runs, so the continuation
                        // is always resumed, but it skips the decode.
                        try cancellation.check()
                        let image = try Self.decode(data, request: request)
                        try cancellation.check()
                        let container = VividImageContainer(image)
                        cache.store(container, for: request, generation: generation)
                        continuation.resume(returning: container)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                #if os(tvOS)
                operation.qualityOfService = request.priority == .low ? .utility : .userInitiated
                operation.queuePriority = request.priority == .low ? .low : .normal
                #endif
                decoding.addOperation(operation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: Bytes

    func data(for request: VividImageRequest) async throws -> Data {
        try Task.checkCancellation()
        if request.url.isFileURL {
            return try Data(contentsOf: request.url, options: .mappedIfSafe)
        }
        // Display, crop, palette and disk warming share a download only for the
        // identical URL in the same scope. Each size keeps its own decode.
        return try await dataFlights.load(request.url, scope: request.cacheScope, priority: request.priority) { [self] transfer in
            try await download(request, transfer: transfer)
        }
    }

    private func download(_ request: VividImageRequest, transfer: VividTransferPriority) async throws -> Data {
        let (data, response) = try await VividImageRetry.load {
            try await session(for: request.cacheScope).data(from: request.url, delegate: transfer)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if VividImageHTTPError.rejectedLinkStatuses.contains(http.statusCode) {
                NotificationCenter.default.post(name: .vividArtworkLinkRejected, object: request.url)
            }
            throw VividImageHTTPError(statusCode: http.statusCode)
        }
        guard response is HTTPURLResponse, data.count <= Self.maxDownloadBytes else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func session(for scope: String) -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let session = sessions[scope] { return session }
        let configuration = sessionConfiguration()
        configuration.urlCache = cache.responses(for: scope)
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        sessions[scope] = session
        return session
    }

    private func sessionSnapshot() -> [URLSession] {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return Array(sessions.values)
    }

    private func cancelAllTransfers() async {
        for session in sessionSnapshot() {
            for task in await session.allTasks { task.cancel() }
        }
    }

    // MARK: Clearing

    func removeCachedArtwork(for urls: Set<URL>, scope: String = VividCacheScope.artwork) async {
        cache.removeAll(caches: .memory)
        await flights.cancel(urls: urls, scope: scope)
        await dataFlights.cancel(urls: urls, scope: scope)
        for url in urls {
            cache.removeCachedData(for: VividImageRequest(url: url, cacheScope: scope))
        }
    }

    /// Called before the next account is published. Cancels the shared work,
    /// not just its waiters, and stops earlier decodes refilling memory.
    func cancelForAccountSwitch() async {
        cache.removeAll(caches: .memory)
        await flights.cancelAll()
        await dataFlights.cancelAll()
        await cancelAllTransfers()
    }

    #if os(iOS)
    /// The iPad app on a Mac is killed with 0xdead10cc if it's suspended while
    /// an artwork response cache holds its SQLite write lock. On the Mac only,
    /// stop artwork transfers as the app goes to the background and keep a
    /// short window for cache writes to finish. Failed artwork retries on return.
    @MainActor
    func prepareForMacSuspension() {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        let window = SuspensionWindow()
        window.id = UIApplication.shared.beginBackgroundTask(withName: "Vivid artwork cache") {
            MainActor.assumeIsolated { window.end() }
        }
        Task { @MainActor [self] in
            await cancelAllTransfers()
            try? await Task.sleep(for: .seconds(2))
            window.end()
        }
    }

    @MainActor
    private final class SuspensionWindow {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
    #endif

    // MARK: Diagnostics and tests

    /// [total, userInitiated, utility, executing] decode operations.
    func diagnosticDecodeOperations() -> [Double] {
        guard VividImageDiagnostics.shared.enabled else { return [] }
        let operations = decoding.operations
        return [
            Double(operations.count),
            Double(operations.filter { $0.qualityOfService == .userInitiated }.count),
            Double(operations.filter { $0.qualityOfService == .utility }.count),
            Double(operations.filter(\.isExecuting).count),
        ]
    }

    #if DEBUG
    /// Read-only synchronisation for tests with a held synthetic response.
    func debugDataFlightWaiterCount(for request: VividImageRequest) async -> Int {
        await dataFlights.debugWaiterCount(for: request.url, scope: request.cacheScope)
    }

    func debugImageFlightWaiterCount(for request: VividImageRequest) async -> Int {
        await flights.debugWaiterCount(for: request)
    }

    func debugSuspendDecoding(_ suspended: Bool) { decoding.isSuspended = suspended }
    var debugPendingDecodeCount: Int { decoding.operationCount }
    #endif

    // MARK: Decoding

    private static func decode(_ data: Data, request: VividImageRequest) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(of: source, for: request.thumbnail),
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        if request.trimsTransparentEdges, let trimmed = trimTransparentEdges(image) {
            image = trimmed
        }
        guard let softening = request.softening, softening > 0 else {
            return UIImage(cgImage: image)
        }
        // A covered still must never fall back to the sharp decode; the view
        // shows its placeholder instead.
        guard let softened = soften(image, fraction: softening) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: softened)
    }

    /// The longest decoded edge: the source's own, or what the thumbnail box
    /// needs, never upscaled and never over 4096 pixels.
    private static func maxPixelSize(of source: CGImageSource, for thumbnail: VividImageRequest.ThumbnailOptions?) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
        let longest = max(width, height)
        guard let thumbnail else { return min(longest, maxDecodedEdge) }
        let widthScale = Double(thumbnail.width) / max(1, width)
        let heightScale = Double(thumbnail.height) / max(1, height)
        let scale = thumbnail.fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        return min(maxDecodedEdge, max(1, ceil(longest * min(1, scale))))
    }

    /// The image cropped to its visible pixels, or nil when it has no
    /// transparent margin to remove (or nothing visible at all).
    private static func trimTransparentEdges(_ image: CGImage) -> CGImage? {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                // Swift requires a colour space here; Core Graphics ignores it
                // for an alpha-only bitmap and creates the context.
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Faint anti-aliasing and stray specks don't count as the edge.
        let threshold: UInt8 = 12
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        if minX == 0, minY == 0, maxX == width - 1, maxY == height - 1 { return nil }
        // The alpha buffer's rows run top to bottom, matching CGImage cropping.
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return image.cropping(to: rect)
    }

    private static let softeningContext = CIContext(options: [.cacheIntermediates: false])

    /// One Gaussian blur over the decoded bitmap. Callers pair it with a small
    /// thumbnail, so it's a few thousand pixels, done once per image.
    private static func soften(_ image: CGImage, fraction: Float) -> CGImage? {
        let input = CIImage(cgImage: image)
        let sigma = Double(Float(image.width) * fraction)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        return softeningContext.createCGImage(blurred, from: input.extent)
    }
}

// MARK: - Shared flights

/// The waiter bookkeeping behind both flight actors. Each actor owns one
/// table and only uses it from its own isolation.
///
/// A flight is one shared task with a set of waiters. When the last waiter
/// leaves, the flight is forgotten; its task is cancelled only if that waiter
/// left because it was cancelled.
private struct FlightTable<Key: Hashable, Value: Sendable, Context> {
    struct Flight {
        let id: UUID
        let task: Task<Value, Error>
        let context: Context
        var waiters: Set<UUID>
    }

    private var flights: [Key: Flight] = [:]

    /// Adds `waiter` to the running flight for `key`, if there is one.
    mutating func join(_ key: Key, waiter: UUID) -> Flight? {
        guard var flight = flights[key] else { return nil }
        flight.waiters.insert(waiter)
        flights[key] = flight
        return flight
    }

    mutating func start(_ key: Key, id: UUID, task: Task<Value, Error>, context: Context, waiter: UUID) -> Flight {
        let flight = Flight(id: id, task: task, context: context, waiters: [waiter])
        flights[key] = flight
        return flight
    }

    mutating func release(_ key: Key, id: UUID, waiter: UUID, cancelled: Bool) {
        guard var flight = flights[key], flight.id == id,
              flight.waiters.remove(waiter) != nil
        else { return }
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            // An abandoned warmer mustn't hold a connection until it times out.
            // Other waiters keep the task alive while they need it.
            if cancelled { flight.task.cancel() }
        } else {
            flights[key] = flight
        }
    }

    mutating func cancelAll() {
        let outgoing = flights.values
        flights.removeAll()
        for flight in outgoing { flight.task.cancel() }
    }

    mutating func cancel(where matches: (Key) -> Bool) {
        for key in Array(flights.keys) where matches(key) {
            flights.removeValue(forKey: key)?.task.cancel()
        }
    }

    func waiterCount(for key: Key) -> Int {
        flights[key]?.waiters.count ?? 0
    }
}

/// Waits for a flight's task as one waiter, through the diagnostics helper
/// when it's on. Awaiting a task's value doesn't end early on cancellation,
/// so `onCancel` lets the owning actor drop the waiter straight away.
private func awaitFlight<Value: Sendable>(
    _ task: Task<Value, Error>,
    id: UUID,
    utility: Bool,
    onCancel: @escaping @Sendable () -> Void
) async throws -> Value {
    let diagnostics = VividImageDiagnostics.shared
    let value = try await withTaskCancellationHandler {
        guard diagnostics.enabled else { return try await task.value }
        return try await diagnostics.value(of: task, id: id, token: diagnostics.join(id, utility: utility))
    } onCancel: {
        onCancel()
    }
    try Task.checkCancellation()
    return value
}

/// Shares in-flight artwork bytes across sizes and platforms. Transport
/// retries stay inside the shared download; finished bytes go to the URL cache.
actor VividImageDataFlights {
    private struct Key: Hashable {
        let url: URL
        let scope: String
    }

    private var table = FlightTable<Key, Data, VividTransferPriority>()

    func load(
        _ url: URL,
        scope: String = "",
        priority: VividImageRequest.Priority = .normal,
        operation: @escaping @Sendable (VividTransferPriority) async throws -> Data
    ) async throws -> Data {
        try Task.checkCancellation()
        let key = Key(url: url, scope: scope)
        let waiter = UUID()
        let flight: FlightTable<Key, Data, VividTransferPriority>.Flight
        if let joined = table.join(key, waiter: waiter) {
            joined.context.raise(to: priority)
            flight = joined
        } else {
            let id = UUID()
            let diagnostics = VividImageDiagnostics.shared
            diagnostics.created(id, kind: "dataFlight", utility: false)
            let transfer = VividTransferPriority(priority)
            let task = Task {
                defer { diagnostics.completed(id, cancelled: Task.isCancelled) }
                let data = try await operation(transfer)
                try Task.checkCancellation()
                return data
            }
            flight = table.start(key, id: id, task: task, context: transfer, waiter: waiter)
        }
        let id = flight.id
        defer { table.release(key, id: id, waiter: waiter, cancelled: false) }
        return try await awaitFlight(flight.task, id: id, utility: false) {
            Task { await self.release(key, id: id, waiter: waiter) }
        }
    }

    func cancelAll() {
        table.cancelAll()
    }

    func cancel(urls: Set<URL>, scope: String) {
        table.cancel { $0.scope == scope && urls.contains($0.url) }
    }

    #if DEBUG
    func debugWaiterCount(for url: URL, scope: String) -> Int {
        table.waiterCount(for: Key(url: url, scope: scope))
    }
    #endif

    private func release(_ key: Key, id: UUID, waiter: UUID) {
        table.release(key, id: id, waiter: waiter, cancelled: true)
    }
}

/// Requests for the same size share the decode as well as the bytes. The
/// byte download is only cancelled once its last image waiter has gone.
private actor VividImageFlights {
    private var table = FlightTable<VividImageRequest, VividImageContainer, Void>()

    func load(
        _ request: VividImageRequest,
        operation: @escaping @Sendable () async throws -> VividImageContainer
    ) async throws -> VividImageContainer {
        try Task.checkCancellation()
        let waiter = UUID()
        let utility = request.priority == .low
        let flight: FlightTable<VividImageRequest, VividImageContainer, Void>.Flight
        if let joined = table.join(request, waiter: waiter) {
            flight = joined
        } else {
            let id = UUID()
            let diagnostics = VividImageDiagnostics.shared
            diagnostics.created(id, kind: "flight", utility: utility)
            let createdAt = diagnostics.timestamp
            let task = Task(priority: utility ? .utility : .userInitiated) {
                diagnostics.duration("flightStartWait", since: createdAt)
                defer { diagnostics.completed(id, cancelled: Task.isCancelled) }
                let result = try await operation()
                try Task.checkCancellation()
                return result
            }
            flight = table.start(request, id: id, task: task, context: (), waiter: waiter)
        }
        let id = flight.id
        defer { table.release(request, id: id, waiter: waiter, cancelled: false) }
        return try await awaitFlight(flight.task, id: id, utility: utility) {
            Task { await self.release(request, id: id, waiter: waiter) }
        }
    }

    func cancelAll() {
        table.cancelAll()
    }

    func cancel(urls: Set<URL>, scope: String) {
        table.cancel { $0.cacheScope == scope && urls.contains($0.url) }
    }

    #if DEBUG
    func debugWaiterCount(for request: VividImageRequest) -> Int {
        table.waiterCount(for: request)
    }
    #endif

    private func release(_ request: VividImageRequest, id: UUID, waiter: UUID) {
        table.release(request, id: id, waiter: waiter, cancelled: true)
    }
}

/// OperationQueue doesn't see Swift task cancellation. This flag lets a
/// queued decode resume its continuation without doing abandoned work.
private final class VividImageDecodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}

// MARK: - Prefetching

/// Warms artwork into memory or onto disk, a few requests at a time, in the
/// order asked. Failures are ignored.
final class VividImagePrefetcher: @unchecked Sendable {
    enum Destination { case memoryCache, diskCache }

    private struct Running {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let pipeline: VividImagePipeline
    private let destination: Destination
    private let limit: Int
    private let lock = NSLock()
    private var storedPriority: VividImageRequest.Priority = .normal
    private var pending: [VividImageRequest] = []
    private var active: [VividImageRequest: Running] = [:]

    /// The priority given to requests built from plain URLs.
    var priority: VividImageRequest.Priority {
        get { locked { storedPriority } }
        set { locked { storedPriority = newValue } }
    }

    init(pipeline: VividImagePipeline, destination: Destination, maxConcurrentRequestCount: Int = 2) {
        self.pipeline = pipeline
        self.destination = destination
        limit = max(1, maxConcurrentRequestCount)
    }

    deinit {
        for running in active.values { running.task.cancel() }
    }

    func startPrefetching(with urls: [URL]) {
        let priority = self.priority
        startPrefetching(with: urls.map { VividImageRequest(url: $0, priority: priority) })
    }

    func startPrefetching(with requests: [VividImageRequest]) {
        locked {
            for request in requests where active[request] == nil && !pending.contains(request) {
                pending.append(request)
            }
            launchPending()
        }
    }

    #if os(tvOS)
    /// Reorders the upcoming Home work without detaching shared downloads
    /// that are already running.
    func replacePendingPrefetching(with requests: [VividImageRequest]) {
        locked {
            var seen = Set<VividImageRequest>()
            pending = requests.filter { active[$0] == nil && seen.insert($0).inserted }
            launchPending()
        }
    }
    #endif

    func stopPrefetching(with urls: [URL]) {
        stopPrefetching(with: urls.map { VividImageRequest(url: $0) })
    }

    func stopPrefetching(with requests: [VividImageRequest]) {
        locked {
            pending.removeAll { requests.contains($0) }
            for request in requests { active.removeValue(forKey: request)?.task.cancel() }
            launchPending()
        }
    }

    func stopPrefetching() {
        let running = locked {
            pending.removeAll()
            defer { active.removeAll() }
            return Array(active.values)
        }
        for item in running { item.task.cancel() }
    }

    /// Call with the lock held.
    private func launchPending() {
        while active.count < limit, !pending.isEmpty {
            let request = pending.removeFirst()
            let id = UUID()
            let task = Task { [weak self, pipeline, destination] in
                switch destination {
                case .diskCache: _ = try? await pipeline.data(for: request)
                case .memoryCache: _ = try? await pipeline.image(for: request)
                }
                self?.finished(request, id: id)
            }
            active[request] = Running(id: id, task: task)
        }
    }

    private func finished(_ request: VividImageRequest, id: UUID) {
        locked {
            if active[request]?.id == id { active.removeValue(forKey: request) }
            launchPending()
        }
    }

    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Lazy image view

struct VividImageState {
    let image: Image?
    let error: Error?
}

/// Shows artwork from the pipeline. A bitmap already in memory shows at once;
/// otherwise it loads while `isLoadingEnabled`, retrying short outages.
struct VividLazyImage<Content: View>: View {
    let request: VividImageRequest?
    let transaction: Transaction
    var isLoadingEnabled = true
    @ViewBuilder let content: (VividImageState) -> Content

    private struct LoadedImage {
        let request: VividImageRequest
        let image: UIImage
    }

    private struct LoadKey: Hashable {
        let request: VividImageRequest?
        let canPresentOrLoad: Bool
        let retryGeneration: Int
    }

    @SwiftUI.State private var loaded: LoadedImage?
    @SwiftUI.State private var failure: Error?
    @SwiftUI.State private var retryGeneration = 0

    var body: some View {
        let diagnostics = VividImageDiagnostics.shared
        let _ = diagnostics.count("leaf.VividLazyImage.body")
        let retained = loaded?.request == request ? loaded?.image : nil
        let available = retained ?? request.flatMap { VividImagePipeline.shared.cache[$0]?.image }
        // A shown bitmap keeps the task identity stable when the gate changes.
        // A missing image still restarts when permission to load changes.
        let key = LoadKey(
            request: request,
            canPresentOrLoad: isLoadingEnabled || available != nil,
            retryGeneration: retryGeneration
        )
        content(VividImageState(image: available.map(Image.init(uiImage:)), error: failure))
            .task(id: key) {
                diagnostics.count(request == nil ? "lazy.nilTask" : "lazy.taskStarted")
                failure = nil
                guard let request else {
                    loaded = nil
                    return
                }
                if let available {
                    if loaded?.request != request {
                        loaded = LoadedImage(request: request, image: available)
                    }
                    return
                }
                loaded = nil
                // Checked here rather than inferred from an earlier cache hit,
                // so a disabled row can never start a cache-miss load.
                guard isLoadingEnabled else {
                    diagnostics.count("lazy.gatedTask")
                    return
                }
                do {
                    let image = try await withTaskCancellationHandler {
                        try await VividImageRetry.recover {
                            try await VividImagePipeline.shared.image(for: request)
                        }
                    } onCancel: {
                        diagnostics.count("lazy.taskCancelled")
                    }
                    try Task.checkCancellation()
                    withTransaction(transaction) { loaded = LoadedImage(request: request, image: image) }
                } catch {
                    if !Task.isCancelled { failure = error }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                if !isLoadingEnabled { loaded = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // A shown error has used up its retries. Try again when the app
                // comes back, as the connection may have changed.
                if failure != nil, isLoadingEnabled { retryGeneration &+= 1 }
            }
            .onDisappear { diagnostics.count("lazy.disappear") }
    }
}
