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

    var height: CGFloat
    var topInset: CGFloat
    /// Compact pages show the heading, synopsis and technical row.
    var isCompact: Bool
    var showsBackdrop: Bool
    var clipsToHeight: Bool

    /// The editorial's top on a hero of the given height, so it sits level
    /// with the shelf logo of the native pages.
    static func browsingTopInset(for height: CGFloat) -> CGFloat {
        max(defaultTopInset, height - 580) + 30
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

/// The top of a detail page: optional backdrop artwork, the editorial block
/// with its credit and summary line, and the action row.
struct TVDetailHeroPanel<Primary: View, Summary: View, Actions: View>: View {
    let layout: TVDetailHeroLayout
    var backdropUrl: String? = nil
    var backdropThumbhash: String? = nil
    let creditLine: String?
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let hero = ZStack(alignment: .topLeading) {
            if layout.showsBackdrop {
                TVDetailHeroBackdrop(url: backdropUrl, thumbhash: backdropThumbhash, height: layout.height)
            }
            VStack(alignment: .leading, spacing: 12) {
                editorial
                actions()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
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
            .frame(
                width: TVDetailHeroLayout.editorialWidth,
                height: TVDetailHeroLayout.editorialHeight,
                alignment: .bottomLeading
            )
            .transaction { $0.animation = nil }
        }
        .frame(
            width: TVDetailHeroLayout.editorialWidth,
            height: TVDetailHeroLayout.editorialHeight,
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

/// Logo or title, heading and synopsis on the native movie and series pages.
struct TVDetailCompactPrimary<Below: View>: View {
    let title: String
    let logoUrl: String?
    let headingTokens: [String]
    let genres: [String]
    let contentRating: String?
    let overview: String?
    let synopsisEnabled: Bool
    var focus: FocusState<TVDetailHeroFocus?>.Binding
    @ViewBuilder let below: () -> Below

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVDetailLogoTitle(logoUrl: logoUrl, label: title, maxWidth: 650, maxHeight: 160) {
                Text(verbatim: title)
                    .font(.system(size: 78, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            .frame(height: 160, alignment: .bottomLeading)

            TVDetailCompactHeading(tokens: headingTokens, genres: genres, contentRating: contentRating)
                .frame(height: 36, alignment: .leading)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 4) {
                TVDetailSynopsisSlot(overview: overview, isCompact: true, isEnabled: synopsisEnabled, focus: focus)
                below()
            }
            .frame(height: 140, alignment: .topLeading)
            .padding(.top, 12)
        }
        .frame(width: TVDetailHeroLayout.editorialWidth, height: 350, alignment: .topLeading)
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

/// The 112-point synopsis slot, empty without an overview.
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
