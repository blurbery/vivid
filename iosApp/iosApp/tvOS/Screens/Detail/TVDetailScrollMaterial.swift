#if os(tvOS)
import SwiftUI

// Apple's fold-snapping implementation from Creating a tvOS media catalog app in SwiftUI.
/*
Copyright © 2024 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
struct TVDetailFoldSnapping: ScrollTargetBehavior {
    let showcaseHeight: CGFloat
    /// On a page with a pinned logo, how far past the fold a scroll may be
    /// aimed and still settle on the fold, so coming back up to the first
    /// shelf lands where arriving from the hero does, with the logo whole.
    var pinnedReach: CGFloat = 0

    /// Snaps focus-driven scrolls on the native movie and series pages to
    /// either the whole hero or the shelves at the top. Vivid decides "above
    /// the fold" from the original target, and snaps back to the top for
    /// small moves near it, so the header controls stay level with the fixed
    /// logo.
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let fold = showcaseHeight
        let startedAboveFold = context.originalTarget.rect.minY < fold / 2
        let proposed = target.rect.minY

        if startedAboveFold, proposed < fold * 0.3 {
            target.rect.origin.y = 0
        } else if !startedAboveFold, proposed > fold {
            if proposed < fold + pinnedReach {
                target.rect.origin.y = fold
            }
            return
        } else if startedAboveFold || (fold * 0.7...fold).contains(proposed) {
            target.rect.origin.y = fold
        } else {
            target.rect.origin.y = 0
        }
    }
}

/// Where the native page has scrolled to. Only the material and the shelf
/// logo read it, so a scroll frame redraws nothing else.
@MainActor
@Observable
final class TVDetailScrollState {
    /// The visible top, clamped to 0 through the showcase height.
    var offset: CGFloat = 0
    /// How far the page has scrolled past the shelves' resting position.
    var overscroll: CGFloat = 0
    var showsShelfLogo = false
    /// Counts requests to bring the page back to the fold.
    private(set) var foldRequests = 0

    /// Asks the page to return to the fold when it has scrolled a little
    /// past it, no further than `reach`. The series page's season selector
    /// calls this when it takes focus with the distance at which it is
    /// still wholly on screen: focus doesn't scroll to a control it can
    /// already see. Further down, the system's own focus scroll brings the
    /// page back and the fold snapping settles it, so nothing is asked.
    func requestFold(within reach: CGFloat) {
        guard overscroll > 0, overscroll <= reach else { return }
        foldRequests += 1
    }
}

/// Fold snapping for the native page's scroll view, the scroll position the
/// material and the shelf logo follow, and the material behind the scroll
/// view. It owns that position, so the page content never rebuilds while it
/// scrolls.
struct TVDetailFoldScrolling: ViewModifier {
    let viewportSize: CGSize
    let showcaseHeight: CGFloat
    /// The visible top from which the shelf logo shows.
    let logoThreshold: CGFloat
    /// The hero's logo, drawn fixed over the page instead of inside it.
    var pinnedLogo: TVDetailHeroLogo? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scroll = TVDetailScrollState()
    @State private var position = ScrollPosition(idType: String.self)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .scrollTargetBehavior(TVDetailFoldSnapping(
                showcaseHeight: showcaseHeight,
                pinnedReach: pinnedLogo == nil ? 0 : 300
            ))
            .onChange(of: scroll.foldRequests) { _, _ in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
                    position.scrollTo(y: showcaseHeight)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.minY
            } action: { _, top in
                let offset = min(max(top, 0), showcaseHeight)
                let overscroll = max(top - showcaseHeight, 0)
                if offset != scroll.offset || overscroll != scroll.overscroll {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scroll.offset = offset
                        scroll.overscroll = overscroll
                    }
                }
                let logoVisible = top >= logoThreshold
                if logoVisible != scroll.showsShelfLogo {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: logoVisible ? 0.25 : 0.08)) {
                        scroll.showsShelfLogo = logoVisible
                    }
                }
            }
            .environment(scroll)
            .background {
                TVDetailScrollMaterialLayer(viewportSize: viewportSize, showcaseHeight: showcaseHeight, scroll: scroll)
            }
            .overlay(alignment: .topLeading) {
                if let pinnedLogo {
                    TVDetailPinnedLogo(logo: pinnedLogo, scroll: scroll)
                }
            }
    }
}

/// The hero's logo held in its corner while the page crosses the fold. It
/// only moves once the page scrolls on past the shelves' first row, when it
/// leaves with them.
private struct TVDetailPinnedLogo: View {
    let logo: TVDetailHeroLogo
    let scroll: TVDetailScrollState

    var body: some View {
        logo
            .offset(y: -scroll.overscroll)
            .allowsHitTesting(false)
    }
}

/// On a page with a pinned logo, fades the hero out as the page leaves it
/// and the shelves in as they arrive, so the two never cross under the logo.
struct TVDetailFoldFade: ViewModifier {
    enum Part { case hero, shelves }

    let part: Part
    let showcaseHeight: CGFloat
    var isEnabled = true

    @Environment(TVDetailScrollState.self) private var scroll: TVDetailScrollState?

    func body(content: Content) -> some View {
        content.opacity(opacity)
    }

    /// Never fully clear: the focus engine skips a view with no opacity,
    /// which would stop focus moving between the hero and the shelves.
    private static let floor = 0.02

    private var opacity: Double {
        guard isEnabled, let scroll, showcaseHeight > 0 else { return 1 }
        let progress = min(max(scroll.offset / showcaseHeight, 0), 1)
        let faded: Double
        switch part {
        case .hero: faded = 1 - min(progress / 0.45, 1)
        case .shelves: faded = min(max((progress - 0.45) / 0.45, 0), 1)
        }
        return max(faded, Self.floor)
    }
}

/// The material that rises behind the scrolling shelves, with the shade
/// that keeps the hero text readable over the backdrop.
struct TVDetailScrollMaterialLayer: View {
    let viewportSize: CGSize
    let showcaseHeight: CGFloat
    let scroll: TVDetailScrollState

    var body: some View {
        let offset = scroll.offset
        let progress = showcaseHeight > 0 ? min(max(offset / showcaseHeight, 0), 1) : 0
        let text = TVDetailHeroLayout.compactTextRect(showcaseHeight: showcaseHeight)
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .frame(width: viewportSize.width, height: viewportSize.height)
                .mask(alignment: .topLeading) {
                    TVDetailScrollMaterialMask(
                        viewportSize: viewportSize,
                        lift: progress * viewportSize.height * 1.2
                    )
                }


            // A soft shade just behind the hero's text, so white text stays
            // readable over bright artwork. It hugs the heading, synopsis and
            // details only, so the rest of the picture keeps its own light,
            // and it fades on one smooth curve with no visible steps. It is
            // sized and placed from the hero's text block (the heading down
            // to the action row), so it follows the layout.
            EllipticalGradient(
                stops: Self.textShadeStops,
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.5
            )
            .frame(width: text.width * Self.textShadeSpread.width, height: text.height * Self.textShadeSpread.height)
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
            .position(x: text.midX + Self.textShadeShift.width, y: text.midY + Self.textShadeShift.height - offset)
            .opacity(1 - progress)
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .clipped()
    }

    /// How far the shade reaches past the text block, as a multiple of the
    /// block's size. The shade is level across its middle quarter and
    /// eases out from there, so it has to be well over the block's size to
    /// stay dark to the ends of the lines. These are the proportions the
    /// shade had around the earlier, smaller text block.
    private static let textShadeSpread = CGSize(width: 2.2, height: 1.7)
    /// The shade's centre sits a little up and left of the text block's,
    /// towards the poster, as it always has.
    private static let textShadeShift = CGSize(width: -60, height: -10)

    /// Level across the middle, where the text sits, then eased out to
    /// nothing at the edge.
    private static let textShadeStops: [Gradient.Stop] = {
        let steps = 64
        return (0...steps).map { step in
            let x = Double(step) / Double(steps)
            let t = min(1, max(0, (x - 0.25) / 0.75))
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            return .init(color: .black.opacity(0.5 * (1 - eased)), location: x)
        }
    }()
}

// MARK: - Curved mask

/// The curved edge of the scroll material. The material shows below a curve
/// that dips in the middle and rises to both sides, lifted as the page
/// scrolls. By default a pre-blurred band stands in for the live blur.
struct TVDetailScrollMaterialMask: View {
    let viewportSize: CGSize
    let lift: CGFloat
    var usesCachedBand = true

    var body: some View {
        if usesCachedBand, let band = TVDetailCurvedBlurBand.band(for: viewportSize) {
            cached(band)
        } else {
            TVDetailCurvedBlurBand.livePath(viewportSize: viewportSize, lift: lift)
        }
    }

    private func cached(_ band: TVDetailCurvedBlurBand.Band) -> some View {
        let solidTop = band.rect.maxY - lift - 4
        return ZStack(alignment: .topLeading) {
            Image(decorative: band.image, scale: band.scale)
                .resizable()
                .interpolation(.high)
                .frame(width: band.rect.width, height: band.rect.height)
                .offset(x: band.rect.minX, y: band.rect.minY - lift)
            Rectangle()
                .fill(.black)
                .frame(width: viewportSize.width, height: max(0, viewportSize.height - solidTop))
                .offset(y: solidTop)
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
    }
}

/// Renders the blurred part of the curve once per viewport size, so the
/// scrolling page moves an image instead of blurring a path every frame.
@MainActor
enum TVDetailCurvedBlurBand {
    struct Band {
        let image: CGImage
        /// Where the image sits in viewport points, before the lift.
        let rect: CGRect
        let scale: CGFloat
    }

    private struct SizeKey: Hashable {
        let width: CGFloat
        let height: CGFloat
    }

    /// Failed renders are kept too, so they aren't retried every frame.
    private static var bands: [SizeKey: Band?] = [:]

    static func band(for viewportSize: CGSize) -> Band? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let key = SizeKey(width: viewportSize.width, height: viewportSize.height)
        if let known = bands[key] { return known }
        let band = render(viewportSize)
        bands[key] = .some(band)
        return band
    }

    /// Where the material's edge meets the sides of the screen, as a
    /// fraction of the height. It only rises a little from its lowest point
    /// in the middle, so the frosting stays low and doesn't climb the sides.
    static let sideEdge: CGFloat = 0.70
    /// The curve's lowest point, in the middle of the screen.
    static let lowestEdge: CGFloat = 0.885
    /// How soft the edge is, as a fraction of the height: wide enough that
    /// the frosting comes in gradually instead of reading as a blurred band.
    static let softness: CGFloat = 0.11

    static func blurRadius(for viewportSize: CGSize) -> CGFloat {
        viewportSize.height * softness
    }

    static func livePath(viewportSize: CGSize, lift: CGFloat) -> some View {
        TVDetailMaterialCurve(lift: lift)
            .fill(.black)
            .blur(radius: blurRadius(for: viewportSize))
            .frame(width: viewportSize.width, height: viewportSize.height)
    }

    private static func render(_ viewportSize: CGSize) -> Band? {
        let width = viewportSize.width
        let height = viewportSize.height
        let radius = blurRadius(for: viewportSize)
        let margin = radius * 4
        let top = height * sideEdge - margin
        let bottom = height * lowestEdge + margin
        let rect = CGRect(x: -margin, y: top, width: width + margin * 2, height: bottom - top)

        let content = TVDetailMaterialCurve(lift: 0)
            .fill(.black)
            .frame(width: width, height: height)
            .blur(radius: radius)
            .offset(x: -rect.minX, y: -rect.minY)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return Band(image: image, rect: rect, scale: 1)
    }
}

/// The region below the material's curved top edge.
///
/// The shape runs well past the screen at both sides and below it. Its
/// straight side edges used to sit only a tenth of the width beyond the
/// screen, and the live shape's bottom edge a fifth of the height below it
/// (the cached band's was already a full height below). A softer blur
/// reaches those: the blurred edges thinned the material along the sides
/// of the screen and, live, along the bottom, and the cached band, which
/// fills in solid below itself, no longer matched the live blur.
private struct TVDetailMaterialCurve: Shape {
    var lift: CGFloat
    var bottomFraction: CGFloat = 2.4
    /// How far past each side the shape carries on level, as a fraction of
    /// the width.
    private static let sideReach: CGFloat = 0.6

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        // A cubic with both controls at the same height dips three quarters
        // of the way to them, so this puts the dip on `lowestEdge`.
        let side = TVDetailCurvedBlurBand.sideEdge
        let low = TVDetailCurvedBlurBand.lowestEdge
        let edge = height * side - lift
        let control = height * (side + (low - side) / 0.75) - lift
        let left = -Self.sideReach * width
        let right = (1 + Self.sideReach) * width
        var path = Path()
        path.move(to: CGPoint(x: left, y: edge))
        path.addLine(to: CGPoint(x: -0.1 * width, y: edge))
        path.addCurve(
            to: CGPoint(x: 1.1 * width, y: edge),
            control1: CGPoint(x: 0.28 * width, y: control),
            control2: CGPoint(x: 0.72 * width, y: control)
        )
        path.addLine(to: CGPoint(x: right, y: edge))
        path.addLine(to: CGPoint(x: right, y: bottomFraction * height))
        path.addLine(to: CGPoint(x: left, y: bottomFraction * height))
        path.closeSubpath()
        return path
    }
}
#endif
