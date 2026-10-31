import SwiftUI

#if !os(tvOS)
/// Everything a detail page puts in its hero.
struct MobileHeroContent {
    var title: String
    var seriesTitle: String? = nil
    var logoUrl: String? = nil
    var posterUrl: String? = nil
    var posterThumbhash: String? = nil
    var backdropUrl: String? = nil
    var backdropThumbhash: String? = nil
    /// The line above the title in the iPhone landscape hero.
    var eyebrow: String? = nil
    var sourceTokens: [String] = []
    var ageRating: String? = nil
    var overview: String? = nil
    var credit: String? = nil
    var factsTokens: [String] = []
    var parallax = false
    var tmdbScore: Double? = nil
    /// The iPad hero's heading starts with these, then the genres.
    var headingTokens: [String] = []
    var releaseFacts: [String] = []
    var qualityBadges: [String] = []

    var pillTokens: [String] {
        MobileHeroRules.pillTokens(facts: factsTokens, sources: sourceTokens)
    }

    var hasRatingRow: Bool {
        ageRating != nil || tmdbScore != nil
    }

    /// The backdrop, else the poster, else nothing.
    var artwork: (url: String, thumbhash: String?)? {
        if let backdropUrl, !MobileHeroRules.isBlank(backdropUrl) {
            return (backdropUrl, backdropThumbhash)
        }
        if let posterUrl, !MobileHeroRules.isBlank(posterUrl) {
            return (posterUrl, posterThumbhash)
        }
        return nil
    }
}

/// The top of a detail page: the iPhone and Duo design, the iPad's Apple TV
/// style hero at regular width, or a wide layout when an iPhone page is laid
/// out in landscape.
struct MobileDetailHero<Actions: View, UnderOverview: View>: View {
    let content: MobileHeroContent
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let underOverview: () -> UnderOverview

    @State private var measuredWidth: CGFloat?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Layout {
        case compact, fullScreen, expanded
    }

    private var layout: Layout {
        let isPortraitPhone = horizontalSizeClass == .compact && verticalSizeClass == .regular
        if !PhoneDuo.usesDuoDetailDesign, !isPortraitPhone {
            let isWide = measuredWidth.map { $0 >= 700 } ?? (horizontalSizeClass == .regular)
            if isWide { return .expanded }
        }
        if UIDevice.current.userInterfaceIdiom == .pad, horizontalSizeClass == .regular {
            return .fullScreen
        }
        return .compact
    }

    var body: some View {
        Group {
            switch layout {
            case .compact:
                MobileCompactHero(
                    content: content,
                    width: measuredWidth ?? 390,
                    actions: actions,
                    underOverview: underOverview
                )
            case .fullScreen:
                MobileTabletHero(content: content, actions: actions, underOverview: underOverview)
            case .expanded:
                MobileExpandedHero(
                    content: content,
                    width: measuredWidth ?? 0,
                    actions: actions,
                    underOverview: underOverview
                )
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if let measuredWidth, abs(width - measuredWidth) <= 1 { return }
            measuredWidth = width
        }
    }
}

// MARK: - Compact (iPhone, Duo, narrow iPad)

private struct MobileCompactHero<Actions: View, UnderOverview: View>: View {
    let content: MobileHeroContent
    let width: CGFloat
    let actions: () -> Actions
    let underOverview: () -> UnderOverview

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let height = min(max(width * 1.18, 430), 540)
        let logoHeight = min(max(height * 0.24, 104), 138)
        let usesDuoColumn = PhoneDuo.usesWideDetailLayout(horizontalSizeClass)
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                PhoneDetailParallaxArtwork(
                    url: content.artwork?.url,
                    thumbhash: content.artwork?.thumbhash,
                    height: height,
                    isEnabled: content.parallax,
                    keepsTopAttached: true,
                    topShadeOpacity: 0.34
                )
                MobileTitleBlock(content: content, alignment: .center, logoHeight: logoHeight)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 6)
            }
            .frame(height: height)
            .accessibilityElement(children: .contain)

            VStack(alignment: .center, spacing: 16) {
                MobileHeroMetadataBlock(content: content)
                actions()
                    .padding(.top, 2)
                if let overview = content.overview, !overview.isEmpty {
                    MobileHeroOverview(text: overview, isCentred: usesDuoColumn)
                }
                if let credit = content.credit, !credit.isEmpty {
                    MobileHeroCredit(text: credit, alignment: usesDuoColumn ? .center : .leading)
                }
                underOverview()
            }
            .onDuoDetail { column in
                column
                    .frame(maxWidth: usesDuoColumn ? PhoneDuo.detailColumnWidth : .infinity)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, VividTheme.safePadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }
}

private struct MobileHeroMetadataBlock: View {
    let content: MobileHeroContent

    var body: some View {
        let pills = content.pillTokens
        if !pills.isEmpty || content.hasRatingRow {
            VStack(alignment: .center, spacing: 8) {
                if !pills.isEmpty {
                    MetadataPillRow(tokens: pills)
                }
                if content.hasRatingRow {
                    HStack(spacing: 8) {
                        MobileRatingRowItems(content: content)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The age rating chip and TMDb score that follow the pills.
private struct MobileRatingRowItems: View {
    let content: MobileHeroContent

    var body: some View {
        if let rating = content.ageRating {
            ContentRatingChip(rating: rating)
        }
        if let score = content.tmdbScore {
            TMDbRatingBadge(
                rating: score,
                logoHeight: 14,
                font: .system(size: 14, weight: .semibold),
                color: Color.vividOnSurface.opacity(0.92)
            )
        }
    }
}

/// Three lines of the overview; tapping opens all of it in a sheet.
private struct MobileHeroOverview: View {
    let text: String
    let isCentred: Bool

    @State private var showsFullText = false

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Color.vividOnSurface.opacity(0.80))
            .lineSpacing(3)
            .lineLimit(3)
            .multilineTextAlignment(isCentred ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: isCentred ? .center : .leading)
            .contentShape(Rectangle())
            .onTapGesture { showsFullText = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Opens the full description"))
            .sheet(isPresented: $showsFullText) {
                ScrollView {
                    Text(verbatim: text)
                        .font(.body)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }
}

private struct MobileHeroCredit: View {
    let text: String
    let alignment: Alignment

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.vividOnSurface.opacity(0.58))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: alignment)
            .onDuoDetail { credit in
                credit.multilineTextAlignment(alignment == .center ? .center : .leading)
            }
    }
}

// MARK: - Title block

/// The title: the series logo or name over an episode's title, the item's
/// logo, or its name split into a main line and a subtitle.
private struct MobileTitleBlock: View {
    enum Placement {
        case leading, center

        var alignment: Alignment { self == .leading ? .leading : .center }
        var textAlignment: TextAlignment { self == .leading ? .leading : .center }
    }

    let content: MobileHeroContent
    let alignment: Placement
    let logoHeight: CGFloat

    private var logoUrl: String? {
        guard let url = content.logoUrl, !url.isEmpty else { return nil }
        return url
    }

    private var logoMaxWidth: CGFloat {
        alignment == .leading ? 430 : .infinity
    }

    var body: some View {
        if let series = content.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty {
            VStack(alignment: .center, spacing: 6) {
                if let logoUrl {
                    AsyncImageView(url: logoUrl, contentMode: .fit, placeholderStyle: .clear)
                        .frame(maxWidth: logoMaxWidth, alignment: alignment.alignment)
                        .frame(height: logoHeight)
                        .accessibilityLabel(Text(verbatim: series))
                } else {
                    Text(verbatim: series)
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(2)
                }
                Text(verbatim: content.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.vividOnSurface.opacity(0.90))
                    .lineLimit(2)
                    .multilineTextAlignment(alignment.textAlignment)
            }
            .frame(maxWidth: .infinity, alignment: alignment.alignment)
        } else if let logoUrl {
            CachedAsyncImage(
                url: logoUrl,
                contentMode: .fit,
                alignment: alignment == .leading ? .bottomLeading : .bottom,
                placeholderStyle: .clear
            )
            .frame(maxWidth: logoMaxWidth)
            .frame(height: logoHeight)
            .accessibilityLabel(Text(verbatim: content.title))
        } else {
            let parts = MobileHeroRules.splitTitle(content.title)
            VStack(alignment: .center, spacing: 4) {
                Text(verbatim: parts.main)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(Color.vividOnSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(alignment.textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = parts.subtitle {
                    Text(verbatim: subtitle.uppercased())
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.vividOnSurface.opacity(0.80))
                        .lineLimit(2)
                        .multilineTextAlignment(alignment.textAlignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment.alignment)
        }
    }
}

// MARK: - Full screen (iPad, regular width)

private struct MobileTabletHero<Actions: View, UnderOverview: View>: View {
    let content: MobileHeroContent
    let actions: () -> Actions
    let underOverview: () -> UnderOverview

    @Environment(\.detailViewportSize) private var viewportSize

    private var heroHeight: CGFloat {
        viewportSize.width > viewportSize.height ? viewportSize.height : viewportSize.height * 0.73
    }

    var body: some View {
        let heroHeight = heroHeight
        VStack(alignment: .leading, spacing: 12) {
            MobileTitleBlock(content: content, alignment: .leading, logoHeight: 122)
                .padding(.bottom, 2)
            MobileTabletHeading(content: content)
            if let overview = content.overview, !overview.isEmpty {
                MobileHeroOverview(text: overview, isCentred: false)
            }
            underOverview()
            if let credit = content.credit, !credit.isEmpty {
                MobileHeroCredit(text: credit, alignment: .leading)
            }
            MobileTabletTechnicalRow(content: content)
            actions()
                .padding(.top, 8)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .bottomLeading)
        .background(alignment: .top) {
            GeometryReader { proxy in
                MobileTabletBackdrop(
                    artwork: content.artwork,
                    heroSize: proxy.size,
                    heroHeight: proxy.size.height,
                    viewportSize: viewportSize
                )
            }
        }
        .environment(\.phoneDetailUsesTVStyle, true)
        .accessibilityElement(children: .contain)
    }
}

private struct MobileTabletHeading: View {
    let content: MobileHeroContent

    var body: some View {
        let parts = content.headingTokens + MobileHeroRules.genreParts(content.sourceTokens)
        if !parts.isEmpty || content.ageRating != nil {
            HStack(spacing: 8) {
                if let first = parts.first {
                    Text(Self.heading(first: first, rest: Array(parts.dropFirst())))
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let rating = content.ageRating {
                    MobileTextBadge(text: rating, isFilled: false)
                }
            }
        }
    }

    /// The first part bright, the rest dimmer after a middle dot.
    private static func heading(first: String, rest: [String]) -> AttributedString {
        var text = AttributedString(first)
        text.foregroundColor = Color.white.opacity(0.92)
        if !rest.isEmpty {
            var tail = AttributedString(" · " + rest.joined(separator: " · "))
            tail.foregroundColor = Color.white.opacity(0.70)
            text += tail
        }
        return text
    }
}

private struct MobileTabletTechnicalRow: View {
    let content: MobileHeroContent

    var body: some View {
        if !content.releaseFacts.isEmpty || !content.qualityBadges.isEmpty || content.tmdbScore != nil {
            HStack(spacing: 8) {
                if !content.releaseFacts.isEmpty {
                    Text(verbatim: content.releaseFacts.joined(separator: " · "))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.84))
                }
                ForEach(Array(content.qualityBadges.enumerated()), id: \.offset) { _, badge in
                    MobileTextBadge(text: badge, isFilled: MobileHeroRules.isResolutionBadge(badge))
                }
                if let score = content.tmdbScore {
                    TMDbRatingBadge(
                        rating: score,
                        logoHeight: 15,
                        font: .system(size: 15, weight: .semibold),
                        color: Color.white.opacity(0.92)
                    )
                    .padding(.leading, 2)
                }
            }
            .lineLimit(1)
        }
    }
}

/// A small boxed label: filled white for resolutions, outlined otherwise.
private struct MobileTextBadge: View {
    let text: String
    let isFilled: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        Text(verbatim: text)
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isFilled ? Color.black : Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                if isFilled {
                    shape.fill(Color.white)
                }
            }
            .overlay {
                if !isFilled {
                    shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                }
            }
    }
}

/// The iPad hero's artwork: sharp at the top, then a blurred copy that
/// feathers in under the hero and stays put on screen as the page scrolls,
/// until it covers the whole screen.
private struct MobileTabletBackdrop: View {
    let artwork: (url: String, thumbhash: String?)?
    let heroSize: CGSize
    let heroHeight: CGFloat
    let viewportSize: CGSize

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let feather: CGFloat = 220
    private static let lead: CGFloat = 150

    var body: some View {
        let size = viewportSize == .zero ? heroSize : viewportSize
        let feather = Self.feather
        let lead = Self.lead
        ZStack(alignment: .topLeading) {
            image(size: size)
                .overlay {
                    LinearGradient(
                        colors: [Color.black.opacity(0.34), .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.3)
                    )
                }
                .visualEffect { content, proxy in
                    content.offset(y: -proxy.frame(in: .scrollView(axis: .vertical)).minY)
                }

            MobileHeroShade(heroHeight: heroHeight, tail: lead)
                .frame(width: heroSize.width, height: heroHeight + lead)

            blurLayer(size: size)
                .overlay(Color.black.opacity(0.45))
                .overlay(MobileSideShade())
                .clipped()
                .visualEffect { content, proxy in
                    let top = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    return content.offset(y: -top - max(0, -top - feather))
                }
                .frame(width: size.width, height: size.height + feather, alignment: .top)
                .clipped()
                .mask { Self.featherMask(height: size.height) }
                .visualEffect { content, proxy in
                    let top = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    return content.offset(y: max(0, -top - feather))
                }
                .padding(.top, max(0, heroHeight - lead))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func image(size: CGSize) -> some View {
        Group {
            if let artwork {
                AsyncImageView(url: artwork.url, thumbhash: artwork.thumbhash, contentMode: .fill)
            } else {
                Color.vividSurface
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder
    private func blurLayer(size: CGSize) -> some View {
        if reduceTransparency {
            Color(white: 0.06)
                .frame(width: size.width, height: size.height)
        } else {
            image(size: size)
                .blur(radius: 40, opaque: true)
                .frame(width: size.width, height: size.height)
        }
    }

    /// Clear at the top, eased to opaque over the feather.
    private static func featherMask(height: CGFloat) -> LinearGradient {
        let span = feather / (height + feather)
        let stops = (0...16).map { index -> Gradient.Stop in
            let t = CGFloat(index) / 16
            return Gradient.Stop(color: .black.opacity(t * t * (3 - 2 * t)), location: span * t)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

/// Darkens the leading side, where the iPad hero's text sits.
private struct MobileSideShade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.55), location: 0),
                .init(color: Color.black.opacity(0.25), location: 0.38),
                .init(color: .clear, location: 0.65)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// The side shade and a darker foot under the iPad hero, fading out over
/// the tail below it.
private struct MobileHeroShade: View {
    let heroHeight: CGFloat
    let tail: CGFloat

    var body: some View {
        let total = max(heroHeight + tail, 1)
        let foot = heroHeight / total
        ZStack {
            MobileSideShade()
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35 * foot),
                    .init(color: Color.black.opacity(0.45), location: 0.78 * foot)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: foot),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Expanded (iPhone page laid out in landscape)

private struct MobileExpandedHero<Actions: View, UnderOverview: View>: View {
    let content: MobileHeroContent
    let width: CGFloat
    let actions: () -> Actions
    let underOverview: () -> UnderOverview

    var body: some View {
        ZStack(alignment: .topLeading) {
            artworkLayer
            copy
        }
        .frame(maxWidth: .infinity, minHeight: 550, alignment: .topLeading)
        .clipped()
    }

    private var artworkLayer: some View {
        GeometryReader { proxy in
            let layerWidth = proxy.size.width
            let imageWidth = 0.66 * layerWidth
            Group {
                if let artwork = content.artwork {
                    AsyncImageView(url: artwork.url, thumbhash: artwork.thumbhash, contentMode: .fill)
                } else {
                    Color.vividSurface
                }
            }
            .frame(width: imageWidth, height: min(550, imageWidth * 9 / 16))
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.52),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .trailing,
                    endPoint: .leading
                )
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.74),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: layerWidth, height: 550, alignment: .topTrailing)
        }
        .frame(height: 550)
        .allowsHitTesting(false)
    }

    private var copy: some View {
        let pills = content.pillTokens
        return VStack(alignment: .leading, spacing: 15) {
            if let eyebrow = content.eyebrow, !eyebrow.isEmpty {
                Text(verbatim: eyebrow.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.vividOnSurface.opacity(0.70))
            }
            MobileTitleBlock(content: content, alignment: .leading, logoHeight: 122)
                .frame(maxWidth: 430, alignment: .leading)
            if !pills.isEmpty || content.hasRatingRow {
                MetadataPillRow(tokens: pills) {
                    MobileRatingRowItems(content: content)
                }
            }
            if let overview = content.overview, !overview.isEmpty {
                MobileHeroOverview(text: overview, isCentred: false)
            }
            if let credit = content.credit, !credit.isEmpty {
                MobileHeroCredit(text: credit, alignment: .leading)
            }
            underOverview()
            actions()
                .padding(.top, 2)
        }
        .frame(maxWidth: min(max(0.47 * width, 410), 560), alignment: .leading)
        .padding(.leading, width >= 1000 ? 56 : 40)
        .padding(.top, 88)
        .padding(.bottom, 38)
    }
}
#endif
