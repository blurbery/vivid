#if os(tvOS)
import SwiftUI

/// The page shown while a title loads with nothing cached. It paints what
/// the card already knew in the loaded page's positions, so the page settles
/// in place. Nothing here takes focus.
struct TVDetailLoadingPage: View {
    let seed: TVItemDetailRouteSeed?

    private var seedTitle: String? {
        let title = seed?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    /// Movies and series load into the native page, so they wait in its shape.
    private var usesNativeShape: Bool {
        guard let seed else { return false }
        let type = seed.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "movie" || VividMediaType.isSeries(type)
    }

    var body: some View {
        Group {
            if usesNativeShape {
                native
            } else {
                standard
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        if let seedTitle {
            return Text("Loading details for \(seedTitle)")
        }
        return Text("Loading details")
    }

    // MARK: Native shape

    private var native: some View {
        TVDetailNativeShell(
            backdropUrl: seed?.backdropUrl,
            backdropThumbhash: seed?.backdropThumbhash,
            logoUrl: seed?.logoUrl,
            title: seedTitle ?? ""
        ) { showcaseHeight in
            ZStack(alignment: .topLeading) {
                if let seedTitle {
                    TVDetailHeroLogo(logoUrl: seed?.logoUrl, title: seedTitle)
                }
                skeletonEditorial(layout: .showcase(height: showcaseHeight))
            }
            .frame(height: showcaseHeight, alignment: .topLeading)
        } shelves: {
            EmptyView()
        }
    }

    // MARK: Standard shape

    /// An episode under its series title shows a source row and a facts
    /// row, so its hero is a row taller. The seed doesn't say whether the
    /// series title will be found, so an episode is assumed to have one,
    /// as nearly all do; one that doesn't loads into the shorter hero.
    private var standardMetadataRows: Int {
        let type = seed?.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return type == "episode" ? 2 : 1
    }

    /// The older hero the seed's type loads into.
    private var standardLayout: TVDetailHeroLayout {
        .standard(clipsToHeight: true, metadataRows: standardMetadataRows)
    }

    private var standard: some View {
        let layout = standardLayout
        return TVDetailStandardSurface(backdropUrl: seed?.backdropUrl) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    standardArtwork(height: layout.height)
                    skeletonEditorial(layout: layout)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: layout.height, alignment: .topLeading)
                .clipped()

                placeholderRail
            }
        }
    }

    private func standardArtwork(height: CGFloat) -> some View {
        GeometryReader { proxy in
            let size = TVBackdropArtworkLayout.artworkSize(forViewportWidth: proxy.size.width)
            Group {
                let backdrop = seed?.backdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !backdrop.isEmpty {
                    AsyncImageView(
                        url: backdrop,
                        thumbhash: seed?.backdropThumbhash,
                        targetSize: size,
                        contentMode: .fill
                    )
                } else {
                    Rectangle().fill(Color.white.opacity(0.035))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .mask { TVBackdropArtworkFadeMask(softensLeadingFade: true) }
            .frame(width: proxy.size.width, height: height, alignment: .topTrailing)
        }
        .frame(height: height)
    }

    // MARK: Skeleton editorial

    private func skeletonEditorial(layout: TVDetailHeroLayout) -> some View {
        // The native pages put the poster beside the details; the skeleton
        // keeps its place so the loaded page lands without moving.
        let inset = layout.isCompact ? TVDetailHeroLayout.posterInset : 0
        let width = layout.textWidth + inset
        return VStack(alignment: .leading, spacing: TVDetailHeroLayout.rowSpacing) {
            ZStack(alignment: .topLeading) {
                if layout.isCompact {
                    nativeBlock(inset: inset)
                } else {
                    standardBlock
                }
                VStack(alignment: .leading, spacing: TVDetailHeroLayout.rowSpacing) {
                    placeholder(width: 390, height: 22, radius: 6)
                        .frame(height: TVDetailHeroLayout.creditHeight, alignment: .leading)
                    Group {
                        if layout.isCompact {
                            TVDetailTechnicalRow(
                                releaseFacts: TVHeroMetadata.releaseFacts(year: seed?.year, runtime: seed?.runtime),
                                badges: TVHeroMetadata.sourceBadges(nil, summary: seed?.overlaySummary),
                                tmdbScore: nil
                            )
                        } else {
                            TVDetailPlaybackSummary(values: TVDetailPlaybackSummaryValues(version: nil))
                        }
                    }
                    .frame(height: layout.summaryHeight, alignment: .topLeading)
                }
                .padding(.leading, inset)
                .frame(
                    width: width,
                    height: layout.editorialHeight,
                    alignment: .bottomLeading
                )
            }
            .frame(
                width: width,
                height: layout.editorialHeight,
                alignment: .topLeading
            )

            HStack(spacing: 18) {
                placeholder(
                    width: TVDetailActionRowLayout.expandedWidth,
                    height: TVDetailActionRowLayout.controlHeight,
                    radius: TVDetailActionRowLayout.controlHeight / 2
                )
                ForEach(0..<(layout.isCompact ? 4 : 5), id: \.self) { _ in
                    placeholder(
                        width: TVDetailActionRowLayout.controlHeight,
                        height: TVDetailActionRowLayout.controlHeight,
                        radius: TVDetailActionRowLayout.controlHeight / 2
                    )
                }
            }
            .padding(.leading, inset)
        }
        // As on the loaded page, the skeleton is as tall as the poster.
        .overlay(alignment: .topLeading) {
            if layout.isCompact {
                TVDetailHeroPosterTile()
            }
        }
        .padding(.top, layout.topInset)
        .padding(.horizontal, TVDetailHeroLayout.horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: layout.height, alignment: .topLeading)
    }

    /// The compact editorial layout with the seed's heading, beside the
    /// poster's place.
    private func nativeBlock(inset: CGFloat) -> some View {
        let type = seed?.mediaType.lowercased() ?? ""
        let token = type == "movie"
            ? String(localized: "Movie")
            : String(localized: "series.typeLabel", defaultValue: "Series", comment: "Media type label for a single series")
        return VStack(alignment: .leading, spacing: 0) {
            TVDetailCompactHeading(
                tokens: [token],
                genres: seed?.genre.map { [$0] } ?? [],
                contentRating: TVHeroMetadata.contentRating(seed?.contentRating)
            )
            .frame(height: TVDetailHeroLayout.compactHeadingHeight, alignment: .leading)
            .padding(.leading, inset)
            loadingSynopsis(lines: 4, width: TVDetailHeroLayout.compactTextWidth)
                .frame(height: TVDetailHeroLayout.compactSynopsisHeight, alignment: .topLeading)
                .padding(.top, TVDetailHeroLayout.compactSynopsisGap)
                .padding(.leading, inset)
        }
        .frame(
            width: TVDetailHeroLayout.compactTextWidth + inset,
            height: TVDetailHeroLayout.compactPrimaryHeight,
            alignment: .topLeading
        )
    }

    private var standardBlock: some View {
        VStack(alignment: .leading, spacing: TVDetailHeroLayout.standardStackSpacing) {
            loadingTitle(native: false)
                .frame(width: 650, height: TVDetailHeroLayout.standardTitleHeight, alignment: .bottomLeading)
            if standardMetadataRows > 1 {
                // The source row an episode shows above its facts.
                placeholder(width: 420, height: 22, radius: 6)
                    .frame(height: TVDetailHeroLayout.standardMetadataHeight, alignment: .leading)
            }
            loadingMetadata
                .frame(height: TVDetailHeroLayout.standardMetadataHeight, alignment: .leading)
            loadingSynopsis(lines: 3, width: TVDetailHeroLayout.standardTextWidth)
                .frame(
                    width: TVDetailHeroLayout.standardTextWidth,
                    height: TVDetailHeroLayout.standardSynopsisHeight,
                    alignment: .topLeading
                )
        }
    }

    @ViewBuilder
    private func loadingTitle(native: Bool) -> some View {
        if let seedTitle {
            TVDetailLogoTitle(
                logoUrl: seed?.logoUrl,
                label: seedTitle,
                maxWidth: native ? 650 : 700,
                maxHeight: native ? 160 : 132
            ) {
                Text(verbatim: seedTitle)
                    .font(.system(size: native ? 78 : 64, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: 700, alignment: .leading)
            }
        } else {
            placeholder(width: 520, height: 64, radius: 10)
        }
    }

    @ViewBuilder
    private var loadingMetadata: some View {
        let parts = metadataParts
        if parts.isEmpty {
            placeholder(width: 390, height: 22, radius: 6)
        } else {
            Text(verbatim: parts.joined(separator: "  \u{00B7}  "))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.vividTextTertiary)
                .lineLimit(1)
        }
    }

    private var metadataParts: [String] {
        guard let seed else { return [] }
        var parts: [String] = []
        if let year = seed.year, year > 0 {
            parts.append(String(year))
        }
        if let genre = seed.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            parts.append(genre)
        }
        if let runtime = seed.runtime, runtime > 0 {
            if runtime % 60 == 0 {
                parts.append(String(localized: "\(runtime / 60)h"))
            } else if runtime >= 60 {
                parts.append(TVHeroMetadata.hoursAndMinutes(runtime))
            } else {
                parts.append(String(localized: "\(runtime) min"))
            }
        }
        if let rating = seed.contentRating?.trimmingCharacters(in: .whitespacesAndNewlines), !rating.isEmpty {
            // Only the rating is upper-cased.
            parts.append(rating.uppercased())
        }
        return parts
    }

    /// The seeded overview at the loaded page's size and line count: four
    /// lines on movie and series pages, three on the older layout, which
    /// shows Read more under them once loaded.
    @ViewBuilder
    private func loadingSynopsis(lines: Int, width: CGFloat) -> some View {
        let overview = seed?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !overview.isEmpty {
            Text(verbatim: overview)
                .font(.system(size: 28))
                .foregroundStyle(Color.vividTextBody)
                .lineLimit(lines)
                .frame(maxWidth: width, alignment: .topLeading)
        } else {
            // Bars on the pitch of the 28-point lines, a little short of
            // the column's width.
            VStack(alignment: .leading, spacing: 11) {
                placeholder(width: (width * 0.97).rounded(), height: 22, radius: 6)
                placeholder(width: (width * 0.92).rounded(), height: 22, radius: 6)
                placeholder(width: (width * 0.81).rounded(), height: 22, radius: 6)
            }
            .padding(.top, 6)
        }
    }

    // MARK: Placeholder rail

    private var placeholderRail: some View {
        let type = seed?.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let landscape = VividMediaType.isSeries(type) || type == "season" || type == "episode"
        return VStack(alignment: .leading, spacing: 14) {
            placeholder(width: 220, height: 26, radius: 6)
            HStack(spacing: landscape ? 34 : 44) {
                ForEach(0..<(landscape ? 4 : 6), id: \.self) { _ in
                    if landscape {
                        placeholder(width: 400, height: 225, radius: 12)
                    } else {
                        placeholder(width: 220, height: 330, radius: 12)
                    }
                }
            }
        }
        .padding(.horizontal, TVDetailHeroLayout.horizontalInset)
        .padding(.bottom, TVDetailHeroLayout.pageBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func placeholder(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .frame(width: width, height: height)
    }
}
#endif
