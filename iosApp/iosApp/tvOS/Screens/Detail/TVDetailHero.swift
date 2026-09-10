#if os(tvOS)
import SwiftUI

/// Shared 1920×1080 detail metrics. These are deliberately separate from the
/// root Skyline metrics: the detail experience has its own approved rhythm,
/// while Home and Browse keep their existing layout untouched.
enum TVDetailLayout {
    static let horizontalInset: CGFloat = 100
    static let heroHeight: CGFloat = 690
    /// Shared title baseline for every detail page. Sits low enough that the
    /// first rail below the 690pt hero bottoms out just above the safe area.
    static let heroTopInset: CGFloat = 116
    static let heroContentWidth: CGFloat = 750
    static let editorialHeight: CGFloat = 435
    static let disclosureSpacing: CGFloat = 12
    static let bodySectionSpacing: CGFloat = 64
    static let sectionHeaderSpacing: CGFloat = 14
    static let pageBottomPadding: CGFloat = 140
}

/// Fully opaque page surface sampled from the title artwork. The sampled tint
/// is composited over black, so this remains a cheap, solid background rather
/// than a live material or blur. Artwork itself lives inside the scrolling
/// hero and therefore leaves the screen naturally as the viewer moves down.
struct TVDetailLowerBackground: View {
    @State private var customization = UICustomizationPreferences.shared

    var body: some View {
        let cardHeight = VividTheme.thumbnailCardHeight
            * customization.cardPresentation.posterSize.scale
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
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: cardHeight + 40)
            Color.black
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TVDetailPageSurface<Content: View>: View {
    let backdropURL: String?
    @ViewBuilder let content: () -> Content

    @State private var sampledTint = Color(red: 0.04, green: 0.12, blue: 0.14)

    var body: some View {
        ZStack {
            Color.black
            sampledTint.opacity(0.42)
            content()
        }
        .ignoresSafeArea()
        .task(id: backdropURL) {
            guard let rawURL = backdropURL,
                  let url = URL(string: rawURL) else {
                sampledTint = Color(red: 0.04, green: 0.12, blue: 0.14)
                return
            }

            if let cached = HeroBackdropPalette.cachedTint(for: url) {
                sampledTint = cached
            }
            if let tint = await HeroBackdropPalette.tintColor(for: url),
               !Task.isCancelled {
                sampledTint = tint
            }
        }
    }
}

/// Full-bleed cinematic hero for the tvOS item-detail screen. Modeled
/// after Apple TV's detail page: a nearly full-viewport backdrop layered
/// with a tall left-column editorial stack (eyebrow pill → title →
/// source row → overview → facts+quality → actions) and a quiet
/// right-side "Starring ..." line positioned mid-hero.
///
/// The intent is to show enough of the below-fold rail peeking at the
/// bottom that the viewer instinctively drifts down when they want
/// episodes / similar titles — rather than reaching the "end" of the
/// hero.
struct TVDetailHero<Actions: View, BelowSynopsis: View>: View {
    let title: String
    let seriesTitle: String?
    let logoUrl: String?
    let backdropUrl: String?
    let backdropThumbhash: String?
    /// Optional short editorial line placed in a capsule above the title
    /// (e.g. "New Episode Friday", "Continuing Series"). Hidden when nil.
    let eyebrow: String?
    /// Source/genre labels shown under the title. The optional outlined
    /// rating chip leads the metadata, followed by dot-separated text.
    let sourceTokens: [String]
    let ratingChip: String?
    /// Short description shown in the hero. Clamped to 3 lines.
    let overview: String?
    /// Inline facts row shown above the action buttons. Mixes plain text
    /// (year / runtime / maturity) and outlined quality chips
    /// (4K / HDR / ATMOS / CC).
    let factsLine: [TVHeroFactToken]
    /// Optional "Starring A, B, C" line floated on the right of the hero
    /// at mid-height. Hidden when nil.
    let starringText: String?
    /// Non-interactive playback readout shown directly below the credits. It
    /// reserves a stable slot while an episode's playback detail is loading,
    /// so changing carousel focus never moves the persistent action row.
    let playbackSummary: TVPlaybackSelectionSummary
    /// A compact editorial header can retain the standard Movie backdrop
    /// geometry independently of its own layout height. Nil keeps both heights
    /// coupled, which is the default behavior for every other detail page.
    var backdropHeight: CGFloat? = nil
    var heroHeight: CGFloat = TVDetailLayout.heroHeight
    var heroTopInset: CGFloat = TVDetailLayout.heroTopInset
    /// Episode mode narrows only the editorial column. The logo keeps the
    /// same leading/top anchor while long episode copy wraps before it reaches
    /// the backdrop subject.
    var editorialContentWidth: CGFloat = TVDetailLayout.heroContentWidth
    /// Optional fixed footprint for the complete editorial stack. Series uses
    /// this to keep the action row on one baseline in Show and Season modes;
    /// changing episode text may never reflow the controls below it.
    var editorialReservedHeight: CGFloat? = TVDetailLayout.editorialHeight
    /// Fixed metadata slot used by Series because Show facts and episode facts
    /// have different intrinsic widths and availability.
    var metadataReservedHeight: CGFloat = 36
    /// Reserves a stable synopsis footprint while adjacent episodes swap in.
    /// This keeps the selector and season tabs from moving when summaries have
    /// different lengths.
    var synopsisReservedHeight: CGFloat = 112
    /// Keeps the playback summary on one baseline whether the Show credit is
    /// present or the focused episode has no credit of its own.
    var creditReservedHeight: CGFloat = 28
    /// Vertical distance between editorial metadata and the hero controls.
    /// Series tightens this inside its fixed hero so Seasons gains clearance
    /// without moving the episode carousel down.
    var actionSpacing: CGFloat = TVDetailLayout.disclosureSpacing
    /// Series keeps its compact layout but lets the standard Movie
    /// backdrop fade finish behind the season row. Movies retain the existing
    /// clipped hero through the default.
    var usesFixedPageArtwork = false
    var extendsBackdropFadeBelowHero = false
    @ViewBuilder let actions: () -> Actions
    /// Affordance rendered directly under the synopsis (e.g. the on-view
    /// description-translation control). Pass `{ EmptyView() }` when there's
    /// nothing to show.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    @ViewBuilder
    var body: some View {
        if extendsBackdropFadeBelowHero {
            heroComposition
        } else {
            heroComposition.clipped()
        }
    }

    private var heroComposition: some View {
        ZStack(alignment: .topLeading) {
            if !usesFixedPageArtwork { backdrop }
            content
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        GeometryReader { geometry in
            let resolvedBackdropHeight = backdropHeight ?? heroHeight
            let artworkSize = TVBackdropArtworkLayout.artworkSize(
                forViewportWidth: geometry.size.width
            )

            if let url = backdropUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: artworkSize,
                    thumbhash: backdropThumbhash,
                    contentMode: .fill
                )
                .frame(width: artworkSize.width, height: artworkSize.height)
                .clipped()
                .mask { TVBackdropArtworkFadeMask(softensLeadingFade: true) }
                .frame(
                    width: geometry.size.width,
                    height: resolvedBackdropHeight,
                    alignment: .topTrailing
                )
            }
        }
    }

    // MARK: - Content column

    private var content: some View {
        VStack(alignment: .leading, spacing: actionSpacing) {
            reservedEditorialColumn

            // Give the action cluster the full hero width with leading
            // content (instead of `HStack { actions(); Spacer() }`) so the
            // selector row inside can stretch its own focus section full-width
            // for Down navigation — a trailing Spacer would split the width
            // with that greedy child and leave the section too narrow.
            // Still a full-width focus destination so lower rails can move
            // "up" into this cluster even from a far-right card.
            actions()
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
        .padding(.top, heroTopInset)
        .padding(.horizontal, TVDetailLayout.horizontalInset)
        .frame(
            maxWidth: .infinity,
            maxHeight: heroHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var reservedEditorialColumn: some View {
        if let editorialReservedHeight {
            ZStack(alignment: .topLeading) {
                editorialPrimaryInformationColumn
                    .frame(
                        height: max(
                            0,
                            editorialReservedHeight
                                - fixedDisclosureReservedHeight
                                - fixedDisclosureSpacing
                        ),
                        alignment: .topLeading
                    )
                    .clipped()

                // The episode credit and playback readout are one bottom-locked
                // disclosure block. Different synopsis lengths can no longer
                // move Starring, Version, Audio, Subtitles, or the action row.
                fixedDisclosureColumn
                    .frame(
                        width: editorialContentWidth,
                        height: editorialReservedHeight,
                        alignment: .bottomLeading
                    )
            }
            .frame(
                width: editorialContentWidth,
                height: editorialReservedHeight,
                alignment: .topLeading
            )
            .clipped()
        } else {
            editorialColumn
        }
    }

    private var editorialColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            editorialPrimaryInformationColumn
            creditBlock
            TVPlaybackSelectionSummaryView(summary: playbackSummary)
        }
        .frame(maxWidth: editorialContentWidth, alignment: .leading)
    }

    private var editorialPrimaryInformationColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow, !eyebrow.isEmpty {
                TVHeroEyebrow(text: eyebrow)
            }
            titleBlock
                .frame(height: 160, alignment: .bottomLeading)
                .padding(.top, eyebrow == nil ? 0 : 2)
            reservedMetadataBlock
            synopsisBlock
            belowSynopsis()
        }
        .frame(maxWidth: editorialContentWidth, alignment: .leading)
    }

    private var fixedDisclosureColumn: some View {
        VStack(alignment: .leading, spacing: creditSummarySpacing) {
            creditBlock
            TVPlaybackSelectionSummaryView(summary: playbackSummary)
                .frame(
                    height: playbackSummaryReservedHeight,
                    alignment: .topLeading
                )
        }
        // Episode focus can replace all four strings in one model update. This
        // block is intentionally static: values change in place without an
        // inherited layout animation that makes the rows appear to bounce.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var playbackSummaryReservedHeight: CGFloat { 40 }
    private var creditSummarySpacing: CGFloat { TVDetailLayout.disclosureSpacing }
    private var fixedDisclosureReservedHeight: CGFloat {
        creditReservedHeight + creditSummarySpacing + playbackSummaryReservedHeight
    }
    private var fixedDisclosureSpacing: CGFloat { 4 }

    @ViewBuilder
    private var reservedMetadataBlock: some View {
        if metadataReservedHeight > 0 {
            metadataBlock
                .frame(height: metadataReservedHeight, alignment: .leading)
                .clipped()
        } else {
            metadataBlock
        }
    }

    @ViewBuilder
    private var synopsisBlock: some View {
        if synopsisReservedHeight > 0 {
            Group {
                if let overview, !overview.isEmpty {
                    TVExpandableSynopsis(overview: overview)
                }
            }
            .frame(height: synopsisReservedHeight, alignment: .topLeading)
            .clipped()
        } else if let overview, !overview.isEmpty {
            TVExpandableSynopsis(overview: overview)
        }
    }

    @ViewBuilder
    private var creditBlock: some View {
        if creditReservedHeight > 0 {
            Group {
                if let starringText, !starringText.isEmpty {
                    heroCredit(starringText)
                }
            }
            .frame(height: creditReservedHeight, alignment: .leading)
            .clipped()
        } else if let starringText, !starringText.isEmpty {
            heroCredit(starringText)
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let episodeSeriesTitle {
            TVEpisodeHierarchyTitle(
                seriesTitle: episodeSeriesTitle,
                episodeTitle: title,
                logoUrl: logoUrl
            )
        } else {
            TVDecodedLogoTitle(
                logoUrl: logoUrl,
                accessibilityLabel: title,
                maxWidth: 650,
                maxHeight: 160
            ) {
                if usesFixedPageArtwork {
                    Text(title).font(.system(size: 78, weight: .bold)).lineLimit(2)
                } else {
                    TVHeroTitle(title: title)
                }
            }
        }
    }

    private var episodeSeriesTitle: String? {
        guard let trimmed = seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - Metadata

    @ViewBuilder
    private var metadataBlock: some View {
        if episodeSeriesTitle != nil {
            sourceRow
            factsRow(includeSourceTokens: false)
        } else {
            factsRow(includeSourceTokens: true)
        }
    }

    @ViewBuilder
    private var sourceRow: some View {
        if !sourceTokens.isEmpty {
            HStack(spacing: 14) {
                ForEach(Array(sourceTokens.enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("·")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                    Text(token)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.78))
                }
            }
        }
    }

    // MARK: - Facts + quality row

    @ViewBuilder
    private func factsRow(includeSourceTokens: Bool) -> some View {
        if !factsLine.isEmpty || (includeSourceTokens && !sourceTokens.isEmpty) || ratingChip != nil {
            HStack(spacing: 14) {
                if let ratingChip, !ratingChip.isEmpty {
                    ratingBadge(ratingChip)
                        .fixedSize(horizontal: true, vertical: false)
                }

                ForEach(Array(factsLine.enumerated()), id: \.offset) { index, token in
                    if index > 0 { metadataDivider }
                    factsItem(token)
                }

                if includeSourceTokens {
                    ForEach(Array(sourceTokens.enumerated()), id: \.offset) { index, token in
                        if !factsLine.isEmpty || index > 0 { metadataDivider }
                        Text(token)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.90))
                    }
                }
            }
        }
    }

    private var metadataDivider: some View {
        Text("·")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.45))
    }

    private func ratingBadge(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.white.opacity(0.78), lineWidth: 1.5)
            )
    }

    @ViewBuilder
    private func factsItem(_ token: TVHeroFactToken) -> some View {
        switch token {
        case .text(let value):
            Text(value)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(Color.white.opacity(0.88))
        case .rating(let value):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.vividSuccess.opacity(0.9))
                Text(value)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.88))
            }
        case .chip(let value):
            Text(value)
                .font(.system(size: 16, weight: .heavy))
                .tracking(1.0)
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.65), lineWidth: 1.2)
                )
        }
    }

    private func heroCredit(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 23, weight: .regular))
            .foregroundColor(Color.white.opacity(0.70))
            .lineLimit(1)
    }
}

// MARK: - Title treatment

/// Heavy condensed display title. Splits on ": " into title + subtitle
/// when the source title contains a colon — e.g. "Monarch: Legacy of
/// Monsters" becomes a two-line composition with a larger lead and a
/// smaller, still-heavy underline, matching the Apple TV wordmark
/// treatment.
private struct TVHeroTitle: View {
    let title: String

    var body: some View {
        let parts = split(title)
        VStack(alignment: .leading, spacing: 4) {
            Text(parts.primary.uppercased())
                .font(primaryFont)
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .font(subtitleFont)
                    .foregroundColor(Color.white.opacity(0.95))
                    .tracking(1.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var primaryFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 92, weight: .black).width(.compressed)
        }
        return .system(size: 88, weight: .black)
    }

    private var subtitleFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 40, weight: .heavy).width(.compressed)
        }
        return .system(size: 38, weight: .heavy)
    }

    private func split(_ raw: String) -> (primary: String, subtitle: String?) {
        let separators: [String] = [": ", " — ", " – ", " - "]
        for sep in separators {
            if let range = raw.range(of: sep) {
                let head = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let tail = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, !tail.isEmpty {
                    return (head, tail)
                }
            }
        }
        return (raw, nil)
    }
}

/// Keeps the text identity on screen until server logo artwork has actually
/// decoded. A prefetched logo is seeded synchronously so warm detail entry does
/// not paint one intermediate frame of text before showing the finished art.
struct TVDecodedLogoTitle<Fallback: View>: View {
    let logoUrl: String?
    let accessibilityLabel: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        logoUrl: String?,
        accessibilityLabel: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        @ViewBuilder fallback: @escaping () -> Fallback
    ) {
        self.logoUrl = logoUrl
        self.accessibilityLabel = accessibilityLabel
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.fallback = fallback
    }

    @ViewBuilder
    var body: some View {
        Group {
            if let normalizedLogoURL {
                let request = VividImageRequest(url: normalizedLogoURL)
                let cachedImage = VividImagePipeline.shared.cache[request]?.image
                VividLazyImage(
                    request: request,
                    transaction: Transaction(
                        animation: reduceMotion || cachedImage != nil
                            ? nil
                            : .easeInOut(duration: 0.2)
                    )
                ) { state in
                    if let image = state.image {
                        renderedLogo(image)
                            .transition(reduceMotion ? .identity : .opacity)
                    } else if let cachedImage {
                        renderedLogo(Image(platformImage: cachedImage))
                    } else {
                        fallback()
                    }
                }
            } else {
                fallback()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var normalizedLogoURL: URL? {
        guard let normalized = logoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return URL(string: normalized)
    }

    private func renderedLogo(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                alignment: .bottomLeading
            )
            .accessibilityHidden(true)
    }
}

private struct TVEpisodeHierarchyTitle: View {
    let seriesTitle: String
    let episodeTitle: String
    let logoUrl: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TVDecodedLogoTitle(
                logoUrl: logoUrl,
                accessibilityLabel: seriesTitle,
                maxWidth: 650,
                maxHeight: 140
            ) {
                Text(seriesTitle.uppercased())
                    .font(seriesFont)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(episodeTitle)
                .font(episodeFont)
                .foregroundColor(Color.white.opacity(0.94))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var seriesFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 92, weight: .black).width(.compressed)
        }
        return .system(size: 88, weight: .black)
    }

    private var episodeFont: Font {
        if #available(tvOS 16.0, *) {
            return .system(size: 46, weight: .bold)
        }
        return .system(size: 44, weight: .bold)
    }
}

// MARK: - Eyebrow pill

private struct TVHeroEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
    }
}

// MARK: - Tokens

/// A token in the combined facts row. `.text` items get pipe separators
/// between them; `.rating` renders a green check + maturity label;
/// `.chip` renders an outlined pill (e.g. 4K / HDR / ATMOS).
enum TVHeroFactToken: Hashable {
    case text(String)
    case rating(String)
    case chip(String)
}

// MARK: - Metadata builders

enum TVHeroMetadata {
    // Source row (type · genres)

    static func movieSourceTokens(from detail: ItemDetail) -> [String] {
        if detail.type == "episode" {
            if let label = episodeNumberLabel(from: detail) {
                return [label]
            }
            return []
        }
        if let genres = detail.genres, !genres.isEmpty {
            return [genres.prefix(2).joined(separator: ", ")]
        }
        return []
    }

    /// "Season 3 · Episode 8" (or "Specials · Episode 5" / "Episode 5")
    /// for an episode `ItemDetail`.
    private static func episodeNumberLabel(from detail: ItemDetail) -> String? {
        let seasonPart: String?
        if let season = detail.seasonNumber {
            seasonPart = season == 0 ? "Specials" : "Season \(season)"
        } else {
            seasonPart = nil
        }
        let episodePart = detail.episodeNumber.flatMap { n in n > 0 ? "Episode \(n)" : nil }

        switch (seasonPart, episodePart) {
        case let (.some(s), .some(e)): return "\(s) \u{00B7} \(e)"
        case let (.some(s), .none):    return s
        case let (.none, .some(e)):    return e
        case (.none, .none):           return nil
        }
    }

    static func seriesSourceTokens(from detail: ItemDetail) -> [String] {
        if let genres = detail.genres, !genres.isEmpty {
            return [genres.prefix(2).joined(separator: ", ")]
        }
        return []
    }

    static func contentRatingChip(from detail: ItemDetail) -> String? {
        guard let rating = detail.contentRating?
            .trimmingCharacters(in: .whitespaces), !rating.isEmpty
        else { return nil }
        return rating
    }

    // Facts line (year · runtime · maturity · quality chips)

    static func movieFactsLine(from detail: ItemDetail, version selectedVersion: FileVersion? = nil) -> [TVHeroFactToken] {
        var tokens: [TVHeroFactToken] = []
        if detail.type == "episode",
           let airDate = DetailDateFormatting.abbreviatedDate(detail.airDate) {
            tokens.append(.text(airDate))
        } else if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let runtime = detail.runtime, runtime > 0 {
            tokens.append(.text(formatRuntime(runtime)))
        }
        return tokens
    }

    static func seriesFactsLine(from detail: ItemDetail) -> [TVHeroFactToken] {
        var tokens: [TVHeroFactToken] = []
        if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let count = detail.seasonCount, count > 0 {
            tokens.append(.text("\(count) Season\(count == 1 ? "" : "s")"))
        }
        return tokens
    }

    // Eyebrow (short editorial line)

    static func eyebrow(from detail: ItemDetail) -> String? {
        if detail.type == "episode" {
            if let seriesTitle = detail.seriesTitle?.trimmingCharacters(in: .whitespaces),
               !seriesTitle.isEmpty {
                return seriesTitle
            }
        }
        if let status = detail.status?.trimmingCharacters(in: .whitespaces),
           !status.isEmpty,
           detail.type == "series" {
            switch status.lowercased() {
            case "continuing", "returning series", "returning":
                return "Continuing Series"
            case "ended":
                return "Complete Series"
            case "in production":
                return "New Season Coming"
            default: break
            }
        }
        return nil
    }

    // Starring (first 3 cast names)

    static func starringText(from detail: ItemDetail) -> String? {
        if detail.type == "movie" {
            let directors = detail.crew?
                .filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
                .map(\.name) ?? []
            guard !directors.isEmpty else { return nil }
            return "Directed by " + directors.prefix(2).joined(separator: ", ")
        }
        guard let cast = detail.cast, !cast.isEmpty else { return nil }
        let names = cast.prefix(3).map(\.name)
        guard !names.isEmpty else { return nil }
        return "Starring " + names.joined(separator: ", ")
    }

    // MARK: - Helpers

    private static func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }
}

/// Equal-width playback readouts with stable icons while metadata loads.
struct TVPlaybackSelectionSummaryView: View {
    let summary: TVPlaybackSelectionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            summaryItem(
                label: "Version",
                symbol: "square.stack",
                value: summary.version,
                placeholderWidth: 84
            )
            summaryItem(
                label: "Audio",
                symbol: "speaker.wave.2",
                value: summary.audio,
                placeholderWidth: 84
            )
            summaryItem(
                label: "Subtitles",
                symbol: "captions.bubble",
                value: summary.subtitles,
                placeholderWidth: 77
            )
        }
        .frame(width: 616, height: 40, alignment: .leading)
    }

    private func summaryItem(
        label: String,
        symbol: String,
        value: String?,
        placeholderWidth: CGFloat
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Group {
                if let value {
                    Text(value)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        .frame(width: placeholderWidth, height: 18)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 40, alignment: .leading)
        .background(Color.white.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.4), .white.opacity(0.12), .white.opacity(0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized), \(value ?? "loading")")
    }
}

// Apple's fold-snapping implementation from Creating a tvOS media catalog app in SwiftUI.
/*
Copyright © 2024 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/
struct FoldSnappingScrollTargetBehavior: ScrollTargetBehavior {
    var aboveFold: Bool
    var showcaseHeight: CGFloat

    /// This takes a `ScrollTarget` that contains the proposed end point of
    /// the current scroll event.  In tvOS, this is the target of a scroll
    /// that the focus engine triggers when attempting to bring a newly focused
    /// item into view.
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Keep Vivid's header controls aligned with its fixed logo while
        // native focus moves within the hero. Lower shelves retain fold snapping.
        if aboveFold && target.rect.minY < showcaseHeight * 0.3 {
            target.rect.origin.y = 0
            return
        }

        // If the header isn't visible and the target isn't high enough to
        // reveal any of the header, the scroll can land anywhere the system
        // determines within this area.
        if !aboveFold && target.rect.minY > showcaseHeight {
            // The target isn't far enough up to reveal the showcase.
            return
        }

        // The view needs to snap upward to reveal the header only if the
        // target is more than 30% of the way up from the bottom edge of the
        // showcase.
        let showcaseRevealThreshold = showcaseHeight * 0.7

        // If the target of the scroll is anywhere between the header's bottom
        // edge and that threshold, the view needs to snap to hide the header.
        let snapToHideRange = showcaseRevealThreshold...showcaseHeight

        if aboveFold || snapToHideRange.contains(target.rect.origin.y) {
            // The view is either above the fold and scrolling more than 30% of
            // the way down, or it's below the fold and isn't moving up far
            // enough to reveal the showcase.

            // This case likely triggers every time you move focus among the
            // items on the top content shelf, as the focus system brings them a
            // little farther onto the screen.  It's very likely that this code
            // is setting the target origin to it's current position here,
            // effectively denying any scrolling at all.
            target.rect.origin.y = showcaseHeight
        }
        else {
            // The view is below the fold and it's moving up beyond the bottom
            // 30% of the header view.  Snap to the view's origin to reveal the
            // entire header.
            target.rect.origin.y = 0
        }
    }
}


private struct TVDetailCurvedBlurMask: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -rect.width * 0.1, y: rect.height * 0.48))
        path.addCurve(to: CGPoint(x: rect.width * 1.1, y: rect.height * 0.48),
                      control1: CGPoint(x: rect.width * 0.28, y: rect.height * 1.02),
                      control2: CGPoint(x: rect.width * 0.72, y: rect.height * 1.02))
        path.addLine(to: CGPoint(x: rect.width * 1.1, y: rect.height * 1.2))
        path.addLine(to: CGPoint(x: -rect.width * 0.1, y: rect.height * 1.2))
        path.closeSubpath()
        return path
    }
}

/// Vivid supplies artwork and existing controls to Apple's fixed-background,
/// gradient-mask and fold-snapping presentation.
struct TVAppleDetailPage<Hero: View, Shelves: View>: View {
    let backdropURL: String?
    let logoURL: String?
    let title: String
    @ViewBuilder let hero: (CGFloat) -> Hero
    @ViewBuilder let shelves: () -> Shelves
    @State private var belowFold = false
    @State private var showsShelfLogo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let showcaseHeight = max(800, geometry.size.height - 100)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 26) {
                    hero(showcaseHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                        .onScrollVisibilityChange { visible in
                            withAnimation(reduceMotion ? nil : .default) { belowFold = !visible }
                        }
                    shelves()
                        .padding(.top, 150)
                        .padding(.horizontal, TVDetailLayout.horizontalInset)
                        .padding(.bottom, TVDetailLayout.pageBottomPadding)
                }
                .scrollTargetLayout()
            }
            .background {
                ZStack {
                    Color.black
                    if let backdropURL {
                        CachedAsyncImage(url: backdropURL, targetSize: geometry.size, contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    Rectangle().fill(.regularMaterial)
                        .mask {
                            ZStack {
                                TVDetailCurvedBlurMask()
                                    .fill(.black)
                                    .blur(radius: geometry.size.height * 0.065)
                                    .opacity(belowFold ? 0 : 1)
                                Rectangle()
                                    .fill(.black)
                                    .opacity(belowFold ? 1 : 0)
                            }
                        }
                }
            }
            .scrollTargetBehavior(FoldSnappingScrollTargetBehavior(
                aboveFold: !belowFold, showcaseHeight: showcaseHeight))
            .scrollClipDisabled()
            .onScrollGeometryChange(for: Bool.self) { scroll in
                scroll.visibleRect.minY >= max(116, showcaseHeight - 580) + 160
            } action: { _, visible in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: visible ? 0.25 : 0.12)) {
                    showsShelfLogo = visible
                }
            }
            .overlay(alignment: .topLeading) {
                TVDecodedLogoTitle(logoUrl: logoURL, accessibilityLabel: title,
                                   maxWidth: 480, maxHeight: 110) {
                    Text(title).font(.system(size: 54, weight: .bold)).lineLimit(2)
                }
                .frame(width: 480, height: 110, alignment: .bottomLeading)
                .position(x: geometry.size.width / 2, y: 85)
                .opacity(showsShelfLogo ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }
}

#endif
