#if os(iOS)
import SwiftUI

/// The invisible touch surface between the video and the controls. Every
/// gesture on the bare picture lives here, so the controls can stay plain
/// buttons:
///
/// - Tap: show or hide the controls.
/// - Double tap in the outer 35% on either side: 10 seconds back or forward,
///   with a badge on that side. Double tap in the middle: play or pause.
/// - Touch and hold: 2x speed until released, with a chip at the top.
/// - Pinch out: Fit, then Fill, then Stretch. Pinch in steps back. A short
///   label at the top names the new mode.
///
/// Nothing here closes the player; only the close button does. The surface
/// is added once playback has loaded and ignores touches while the controls
/// are showing, so these gestures only work over the clear picture.
struct MobilePlayerGestureLayer: View {
    let viewModel: PlayerViewModel

    /// Where a double tap landed across the width.
    private enum TapZone {
        case back
        case middle
        case forward

        /// Share of the width at each edge that skips rather than toggles.
        static let edgeShare: CGFloat = 0.35

        init(x: CGFloat, width: CGFloat) {
            if x < width * Self.edgeShare {
                self = .back
            } else if x > width * (1 - Self.edgeShare) {
                self = .forward
            } else {
                self = .middle
            }
        }
    }

    /// The badge a double-tap skip shows. A new token per skip restarts the
    /// fade even for a repeat on the same side.
    private struct SkipBadge: Equatable {
        let isForward: Bool
        let token = UUID()
    }

    @State private var skipBadge: SkipBadge?
    @State private var skipBadgeTimer: Task<Void, Never>?
    /// The picture mode a pinch just picked, named briefly at the top.
    @State private var gravityLabel: VideoGravity?
    @State private var gravityLabelTimer: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                touchSurface(width: geometry.size.width)
                feedback(in: geometry.size)
            }
        }
        // The controls' scrim sits over this surface, but a covered sibling's
        // tap recognisers can still follow touches, and fast presses on the
        // 10 second buttons once counted here as a double-tap skip. So the
        // surface stops hit testing while the controls are up.
        .allowsHitTesting(!viewModel.showControls)
        .ignoresSafeArea()
        .onDisappear {
            // A reload or Next Up change can remove the surface mid-hold,
            // with no final pressing change to end it.
            viewModel.endHoldFastForward()
            skipBadgeTimer?.cancel()
            gravityLabelTimer?.cancel()
        }
    }

    // MARK: - Gestures

    private func touchSurface(width: CGFloat) -> some View {
        let tap = TapGesture().onEnded {
            viewModel.toggleControls(cause: .videoTap)
        }
        let doubleTap = SpatialTapGesture(count: 2).onEnded { value in
            handleDoubleTap(in: TapZone(x: value.location.x, width: width))
        }
        let pinch = MagnificationGesture().onEnded { scale in
            handlePinch(endingAt: scale)
        }
        return Color.clear
            .contentShape(Rectangle())
            .gesture(doubleTap.exclusively(before: tap))
            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 24) {
                viewModel.beginHoldFastForward()
            } onPressingChanged: { isPressing in
                guard !isPressing else { return }
                viewModel.endHoldFastForward()
            }
            .simultaneousGesture(pinch)
    }

    private func handleDoubleTap(in zone: TapZone) {
        // A recogniser can begin just before the controls appear; never skip
        // while they're up.
        if viewModel.showControls { return }
        // The badge is the feedback. Showing the controls would put their
        // scrim over this surface and eat the next double tap.
        switch zone {
        case .back:
            viewModel.skipBackward(10, revealingControls: false)
            flashSkip(forward: false)
        case .forward:
            viewModel.skipForward(10, revealingControls: false)
            flashSkip(forward: true)
        case .middle:
            viewModel.togglePlayPause(revealedBy: .doubleTapPlayPause)
        }
    }

    private func handlePinch(endingAt scale: CGFloat) {
        let step: Int
        if scale > 1.08 {
            step = 1
        } else if scale < 0.92 {
            step = -1
        } else {
            return
        }
        let chosen = Self.gravity(movedBy: step, from: viewModel.settings.videoGravity)
        viewModel.setVideoGravity(chosen)
        announceGravity(chosen)
    }

    /// Steps through Fit, Fill and Stretch, stopping at either end.
    private static func gravity(movedBy step: Int, from current: VideoGravity) -> VideoGravity {
        let order: [VideoGravity] = [.fit, .fill, .stretch]
        guard let position = order.firstIndex(of: current) else { return current }
        let target = min(max(position + step, 0), order.count - 1)
        return order[target]
    }

    // MARK: - Feedback

    private func flashSkip(forward: Bool) {
        skipBadge = SkipBadge(isForward: forward)
        skipBadgeTimer?.cancel()
        skipBadgeTimer = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.2)) { skipBadge = nil }
        }
    }

    private func announceGravity(_ gravity: VideoGravity) {
        withAnimation(.easeOut(duration: 0.15)) { gravityLabel = gravity }
        gravityLabelTimer?.cancel()
        gravityLabelTimer = Task {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.25)) { gravityLabel = nil }
        }
    }

    @ViewBuilder
    private func feedback(in size: CGSize) -> some View {
        let topCentre = CGPoint(x: size.width / 2, y: 46)

        if let badge = skipBadge {
            skipBadgeView(forward: badge.isForward)
                .position(x: size.width * (badge.isForward ? 0.82 : 0.18), y: size.height / 2)
                .transition(.opacity)
                .id(badge.token)
                .allowsHitTesting(false)
        }

        if let gravity = gravityLabel {
            glassChip {
                Image(systemName: Self.symbol(for: gravity))
                    .font(.system(size: 12, weight: .semibold))
                Text(gravity.label)
                    .font(.system(size: 14, weight: .bold))
            }
            .position(topCentre)
            .transition(.opacity)
            .allowsHitTesting(false)
        }

        if viewModel.isHoldFastForwarding {
            glassChip {
                Text("2×")
                    .font(.system(size: 14, weight: .bold))
                Image(systemName: "forward.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .position(topCentre)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func skipBadgeView(forward: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: forward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 26, weight: .semibold))
            Text(forward ? "+10s" : "−10s")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: 74, height: 74)
        .vividPlayerGlass(in: Circle())
    }

    /// The small glass capsule the top-of-screen labels share.
    private func glassChip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .vividPlayerGlass(in: Capsule())
    }

    private static func symbol(for gravity: VideoGravity) -> String {
        switch gravity {
        case .fit: "rectangle.arrowtriangle.2.inward"
        case .fill: "rectangle.arrowtriangle.2.outward"
        case .stretch: "arrow.left.and.right.square"
        }
    }
}
#endif
