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
    var showsShelfLogo = false
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scroll = TVDetailScrollState()

    func body(content: Content) -> some View {
        content
            .scrollTargetBehavior(TVDetailFoldSnapping(showcaseHeight: showcaseHeight))
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.minY
            } action: { _, top in
                let offset = min(max(top, 0), showcaseHeight)
                if offset != scroll.offset {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scroll.offset = offset
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
    }
}

/// The material that rises behind the scrolling shelves, with the contrast
/// gradient that keeps the hero text readable over the backdrop.
struct TVDetailScrollMaterialLayer: View {
    let viewportSize: CGSize
    let showcaseHeight: CGFloat
    let scroll: TVDetailScrollState

    var body: some View {
        let offset = scroll.offset
        let progress = showcaseHeight > 0 ? min(max(offset / showcaseHeight, 0), 1) : 0
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

            EllipticalGradient(
                stops: [
                    .init(color: .black.opacity(0.60), location: 0),
                    .init(color: .black.opacity(0.56), location: 0.4),
                    .init(color: .clear, location: 1)
                ],
                center: UnitPoint(x: 0.12, y: 0.68 - offset / max(1, viewportSize.height)),
                startRadiusFraction: 0,
                endRadiusFraction: 0.8
            )
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
            .opacity(1 - progress)
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .clipped()
    }
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

    static func blurRadius(for viewportSize: CGSize) -> CGFloat {
        viewportSize.height * 0.065
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
        // 0.885 of the height is the curve's lowest point.
        let top = height * 0.48 - margin
        let bottom = height * 0.885 + margin
        let rect = CGRect(x: -margin, y: top, width: width + margin * 2, height: bottom - top)

        let content = TVDetailMaterialCurve(lift: 0, bottomFraction: 2)
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
private struct TVDetailMaterialCurve: Shape {
    var lift: CGFloat
    var bottomFraction: CGFloat = 1.2

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let edge = height * 0.48 - lift
        let control = height * 1.02 - lift
        var path = Path()
        path.move(to: CGPoint(x: -0.1 * width, y: edge))
        path.addCurve(
            to: CGPoint(x: 1.1 * width, y: edge),
            control1: CGPoint(x: 0.28 * width, y: control),
            control2: CGPoint(x: 0.72 * width, y: control)
        )
        path.addLine(to: CGPoint(x: 1.1 * width, y: bottomFraction * height))
        path.addLine(to: CGPoint(x: -0.1 * width, y: bottomFraction * height))
        path.closeSubpath()
        return path
    }
}
#endif
