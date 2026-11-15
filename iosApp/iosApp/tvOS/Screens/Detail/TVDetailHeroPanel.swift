#if os(tvOS)
import SwiftUI

/// Hero sizes for each kind of page. Every row sits in a fixed box, so
/// nothing moves with what a title happens to have. The boxes are sized
/// from these constants only; change one here and the rest follow.
struct TVDetailHeroLayout {
    static let horizontalInset: CGFloat = 100
    static let defaultTopInset: CGFloat = 116
    static let sectionSpacing: CGFloat = 64
    static let sectionHeaderSpacing: CGFloat = 14
    static let pageBottomPadding: CGFloat = 140

    // MARK: Rows every hero has

    /// The gap between the credit line, the summary row and the action row.
    static let rowSpacing: CGFloat = 12
    /// The credit line's box: one line of 27-point text, with room for
    /// scripts whose lines stand taller than Latin ones.
    static let creditHeight: CGFloat = 40
    /// Kept clear between the primary block and the credit line.
    static let primaryClearance: CGFloat = 4
    /// The height left for the primary block above the credit line and the
    /// summary row.
    static func primaryBlockHeight(editorialHeight: CGFloat, summaryHeight: CGFloat) -> CGFloat {
        editorialHeight - creditHeight - rowSpacing - summaryHeight - primaryClearance
    }

    // MARK: Poster

    /// The hero poster's height. The season poster on the series shelf is
    /// the same size.
    static let posterHeight: CGFloat = 435
    static let posterWidth: CGFloat = (posterHeight * 2 / 3).rounded()
    static let posterSize = CGSize(width: posterWidth, height: posterHeight)
    /// The gap between the hero poster and the details beside it.
    static let posterSpacing: CGFloat = 40
    /// How far the details sit right of the logo on the native pages, which
    /// the loading page matches so nothing moves when the title loads.
    static let posterInset: CGFloat = posterWidth + posterSpacing

    // MARK: Native movie and series pages

    /// The width of the heading, synopsis, credit line and technical row.
    /// Four lines of the 28-point synopsis hold about what four lines held
    /// at 22 points in the earlier 750-point column.
    static let compactTextWidth: CGFloat = 900
    /// The poster runs from the top of the heading to the bottom of the
    /// action row, so the editorial is the poster less the gap above the
    /// action row and the row itself.
    static let compactEditorialHeight: CGFloat = posterHeight - rowSpacing - TVDetailActionRowLayout.controlHeight
    /// The heading's box: one line of 29-point text and its rating badge.
    static let compactHeadingHeight: CGFloat = 44
    static let compactSynopsisGap: CGFloat = 22
    /// The technical row's box: 29-point text and 22-point badges.
    static let compactSummaryHeight: CGFloat = 44
    static let compactPrimaryHeight: CGFloat = primaryBlockHeight(
        editorialHeight: compactEditorialHeight,
        summaryHeight: compactSummaryHeight
    )
    /// The synopsis has the rest of the primary block: four 28-point lines
    /// need about 134 points of it, and taller scripts have the remainder.
    static let compactSynopsisHeight: CGFloat = compactPrimaryHeight - compactHeadingHeight - compactSynopsisGap

    // MARK: Older layout and season page

    static let standardTextWidth: CGFloat = 750
    static let standardStackSpacing: CGFloat = 14
    static let standardTitleHeight: CGFloat = 160
    /// One metadata row's box.
    static let standardMetadataHeight: CGFloat = 36
    /// Three 28-point lines and Read more, with room for taller scripts.
    static let standardSynopsisHeight: CGFloat = 150
    /// The playback readout's height.
    static let standardSummaryHeight: CGFloat = 40
    /// The room under the action row.
    static let standardBottomMargin: CGFloat = 51
    /// The gap between the eyebrow and the top of the editorial below it.
    static let eyebrowGap: CGFloat = 16

    /// The title, each metadata row and the synopsis, with the stack's
    /// spacing after each.
    static func standardPrimaryHeight(metadataRows: Int) -> CGFloat {
        standardTitleHeight + standardStackSpacing
            + CGFloat(metadataRows) * (standardMetadataHeight + standardStackSpacing)
            + standardSynopsisHeight + standardStackSpacing
    }

    static func standardEditorialHeight(metadataRows: Int) -> CGFloat {
        standardPrimaryHeight(metadataRows: metadataRows) + primaryClearance
            + creditHeight + rowSpacing + standardSummaryHeight
    }

    // MARK: Logo

    /// The native pages' logo sits in the top-left corner, as far from the
    /// top as the content is from the left.
    static let logoTopInset: CGFloat = 100
    static let logoWidth: CGFloat = 650
    static let logoHeight: CGFloat = 160
    /// The shelves' top padding under a pinned logo: the logo box's bottom
    /// edge plus 4. The page leaves 26 points above the shelves as well,
    /// so their content starts 30 points below the logo box.
    static let pinnedLogoShelfInset: CGFloat = logoTopInset + logoHeight + 4

    var height: CGFloat
    var topInset: CGFloat
    /// Compact pages show the heading, synopsis and technical row.
    var isCompact: Bool
    var showsBackdrop: Bool
    var clipsToHeight: Bool
    /// The primary block, credit line and summary row together.
    var editorialHeight: CGFloat
    /// The width of the text, not counting the poster beside it.
    var textWidth: CGFloat
    /// The technical row's or the playback readout's box.
    var summaryHeight: CGFloat

    var primaryHeight: CGFloat {
        Self.primaryBlockHeight(editorialHeight: editorialHeight, summaryHeight: summaryHeight)
    }

    /// The native movie and series pages. The poster, and with it the
    /// editorial and the action row, ends at the hero's bottom, which the
    /// shell puts as far above the screen's bottom edge as the content sits
    /// from the left. The poster grows upwards from there.
    static func showcase(height: CGFloat) -> TVDetailHeroLayout {
        TVDetailHeroLayout(
            height: height,
            topInset: height - posterHeight,
            isCompact: true,
            showsBackdrop: false,
            clipsToHeight: false,
            editorialHeight: compactEditorialHeight,
            textWidth: compactTextWidth,
            summaryHeight: compactSummaryHeight
        )
    }

    /// The older layout and the season page, tall enough for the given
    /// number of metadata rows (an episode under its series title has two).
    static func standard(clipsToHeight: Bool, metadataRows: Int = 1) -> TVDetailHeroLayout {
        let editorialHeight = standardEditorialHeight(metadataRows: metadataRows)
        return TVDetailHeroLayout(
            height: defaultTopInset + editorialHeight + rowSpacing
                + TVDetailActionRowLayout.controlHeight + standardBottomMargin,
            topInset: defaultTopInset,
            isCompact: false,
            showsBackdrop: true,
            clipsToHeight: clipsToHeight,
            editorialHeight: editorialHeight,
            textWidth: standardTextWidth,
            summaryHeight: standardSummaryHeight
        )
    }

    /// Where the native hero's text and action row sit on a hero of the
    /// given height, for the shade drawn behind them.
    static func compactTextRect(showcaseHeight: CGFloat) -> CGRect {
        CGRect(
            x: horizontalInset + posterInset,
            y: showcaseHeight - posterHeight,
            width: compactTextWidth,
            height: posterHeight
        )
    }
}

/// The item's poster beside the hero details on the native pages.
struct TVDetailHeroPoster {
    var url: String?
    var thumbhash: String?

    var hasArtwork: Bool { !(url ?? "").isEmpty }
}

/// The poster's place on the hero: the artwork when there is some, and a
/// plain tile otherwise or while it loads, so the details never move.
struct TVDetailHeroPosterTile: View {
    var poster: TVDetailHeroPoster?

    var body: some View {
        let size = TVDetailHeroLayout.posterSize
        ZStack {
            RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                .fill(Color.white.opacity(0.10))
            if let poster, poster.hasArtwork {
                CachedAsyncImage(
                    url: poster.url ?? "",
                    targetSize: size,
                    thumbhash: poster.thumbhash,
                    contentMode: .fill
                )
                .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
        .shadow(color: .black.opacity(0.35), radius: 12)
        .accessibilityHidden(true)
    }
}

/// The title's logo, or its name, in the top-left corner of the native pages.
struct TVDetailHeroLogo: View {
    let logoUrl: String?
    let title: String

    var body: some View {
        TVDetailLogoTitle(
            logoUrl: logoUrl,
            label: title,
            maxWidth: TVDetailHeroLayout.logoWidth,
            maxHeight: TVDetailHeroLayout.logoHeight,
            alignment: .topLeading,
            trimsTransparentEdges: true
        ) {
            Text(verbatim: title)
                .font(.system(size: 78, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(
            width: TVDetailHeroLayout.logoWidth,
            height: TVDetailHeroLayout.logoHeight,
            alignment: .topLeading
        )
        // Hidden while a Spotlight logo flies into this spot.
        .opacity(TVSpotlightLogoFlight.shared.hidesDetailLogo ? 0 : 1)
        .padding(.top, TVDetailHeroLayout.logoTopInset)
        .padding(.leading, TVDetailHeroLayout.horizontalInset)
    }
}

/// How far the compact page's details sit right of the logo, to clear the
/// hero poster.
private struct TVDetailHeroContentInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var tvDetailHeroContentInset: CGFloat {
        get { self[TVDetailHeroContentInsetKey.self] }
        set { self[TVDetailHeroContentInsetKey.self] = newValue }
    }
}

/// The top of a detail page: optional backdrop artwork, the editorial block
/// with its credit and summary line, and the action row. A compact page with
/// a poster shows it under the logo, from the heading line to the bottom of
/// the action row, with the details beside it.
struct TVDetailHeroPanel<Primary: View, Summary: View, Actions: View>: View {
    let layout: TVDetailHeroLayout
    var backdropUrl: String? = nil
    var backdropThumbhash: String? = nil
    var poster: TVDetailHeroPoster? = nil
    /// Shown in the top-left corner on a compact page.
    var logo: TVDetailHeroLogo? = nil
    /// The small capsule over the editorial, such as a season's series. It
    /// stands in the hero's top inset, so the editorial below is the same
    /// with or without it.
    var eyebrow: String? = nil
    let creditLine: String?
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let actions: () -> Actions

    /// A compact page keeps the poster's place even without artwork, so
    /// it matches the loading page and never shifts.
    private var showsPoster: Bool { layout.isCompact && poster != nil }

    private var contentInset: CGFloat {
        showsPoster ? TVDetailHeroLayout.posterInset : 0
    }

    private var editorialWidth: CGFloat { layout.textWidth + contentInset }

    var body: some View {
        let hero = ZStack(alignment: .topLeading) {
            if layout.showsBackdrop {
                TVDetailHeroBackdrop(url: backdropUrl, thumbhash: backdropThumbhash, height: layout.height)
            }
            if layout.isCompact, let logo {
                logo
            }
            VStack(alignment: .leading, spacing: TVDetailHeroLayout.rowSpacing) {
                editorial
                    .overlay(alignment: .topLeading) {
                        if let eyebrow, !eyebrow.isEmpty {
                            TVDetailEyebrow(text: eyebrow)
                                .lineLimit(1)
                                .frame(maxWidth: layout.textWidth, alignment: .leading)
                                .alignmentGuide(.top) { $0[.bottom] + TVDetailHeroLayout.eyebrowGap }
                        }
                    }
                actions()
                    .padding(.leading, contentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
            }
            // The editorial, the gap and the action row are as tall as the
            // poster, so it runs from the heading to the action row's
            // bottom edge.
            .overlay(alignment: .topLeading) {
                if showsPoster, let poster {
                    TVDetailHeroPosterTile(poster: poster)
                }
            }
            .padding(.top, layout.topInset)
            .padding(.horizontal, TVDetailHeroLayout.horizontalInset)
            .frame(maxWidth: .infinity, maxHeight: layout.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: layout.height, alignment: .topLeading)

        if layout.clipsToHeight {
            hero.clipped()
        } else {
            hero
        }
    }

    private var editorial: some View {
        ZStack(alignment: .topLeading) {
            primary()
                .environment(\.tvDetailHeroContentInset, contentInset)
                .frame(height: layout.primaryHeight, alignment: .topLeading)
                .clipped()

            VStack(alignment: .leading, spacing: TVDetailHeroLayout.rowSpacing) {
                ZStack(alignment: .leading) {
                    if let creditLine, !creditLine.isEmpty {
                        Text(verbatim: creditLine)
                            .font(.system(size: 27))
                            .foregroundStyle(Color.white.opacity(0.70))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: TVDetailHeroLayout.creditHeight)
                .clipped()

                summary()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: layout.summaryHeight, alignment: .topLeading)
            }
            .padding(.leading, contentInset)
            .frame(
                width: editorialWidth,
                height: layout.editorialHeight,
                alignment: .bottomLeading
            )
            .transaction { $0.animation = nil }
        }
        .frame(
            width: editorialWidth,
            height: layout.editorialHeight,
            alignment: .topLeading
        )
        .clipped()
    }
}

/// Backdrop artwork in the hero's top-trailing corner, faded into the page.
struct TVDetailHeroBackdrop: View {
    let url: String?
    let thumbhash: String?
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let size = TVBackdropArtworkLayout.artworkSize(forViewportWidth: proxy.size.width)
            if let url, !url.isEmpty {
                CachedAsyncImage(url: url, targetSize: size, thumbhash: thumbhash, contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .mask { TVBackdropArtworkFadeMask(softensLeadingFade: true) }
                    .frame(width: proxy.size.width, height: height, alignment: .topTrailing)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Primary information

/// Heading and synopsis on the native movie and series pages, beside the
/// poster. The heading starts level with the poster's top edge.
struct TVDetailCompactPrimary: View {
    let headingTokens: [String]
    let genres: [String]
    let contentRating: String?
    let overview: String?
    let synopsisEnabled: Bool
    var focus: FocusState<TVDetailHeroFocus?>.Binding

    @Environment(\.tvDetailHeroContentInset) private var contentInset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVDetailCompactHeading(tokens: headingTokens, genres: genres, contentRating: contentRating)
                .frame(height: TVDetailHeroLayout.compactHeadingHeight, alignment: .leading)
                .padding(.leading, contentInset)

            TVDetailSynopsisSlot(
                overview: overview,
                isCompact: true,
                isEnabled: synopsisEnabled,
                height: TVDetailHeroLayout.compactSynopsisHeight,
                maxWidth: TVDetailHeroLayout.compactTextWidth,
                focus: focus
            )
            .padding(.top, TVDetailHeroLayout.compactSynopsisGap)
            .padding(.leading, contentInset)
        }
        .frame(
            width: TVDetailHeroLayout.compactTextWidth + contentInset,
            height: TVDetailHeroLayout.compactPrimaryHeight,
            alignment: .topLeading
        )
    }
}

/// How the standard hero titles the item.
enum TVDetailTitleTreatment {
    /// An episode under its series' logo or name.
    case hierarchy(seriesTitle: String, seriesLogoUrl: String?, episodeTitle: String)
    /// A logo, falling back to the display title.
    case logo(url: String?, title: String)
}

/// Title, metadata and synopsis on the older layout and the season page.
/// The hero panel draws the season page's eyebrow above this block.
struct TVDetailStandardPrimary: View {
    let treatment: TVDetailTitleTreatment
    let metadata: TVDetailMetadataSlots
    let overview: String?
    let synopsisEnabled: Bool
    var focus: FocusState<TVDetailHeroFocus?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: TVDetailHeroLayout.standardStackSpacing) {
            titleBlock
                .frame(height: TVDetailHeroLayout.standardTitleHeight, alignment: .bottomLeading)
            metadata
            TVDetailSynopsisSlot(
                overview: overview,
                isCompact: false,
                isEnabled: synopsisEnabled,
                height: TVDetailHeroLayout.standardSynopsisHeight,
                maxWidth: TVDetailHeroLayout.standardTextWidth,
                focus: focus
            )
            // A zero-size last child, so the stack keeps the spacing it has
            // always had after the synopsis.
            Color.clear.frame(width: 0, height: 0)
        }
        .frame(maxWidth: TVDetailHeroLayout.standardTextWidth, alignment: .leading)
    }

    @ViewBuilder
    private var titleBlock: some View {
        switch treatment {
        case let .hierarchy(seriesTitle, seriesLogoUrl, episodeTitle):
            TVDetailHierarchyTitle(seriesTitle: seriesTitle, seriesLogoUrl: seriesLogoUrl, episodeTitle: episodeTitle)
        case let .logo(url, title):
            TVDetailLogoTitle(
                logoUrl: url,
                label: title,
                maxWidth: 650,
                maxHeight: TVDetailHeroLayout.standardTitleHeight
            ) {
                TVDetailDisplayTitle(title: title)
            }
        }
    }
}

/// The synopsis slot, kept empty without an overview so the rows below
/// keep their fixed positions. The slot itself doesn't clip: a script with
/// taller lines runs on into the room the hero keeps under it, and the
/// hero's primary block clips above the credit line.
private struct TVDetailSynopsisSlot: View {
    let overview: String?
    let isCompact: Bool
    let isEnabled: Bool
    let height: CGFloat
    let maxWidth: CGFloat
    var focus: FocusState<TVDetailHeroFocus?>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let overview, !overview.isEmpty {
                TVDetailSynopsisButton(
                    overview: overview,
                    isCompact: isCompact,
                    isEnabled: isEnabled,
                    maxWidth: maxWidth,
                    focus: focus
                )
            }
        }
        .frame(height: height, alignment: .topLeading)
    }
}
#endif
