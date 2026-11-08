#if os(tvOS)
import SwiftUI

/// Hero sizes for each kind of page.
struct TVDetailHeroLayout {
    static let horizontalInset: CGFloat = 100
    static let defaultHeight: CGFloat = 690
    static let defaultTopInset: CGFloat = 116
    static let editorialWidth: CGFloat = 750
    static let editorialHeight: CGFloat = 435
    static let sectionSpacing: CGFloat = 64
    static let sectionHeaderSpacing: CGFloat = 14
    static let pageBottomPadding: CGFloat = 140
    /// Where the heading line starts below the top of the compact editorial.
    static let compactHeadingTop: CGFloat = 170
    /// The gap between the hero poster and the details beside it.
    static let posterSpacing: CGFloat = 40
    /// The poster runs from the heading line to the bottom of the action row
    /// (the editorial's remainder, the 12-point gap and the 76-point row).
    static let posterHeight: CGFloat = editorialHeight - compactHeadingTop + 12 + TVDetailActionRowLayout.controlHeight
    static let posterWidth: CGFloat = (posterHeight * 2 / 3).rounded()
    /// How far the details sit right of the logo on the native pages, which
    /// the loading page matches so nothing moves when the title loads.
    static let posterInset: CGFloat = posterWidth + posterSpacing
    /// The native pages' logo sits in the top-left corner, as far from the
    /// top as the content is from the left.
    static let logoTopInset: CGFloat = 100
    static let logoWidth: CGFloat = 650
    static let logoHeight: CGFloat = 160

    var height: CGFloat
    var topInset: CGFloat
    /// Compact pages show the heading, synopsis and technical row.
    var isCompact: Bool
    var showsBackdrop: Bool
    var clipsToHeight: Bool

    /// The editorial's top on a hero of the given height. The action row
    /// (editorial, 12-point gap, 76-point row) ends at the hero's bottom, so
    /// on the native pages it sits as far above the screen's bottom edge as
    /// the content sits from the left.
    static func browsingTopInset(for height: CGFloat) -> CGFloat {
        max(defaultTopInset, height - 553) + 30
    }

    /// The native movie and series pages.
    static func showcase(height: CGFloat) -> TVDetailHeroLayout {
        TVDetailHeroLayout(
            height: height,
            topInset: browsingTopInset(for: height),
            isCompact: true,
            showsBackdrop: false,
            clipsToHeight: false
        )
    }

    /// The older layout and the season page.
    static func standard(clipsToHeight: Bool) -> TVDetailHeroLayout {
        TVDetailHeroLayout(
            height: defaultHeight,
            topInset: defaultTopInset,
            isCompact: false,
            showsBackdrop: true,
            clipsToHeight: clipsToHeight
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
        let size = CGSize(width: TVDetailHeroLayout.posterWidth, height: TVDetailHeroLayout.posterHeight)
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

    private var editorialWidth: CGFloat { TVDetailHeroLayout.editorialWidth + contentInset }

    var body: some View {
        let hero = ZStack(alignment: .topLeading) {
            if layout.showsBackdrop {
                TVDetailHeroBackdrop(url: backdropUrl, thumbhash: backdropThumbhash, height: layout.height)
            }
            if layout.isCompact, let logo {
                logo
            }
            VStack(alignment: .leading, spacing: 12) {
                editorial
                actions()
                    .padding(.leading, contentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
            }
            .overlay(alignment: .topLeading) {
                if showsPoster, let poster {
                    posterArtwork(poster)
                        .padding(.top, TVDetailHeroLayout.compactHeadingTop)
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
                .frame(height: TVDetailHeroLayout.editorialHeight - 80 - 4, alignment: .topLeading)
                .clipped()

            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .leading) {
                    if let creditLine, !creditLine.isEmpty {
                        Text(verbatim: creditLine)
                            .font(.system(size: 23))
                            .foregroundStyle(Color.white.opacity(0.70))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28)
                .clipped()

                summary()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 40, alignment: .topLeading)
            }
            .padding(.leading, contentInset)
            .frame(
                width: editorialWidth,
                height: TVDetailHeroLayout.editorialHeight,
                alignment: .bottomLeading
            )
            .transaction { $0.animation = nil }
        }
        .frame(
            width: editorialWidth,
            height: TVDetailHeroLayout.editorialHeight,
            alignment: .topLeading
        )
        .clipped()
    }

    private func posterArtwork(_ poster: TVDetailHeroPoster) -> some View {
        TVDetailHeroPosterTile(poster: poster)
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

/// Heading and synopsis on the native movie and series pages, below the
/// space the logo used to fill (the logo now sits in the top-left corner).
struct TVDetailCompactPrimary<Below: View>: View {
    let headingTokens: [String]
    let genres: [String]
    let contentRating: String?
    let overview: String?
    let synopsisEnabled: Bool
    var focus: FocusState<TVDetailHeroFocus?>.Binding
    @ViewBuilder let below: () -> Below

    @Environment(\.tvDetailHeroContentInset) private var contentInset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 160)

            TVDetailCompactHeading(tokens: headingTokens, genres: genres, contentRating: contentRating)
                .frame(height: 36, alignment: .leading)
                .padding(.top, 10)
                .padding(.leading, contentInset)

            VStack(alignment: .leading, spacing: 4) {
                TVDetailSynopsisSlot(overview: overview, isCompact: true, isEnabled: synopsisEnabled, focus: focus)
                below()
            }
            .frame(height: 140, alignment: .topLeading)
            .padding(.top, 12)
            .padding(.leading, contentInset)
        }
        .frame(width: TVDetailHeroLayout.editorialWidth + contentInset, height: 350, alignment: .topLeading)
    }
}

/// How the standard hero titles the item.
enum TVDetailTitleTreatment {
    /// An episode under its series' logo or name.
    case hierarchy(seriesTitle: String, seriesLogoUrl: String?, episodeTitle: String)
    /// A logo, falling back to the display title.
    case logo(url: String?, title: String)
}

/// Eyebrow, title, metadata and synopsis on the older layout and the season
/// page.
struct TVDetailStandardPrimary<Below: View>: View {
    let eyebrow: String?
    let treatment: TVDetailTitleTreatment
    let metadata: TVDetailMetadataSlots
    let overview: String?
    let synopsisEnabled: Bool
    var focus: FocusState<TVDetailHeroFocus?>.Binding
    @ViewBuilder let below: () -> Below

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow, !eyebrow.isEmpty {
                TVDetailEyebrow(text: eyebrow)
            }
            titleBlock
                .frame(height: 160, alignment: .bottomLeading)
                .padding(.top, eyebrow == nil ? 0 : 2)
            metadata
            TVDetailSynopsisSlot(overview: overview, isCompact: false, isEnabled: synopsisEnabled, focus: focus)
            below()
        }
        .frame(maxWidth: TVDetailHeroLayout.editorialWidth, alignment: .leading)
    }

    @ViewBuilder
    private var titleBlock: some View {
        switch treatment {
        case let .hierarchy(seriesTitle, seriesLogoUrl, episodeTitle):
            TVDetailHierarchyTitle(seriesTitle: seriesTitle, seriesLogoUrl: seriesLogoUrl, episodeTitle: episodeTitle)
        case let .logo(url, title):
            TVDetailLogoTitle(logoUrl: url, label: title, maxWidth: 650, maxHeight: 160) {
                TVDetailDisplayTitle(title: title)
            }
        }
    }
}

/// The 112-point synopsis slot, kept empty without an overview so the rows
/// below keep their fixed positions.
private struct TVDetailSynopsisSlot: View {
    let overview: String?
    let isCompact: Bool
    let isEnabled: Bool
    var focus: FocusState<TVDetailHeroFocus?>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let overview, !overview.isEmpty {
                TVDetailSynopsisButton(overview: overview, isCompact: isCompact, isEnabled: isEnabled, focus: focus)
            }
        }
        .frame(height: 112, alignment: .topLeading)
        .clipped()
    }
}
#endif
