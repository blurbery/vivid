import SwiftUI

/// The small capsule naming a title's request state over its poster.
struct RequestStatusRibbon: View {
    let badge: RequestBadge

    #if os(tvOS)
    private let spacing: CGFloat = 8
    private let dotSize: CGFloat = 10
    private let fontSize: CGFloat = 20
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 8
    #else
    private let spacing: CGFloat = 5
    private let dotSize: CGFloat = 6
    private let fontSize: CGFloat = 10
    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 4
    #endif

    var body: some View {
        HStack(spacing: spacing) {
            Circle()
                .fill(badge.tint)
                .frame(width: dotSize, height: dotSize)
            Text(badge.label)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// A Seerr search result as a poster card that opens its request page.
struct RequestResultCard: View {
    let result: RequestMediaResult
    #if os(tvOS)
    let width: CGFloat
    #endif

    @Environment(AppRouter.self) private var router

    #if os(tvOS)
    private let ribbonInset: CGFloat = 14
    #else
    private let ribbonInset: CGFloat = 6
    #endif

    private var presentation: CardPresentationPreference {
        UICustomizationPreferences.shared.cardPresentation
    }

    private var cardWidth: CGFloat {
        #if os(tvOS)
        width
        #else
        VividTheme.posterCardWidth * presentation.posterSize.scale
        #endif
    }

    private var cardHeight: CGFloat {
        cardWidth * VividTheme.posterCardHeight / VividTheme.posterCardWidth
    }

    private var badge: RequestBadge? {
        RequestBadge.forCard(availability: result.availability, request: result.request)
    }

    private var shownYear: Int? {
        guard let year = result.year, year > 0 else { return nil }
        return year
    }

    private var accessibilityText: String {
        var text = result.title
        if let shownYear { text += ", " + String(shownYear) }
        if let badge { text += ", " + badge.label }
        return text
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 22) {
            Button(action: open) {
                artwork
            }
            .buttonStyle(.card)
            .accessibilityLabel(accessibilityText)
            caption
        }
        .frame(width: cardWidth, alignment: .leading)
        #else
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                artwork
                if presentation.caption.showsTitle {
                    caption
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: cardWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        #endif
    }

    private func open() {
        router.navigate(to: .requestDetail(mediaType: result.mediaType, tmdbId: result.tmdbId))
    }

    private var artwork: some View {
        ZStack(alignment: .topTrailing) {
            if let url = RequestArtworkURL.poster(result.posterPath) {
                AsyncImageView(url: url, targetSize: CGSize(width: cardWidth, height: cardHeight), contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.vividSurfaceElevated)
                    .overlay {
                        Text(result.title)
                            .font(.vividCaption.weight(.semibold))
                            .foregroundStyle(Color.vividSecondaryText)
                            .multilineTextAlignment(.center)
                            .padding(12)
                    }
            }
            if let badge {
                RequestStatusRibbon(badge: badge)
                    .padding(ribbonInset)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
            if presentation.caption.showsMetadata, let shownYear {
                Text(verbatim: String(shownYear))
                    .font(.vividCaption)
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var title: some View {
        #if os(tvOS)
        Text(result.title)
            .font(.vividSubheadline)
            .foregroundStyle(Color.vividOnSurface)
            .lineLimit(1)
            .truncationMode(.tail)
        #else
        Text(result.title)
            .font(.vividSubheadline)
            .foregroundStyle(Color.vividOnSurface)
            .lineLimit(2, reservesSpace: true)
        #endif
    }
}

#if !os(tvOS)
/// A horizontal row of result cards for iPhone and iPad.
struct RequestResultRail: View {
    let results: [RequestMediaResult]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(results) { result in
                    RequestResultCard(result: result)
                }
            }
            .phoneMediaRailBounds()
        }
    }
}
#endif
