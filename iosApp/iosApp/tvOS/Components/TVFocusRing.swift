#if os(tvOS)
import SwiftUI

/// The ring around a focused card: plain white on the base theme, and an
/// artwork's own hue while Theme Mode is Adaptive.
///
/// Put it in an overlay inside the card button's label, so it lifts with the
/// artwork. It reads the button's focus from the environment, so only the
/// two cards a focus move touches re-evaluate, and only the focused card
/// draws a stroke or looks up a colour: every other card holds an empty
/// view.
struct TVFocusRing: View {
    /// Where the ring's Adaptive colour comes from.
    enum Source: Equatable {
        /// The colour the Adaptive backdrop is showing, for pages it is
        /// behind, so the ring and the backdrop change together.
        case backdrop
        /// This artwork's own colour, for a poster on a page with its own
        /// backdrop. Focus has to rest on the card before the colour is
        /// looked up, as for the backdrop, so passing along a row does no
        /// colour work.
        case artwork(String?)
        /// A colour worked out elsewhere, nil for white.
        case fixed(Color?)
    }

    /// The system card's own corners by default. The `.card` style clips its
    /// label to them, so a ring with the artwork's tighter corners gets its
    /// corners shaved; at this radius the ring's inner edge still meets the
    /// artwork's 12-point corners.
    var cornerRadius: CGFloat = TVFocusRing.cardCornerRadius
    var cornerStyle: RoundedCornerStyle = .continuous
    var source: Source = .backdrop

    @Environment(\.isFocused) private var isFocused

    static let lineWidth: CGFloat = 4
    static let cardCornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            if isFocused {
                Stroke(cornerRadius: cornerRadius, cornerStyle: cornerStyle, source: source)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The Adaptive colour as a ring: the backdrop's hue at full brightness
    /// with its saturation held back, so it reads as the artwork's colour
    /// but never sinks into the dark wash of the same hue behind it. Black
    /// and white artwork gives a near-white ring.
    static func colour(for tint: Color) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(tint).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // The same neutral edge as `TVThemeWash.shades`.
        let edge = min(1, max(0, (saturation - 0.06) / 0.14))
        let lift = edge * edge * (3 - 2 * edge)
        let rich = min(0.9, saturation * 1.25 + 0.12 * lift)
        return Color(hue: hue, saturation: min(0.62, rich * 0.8), brightness: 1)
    }

    /// Exists only while its card has focus, so one view at most observes
    /// the Adaptive colour or looks one up.
    private struct Stroke: View {
        let cornerRadius: CGFloat
        let cornerStyle: RoundedCornerStyle
        let source: Source

        /// The artwork's colour, for `.artwork`. Starts on the remembered
        /// colour, so a card focused before doesn't flash white.
        @State private var own: Color?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(cornerRadius: CGFloat, cornerStyle: RoundedCornerStyle, source: Source) {
            self.cornerRadius = cornerRadius
            self.cornerStyle = cornerStyle
            self.source = source
            if case let .artwork(raw) = source {
                _own = State(initialValue: TVAdaptiveAmbience.shared.rememberedRingColour(forCardArtwork: raw))
            }
        }

        private var artwork: String? {
            if case let .artwork(raw) = source { return raw }
            return nil
        }

        private var colour: Color {
            switch source {
            case .backdrop: TVAdaptiveAmbience.shared.ringTint ?? .white
            case .artwork: own ?? .white
            case let .fixed(colour): colour ?? .white
            }
        }

        var body: some View {
            let colour = colour
            RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
                .strokeBorder(colour, lineWidth: TVFocusRing.lineWidth)
                // The backdrop's own fade, so the two change together; an
                // artwork's colour comes in quicker over white.
                .animation(reduceMotion ? nil : .easeInOut(duration: source == .backdrop ? 0.9 : 0.35), value: colour)
                .task(id: artwork) {
                    guard case let .artwork(raw) = source else { return }
                    // A page opened from this poster carries its colour.
                    TVAdaptiveAmbience.shared.carry(artwork: raw)
                    // Already known, or the artwork changed under a focused
                    // card to one that is.
                    if let known = TVAdaptiveAmbience.shared.rememberedRingColour(forCardArtwork: raw) {
                        if own != known { own = known }
                        return
                    }
                    try? await Task.sleep(for: TVAdaptiveAmbience.settle)
                    guard !Task.isCancelled else { return }
                    let found = await TVAdaptiveAmbience.shared.ringColour(forCardArtwork: raw)
                    guard !Task.isCancelled, own != found else { return }
                    own = found
                }
        }
    }
}

/// `TVFocusRing` for poster cards shared with pages that don't show it:
/// drawn only where `tvPosterFocusRing` is set, as `tvAdaptivePage()` does.
struct TVPageFocusRing: View {
    let artwork: String?

    @Environment(\.tvPosterFocusRing) private var ring

    var body: some View {
        switch ring {
        case .backdrop: TVFocusRing()
        case .ownArtwork: TVFocusRing(source: .artwork(artwork))
        case nil: EmptyView()
        }
    }
}

/// `TVFocusRing` in the colour a detail page was opened in, for its
/// episodes, cast and trailers. The page takes that colour with
/// `tvTitleFocusRing()`.
struct TVTitleFocusRing: View {
    var cornerRadius: CGFloat = TVFocusRing.cardCornerRadius

    @Environment(\.tvTitleRingColour) private var colour

    var body: some View {
        TVFocusRing(cornerRadius: cornerRadius, source: .fixed(colour))
    }
}

/// How shared poster cards draw the focus ring on a page.
enum TVPosterFocusRing {
    /// White, or the Adaptive backdrop's colour while one is showing.
    case backdrop
    /// White, or the focused poster's own colour while Theme Mode is
    /// Adaptive, for a page the Adaptive backdrop isn't behind.
    case ownArtwork
}

private struct TVPosterFocusRingKey: EnvironmentKey {
    static let defaultValue: TVPosterFocusRing? = nil
}

private struct TVTitleRingColourKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// Set where shared poster cards draw the focus ring; nil draws none.
    var tvPosterFocusRing: TVPosterFocusRing? {
        get { self[TVPosterFocusRingKey.self] }
        set { self[TVPosterFocusRingKey.self] = newValue }
    }

    /// The ring colour a detail page was opened in, nil for white.
    var tvTitleRingColour: Color? {
        get { self[TVTitleRingColourKey.self] }
        set { self[TVTitleRingColourKey.self] = newValue }
    }
}

/// A detail page keeps the ring colour it was opened in: the Adaptive
/// colour of the card or Spotlight slide that opened it, or of the More
/// Like This poster on the page before. It is taken once, as the page
/// opens, and stays while other pages are pushed over it. Only the page's
/// `TVTitleFocusRing`s read it, so setting it re-evaluates nothing else.
private struct TVTitleFocusRingSource: ViewModifier {
    @State private var colour: Color?
    @State private var isTaken = false

    func body(content: Content) -> some View {
        content
            .environment(\.tvTitleRingColour, colour)
            .task {
                guard !isTaken else { return }
                isTaken = true
                colour = await TVAdaptiveAmbience.shared.openingRingColour()
            }
    }
}

extension View {
    func tvTitleFocusRing() -> some View {
        modifier(TVTitleFocusRingSource())
    }
}
#endif
