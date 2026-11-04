#if os(iOS)
import SwiftUI

/// The full-screen touch layer between the video and the controls. It owns
/// the player's invisible gestures, so the controls stay plain buttons:
///
/// - A tap shows or hides the controls.
/// - A double tap on the left or right 35% skips 10 seconds back or forward,
///   with a flash on that side. A double tap in the middle plays or pauses.
/// - Touch and hold plays at 2x while held, with a chip at the top.
/// - Pinching out steps the picture from Fit to Fill to Stretch, and pinching
///   in steps back, with a short label at the top.
///
/// No drag closes the player; only the close button does. The layer is
/// mounted once playback has loaded, and it stops taking touches while the
/// controls are up, so these gestures only work over the clean picture.
struct MobilePlayerGestureLayer: View {
    let viewModel: PlayerViewModel

    private struct SkipFlash: Equatable {
        let forward: Bool
        let id: UUID
    }

    @State private var skipFlash: SkipFlash?
    @State private var skipFlashHideTask: Task<Void, Never>?

    /// The picture mode a pinch chose, shown briefly at the top.
    @State private var gravityToast: VideoGravity?
    @State private var gravityToastHideTask: Task<Void, Never>?

    /// The share of the width on each side where a double tap skips. A
    /// double tap in the middle plays or pauses instead.
    private static let skipZoneFraction: CGFloat = 0.35

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(doubleTapGesture(in: size).exclusively(before: singleTapGesture))
                    .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 24) {
                        viewModel.beginHoldFastForward()
                    } onPressingChanged: { pressing in
                        if !pressing {
                            viewModel.endHoldFastForward()
                        }
                    }
                    .simultaneousGesture(videoGravityPinchGesture)

                feedbackOverlays(in: size)
            }
        }
        // The controls' scrim covers this layer, but tap recognisers on a
        // covered sibling can still track touches: quick presses on the 10
        // second buttons used to register here as a double-tap skip. So the
        // layer leaves hit testing while the controls are up.
        .allowsHitTesting(!viewModel.showControls)
        .ignoresSafeArea()
        .onDisappear {
            // The layer can go mid-gesture (a reload, a Next Up change)
            // without a final onPressingChanged(false).
            viewModel.endHoldFastForward()
            skipFlashHideTask?.cancel()
            gravityToastHideTask?.cancel()
        }
    }

    // MARK: - Gestures

    private var singleTapGesture: some Gesture {
        TapGesture().onEnded { viewModel.toggleControls(cause: .videoTap) }
    }

    private func doubleTapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            // A recogniser can start tracking just before the controls
            // appear. Never skip while they're up.
            guard !viewModel.showControls else { return }
            let x = value.location.x
            // The flash is the feedback. Showing the controls would put
            // their scrim over this layer and swallow the next double tap.
            if x < size.width * Self.skipZoneFraction {
                viewModel.skipBackward(10, revealingControls: false)
                showSkipFlash(forward: false)
            } else if x > size.width * (1 - Self.skipZoneFraction) {
                viewModel.skipForward(10, revealingControls: false)
                showSkipFlash(forward: true)
            } else {
                viewModel.togglePlayPause(revealedBy: .doubleTapPlayPause)
            }
        }
    }

    private var videoGravityPinchGesture: some Gesture {
        MagnificationGesture()
            .onEnded { scale in
                if scale > 1.08 {
                    let gravity = nextVideoGravity(after: viewModel.settings.videoGravity)
                    viewModel.setVideoGravity(gravity)
                    showGravityToast(gravity)
                } else if scale < 0.92 {
                    let gravity = previousVideoGravity(before: viewModel.settings.videoGravity)
                    viewModel.setVideoGravity(gravity)
                    showGravityToast(gravity)
                }
            }
    }

    private func nextVideoGravity(after gravity: VideoGravity) -> VideoGravity {
        switch gravity {
        case .fit: return .fill
        case .fill: return .stretch
        case .stretch: return .stretch
        }
    }

    private func previousVideoGravity(before gravity: VideoGravity) -> VideoGravity {
        switch gravity {
        case .fit: return .fit
        case .fill: return .fit
        case .stretch: return .fill
        }
    }

    // MARK: - Transient feedback

    private func showSkipFlash(forward: Bool) {
        skipFlash = SkipFlash(forward: forward, id: UUID())
        skipFlashHideTask?.cancel()
        skipFlashHideTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { skipFlash = nil }
        }
    }

    private func showGravityToast(_ gravity: VideoGravity) {
        withAnimation(.easeOut(duration: 0.15)) { gravityToast = gravity }
        gravityToastHideTask?.cancel()
        gravityToastHideTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { gravityToast = nil }
        }
    }

    @ViewBuilder
    private func feedbackOverlays(in size: CGSize) -> some View {
        if let flash = skipFlash {
            skipFlashView(flash)
                .position(
                    x: flash.forward ? size.width * 0.82 : size.width * 0.18,
                    y: size.height / 2
                )
                .transition(.opacity)
                .id(flash.id)
                .allowsHitTesting(false)
        }

        if let gravity = gravityToast {
            gravityToastChip(for: gravity)
                .position(x: size.width / 2, y: 46)
                .transition(.opacity)
                .allowsHitTesting(false)
        }

        if viewModel.isHoldFastForwarding {
            holdFastForwardChip
                .position(x: size.width / 2, y: 46)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func skipFlashView(_ flash: SkipFlash) -> some View {
        VStack(spacing: 3) {
            Image(systemName: flash.forward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 26, weight: .semibold))
            Text(flash.forward ? "+10s" : "−10s")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: 74, height: 74)
        .vividPlayerGlass(in: Circle())
    }

    private func gravityToastChip(for gravity: VideoGravity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: gravityToastIcon(for: gravity))
                .font(.system(size: 12, weight: .semibold))
            Text(gravity.label)
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .vividPlayerGlass(in: Capsule())
    }

    private func gravityToastIcon(for gravity: VideoGravity) -> String {
        switch gravity {
        case .fit:     return "rectangle.arrowtriangle.2.inward"
        case .fill:    return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.left.and.right.square"
        }
    }

    private var holdFastForwardChip: some View {
        HStack(spacing: 6) {
            Text("2×")
                .font(.system(size: 14, weight: .bold))
            Image(systemName: "forward.fill")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .vividPlayerGlass(in: Capsule())
    }
}
#endif
