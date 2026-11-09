#if os(tvOS)
import SwiftUI
import UIKit

/// Flies a Spotlight slide's logo to the detail page's logo corner while the
/// page zooms out of the card, and back again on Back. The zoom itself is
/// unchanged; one copy of the logo is drawn above everything for the length
/// of the flight while both real logos are hidden. Reduce Motion keeps the
/// plain transition.
///
/// The copy is a UIKit image view moved by Core Animation, which runs in the
/// render server like the system zoom. A SwiftUI animation would run on the
/// main thread and stall while the detail page is being built.
@Observable
@MainActor
final class TVSpotlightLogoFlight {
    static let shared = TVSpotlightLogoFlight()

    /// Close to the system zoom, so the logo lands as the page settles.
    static let duration: TimeInterval = 0.55

    private struct Source {
        var image: UIImage
        var frame: CGRect
    }

    /// Recent Spotlight logos by zoom source ID, in screen points. Entries
    /// stay while a detail page covers Home, since the flight back needs
    /// them, and the oldest go once there are more than `sourceLimit`.
    /// Frames change while the carousel scrolls, so this isn't observed.
    @ObservationIgnored private var sources: [String: Source] = [:]
    @ObservationIgnored private var sourceOrder: [String] = []
    private static let sourceLimit = 16
    /// The card the open detail page came from, for the flight back.
    @ObservationIgnored private var openedSourceID: String?
    @ObservationIgnored private var flyingView: UIImageView?
    @ObservationIgnored private var generation = 0

    /// The Spotlight card whose own logo is hidden.
    private(set) var hiddenSourceID: String?
    /// Hides the detail page's logo while the copy is in the air.
    private(set) var hidesDetailLogo = false

    private init() {}

    func register(sourceID: String, image: UIImage, frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        sources[sourceID] = Source(image: image, frame: frame)
        sourceOrder.removeAll { $0 == sourceID }
        sourceOrder.append(sourceID)
        while sourceOrder.count > Self.sourceLimit {
            let oldest = sourceOrder.removeFirst()
            if oldest != openedSourceID { sources.removeValue(forKey: oldest) }
        }
    }

    /// Hides the card's logo ahead of `open(sourceID:)`, which follows on
    /// the next turn of the run loop with the push.
    func prepare(sourceID: String) {
        guard !UIAccessibility.isReduceMotionEnabled, sources[sourceID] != nil else { return }
        hiddenSourceID = sourceID
    }

    /// Starts the flight to the detail page for the card being opened.
    func open(sourceID: String) {
        guard !UIAccessibility.isReduceMotionEnabled, let source = sources[sourceID] else {
            reset()
            return
        }
        openedSourceID = sourceID
        fly(image: source.image, sourceID: sourceID,
            from: source.frame, to: Self.detailFrame(for: source.image.size),
            shadow: (0.5, 0))
    }

    /// Follows the navigation path, flying back when the page the logo flew
    /// to is closed straight back to Home.
    func pathCountChanged(from old: Int, to new: Int) {
        guard new == 0, let sourceID = openedSourceID else { return }
        openedSourceID = nil
        guard old == 1, !UIAccessibility.isReduceMotionEnabled, let source = sources[sourceID] else {
            reset()
            return
        }
        // The page's logo goes first and the copy follows a frame later, so
        // the two never show together.
        hiddenSourceID = sourceID
        hidesDetailLogo = true
        generation += 1
        let flight = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == flight else { return }
            self.fly(image: source.image, sourceID: sourceID,
                     from: Self.detailFrame(for: source.image.size), to: source.frame,
                     shadow: (0, 0.5))
        }
    }

    private func fly(image: UIImage, sourceID: String, from: CGRect, to: CGRect, shadow: (Float, Float)) {
        guard let window = Self.keyWindow else { reset(); return }
        generation += 1
        let flight = generation
        flyingView?.removeFromSuperview()

        let view = UIImageView(image: image)
        view.contentMode = .scaleToFill
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.frame = from
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowRadius = 22
        view.layer.shadowOffset = CGSize(width: 0, height: 6)
        view.layer.shadowOpacity = shadow.1
        window.addSubview(view)
        flyingView = view

        hiddenSourceID = sourceID
        hidesDetailLogo = true

        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = shadow.0
        fade.toValue = shadow.1
        fade.duration = Self.duration
        view.layer.add(fade, forKey: "shadowOpacity")
        UIView.animate(withDuration: Self.duration, delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            view.frame = to
        } completion: { [weak self] _ in
            guard let self, self.generation == flight else { return }
            self.land()
        }
    }

    /// Hands back to the real logos. The copy and the logo it lands on are
    /// at the same place and size, so the swap doesn't show.
    private func land() {
        flyingView?.removeFromSuperview()
        flyingView = nil
        hidesDetailLogo = false
        if openedSourceID == nil { hiddenSourceID = nil }
    }

    private func reset() {
        generation += 1
        openedSourceID = nil
        land()
        hiddenSourceID = nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Where the detail page draws this logo: fitted into its logo box from
    /// the top-left corner, as `TVDetailHeroLogo` lays it out.
    private static func detailFrame(for size: CGSize) -> CGRect {
        let box = CGSize(width: TVDetailHeroLayout.logoWidth, height: TVDetailHeroLayout.logoHeight)
        let origin = CGPoint(x: TVDetailHeroLayout.horizontalInset, y: TVDetailHeroLayout.logoTopInset)
        guard size.width > 0, size.height > 0 else { return CGRect(origin: origin, size: box) }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGRect(origin: origin, size: CGSize(width: size.width * scale, height: size.height * scale))
    }
}
#endif
