// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation
import ImageIO
import SwiftUI
import UIKit

struct VividImageRequest: Hashable, Sendable {
    enum Priority: Sendable { case low, normal, high }
    struct ThumbnailOptions: Hashable, Sendable {
        enum Unit { case pixels }
        enum ContentMode { case aspectFill, aspectFit }
        let width: Int
        let height: Int
        let fill: Bool
        init(maxPixelSize: Float) { width = Int(maxPixelSize); height = Int(maxPixelSize); fill = false }
        init(size: CGSize, unit: Unit, contentMode: ContentMode) {
            width = max(1, Int(size.width.rounded(.up)))
            height = max(1, Int(size.height.rounded(.up)))
            fill = contentMode == .aspectFill
        }
    }
    let url: URL
    var priority: Priority
    var thumbnail: ThumbnailOptions?
    init(url: URL, priority: Priority = .normal) { self.url = url; self.priority = priority }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url && lhs.thumbnail == rhs.thumbnail }
    func hash(into hasher: inout Hasher) { hasher.combine(url); hasher.combine(thumbnail) }
    var key: NSString {
        "\(url.absoluteString)|\(thumbnail?.width ?? 0)x\(thumbnail?.height ?? 0)|\(thumbnail?.fill ?? false)" as NSString
    }
}

final class VividImageContainer: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

final class VividImageCache: @unchecked Sendable {
    enum Caches { case memory }
    private let memory = NSCache<NSString, VividImageContainer>()
    let responses: URLCache
    private let generationLock = NSLock()
    private var generation = 0
    init(costLimit: Int, countLimit: Int, diskCapacity: Int) {
        memory.totalCostLimit = costLimit
        memory.countLimit = countLimit
        responses = URLCache(memoryCapacity: 0, diskCapacity: diskCapacity,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("com.vivid.app.artwork", isDirectory: true))
    }
    subscript(request: VividImageRequest) -> VividImageContainer? {
        get { memory.object(forKey: request.key) }
        set {
            if let newValue {
                let cost = newValue.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
                memory.setObject(newValue, forKey: request.key, cost: cost)
            } else { memory.removeObject(forKey: request.key) }
        }
    }
    #if os(tvOS)
    func setMemoryLimits(cost: Int, count: Int) {
        memory.totalCostLimit = cost
        memory.countLimit = count
    }
    #endif
    var currentGeneration: Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation
    }
    func store(_ image: VividImageContainer, for request: VividImageRequest, generation expected: Int) {
        generationLock.lock(); defer { generationLock.unlock() }
        guard generation == expected else { return }
        self[request] = image
    }
    func removeAll(caches: Caches) {
        generationLock.lock(); defer { generationLock.unlock() }
        generation &+= 1
        memory.removeAllObjects()
    }
    func containsData(for request: VividImageRequest) -> Bool { responses.cachedResponse(for: URLRequest(url: request.url)) != nil }
    func removeCachedData(for request: VividImageRequest) { responses.removeCachedResponse(for: URLRequest(url: request.url)) }
    func removeCachedImage(for request: VividImageRequest, caches: Caches) { memory.removeObject(forKey: request.key) }
}

final class VividImagePipeline: @unchecked Sendable {
    static var shared = VividImagePipeline()
    let cache: VividImageCache
    private let session: URLSession
    private let decoding = OperationQueue()
    private let flights = VividImageFlights()
    #if os(tvOS)
    private let embyDataFlights = VividEmbyImageDataFlights()
    #endif
    init(costLimit: Int = 96 * 1024 * 1024, countLimit: Int = 180, diskCapacity: Int = 1_024 * 1024 * 1024) {
        cache = VividImageCache(costLimit: costLimit, countLimit: countLimit, diskCapacity: diskCapacity)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache.responses
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        decoding.maxConcurrentOperationCount = 2
        #if os(tvOS)
        decoding.qualityOfService = .utility
        #else
        decoding.qualityOfService = .userInitiated
        #endif
    }
    func image(for request: VividImageRequest) async throws -> UIImage {
        let diagnostics = VividImageDiagnostics.shared
        if let cached = cache[request] {
            diagnostics.count("memory.hit")
            return cached.image
        }
        diagnostics.count("memory.miss")
        let cacheGeneration = cache.currentGeneration
        let result = try await flights.load(request) { [self] in
            let dataStart = diagnostics.timestamp
            let data = try await data(for: request)
            diagnostics.duration("dataWait", since: dataStart)
            try Task.checkCancellation()
            let queuedAt = diagnostics.timestamp
            let qos = request.priority == .low ? "utility" : "demand"
            return try await withCheckedThrowingContinuation { continuation in
                let operation = BlockOperation { [self] in
                    diagnostics.duration("decodeQueue.\(qos)", since: queuedAt)
                    let decodeStart = diagnostics.timestamp
                    defer { diagnostics.duration("decode.\(qos)", since: decodeStart) }
                    do {
                        let image = try Self.decode(data, request: request)
                        let result = VividImageContainer(image)
                        cache.store(result, for: request, generation: cacheGeneration)
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
                #if os(tvOS)
                operation.qualityOfService = request.priority == .low ? .utility : .userInitiated
                operation.queuePriority = request.priority == .low ? .low : .normal
                #endif
                decoding.addOperation(operation)
            }
        }
        try Task.checkCancellation()
        return result.image
    }
    func removeCachedArtwork(for urls: Set<URL>) async {
        cache.removeAll(caches: .memory)
        await flights.cancel(urls: urls)
        #if os(tvOS)
        await embyDataFlights.cancel(urls: urls)
        #endif
        for url in urls { cache.removeCachedData(for: VividImageRequest(url: url)) }
    }

    func data(for request: VividImageRequest) async throws -> Data {
        if request.url.isFileURL { return try Data(contentsOf: request.url, options: .mappedIfSafe) }
        #if os(tvOS)
        // Emby's generated artwork URLs are shared by display-size, crop and
        // palette requests. Share their bytes before doing separate decodes.
        if request.url.path.contains("/emby/Items/"), request.url.path.contains("/Images/") {
            return try await embyDataFlights.load(request.url) { [self] in
                try await fetchData(for: request)
            }
        }
        #endif
        return try await fetchData(for: request)
    }

    private func fetchData(for request: VividImageRequest) async throws -> Data {
        let delegate = VividImageDiagnostics.shared.enabled ? VividImageMetricsDelegate.shared : nil
        let (data, response) = try await session.data(from: request.url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 32 * 1024 * 1024 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
    func diagnosticDecodeOperations() -> [Double] {
        guard VividImageDiagnostics.shared.enabled else { return [] }
        let operations = decoding.operations
        return [Double(operations.count),
                Double(operations.filter { $0.qualityOfService == .userInitiated }.count),
                Double(operations.filter { $0.qualityOfService == .utility }.count),
                Double(operations.filter(\.isExecuting).count)]
    }
    private static func decode(_ data: Data, request: VividImageRequest) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
        var maximum = min(max(width, height), 4096)
        if let thumbnail = request.thumbnail {
            let x = Double(thumbnail.width) / max(1, width)
            let y = Double(thumbnail.height) / max(1, height)
            let scale = thumbnail.fill ? max(x, y) : min(x, y)
            maximum = min(4096, max(1, ceil(max(width, height) * min(1, scale))))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: image)
    }
}

/// Coalesce Emby artwork independently of thumbnail size. Retry one transient
/// transport failure; cancellations and HTTP failures are never retried here.
private actor VividEmbyImageDataFlights {
    private var tasks: [URL: (UUID, Task<Data, Error>)] = [:]

    func cancel(urls: Set<URL>) {
        for url in urls { tasks.removeValue(forKey: url)?.1.cancel() }
    }

    func load(_ url: URL, operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let diagnostics = VividImageDiagnostics.shared
        if let (id, existing) = tasks[url] {
            if diagnostics.enabled {
                return try await diagnostics.value(of: existing, id: id, token: diagnostics.join(id, utility: false))
            }
            return try await existing.value
        }
        let id = UUID()
        diagnostics.created(id, kind: "dataFlight", utility: false)
        let task = Task {
            defer { diagnostics.completed(id, cancelled: Task.isCancelled) }
            do { return try await operation() }
            catch {
                let failure = error as NSError
                guard failure.domain == NSURLErrorDomain,
                      [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains(failure.code) else { throw error }
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                return try await operation()
            }
        }
        tasks[url] = (id, task)
        defer { if tasks[url]?.0 == id { tasks[url] = nil } }
        if diagnostics.enabled {
            return try await diagnostics.value(of: task, id: id, token: diagnostics.join(id, utility: false))
        }
        return try await task.value
    }
}

private actor VividImageFlights {
    private var tasks: [VividImageRequest: (UUID, Task<VividImageContainer, Error>)] = [:]
    func cancel(urls: Set<URL>) {
        for request in Array(tasks.keys) where urls.contains(request.url) {
            tasks.removeValue(forKey: request)?.1.cancel()
        }
    }

    func load(_ request: VividImageRequest, operation: @escaping @Sendable () async throws -> VividImageContainer) async throws -> VividImageContainer {
        let diagnostics = VividImageDiagnostics.shared
        let utility = request.priority == .low
        if let (id, existing) = tasks[request] {
            if diagnostics.enabled {
                return try await diagnostics.value(of: existing, id: id, token: diagnostics.join(id, utility: utility))
            }
            return try await existing.value
        }
        let id = UUID()
        diagnostics.created(id, kind: "flight", utility: utility)
        let createdAt = diagnostics.timestamp
        let task = Task(priority: utility ? .utility : .userInitiated) {
            diagnostics.duration("flightStartWait", since: createdAt)
            defer { diagnostics.completed(id, cancelled: Task.isCancelled) }
            return try await operation()
        }
        tasks[request] = (id, task)
        defer { if tasks[request]?.0 == id { tasks[request] = nil } }
        if diagnostics.enabled {
            return try await diagnostics.value(of: task, id: id, token: diagnostics.join(id, utility: utility))
        }
        return try await task.value
    }
}

final class VividImagePrefetcher: @unchecked Sendable {
    enum Destination { case memoryCache, diskCache }
    var priority: VividImageRequest.Priority = .normal
    private let pipeline: VividImagePipeline
    private let destination: Destination
    private let limit: Int
    private let lock = NSLock()
    private var pending: [VividImageRequest] = []
    private var active: [VividImageRequest: (UUID, Task<Void, Never>)] = [:]
    init(pipeline: VividImagePipeline, destination: Destination, maxConcurrentRequestCount: Int = 2) {
        self.pipeline = pipeline; self.destination = destination; limit = max(1, maxConcurrentRequestCount)
    }
    func startPrefetching(with urls: [URL]) { startPrefetching(with: urls.map { VividImageRequest(url: $0, priority: priority) }) }
    func startPrefetching(with requests: [VividImageRequest]) {
        lock.lock()
        for request in requests where active[request] == nil && !pending.contains(request) { pending.append(request) }
        launchLocked()
        lock.unlock()
    }
    #if os(tvOS)
    /// Reprioritise upcoming Home work without detaching active shared downloads.
    func replacePendingPrefetching(with requests: [VividImageRequest]) {
        lock.lock()
        var seen = Set<VividImageRequest>()
        pending = requests.filter { active[$0] == nil && seen.insert($0).inserted }
        launchLocked()
        lock.unlock()
    }
    #endif
    func stopPrefetching(with urls: [URL]) { stopPrefetching(with: urls.map { VividImageRequest(url: $0) }) }
    func stopPrefetching(with requests: [VividImageRequest]) {
        lock.lock()
        pending.removeAll { requests.contains($0) }
        for request in requests { active.removeValue(forKey: request)?.1.cancel() }
        launchLocked()
        lock.unlock()
    }
    func stopPrefetching() {
        lock.lock(); pending.removeAll(); let tasks = active.values; active.removeAll(); lock.unlock()
        for (_, task) in tasks { task.cancel() }
    }
    private func launchLocked() {
        while active.count < limit && !pending.isEmpty {
            let request = pending.removeFirst()
            let id = UUID()
            let task = Task { [weak self, pipeline, destination] in
                if destination == .diskCache { _ = try? await pipeline.data(for: request) }
                else { _ = try? await pipeline.image(for: request) }
                self?.finished(request, id: id)
            }
            active[request] = (id, task)
        }
    }
    private func finished(_ request: VividImageRequest, id: UUID) {
        lock.lock()
        if active[request]?.0 == id { active.removeValue(forKey: request) }
        launchLocked(); lock.unlock()
    }
    deinit { for (_, task) in active.values { task.cancel() } }
}

struct VividImageState {
    let image: Image?
    let error: Error?
}

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
    }
    @SwiftUI.State private var loaded: LoadedImage?
    @SwiftUI.State private var failure: Error?
    var body: some View {
        let _ = VividImageDiagnostics.shared.count("leaf.VividLazyImage.body")
        let retained = loaded?.request == request ? loaded?.image : nil
        let availableImage = retained ?? request.flatMap { VividImagePipeline.shared.cache[$0]?.image }
        // A displayed bitmap keeps the task identity stable across gate changes.
        // Missing images still restart when permission to load changes.
        let key = LoadKey(request: request, canPresentOrLoad: isLoadingEnabled || availableImage != nil)
        content(VividImageState(image: availableImage.map(Image.init(uiImage:)), error: failure))
            .task(id: key) {
                VividImageDiagnostics.shared.count(request == nil ? "lazy.nilTask" : "lazy.taskStarted")
                failure = nil
                guard let request else { loaded = nil; return }
                if let availableImage {
                    if loaded?.request != request {
                        loaded = LoadedImage(request: request, image: availableImage)
                    }
                    return
                }
                loaded = nil
                // Permission is checked here, not inferred from an earlier
                // cache hit. A disabled row can never start a cache-miss load.
                guard isLoadingEnabled else {
                    VividImageDiagnostics.shared.count("lazy.gatedTask")
                    return
                }
                do {
                    let image = try await withTaskCancellationHandler {
                        try await VividImagePipeline.shared.image(for: request)
                    } onCancel: {
                        VividImageDiagnostics.shared.count("lazy.taskCancelled")
                    }
                    try Task.checkCancellation()
                    withTransaction(transaction) { loaded = LoadedImage(request: request, image: image) }
                } catch { if !Task.isCancelled { failure = error } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                if !isLoadingEnabled { loaded = nil }
            }
            .onDisappear { VividImageDiagnostics.shared.count("lazy.disappear") }
    }
}
