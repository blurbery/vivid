// SPDX-License-Identifier: Apache-2.0
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
    func removeAll(caches: Caches) { memory.removeAllObjects() }
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
    init(costLimit: Int = 96 * 1024 * 1024, countLimit: Int = 180, diskCapacity: Int = 1_024 * 1024 * 1024) {
        cache = VividImageCache(costLimit: costLimit, countLimit: countLimit, diskCapacity: diskCapacity)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache.responses
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        decoding.maxConcurrentOperationCount = 2
        decoding.qualityOfService = .userInitiated
    }
    func image(for request: VividImageRequest) async throws -> UIImage {
        if let cached = cache[request] { return cached.image }
        let result = try await flights.load(request) { [self] in
            let data = try await data(for: request)
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                decoding.addOperation { [self] in
                    do {
                        let image = try Self.decode(data, request: request)
                        let result = VividImageContainer(image)
                        cache[request] = result
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        try Task.checkCancellation()
        return result.image
    }
    func data(for request: VividImageRequest) async throws -> Data {
        if request.url.isFileURL { return try Data(contentsOf: request.url, options: .mappedIfSafe) }
        let (data, response) = try await session.data(from: request.url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 32 * 1024 * 1024 else {
            throw URLError(.badServerResponse)
        }
        return data
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

private actor VividImageFlights {
    private var tasks: [VividImageRequest: (UUID, Task<VividImageContainer, Error>)] = [:]
    func load(_ request: VividImageRequest, operation: @escaping @Sendable () async throws -> VividImageContainer) async throws -> VividImageContainer {
        if let (_, existing) = tasks[request] { return try await existing.value }
        let id = UUID()
        let task = Task(priority: request.priority == .low ? .utility : .userInitiated) { try await operation() }
        tasks[request] = (id, task)
        defer { if tasks[request]?.0 == id { tasks[request] = nil } }
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
    @ViewBuilder let content: (VividImageState) -> Content
    @SwiftUI.State private var loaded: UIImage?
    @SwiftUI.State private var failure: Error?
    var body: some View {
        content(VividImageState(image: (loaded ?? request.flatMap { VividImagePipeline.shared.cache[$0]?.image }).map(Image.init(uiImage:)), error: failure))
            .task(id: request) {
                failure = nil
                loaded = request.flatMap { VividImagePipeline.shared.cache[$0]?.image }
                guard let request, loaded == nil else { return }
                do {
                    let image = try await VividImagePipeline.shared.image(for: request)
                    try Task.checkCancellation()
                    withTransaction(transaction) { loaded = image }
                } catch { if !Task.isCancelled { failure = error } }
            }
    }
}
