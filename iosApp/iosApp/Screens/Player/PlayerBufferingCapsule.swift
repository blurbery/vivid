import SwiftUI

/// A single, shell-level buffering indicator shared by every player surface.
struct PlayerBufferingCapsule: View {
    var label: LocalizedStringKey = "Loading…"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(tvOS) || os(iOS)
        VividLoadingDots()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        #else
        HStack(spacing: spacing) {
            ProgressView()
                .tint(.white)
                .progressViewStyle(.circular)
                .scaleEffect(spinnerScale)

            Text(label)
                .font(.vividSmall.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
        .vividPlayerGlass(in: Capsule())
        .shadow(color: .black.opacity(0.45), radius: 18, y: 7)
        .padding(.top, topPadding)
        .padding(.trailing, trailingPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        #endif
    }

    private var spacing: CGFloat {
        #if os(tvOS)
        8
        #else
        7
        #endif
    }

    private var spinnerScale: CGFloat {
        #if os(tvOS)
        0.9
        #else
        0.8
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        12
        #else
        10
        #endif
    }

    private var topPadding: CGFloat {
        #if os(tvOS)
        64
        #elseif os(macOS)
        88
        #else
        68
        #endif
    }

    private var trailingPadding: CGFloat {
        #if os(tvOS)
        80
        #elseif os(macOS)
        20
        #else
        16
        #endif
    }
}

struct VividLoadingDots: View {
    var compact = false
    var dotDiameter: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            HStack(spacing: compact ? 4 : 16) {
                ForEach(0..<4, id: \.self) { index in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.1 - Double(index) * 0.65
                    Circle()
                        .fill(.primary)
                        .frame(width: dotDiameter ?? (compact ? 4 : 12), height: dotDiameter ?? (compact ? 4 : 12))
                        .offset(y: reduceMotion ? 0 : -CGFloat((sin(phase) + 1) / 2) * (compact ? 6 : 18))
                }
            }
            .frame(height: compact ? 20 : 48)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

struct VividLoadingProgressStyle: ProgressViewStyle {
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if let fraction = configuration.fractionCompleted {
            ProgressView(value: fraction) { configuration.label }
                .progressViewStyle(.linear)
        } else {
            VStack(spacing: 6) {
                VividLoadingDots(compact: true)
                configuration.label
            }
        }
    }
}

struct PlayerLoadingIndicator: View {
    let isLoading: Bool
    let isBuffering: Bool
    let isPlaying: Bool
    let currentTime: Double
    @State private var lastAdvance = ProcessInfo.processInfo.systemUptime

    static func shouldShow(requested: Bool, isPlaying: Bool, isLoading: Bool, elapsed: TimeInterval) -> Bool {
        requested && (isPlaying || isLoading) && elapsed >= 0.8
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            if Self.shouldShow(requested: isLoading || isBuffering, isPlaying: isPlaying,
                               isLoading: isLoading, elapsed: ProcessInfo.processInfo.systemUptime - lastAdvance) {
                PlayerBufferingCapsule()
            }
        }
        .onChange(of: currentTime) { old, new in
            if new.isFinite, new != old { lastAdvance = ProcessInfo.processInfo.systemUptime }
        }
        .onChange(of: isLoading || isBuffering) { _, _ in
            lastAdvance = ProcessInfo.processInfo.systemUptime
        }
    }
}
