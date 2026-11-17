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
    /// Hides Home's blurred backdrop around the card: from the press that
    /// opens a title until Back starts. It returns as the flight back
    /// begins, not when it lands, so the space around the card is already
    /// the backdrop while the picture shrinks into it.
    private(set) var hidesHomeBackdrop = false
    /// Hides the detail page's logo while the copy is in the air.
    private(set) var hidesDetailLogo = false

    private init() {}

    // MARK: Shared looks
    //
    // The card and the flying copies draw these the same way, so nothing
    // changes at the moment one takes over from the other.

    /// The logo's shadow on the picture, drawn by the card.
    static let shadowRadius: CGFloat = 24
    static let shadowOpacity: Float = 0.72
    static func shadowOffset(logoHeight: CGFloat) -> CGSize {
        let down = min(38, logoHeight * 0.3)
        return CGSize(width: down * 24 / 38, height: down)
    }

    /// The logo's own close shadow, for definition. The card's logo and
    /// its flying copy both carry it, so nothing changes when one takes
    /// over from the other; the detail page's logo has none, so the copy's
    /// clears on the way there and builds on the way back.
    static let closeShadowOpacity: Float = 0.35
    static let closeShadowRadius: CGFloat = 3
    static let closeShadowDrop: CGFloat = 2

    /// The shadow the picture's edges fall into: a rounded rectangle's
    /// inner shadow, the same on every side, as an image whose middle
    /// stretches.
    static let recessCap: CGFloat = 110
    static let recessOpacity: Double = 0.45
    static let recessShade: UIImage = {
        let side = recessCap * 2 + 20
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let image = UIGraphicsImageRenderer(size: rect.size).image { renderer in
            let shape = UIBezierPath(roundedRect: rect, cornerRadius: 22)
            shape.addClip()
            // Everything outside the shape, casting its shadow inwards.
            let outside = UIBezierPath(rect: rect.insetBy(dx: -120, dy: -120))
            outside.append(shape)
            outside.usesEvenOddFillRule = true
            renderer.cgContext.setShadow(offset: .zero, blur: 56, color: UIColor.black.cgColor)
            UIColor.black.setFill()
            outside.fill()
        }
        return image.resizableImage(
            withCapInsets: UIEdgeInsets(top: recessCap, left: recessCap, bottom: recessCap, right: recessCap),
            resizingMode: .stretch)
    }()

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
        guard !UIAccessibility.isReduceMotionEnabled, let logo = logos[sourceID], logo.slideID == slideID else { return }
        hiddenSourceID = sourceID
        hidesHomeBackdrop = true
        stage(logo, at: logo.frame, closeShadow: Self.closeShadowOpacity)
    }

    /// Puts the logo's copy on screen, still, where the real logo is, in
    /// the same update that hides the real one. The flight starts a turn of
    /// the run loop later; without this the logo was gone for that frame
    /// and blinked.
    private func stage(_ logo: Logo, at frame: CGRect, closeShadow: Float) {
        clearViews()
        guard let window = Self.keyWindow else { return }
        let view = UIImageView(image: logo.image)
        view.contentMode = .scaleToFill
        view.isUserInteractionEnabled = false
        view.frame = frame
        Self.setCloseShadow(on: view, opacity: closeShadow)
        window.addSubview(view)
        flyingViews.append(view)
    }

    private static func setCloseShadow(on view: UIView, opacity: Float) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowRadius = closeShadowRadius
        view.layer.shadowOffset = CGSize(width: 0, height: closeShadowDrop)
        view.layer.shadowOpacity = opacity
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

    /// The page at the bottom of the stack, the one the card opened, was
    /// replaced without going back to Home, so Back no longer returns to
    /// that card.
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
        hidesHomeBackdrop = false
        if let logo = logos[sourceID] { stage(logo, at: Self.detailLogoFrame(for: logo.image.size), closeShadow: 0) }
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
            let shade = UIImageView(image: Self.recessShade)
            shade.frame = container.bounds
            shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shade.alpha = toDetail ? Self.recessOpacity : 0
            container.addSubview(shade)
            window.addSubview(container)
            flyingViews.append(container)
            backdropViews = (container, image, shade)
        }

        let logoView = UIImageView(image: logo.image)
        logoView.contentMode = .scaleToFill
        logoView.isUserInteractionEnabled = false
        logoView.frame = toDetail ? logo.frame : detailLogo
        // No cast shadow of its own. The card's shadow of the logo stays on
        // the picture, under the picture's copy, so it fades out from under
        // the logo as the copy covers the card, and back in as it uncovers
        // it. Only the logo's close shadow travels with the copy.
        let close: (Float, Float) = toDetail ? (Self.closeShadowOpacity, 0) : (0, Self.closeShadowOpacity)
        Self.setCloseShadow(on: logoView, opacity: close.1)
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = close.0
        fade.toValue = close.1
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
                views.shade.alpha = toDetail ? 0 : Self.recessOpacity
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
        hidesHomeBackdrop = false
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

#endif
