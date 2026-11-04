import SwiftUI

/// Next Up supplies geometry, never another video view. Moving a shared
/// AVPlayerLayer between two representables lets an outgoing view steal or
/// detach the incoming view's picture during a SwiftUI transition.
struct PlayerPreviewBoundsKey: PreferenceKey {
    struct Value {
        var bounds: Anchor<CGRect>?
        var viewport: Anchor<CGRect>?
        var actions: Anchor<CGRect>?
    }

    static var defaultValue: Value { Value() }

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.bounds = next.bounds ?? value.bounds
        value.viewport = next.viewport ?? value.viewport
        value.actions = next.actions ?? value.actions
    }
}

struct PlayerSurfaceLayout<Surface: View, Content: View>: View {
    let isPreview: Bool
    var isTransitioning: Bool = false
    /// Holds the video to the top of the screen, this tall, while the iPhone
    /// Duo is half folded like a laptop. Nil fills the screen.
    var topRegionHeight: CGFloat? = nil
    @ViewBuilder let surface: () -> Surface
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .overlayPreferenceValue(PlayerPreviewBoundsKey.self) { geometry in
                GeometryReader { proxy in
                    let fullFrame = topRegionHeight.map {
                        CGRect(x: 0, y: 0, width: proxy.size.width, height: min($0, proxy.size.height))
                    } ?? CGRect(origin: .zero, size: proxy.size)
                    let showsPreview = isPreview && !isTransitioning
                    let frame = showsPreview ? geometry.bounds.map { proxy[$0] } ?? fullFrame : fullFrame
                    let viewport = showsPreview ? geometry.viewport.map { proxy[$0] } ?? fullFrame : fullFrame
                    // One structural identity in both modes. Only geometry changes;
                    // expansion must not load, seek, bind a second host, or resume.
                    surface()
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: showsPreview ? 8 : 0))
                        .overlay {
                            RoundedRectangle(cornerRadius: showsPreview ? 8 : 0)
                                .stroke(.white.opacity(showsPreview ? 0.16 : 0), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(showsPreview ? 0.55 : 0), radius: showsPreview ? 34 : 0, y: showsPreview ? 18 : 0)
                        .position(x: frame.midX, y: frame.midY)
                        // Respect the original ScrollView's clipping even though
                        // the video itself is a persistent sibling of that view.
                        .mask {
                            Rectangle()
                                .frame(width: viewport.width, height: viewport.height)
                                .position(x: viewport.midX, y: viewport.midY)
                        }
                        .animation(reduceMotion || isTransitioning ? nil : .easeInOut(duration: 0.3), value: showsPreview)
                        .overlay { Color.black.opacity(isTransitioning ? 1 : 0) }
                        .animation(nil, value: isTransitioning)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(isPreview)
            }
    }
}

#if os(iOS)
/// The Next Up layout on iPhone and iPad: the preview top right and the
/// episode panel bottom left, in one stack that survives rotation. `extras`
/// is never mounted, because iPhone and iPad show no On Deck shelf.
struct PlayerNextUpMobileLayout<Preview: View, Panel: View, Extras: View>: View {
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let panel: (_ compact: Bool) -> Panel
    @ViewBuilder let extras: () -> Extras

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width > proxy.size.height
            PlayerNextUpStackLayout(compact: compact) {
                preview()
                panel(compact)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, compact ? 8 : 16)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Measure the actual action panel first, then fit the preview above it.
/// Keeping the same stack and video anchor across sizes avoids reparenting
/// the playing surface or guessing how much room the text and buttons need.
struct PlayerNextUpStackLayout: Layout {
    var compact: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let panelWidth = min(bounds.width, 360)
        let panelSize = subviews[1].sizeThatFits(.init(width: panelWidth, height: nil))
        let availableHeight = max(0, bounds.height - panelSize.height - 16)
        let sideWidth = max(0, bounds.width - panelWidth - 16)
        let previewWidth = compact && sideWidth >= 80
            ? min(220, sideWidth, bounds.height * 16 / 9)
            : min(compact ? 220 : 260, bounds.width, availableHeight * 16 / 9)
        let previewHeight = previewWidth * 9 / 16
        subviews[0].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                          proposal: .init(width: previewWidth, height: previewHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                          proposal: .init(width: panelWidth, height: panelSize.height))
    }
}
#endif
