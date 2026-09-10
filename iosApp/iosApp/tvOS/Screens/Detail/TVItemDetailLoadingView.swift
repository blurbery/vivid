#if os(tvOS)
import SwiftUI

/// Passive first frame for an item route whose authoritative `ItemDetail` has
/// not arrived yet. Card routes can brand the frame from their lightweight
/// route seed; ID-only deep links and cold trailer restores use the same fixed
/// geometry with quiet placeholders. Nothing here participates in focus — the
/// loaded detail view installs its own native focus graph and default owner.
struct TVItemDetailLoadingView: View {
    let seed: TVItemDetailRouteSeed?

    var body: some View {
        Group {
            if usesNativePage {
                TVAppleDetailPage(backdropURL: seed?.backdropUrl, logoURL: seed?.logoUrl,
                                  title: seed?.title ?? "") { height in
                    cinematicEditorial(height: height, topInset: max(116, height - 580))
                        .frame(height: height, alignment: .topLeading)
                } shelves: {
                    EmptyView()
                }
            } else {
                cinematicLayout
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Movie / series / episode

    private var cinematicLayout: some View {
        TVDetailPageSurface(backdropURL: seed?.backdropUrl) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    cinematicArtwork
                    cinematicEditorial()
                }
                .frame(height: TVDetailLayout.heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()

                loadingRail
            }
        }
    }

    private var cinematicArtwork: some View {
        GeometryReader { geometry in
            let artworkSize = TVBackdropArtworkLayout.artworkSize(
                forViewportWidth: geometry.size.width
            )

            Group {
                if let url = nonEmpty(seed?.backdropUrl) {
                    AsyncImageView(
                        url: url,
                        thumbhash: seed?.backdropThumbhash,
                        targetSize: artworkSize,
                        contentMode: .fill
                    )
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.035))
                }
            }
            .frame(width: artworkSize.width, height: artworkSize.height)
            .clipped()
            .mask { TVBackdropArtworkFadeMask(softensLeadingFade: true) }
            .frame(
                width: geometry.size.width,
                height: TVDetailLayout.heroHeight,
                alignment: .topTrailing
            )
        }
    }

    private func cinematicEditorial(height: CGFloat = TVDetailLayout.heroHeight,
                                    topInset: CGFloat = TVDetailLayout.heroTopInset) -> some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.disclosureSpacing) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    loadingTitle
                        .frame(width: 650, height: 160, alignment: .bottomLeading)
                    loadingMetadata
                        .frame(height: 36, alignment: .leading)
                    loadingSynopsis
                        .frame(width: TVDetailLayout.heroContentWidth, height: 112, alignment: .topLeading)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: TVDetailLayout.disclosureSpacing) {
                    placeholder(width: 390, height: 18, cornerRadius: 5)
                        .frame(height: 28, alignment: .leading)
                    loadingPlaybackSummary
                        .frame(height: 40, alignment: .topLeading)
                }
                .frame(height: TVDetailLayout.editorialHeight, alignment: .bottomLeading)
            }
            .frame(width: TVDetailLayout.heroContentWidth, height: TVDetailLayout.editorialHeight, alignment: .topLeading)
            loadingActions
        }
        .padding(.top, topInset)
        .padding(.horizontal, TVDetailLayout.horizontalInset)
        .frame(
            maxWidth: .infinity,
            maxHeight: height,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var loadingTitle: some View {
        if let title = nonEmpty(seed?.title) {
            TVDecodedLogoTitle(
                logoUrl: seed?.logoUrl,
                accessibilityLabel: title,
                maxWidth: usesNativePage ? 650 : 700,
                maxHeight: usesNativePage ? 160 : 132
            ) {
                Text(title)
                    .font(.system(size: usesNativePage ? 78 : 64, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: 700, alignment: .leading)
            }
        } else {
            placeholder(width: 520, height: 64, cornerRadius: 10)
        }
    }

    @ViewBuilder
    private var loadingMetadata: some View {
        if !metadataTokens.isEmpty {
            Text(metadataTokens.joined(separator: "  ·  "))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))
                .lineLimit(1)
        } else {
            placeholder(width: 390, height: 22, cornerRadius: 6)
        }
    }

    @ViewBuilder
    private var loadingSynopsis: some View {
        if let overview = nonEmpty(seed?.overview) {
            Text(overview)
                .font(.system(size: 26))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineSpacing(5)
                .lineLimit(3)
                .frame(maxWidth: TVDetailLayout.heroContentWidth, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 13) {
                placeholder(width: 730, height: 18, cornerRadius: 5)
                placeholder(width: 690, height: 18, cornerRadius: 5)
                placeholder(width: 610, height: 18, cornerRadius: 5)
            }
            .padding(.top, 4)
        }
    }

    private var loadingPlaybackSummary: some View {
        TVPlaybackSelectionSummaryView(summary: .init(version: nil, audio: nil, subtitles: nil))
    }

    private var loadingActions: some View {
        HStack(spacing: 18) {
            placeholder(width: 280, height: 76, cornerRadius: 38)
            ForEach(0..<5, id: \.self) { _ in
                placeholder(width: 76, height: 76, cornerRadius: 38)
            }
        }
    }

    private var loadingRail: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            placeholder(width: 220, height: 26, cornerRadius: 6)

            HStack(spacing: railSpacing) {
                ForEach(0..<railCardCount, id: \.self) { _ in
                    placeholder(
                        width: railCardSize.width,
                        height: railCardSize.height,
                        cornerRadius: VividTheme.cornerRadius
                    )
                }
            }
        }
        .padding(.horizontal, TVDetailLayout.horizontalInset)
        .padding(.bottom, TVDetailLayout.pageBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    // MARK: - Derived presentation

    private var usesNativePage: Bool {
        guard let type = seed?.mediaType else { return false }
        return type == "movie" || VividMediaType.isSeries(type)
    }

    private var metadataTokens: [String] {
        guard let seed else { return [] }
        var values: [String] = []
        if let year = seed.year, year > 0 {
            values.append(String(year))
        }
        if let genre = nonEmpty(seed.genre) {
            values.append(genre)
        }
        if let runtime = seed.runtime, runtime > 0 {
            values.append(runtimeLabel(runtime))
        }
        if let rating = nonEmpty(seed.contentRating) {
            values.append(rating.uppercased())
        }
        return values
    }

    private var usesLandscapeRail: Bool {
        guard let mediaType = seed?.mediaType else { return false }
        let type = mediaType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return VividMediaType.isSeries(type) || type == "season" || type == "episode"
    }

    private var railCardSize: CGSize {
        if usesLandscapeRail {
            return CGSize(width: 400, height: 225)
        }
        return CGSize(width: 220, height: 330)
    }

    private var railCardCount: Int { usesLandscapeRail ? 4 : 6 }
    private var railSpacing: CGFloat { usesLandscapeRail ? 34 : 44 }

    private var accessibilityLabel: String {
        if let title = nonEmpty(seed?.title) {
            return "Loading details for \(title)"
        }
        return "Loading details"
    }

    private func runtimeLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let remainder = minutes % 60
            return remainder == 0
                ? "\(minutes / 60)h"
                : "\(minutes / 60)h \(remainder)m"
        }
        return "\(minutes) min"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func placeholder(
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .frame(width: width, height: height)
    }
}
#endif
