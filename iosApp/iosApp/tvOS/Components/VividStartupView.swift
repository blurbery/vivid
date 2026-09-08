#if os(tvOS) || os(iOS)
import SwiftUI
import MetalKit

struct VividStartupView: View {
    let isContentReady: Bool
    var statusText: String? = nil
    let onCompletion: () -> Void
    @State private var animationFinished = false
    @State private var completed = false
    @State private var renderingUnavailable = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if renderingUnavailable {
                VividLogoView(size: 480)
            } else {
                VividStarCanvas(
                    reduceMotion: reduceMotion,
                    isActive: scenePhase == .active,
                    onCompletion: { animationFinished = true },
                    onUnavailable: {
                        renderingUnavailable = true
                        animationFinished = true
                    }
                )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 720, maxHeight: 720)
            }
        }
        .overlay {
            if let statusText {
                VStack {
                    Spacer().frame(height: 620)
                    Text(statusText)
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .id(statusText)
                        .transition(.opacity)
                }
                .frame(height: 720, alignment: .top)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: statusText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusText ?? "Vivid is loading")
        .onChange(of: animationFinished) { _, _ in finishIfReady() }
        .onChange(of: isContentReady) { _, _ in finishIfReady() }
    }

    private func finishIfReady() {
        guard animationFinished, isContentReady, !completed else { return }
        completed = true
        onCompletion()
    }
}

private struct VividStarCanvas: UIViewRepresentable {
    let reduceMotion: Bool
    let isActive: Bool
    let onCompletion: () -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        view.isOpaque = true
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = false
        guard let renderer = VividStarRenderer(view: view, onCompletion: onCompletion) else {
            view.isPaused = true
            DispatchQueue.main.async(execute: onUnavailable)
            return view
        }
        context.coordinator.renderer = renderer
        view.delegate = renderer
        renderer.update(view: view, reduceMotion: reduceMotion, isActive: isActive)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.update(view: view, reduceMotion: reduceMotion, isActive: isActive)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }

    final class Coordinator {
        var renderer: VividStarRenderer?
    }
}

private final class VividStarRenderer: NSObject, MTKViewDelegate {
    private struct Star {
        let homeScatter: SIMD4<Float>
        let angle: SIMD4<Float>
    }
    private struct Uniforms {
        var assembly: Float
        var pixels: Float
    }

    private let queue: MTLCommandQueue
    private let markPipeline: MTLRenderPipelineState
    private let starPipeline: MTLRenderPipelineState
    private let texture: MTLTexture
    private let stars: MTLBuffer
    private let starCount: Int
    private let onCompletion: () -> Void
    private var elapsed: Double = 0
    private var previousTime: CFTimeInterval?
    private var finished = false
    private var reduceMotion = false

    init?(view: MTKView, onCompletion: @escaping () -> Void) {
        guard let device = view.device,
              let queue = device.makeCommandQueue(),
              let sourceURL = Bundle.main.url(forResource: "VividStarAnimation.metal", withExtension: "txt"),
              let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let library = try? device.makeLibrary(source: source, options: nil),
              let image = UIImage(named: "VividMarkSource")?.cgImage,
              let texture = try? MTKTextureLoader(device: device).newTexture(
                cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
              ) else { return nil }

        func pipeline(vertex: String, fragment: String, blending: Bool) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = blending
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let markPipeline = pipeline(vertex: "vividMarkVertex", fragment: "vividMarkFragment", blending: false),
              let starPipeline = pipeline(vertex: "vividStarVertex", fragment: "vividStarFragment", blending: true),
              let pixels = CGContext(
                data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        pixels.interpolationQuality = .high
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        guard let rgba = pixels.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var particles: [Star] = []
        for y in stride(from: 0, to: 96, by: 2) {
            for x in 0..<96 where rgba[(y * 96 + x) * 4 + 3] >= 180 {
                let seed = Double(x * 197 + y * 9277)
                func random(_ n: Double) -> Float {
                    let value = sin(seed + n * 71.7) * 43758.5453
                    return Float(value - floor(value))
                }
                particles.append(Star(
                    homeScatter: SIMD4((Float(x) + 0.5) / 48 - 1, 1 - (Float(y) + 0.5) / 48,
                                       0.18 + random(1) * 0.62, 0.2 + random(2) * 0.8),
                    angle: SIMD4(random(3) * .pi * 2, 0, 0, 0)
                ))
            }
        }
        guard !particles.isEmpty,
              let stars = device.makeBuffer(bytes: particles, length: particles.count * MemoryLayout<Star>.stride) else { return nil }
        self.queue = queue
        self.markPipeline = markPipeline
        self.starPipeline = starPipeline
        self.texture = texture
        self.stars = stars
        self.starCount = particles.count
        self.onCompletion = onCompletion
        super.init()
    }

    func update(view: MTKView, reduceMotion: Bool, isActive: Bool) {
        self.reduceMotion = reduceMotion
        if !isActive { previousTime = nil }
        view.isPaused = finished || !isActive
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !finished,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        if let previousTime { elapsed += min(max(now - previousTime, 0), 0.05) }
        previousTime = now
        let progress = reduceMotion ? 1 : min(elapsed / 2.35, 1)
        var uniforms = Uniforms(assembly: Float(progress * progress * (3 - 2 * progress)), pixels: Float(view.drawableSize.width))
        encoder.setRenderPipelineState(markPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if uniforms.assembly < 0.999 {
            encoder.setRenderPipelineState(starPipeline)
            encoder.setVertexBuffer(stars, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
        }
        encoder.endEncoding()
        command.present(drawable)
        if progress >= 1 {
            finished = true
            view.isPaused = true
            let completion = onCompletion
            command.addCompletedHandler { _ in DispatchQueue.main.async(execute: completion) }
        }
        command.commit()
    }
}
#endif
