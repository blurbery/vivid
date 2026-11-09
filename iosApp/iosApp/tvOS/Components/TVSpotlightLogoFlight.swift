#if os(tvOS)
import SwiftUI
import UIKit

/// Carries a Spotlight slide into its detail page, and back again on Back:
/// the card's backdrop grows from the card to the full screen and squares off
/// its corners, the logo flies from the card to the page's logo corner, and
/// the page's text, poster and buttons fade in once the backdrop is in place.
/// The system zoom still runs underneath; these copies are drawn above
/// everything for the length of the move. Reduce Motion keeps the plain
/// transition.
///
/// The copies are UIKit views moved by Core Animation, which runs in the
/// render server like the system zoom. SwiftUI animations would run on the
/// main thread and stall while the detail page is being built.
@Observable
@MainActor
final class TVSpotlightLogoFlight {
    static let shared = TVSpotlightLogoFlight()

    /// Close to the system zoom, so the move ends as the page settles.
    static let duration: TimeInterval = 0.55
    /// How quickly the backdrop copy covers the card or page as it starts.
    static let fadeIn: TimeInterval = 0.12
    /// How long the backdrop copy takes to reveal what's under it at the end.
    static let fadeOut: TimeInterval = 0.25
    /// How long the copies are on screen, from the press or Back to landing.
    static let totalDuration: TimeInterval = duration + fadeOut

    /// Each entry records the slide it was drawn for, since a carousel
    /// position shows another slide once Home refreshes its rows.
    private struct Logo {
        var slideID: String
        var image: UIImage
        var frame: CGRect
    }

    private struct Backdrop {
        var slideID: String?
        var image: UIImage?
        /// Where the image is drawn inside the card, in card points.
        var crop: CGRect = .zero
        var card: CGRect = .zero
    }

    /// Recent Spotlight cards by zoom source ID, in screen points. Entries
    /// stay while a detail page covers Home, since the flight back needs
    /// them, and the oldest go once there are more than `sourceLimit`.
    /// Frames change while the carousel scrolls, so none of this is observed.
    @ObservationIgnored private var logos: [String: Logo] = [:]
    @ObservationIgnored private var backdrops: [String: Backdrop] = [:]
    @ObservationIgnored private var sourceOrder: [String] = []
    private static let sourceLimit = 16
    /// The card the open detail page came from, for the flight back.
    @ObservationIgnored private var openedSourceID: String?
    @ObservationIgnored private var openedSlideID: String?
    @ObservationIgnored private var flyingViews: [UIView] = []
    @ObservationIgnored private var generation = 0

    /// The Spotlight card whose own logo is hidden.
    private(set) var hiddenSourceID: String?
    /// Hides the detail page's logo while the copy is in the air.
    private(set) var hidesDetailLogo = false

    private init() {}

    // MARK: Sources

    func register(sourceID: String, slideID: String, image: UIImage, frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        logos[sourceID] = Logo(slideID: slideID, image: image, frame: frame)
        touch(sourceID)
    }

    func registerBackdrop(sourceID: String, slideID: String, image: UIImage, crop: CGRect) {
        backdrops[sourceID, default: Backdrop()].slideID = slideID
        backdrops[sourceID]?.image = image
        backdrops[sourceID]?.crop = crop
        touch(sourceID)
    }

    func registerCard(sourceID: String, frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        backdrops[sourceID, default: Backdrop()].card = frame
        touch(sourceID)
    }

    private func touch(_ sourceID: String) {
        sourceOrder.removeAll { $0 == sourceID }
        sourceOrder.append(sourceID)
        // The oldest entries go first, never the open card's, which the
        // flight back needs and which stays in the order to go later.
        while sourceOrder.count > Self.sourceLimit,
              let index = sourceOrder.firstIndex(where: { $0 != openedSourceID }) {
            let oldest = sourceOrder.remove(at: index)
            logos.removeValue(forKey: oldest)
            backdrops.removeValue(forKey: oldest)
        }
    }

    // MARK: Flights

    /// Hides the card's logo ahead of `open(sourceID:)`, which follows on
    /// the next turn of the run loop with the push.
    func prepare(sourceID: String, slideID: String) {
        guard !UIAccessibility.isReduceMotionEnabled, logos[sourceID]?.slideID == slideID else { return }
        hiddenSourceID = sourceID
    }

    /// Starts the flight to the detail page for the card being opened.
    func open(sourceID: String, slideID: String) {
        guard !UIAccessibility.isReduceMotionEnabled, logos[sourceID]?.slideID == slideID else {
            reset()
            return
        }
        openedSourceID = sourceID
        openedSlideID = slideID
        fly(sourceID: sourceID, toDetail: true)
    }

    /// The navigation stack was swapped for another of the same depth, so
    /// Back no longer returns to the Spotlight card the page came from.
    func stackReplaced() {
        guard openedSourceID != nil else { return }
        reset()
    }

    /// Follows the navigation path, flying back when the page the logo flew
    /// to is closed straight back to Home.
    func pathCountChanged(from old: Int, to new: Int) {
        guard new == 0, let sourceID = openedSourceID else { return }
        let slideID = openedSlideID
        openedSourceID = nil
        openedSlideID = nil
        guard old == 1, !UIAccessibility.isReduceMotionEnabled, logos[sourceID]?.slideID == slideID else {
            reset()
            return
        }
        // The page's logo goes first and the copies follow a frame later, so
        // the two logos never show together.
        hiddenSourceID = sourceID
        hidesDetailLogo = true
        generation += 1
        let flight = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == flight else { return }
            self.fly(sourceID: sourceID, toDetail: false)
        }
    }

    private func fly(sourceID: String, toDetail: Bool) {
        guard let window = Self.keyWindow, let logo = logos[sourceID] else { reset(); return }
        generation += 1
        let flight = generation
        clearViews()
        hiddenSourceID = sourceID
        hidesDetailLogo = true

        let screen = window.bounds
        let detailLogo = Self.detailLogoFrame(for: logo.image.size)
        let backdrop = backdrops[sourceID]
            .flatMap { $0.slideID == logo.slideID ? $0 : nil }
            .flatMap(Self.backdropFlight(screen: screen))

        // Backdrop first, so the logo draws above it.
        var backdropViews: (container: UIView, image: UIImageView, shade: UIView)?
        if let backdrop {
            let container = UIView(frame: toDetail ? backdrop.card : screen)
            container.clipsToBounds = true
            container.layer.cornerCurve = .continuous
            container.layer.cornerRadius = toDetail ? 22 : 0
            container.isUserInteractionEnabled = false
            container.alpha = 0
            let image = UIImageView(image: backdrop.image)
            image.contentMode = .scaleToFill
            image.frame = toDetail ? backdrop.cardCrop : backdrop.screenCrop
            container.addSubview(image)
            let shade = TVSpotlightFlightShade(frame: container.bounds)
            shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shade.alpha = toDetail ? 1 : 0
            container.addSubview(shade)
            window.addSubview(container)
            flyingViews.append(container)
            backdropViews = (container, image, shade)
        }

        let logoView = UIImageView(image: logo.image)
        logoView.contentMode = .scaleToFill
        logoView.isUserInteractionEnabled = false
        logoView.frame = toDetail ? logo.frame : detailLogo
        logoView.layer.shadowColor = UIColor.black.cgColor
        logoView.layer.shadowRadius = 22
        logoView.layer.shadowOffset = CGSize(width: 0, height: 6)
        let shadow: (Float, Float) = toDetail ? (0.5, 0) : (0, 0.5)
        logoView.layer.shadowOpacity = shadow.1
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = shadow.0
        fade.toValue = shadow.1
        fade.duration = Self.duration
        logoView.layer.add(fade, forKey: "shadowOpacity")
        window.addSubview(logoView)
        flyingViews.append(logoView)

        if let views = backdropViews {
            UIView.animate(withDuration: Self.fadeIn, delay: 0, options: [.curveEaseOut]) {
                views.container.alpha = 1
            }
        }
        UIView.animate(withDuration: Self.duration, delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            logoView.frame = toDetail ? detailLogo : logo.frame
            if let views = backdropViews, let backdrop {
                views.container.frame = toDetail ? screen : backdrop.card
                views.container.layer.cornerRadius = toDetail ? 0 : 22
                views.image.frame = toDetail ? backdrop.screenCrop : backdrop.cardCrop
                views.shade.alpha = toDetail ? 0 : 1
            }
        } completion: { [weak self] _ in
            guard let self, self.generation == flight else { return }
            guard let container = backdropViews?.container else {
                self.land()
                return
            }
            // Reveal the page (or the card) under the backdrop copy; the logo
            // copy stays until then so it never dips behind it.
            UIView.animate(withDuration: Self.fadeOut, delay: 0, options: [.curveEaseInOut]) {
                container.alpha = 0
            } completion: { [weak self] _ in
                guard let self, self.generation == flight else { return }
                self.land()
            }
        }
    }

    /// Hands back to the real views. The logo copy and the logo it lands on
    /// are at the same place and size, so the swap doesn't show.
    private func land() {
        clearViews()
        hidesDetailLogo = false
        if openedSourceID == nil { hiddenSourceID = nil }
    }

    private func clearViews() {
        flyingViews.forEach { $0.removeFromSuperview() }
        flyingViews.removeAll()
    }

    private func reset() {
        generation += 1
        openedSourceID = nil
        openedSlideID = nil
        land()
        hiddenSourceID = nil
    }

    // MARK: Geometry

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Where the detail page draws this logo: fitted into its logo box from
    /// the top-left corner, as `TVDetailHeroLogo` lays it out.
    private static func detailLogoFrame(for size: CGSize) -> CGRect {
        let box = CGSize(width: TVDetailHeroLayout.logoWidth, height: TVDetailHeroLayout.logoHeight)
        let origin = CGPoint(x: TVDetailHeroLayout.horizontalInset, y: TVDetailHeroLayout.logoTopInset)
        guard size.width > 0, size.height > 0 else { return CGRect(origin: origin, size: box) }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGRect(origin: origin, size: CGSize(width: size.width * scale, height: size.height * scale))
    }

    private struct BackdropFlight {
        var image: UIImage
        /// The card on screen.
        var card: CGRect
        /// The image inside the card, as the card draws it.
        var cardCrop: CGRect
        /// The image filling the screen, centred, as the detail page draws it.
        var screenCrop: CGRect
    }

    private static func backdropFlight(screen: CGRect) -> (Backdrop) -> BackdropFlight? {
        { backdrop in
            guard let image = backdrop.image, backdrop.card.width > 0,
                  image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = max(screen.width / image.size.width, screen.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let screenCrop = CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2,
                                    width: size.width, height: size.height)
            return BackdropFlight(image: image, card: backdrop.card, cardCrop: backdrop.crop, screenCrop: screenCrop)
        }
    }
}

/// The card's darkening, approximated, so the backdrop copy starts out
/// looking like the card it covers.
private final class TVSpotlightFlightShade: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        guard let gradient = layer as? CAGradientLayer else { return }
        let stops: [(Double, CGFloat)] = [(0, 0), (0.28, 0.02), (0.45, 0.08), (0.5, 0.1), (0.72, 0.5), (1, 0.9)]
        gradient.colors = stops.map { UIColor.black.withAlphaComponent($0.1).cgColor }
        gradient.locations = stops.map { NSNumber(value: $0.0) }
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }

    required init?(coder: NSCoder) { nil }
}
#endif
