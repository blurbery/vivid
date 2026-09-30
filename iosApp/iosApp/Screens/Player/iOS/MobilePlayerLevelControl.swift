#if os(iOS)
import AVFAudio
import MediaPlayer
import SwiftUI
import UIKit

/// A relative vertical drag avoids jumping to a new level on first contact.
/// The whole capsule is a touch target; the centre of the player stays free.
struct MobilePlayerLevelControl: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let height: CGFloat

    @Environment(\.mobilePlayerControlPressChanged) private var pressChanged
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var isDragging = false
    @State private var dragStartValue: Double?

    private var percentage: String { "\(Int((value * 100).rounded()))%" }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(height: 18)

            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.18))
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(.white)
                            .frame(height: proxy.size.height * value)
                    }
            }
            .frame(width: 4)

            Text(percentage)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(.vertical, 12)
        .frame(width: 44, height: height)
        .vividPlayerGlass(in: Capsule())
        .opacity(isEnabled ? 1 : 0.45)
        .overlay(Capsule().strokeBorder(.white.opacity(isDragging ? 0.4 : 0.12), lineWidth: 0.5))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged { drag in
                    guard isEnabled else { return }
                    if dragStartValue == nil {
                        dragStartValue = value
                        pressChanged(true)
                    }
                    value = min(max((dragStartValue ?? value)
                        - Double(drag.translation.height / height), 0), 1)
                }
        )
        // GestureState also resets on cancellation, including rotation or
        // dismissal, so an interrupted drag cannot leave auto-hide suspended.
        .onChange(of: isDragging) { _, dragging in
            if !dragging { endDrag() }
        }
        .onDisappear { endDrag() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(percentage)
        .accessibilityHint(isEnabled
            ? "Swipe up to increase or down to decrease"
            : "Volume adjustment is unavailable for this audio output")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            pressChanged(true)
            switch direction {
            case .increment: value = min(value + 0.05, 1)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
            pressChanged(false)
        }
    }

    private func endDrag() {
        guard dragStartValue != nil else { return }
        dragStartValue = nil
        pressChanged(false)
    }
}

/// Brightness belongs to the player's screen and survives chrome auto-hide.
/// Restore it on exit only if the viewer has not since changed it elsewhere.
@MainActor @Observable
final class MobilePlayerBrightness {
    private(set) var value: Double = 0.5
    private weak var screen: UIScreen?
    private var originalValue: CGFloat?
    private var lastAppliedValue: CGFloat?

    func attach(to screen: UIScreen) {
        guard self.screen !== screen else { return }
        restore()
        self.screen = screen
        refresh()
    }

    func refresh() {
        guard let screen else { return }
        let currentValue = screen.brightness
        if let lastAppliedValue, abs(currentValue - lastAppliedValue) >= 0.001 {
            originalValue = nil
            self.lastAppliedValue = nil
        }
        value = Double(currentValue)
    }

    func set(_ value: Double) {
        guard let screen else { return }
        // Catch an external adjustment even if its notification is still pending.
        refresh()
        if originalValue == nil { originalValue = screen.brightness }
        // Keep touch feedback immediate. Screen updates may lag behind the
        // gesture, and Simulator does not emulate display brightness.
        self.value = min(max(value, 0), 1)
        // A notification from our own write must retain the restore point.
        lastAppliedValue = CGFloat(self.value)
        screen.brightness = CGFloat(self.value)
        lastAppliedValue = screen.brightness
    }

    func restore() {
        if let screen, let originalValue, let lastAppliedValue,
           abs(screen.brightness - lastAppliedValue) < 0.001 {
            screen.brightness = originalValue
        }
        originalValue = nil
        lastAppliedValue = nil
    }
}

struct MobilePlayerScreenReader: UIViewRepresentable {
    let onScreen: (UIScreen) -> Void

    func makeUIView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.onScreen = onScreen
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ScreenView, context: Context) {
        uiView.onScreen = onScreen
    }

    final class ScreenView: UIView {
        var onScreen: ((UIScreen) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self, let screen = self.window?.windowScene?.screen else { return }
                self.onScreen?(screen)
            }
        }
    }
}

/// The capsule drives MPVolumeView's native slider, never the player's gain.
/// Observing the audio session keeps physical buttons and Control Centre in sync.
@MainActor @Observable
final class MobilePlayerSystemVolume {
    private(set) var value = Double(AVAudioSession.sharedInstance().outputVolume)
    private(set) var canAdjust = false
    private weak var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?

    private var slider: UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    func connect(_ volumeView: MPVolumeView) {
        self.volumeView = volumeView
        if observation == nil {
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    func disconnect(_ volumeView: MPVolumeView) {
        guard self.volumeView === volumeView else { return }
        observation?.invalidate()
        observation = nil
        self.volumeView = nil
        canAdjust = false
    }

    func refresh() {
        value = Double(AVAudioSession.sharedInstance().outputVolume)
        #if targetEnvironment(simulator)
        // Simulator has no adjustable system volume.
        canAdjust = false
        #else
        if let slider, volumeView?.window != nil {
            canAdjust = slider.isEnabled && !slider.isHidden
        } else {
            canAdjust = false
        }
        #endif
    }

    func set(_ value: Double) {
        guard canAdjust, let slider, slider.isEnabled, !slider.isHidden else { return }
        slider.setValue(Float(min(max(value, 0), 1)), animated: false)
        slider.sendActions(for: .valueChanged)
        // Native volume observation supplies the authoritative value, including
        // any system limits. No player-gain fallback on unsupported routes.
        refresh()
    }
}

/// MPVolumeView stays mounted while the chrome hides so route changes and
/// hardware-button updates keep working. Its native artwork is transparent;
/// the accessible glass capsule above provides the visible touch surface.
struct MobilePlayerSystemVolumeReader: UIViewRepresentable {
    let volume: MobilePlayerSystemVolume

    func makeUIView(context: Context) -> VolumeHost {
        VolumeHost(volume: volume)
    }

    func updateUIView(_ uiView: VolumeHost, context: Context) {}

    static func dismantleUIView(_ uiView: VolumeHost, coordinator: ()) {
        uiView.volume.disconnect(uiView.volumeView)
    }

    final class VolumeHost: UIView {
        let volume: MobilePlayerSystemVolume
        let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 44))

        init(volume: MobilePlayerSystemVolume) {
            self.volume = volume
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            clipsToBounds = true
            volumeView.showsRouteButton = false
            let clearImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            for state: UIControl.State in [.normal, .highlighted, .disabled] {
                volumeView.setMinimumVolumeSliderImage(clearImage, for: state)
                volumeView.setMaximumVolumeSliderImage(clearImage, for: state)
                volumeView.setVolumeThumbImage(clearImage, for: state)
            }
            addSubview(volumeView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateConnection()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateConnection()
        }

        private func updateConnection() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.window != nil { self.volume.connect(self.volumeView) }
                else { self.volume.disconnect(self.volumeView) }
            }
        }
    }
}
#endif
