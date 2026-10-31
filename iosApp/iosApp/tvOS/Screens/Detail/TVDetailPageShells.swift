#if os(tvOS)
import SwiftUI

/// The native movie and series page: a fixed backdrop, the material that
/// rises as the page scrolls, and a hero that snaps away to reveal the
/// shelves under the title's logo.
struct TVDetailNativeShell<Hero: View, Shelves: View>: View {
    let backdropUrl: String?
    let backdropThumbhash: String?
    let logoUrl: String?
    let title: String
    /// Built for the showcase height.
    @ViewBuilder let hero: (CGFloat) -> Hero
    @ViewBuilder let shelves: () -> Shelves

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollTop: CGFloat = 0
    @State private var showsShelfLogo = false

    /// The hero's height on a viewport of the given height.
    static func showcaseHeight(forViewportHeight height: CGFloat) -> CGFloat {
        max(800, height - 100)
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let showcase = Self.showcaseHeight(forViewportHeight: viewport.height)
            ZStack {
                Color.black
                if let backdropUrl {
                    CachedAsyncImage(
                        url: backdropUrl,
                        targetSize: viewport,
                        thumbhash: backdropThumbhash,
                        contentMode: .fill
                    )
                    .frame(width: viewport.width, height: viewport.height)
                    .clipped()
                }
                TVDetailScrollMaterialLayer(viewportSize: viewport, showcaseHeight: showcase, offset: scrollTop)
                scrollContent(viewport: viewport, showcase: showcase)
            }
            .frame(width: viewport.width, height: viewport.height)
        }
        .ignoresSafeArea()
    }

    private func scrollContent(viewport: CGSize, showcase: CGFloat) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 26) {
                hero(showcase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                shelves()
                    .padding(.top, 150)
                    .padding(.horizontal, TVDetailHeroLayout.horizontalInset)
                    .padding(.bottom, TVDetailHeroLayout.pageBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        TVDetailShelfLogo(logoUrl: logoUrl, title: title, isVisible: showsShelfLogo)
                    }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(TVDetailFoldSnapping(showcaseHeight: showcase))
        .scrollClipDisabled()
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.visibleRect.minY
        } action: { _, top in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollTop = min(max(top, 0), showcase)
            }
            let logoVisible = top >= TVDetailHeroLayout.browsingTopInset(for: showcase) + 160
            if logoVisible != showsShelfLogo {
                let animation: Animation? = reduceMotion ? nil : .easeOut(duration: logoVisible ? 0.25 : 0.08)
                withAnimation(animation) {
                    showsShelfLogo = logoVisible
                }
            }
        }
    }
}

/// The older layout's surface: black under a tint sampled from the
/// backdrop.
struct TVDetailStandardSurface<Content: View>: View {
    let backdropUrl: String?
    @ViewBuilder let content: () -> Content

    private static var defaultTint: Color { Color(red: 0.04, green: 0.12, blue: 0.14) }

    @State private var tint = Self.defaultTint

    var body: some View {
        ZStack {
            Color.black
            tint.opacity(0.42)
            content()
        }
        .ignoresSafeArea()
        .task(id: backdropUrl) {
            guard let raw = backdropUrl, let url = URL(string: raw) else {
                tint = Self.defaultTint
                return
            }
            if let cached = HeroBackdropPalette.cachedTint(for: url) {
                tint = cached
            }
            let sampled = await HeroBackdropPalette.tintColor(for: url)
            guard !Task.isCancelled, let sampled else { return }
            tint = sampled
        }
    }
}

/// Darkens the older layout below its first shelf, so the rails sit on
/// black while the hero keeps its tint.
struct TVDetailLowerBackground: View {
    @State private var preferences = UICustomizationPreferences.shared

    var body: some View {
        let cardHeight = VividTheme.thumbnailCardHeight * preferences.cardPresentation.posterSize.scale
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 52 + 8 + 14 + 12 + cardHeight / 2)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.12), location: 0.25),
                    .init(color: .black.opacity(0.5), location: 0.55),
                    .init(color: .black.opacity(0.88), location: 0.82),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: cardHeight + 40)
            Color.black
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A shelf section: its header and content.
struct TVDetailSection<Content: View>: View {
    let title: LocalizedStringKey
    var spacing: CGFloat = TVDetailHeroLayout.sectionHeaderSpacing
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            TVDetailSectionHeader(title)
            content()
        }
    }
}
#endif
