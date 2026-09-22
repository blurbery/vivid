#if os(tvOS) || os(iOS)
import SwiftUI
import Vision

struct TVSpotlightBackdropImage: View {
    let url: String
    let size: CGSize
    var fillsViewport = false
    var onReady: () -> Void = {}
    @State private var image: UIImage?
    @State private var subject: CGRect?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                let crop = TVSpotlightCrop.layout(image: image.size, viewport: size, subject: subject, fillsViewport: fillsViewport)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: crop.size.width, height: crop.size.height)
                    .offset(x: crop.origin.x, y: crop.origin.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .task(id: "\(url)#\(size)#\(displayScale)") {
            let base = MediaServerProvider.active == .silo
                ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
            guard let imageURL = SiloAPICompatibility.artworkURL(url, relativeTo: base) else {
                onReady()
                return
            }
            let request = PosterImageCache.displayRequest(
                url: imageURL,
                pixelSize: CGSize(width: size.width * displayScale, height: size.height * displayScale)
            )
            let loaded: UIImage
            do { loaded = try await VividImagePipeline.shared.image(for: request) }
            catch {
                // The existing background and text are the terminal fallback.
                if !Task.isCancelled { onReady() }
                return
            }
            guard !Task.isCancelled else { return }
            #if os(tvOS)
            let region = await TVHomeMetadataCache.shared.preparedSpotlightSubject(in: loaded, url: imageURL.absoluteString)
            #else
            let task = Task.detached(priority: .utility) { await TVSpotlightCrop.prepareSubject(in: loaded, key: request.cacheScope + "|" + imageURL.absoluteString) }
            let region = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            #endif
            guard !Task.isCancelled else { return }
            subject = region
            image = loaded
            onReady()
        }
    }
}

enum TVSpotlightCrop {
    private actor SubjectPreparation {
        func prepare(_ image: UIImage, key: String) -> CGRect? {
            guard !Task.isCancelled else { return nil }
            return TVSpotlightCrop.subject(in: image, key: key)
        }
    }
    private static let preparation = SubjectPreparation()

    static func prepareSubject(in image: UIImage, key: String) async -> CGRect? {
        await preparation.prepare(image, key: key)
    }

    private static let subjects: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 40
        return cache
    }()

    static func subject(in image: UIImage, key: String) -> CGRect? {
        let cached = subjects.object(forKey: key as NSString)
        if let cached { return cached.cgRectValue.isNull ? nil : cached.cgRectValue }
        guard !Task.isCancelled, let source = image.cgImage else { return nil }
        // Avoid UIImage's synchronous preparation service here. Home is
        // already decoding images concurrently, and crop work must not join
        // that service or contend with playback's GPU work.
        let scale = min(1, 768 / CGFloat(max(source.width, source.height)))
        let width = max(1, Int(CGFloat(source.width) * scale))
        let height = max(1, Int(CGFloat(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { return nil }
        let handler = VNImageRequestHandler(cgImage: thumbnail)
        let faces = VNDetectFaceRectanglesRequest()
        faces.usesCPUOnly = true
        try? handler.perform([faces])
        guard !Task.isCancelled else { return nil }
        var bounds = (faces.results ?? []).filter { $0.confidence >= 0.35 }
            .map { face in
                let rect = face.boundingBox
                return rect.insetBy(dx: -rect.width * 0.18, dy: -rect.height * 0.4)
            }
            .reduce(CGRect.null) { $0.union($1) }
        if bounds.isNull {
            let people = VNDetectHumanRectanglesRequest()
            people.usesCPUOnly = true
            people.upperBodyOnly = true
            try? handler.perform([people])
            guard !Task.isCancelled else { return nil }
            bounds = (people.results ?? []).filter { $0.confidence >= 0.45 }
                .map { person in
                    let rect = person.boundingBox
                    return CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.32,
                                  width: rect.width, height: rect.height * 0.32)
                }
                .reduce(CGRect.null) { $0.union($1) }
        }
        if bounds.isNull {
            let attention = VNGenerateAttentionBasedSaliencyImageRequest()
            attention.usesCPUOnly = true
            try? handler.perform([attention])
            bounds = (attention.results?.first?.salientObjects ?? [])
                .map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        }
        let topOrigin = bounds.isNull ? CGRect.null : CGRect(
            x: bounds.minX, y: 1 - bounds.maxY, width: bounds.width, height: bounds.height
        ).insetBy(dx: -0.04, dy: -0.08).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        subjects.setObject(NSValue(cgRect: topOrigin), forKey: key as NSString)
        return topOrigin.isNull ? nil : topOrigin
    }

    static func layout(image: CGSize, viewport: CGSize, subject: CGRect?, fillsViewport: Bool = false) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: viewport) }
        let fit = min(viewport.width / image.width, viewport.height / image.height)
        let fill = max(viewport.width / image.width, viewport.height / image.height)
        let scale = fillsViewport ? fill : min(fill, fit * 1.2)
        let rendered = CGSize(width: image.width * scale, height: image.height * scale)
        func position(length: CGFloat, viewport: CGFloat, minSubject: CGFloat?, maxSubject: CGFloat?, target: CGFloat) -> CGFloat {
            guard length > viewport else { return viewport - length }
            let proposed = viewport * target - ((minSubject ?? 0) + (maxSubject ?? 1)) / 2 * length
            var offset = min(0, max(viewport - length, proposed))
            if let minSubject, let maxSubject {
                let lower = max(viewport - length, -minSubject * length)
                let upper = min(0, viewport - maxSubject * length)
                if lower <= upper { offset = min(upper, max(lower, offset)) }
            }
            return offset
        }
        let verticalOffset: CGFloat
        if rendered.height <= viewport.height {
            verticalOffset = viewport.height - rendered.height
        } else if let subject {
            let headroom = viewport.height * 0.12
            verticalOffset = min(0, max(viewport.height - rendered.height,
                                      headroom - subject.minY * rendered.height))
        } else {
            verticalOffset = (viewport.height - rendered.height) * 0.15
        }
        return CGRect(
            x: position(length: rendered.width, viewport: viewport.width, minSubject: subject?.minX, maxSubject: subject?.maxX, target: 0.62),
            y: verticalOffset,
            width: rendered.width, height: rendered.height
        )
    }
}
#endif
