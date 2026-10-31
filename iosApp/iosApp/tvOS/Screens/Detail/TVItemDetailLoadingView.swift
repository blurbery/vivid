#if os(tvOS)
import SwiftUI

/// The page shown while a title loads with nothing cached. It paints what
/// the card already knew in the loaded page's positions, so the page settles
/// in place. Nothing here takes focus.
struct TVItemDetailLoadingView: View {
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
            title: seed?.title ?? ""
        ) { showcaseHeight in
            skeletonEditorial(layout: .showcase(height: showcaseHeight))
                .frame(height: showcaseHeight, alignment: .topLeading)
        } shelves: {
            EmptyView()
        }
    }

    // MARK: Standard shape

    private var standard: some View {
        TVDetailStandardSurface(backdropUrl: seed?.backdropUrl) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    standardArtwork
                    skeletonEditorial(layout: .standard(clipsToHeight: true))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: TVDetailHeroLayout.defaultHeight, alignment: .topLeading)
                .clipped()

                placeholderRail
            }
        }
    }

    private var standardArtwork: some View {
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
            .frame(width: proxy.size.width, height: TVDetailHeroLayout.defaultHeight, alignment: .topTrailing)
        }
        .frame(height: TVDetailHeroLayout.defaultHeight)
    }

    // MARK: Skeleton editorial

    private func skeletonEditorial(layout: TVDetailHeroLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if layout.isCompact {
                    nativeBlock
                } else {
                    standardBlock
                }
                VStack(alignment: .leading, spacing: 12) {
                    placeholder(width: 390, height: 18, radius: 5)
                        .frame(height: 28, alignment: .leading)
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
                    .frame(height: 40, alignment: .topLeading)
                }
                .frame(
                    width: TVDetailHeroLayout.editorialWidth,
                    height: TVDetailHeroLayout.editorialHeight,
                    alignment: .bottomLeading
                )
            }
            .frame(
                width: TVDetailHeroLayout.editorialWidth,
                height: TVDetailHeroLayout.editorialHeight,
                alignment: .topLeading
            )

            HStack(spacing: 18) {
                placeholder(width: 280, height: 76, radius: 38)
                ForEach(0..<(layout.isCompact ? 4 : 5), id: \.self) { _ in
                    placeholder(width: 76, height: 76, radius: 38)
                }
            }
        }
        .padding(.top, layout.topInset)
        .padding(.horizontal, TVDetailHeroLayout.horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: layout.height, alignment: .topLeading)
    }

    /// The compact editorial layout with the seed's heading.
    private var nativeBlock: some View {
        let type = seed?.mediaType.lowercased() ?? ""
        let token = type == "movie"
            ? String(localized: "Movie")
            : String(localized: "series.typeLabel", defaultValue: "Series", comment: "Media type label for a single series")
        return VStack(alignment: .leading, spacing: 0) {
            loadingTitle(native: true)
                .frame(height: 160, alignment: .bottomLeading)
            TVDetailCompactHeading(
                tokens: [token],
                genres: seed?.genre.map { [$0] } ?? [],
                contentRating: TVHeroMetadata.contentRating(seed?.contentRating)
            )
            .frame(height: 36, alignment: .leading)
            .padding(.top, 10)
            loadingSynopsis
                .frame(height: 140, alignment: .topLeading)
                .padding(.top, 12)
        }
        .frame(width: TVDetailHeroLayout.editorialWidth, height: 350, alignment: .topLeading)
    }

    private var standardBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            loadingTitle(native: false)
                .frame(width: 650, height: 160, alignment: .bottomLeading)
            loadingMetadata
                .frame(height: 36, alignment: .leading)
            loadingSynopsis
                .frame(width: TVDetailHeroLayout.editorialWidth, height: 112, alignment: .topLeading)
                .clipped()
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
            Text(verbatim: parts.joined(separator: "  \u{00B7}  ").uppercased())
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))
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
            parts.append(rating)
        }
        return parts
    }

    @ViewBuilder
    private var loadingSynopsis: some View {
        let overview = seed?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !overview.isEmpty {
            Text(verbatim: overview)
                .font(.system(size: 26))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineSpacing(5)
                .lineLimit(3)
                .frame(maxWidth: TVDetailHeroLayout.editorialWidth, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 13) {
                placeholder(width: 730, height: 18, radius: 5)
                placeholder(width: 690, height: 18, radius: 5)
                placeholder(width: 610, height: 18, radius: 5)
            }
            .padding(.top, 4)
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
