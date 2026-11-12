#if os(tvOS)
import SwiftUI
import Observation

/// The colour the Adaptive theme mode shows, from whatever artwork last had
/// focus on a root page. Cards and the Spotlight report focus with a plain
/// method call and never read anything here, and only `TVAdaptiveBackdrop`
/// observes `tint`, so a focus move never invalidates a page or a row.
///
/// Focus has to rest on a card briefly before its colour is looked up, so
/// scrolling quickly along a row does no colour work for the cards it passes.
/// The look-up runs off the main thread on the card's small palette image
/// and is remembered for the session.
@MainActor
@Observable
final class TVAdaptiveAmbience {
    static let shared = TVAdaptiveAmbience()

    /// What drives the colour.
    enum Source {
        /// A Spotlight slide: the saved Spotlight tint, the same colour
        /// Spotlight Only shows.
        case spotlight
        /// A poster or Continue Watching card.
        case card
    }

    /// The colour on show, or nil for the base theme.
    private(set) var tint: Color?

    /// Set by the backdrop from Theme Mode. Off, focus reports return at once.
    @ObservationIgnored var isActive = false
    /// Set by the shell: false while a page is pushed over the root pages,
    /// so cards on detail and other pushed pages don't change the colour.
    @ObservationIgnored var isOnRootPage = true
    /// The artwork focus last rested on, so repeated reports are ignored.
    @ObservationIgnored private var requested: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var tints: [String: Color] = [:]

    /// How long focus rests on a card before its colour is used.
    private static let settle: Duration = .milliseconds(200)
    private static let rememberedLimit = 400

    private init() {
        isActive = Self.savedModeIsAdaptive
    }

    private static var savedModeIsAdaptive: Bool {
        (UserDefaults.standard.string(forKey: TVThemeMode.storageKey)
            .flatMap(TVThemeMode.init(rawValue:)) ?? TVThemeMode.defaultValue) == .adaptive
    }

    /// A card or Spotlight slide showing this artwork took focus. Cheap to
    /// call from a focus handler: it returns at once, and the artwork isn't
    /// even worked out unless Adaptive is on and a root page is showing, so
    /// the other modes do no work on a focus move.
    func focused(artwork: @autoclosure () -> String?, source: Source = .card) {
        guard isActive, isOnRootPage else { return }
        guard let raw = artwork(), !raw.isEmpty else {
            // A card with no artwork: don't let the card before it land late.
            pending?.cancel()
            requested = nil
            return
        }
        request(raw, source: source)
    }

    /// Home's Spotlight, when Home shows and nothing has set a colour yet
    /// (Adaptive just turned on, or back from Settings or Search with focus
    /// on the tab bar), so the first screen isn't left on the base theme.
    func seedSpotlight(artwork raw: String?) {
        // Read fresh: Home can reappear before the backdrop sees a Theme
        // Mode change made in Settings.
        isActive = Self.savedModeIsAdaptive
        guard isActive, tint == nil, requested == nil, let raw, !raw.isEmpty else { return }
        request(raw, source: .spotlight)
    }

    private func request(_ raw: String, source: Source) {
        guard raw != requested else { return }
        let url: URL?
        switch source {
        case .spotlight:
            // Spotlight tints are saved under the slide's own address.
            url = URL(string: raw)
        case .card:
            // As the card resolved it to draw it.
            let base = MediaServerProvider.active == .silo ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
            url = SiloAPICompatibility.artworkURL(raw, relativeTo: base)
        }
        guard let url else { return }
        requested = raw
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled, let self else { return }
            let colour = await self.colour(for: url, source: source)
            guard !Task.isCancelled, self.isActive, self.requested == raw else { return }
            // Nothing to show; let the card try again next time it's focused.
            guard let colour else { self.requested = nil; return }
            if self.tint != colour { self.tint = colour }
        }
    }

    /// Back to the base theme, for Theme Mode changes and when the tab shell
    /// goes (another profile, sign-out), so the next one starts on the theme.
    /// Not when a player covers it, so playback returns to the same colour.
    func reset() {
        pending?.cancel()
        pending = nil
        requested = nil
        if tint != nil { tint = nil }
    }

    private func colour(for url: URL, source: Source) async -> Color? {
        // The Spotlight and cards sample differently sized images.
        let key = "\(source)|\(url.absoluteString)"
        if let known = tints[key] { return known }
        let colour: Color?
        switch source {
        case .spotlight:
            colour = await TVHomeMetadataCache.shared.preparedSpotlightTint(for: url)
        case .card:
            colour = await HeroBackdropPalette.adaptiveTintColor(for: url)
        }
        guard let colour else { return nil }
        if tints.count >= Self.rememberedLimit { tints.removeAll(keepingCapacity: true) }
        tints[key] = colour
        return colour
    }
}

/// Theme Mode's Adaptive backdrop: one full-screen layer behind every root
/// page, above the base theme, in the colour of whatever last had focus. It
/// sits outside the pages, so it keeps its colour across tab changes until
/// something new takes focus. Studios & Networks and the tab bar don't
/// report focus, so the colour stays as it was over them.
///
/// It draws the Spotlight's shading and grain. A new colour fades in over
/// the one on screen; only opacity animates, so a focus move costs no layout
/// and no redraw of the pages. A colour that arrives mid-fade starts from
/// the blend actually showing, so quick moves never snap.
struct TVAdaptiveBackdrop: View {
    @AppStorage(TVThemeMode.storageKey) private var themeMode = TVThemeMode.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The gradients' colours, so a fade can be blended exactly.
    @State private var front: [Color]?
    @State private var back: [Color]?
    @State private var frontOpacity: Double = 0
    /// Below 1 only when a fade in from the theme was interrupted.
    @State private var backOpacity: Double = 1
    /// The fade running now: when it began and the front's opacity then.
    @State private var fade: (start: Date, from: Double)?
    @State private var run = 0

    private let ambience = TVAdaptiveAmbience.shared

    private static let duration = 0.9

    var body: some View {
        ZStack {
            if let back { TVThemeWash.gradient(shades: back).opacity(backOpacity) }
            if let front { TVThemeWash.gradient(shades: front).opacity(frontOpacity) }
            if back != nil || front != nil {
                Image(uiImage: TVThemeWash.grainTile)
                    .resizable(resizingMode: .tile)
                    .interpolation(.none)
                    .opacity(0.04 * (back != nil ? max(backOpacity, frontOpacity) : frontOpacity))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: themeMode, initial: true) { _, mode in
            ambience.isActive = mode == .adaptive
            if mode != .adaptive { ambience.reset() }
        }
        .onChange(of: ambience.tint, initial: true) { _, tint in
            if let tint { show(TVThemeWash.shades(tint)) } else { hide() }
        }
    }

    /// What's on screen as one gradient and opacity: the front over the back
    /// as far as its fade has got. Gradients with the same stops blend
    /// exactly stop by stop.
    private func onScreen() -> (shades: [Color], opacity: Double)? {
        guard let front else { return back.map { ($0, backOpacity) } }
        var opacity = frontOpacity
        if let fade, !reduceMotion {
            let t = min(1, max(0, Date().timeIntervalSince(fade.start) / Self.duration))
            // Smoothstep, within 3% of SwiftUI's ease in and out.
            opacity = fade.from + (frontOpacity - fade.from) * (t * t * (3 - 2 * t))
        }
        guard let back else { return opacity > 0 ? (front, opacity) : nil }
        let total = backOpacity + (1 - backOpacity) * opacity
        let weight = opacity / max(total, 0.001)
        return (zip(back, front).map { Self.blend($0, $1, weight) }, total)
    }

    private static func blend(_ from: Color, _ to: Color, _ amount: Double) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(from).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(to).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let k = CGFloat(amount)
        return Color(.sRGB, red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k, blue: b1 + (b2 - b1) * k)
    }

    /// Fades whatever is showing out to the base theme.
    private func hide() {
        guard let showing = onScreen() else {
            front = nil
            back = nil
            return
        }
        run += 1
        let token = run
        var snap = Transaction(animation: nil)
        snap.disablesAnimations = true
        withTransaction(snap) {
            back = nil
            backOpacity = 1
            front = showing.shades
            frontOpacity = showing.opacity
        }
        fade = (Date(), showing.opacity)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Self.duration)) {
            frontOpacity = 0
        } completion: {
            guard token == run else { return }
            front = nil
            fade = nil
        }
    }

    /// What's showing drops behind and the new colour fades in over it.
    private func show(_ shades: [Color]) {
        let showing = onScreen()
        run += 1
        let token = run
        var snap = Transaction(animation: nil)
        snap.disablesAnimations = true
        withTransaction(snap) {
            back = showing?.shades
            backOpacity = showing?.opacity ?? 1
            front = shades
            frontOpacity = 0
        }
        // Counts as a fade from 0 straight away, so a change before the next
        // turn of the run loop still reads what's showing correctly.
        fade = (Date(), 0)
        DispatchQueue.main.async {
            guard token == run else { return }
            fade = (Date(), 0)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Self.duration)) {
                frontOpacity = 1
            } completion: {
                // The colour underneath is fully covered now; stop drawing it.
                guard token == run else { return }
                back = nil
                backOpacity = 1
                fade = nil
            }
        }
    }
}

/// Reports a card's artwork to the Adaptive backdrop when it takes focus,
/// for cards with no focus handler of their own. Only this modifier sees the
/// focus change; the card's content isn't rebuilt by it.
private struct TVAdaptiveFocusReport: ViewModifier {
    let artwork: String?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused { TVAdaptiveAmbience.shared.focused(artwork: artwork) }
            }
    }
}

extension View {
    /// Tells the Adaptive backdrop this artwork took focus. Apply it to the
    /// card's button.
    func tvAdaptiveFocusReport(_ artwork: String?) -> some View {
        modifier(TVAdaptiveFocusReport(artwork: artwork))
    }
}
#endif
