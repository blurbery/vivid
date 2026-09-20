#if os(tvOS) || os(iOS)
import SwiftUI
import UIKit

struct VividStartupView: View {
    let isContentReady: Bool
    var statusText: String? = nil
    let onCompletion: () -> Void
    @State private var animationFinished = false
    @State private var completed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                let canvasSize = min(geometry.size.width, geometry.size.height, 720)
                VividGlideLogo(size: canvasSize / 1.5) {
                    animationFinished = true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct VividGlideLogo: View {
    let size: CGFloat
    var onCompletion: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var arrived = false
    @State private var finished = false

    private static let hasPieces = UIImage(named: "VividMarkLeft") != nil
        && UIImage(named: "VividMarkRight") != nil

    var body: some View {
        ZStack {
            if finished || reduceMotion || !Self.hasPieces {
                VividLogoView(size: size)
            } else {
                piece("VividMarkLeft", direction: -1, delay: 0)
                piece("VividMarkRight", direction: 1, delay: 0.144)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vivid")
        .task(id: scenePhase) {
            guard !finished, scenePhase == .active else { return }
            guard !reduceMotion, Self.hasPieces else {
                finish()
                return
            }
            arrived = true
            do {
                try await Task.sleep(for: .seconds(1.344))
            } catch { return }
            guard !Task.isCancelled else { return }
            finish()
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { finish() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Finish in place when interrupted, without replaying on return.
            if phase != .active && arrived { finish() }
        }
    }

    private func piece(_ name: String, direction: CGFloat, delay: Double) -> some View {
        Image(name)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .offset(x: arrived ? 0 : direction * size * 30 / 346,
                    y: arrived ? 0 : -size * 20 / 346)
            .opacity(arrived ? 1 : 0)
            .animation(.timingCurve(0.22, 0.75, 0.18, 1, duration: 1.2).delay(delay), value: arrived)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onCompletion()
    }
}
#endif
