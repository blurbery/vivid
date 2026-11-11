#if os(tvOS)
import SwiftUI

/// The series page's season pills over one continuous row of every loaded
/// season's episodes.
///
/// Coming down from the hero, the shelf opens on the Play target's season
/// and episode. After that, the browsed season follows the pills and the
/// focused episode, and the pill highlight follows the scroll position.
struct TVSeriesEpisodeShelf: View {
    let seasons: [Season]
    /// Loaded episode pages by season number, spoilers already covered.
    let pages: [Int: [EpisodeListItem]]
    let selectedSeason: Season?
    /// The episode Play targets, marked as current.
    let currentEpisodeId: String?
    /// Where focus lands when it comes down from the hero.
    let playTarget: EpisodeListItem?
    let isActionRowFocused: Bool
    let favoriteStates: [String: Bool]
    let onSelectSeason: (Season) -> Void
    let onEpisodeFocus: (String) -> Void
    let onPlayEpisode: (String) -> Void
    let onSetWatched: (String, Bool) async -> Bool
    let onSetFavorite: (String, Bool) async -> Bool

    private static let slotWidth: CGFloat = 440
    private static let cardCentre: CGFloat = 200

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedPillId: String?
    @FocusState private var focusedEpisodeId: String?
    @Namespace private var pillScope

    @State private var browseSeasonId: String?
    @State private var scrollSeasonId: String?
    @State private var isEnteringFromHero = true
    @State private var pendingSeasonJump: Int?
    @State private var pendingEpisodeJump: String?
    @State private var isSeeded = false
    @State private var dwellTask: Task<Void, Never>?

    private var referenceSeasonId: String? { browseSeasonId ?? selectedSeason?.contentId }

    private var shownSeasonId: String? {
        focusedPillId ?? scrollSeasonId ?? browseSeasonId ?? selectedSeason?.contentId
    }

    private var targetSeason: Season? {
        guard let playTarget else { return nil }
        return seasons.first { $0.seasonNumber == playTarget.seasonNumber }
    }

    private var shownEpisodeIds: [String] {
        seasons.flatMap { pages[$0.seasonNumber]?.map(\.contentId) ?? [] }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 24) {
                pills(proxy)
                episodeRow(proxy)
            }
            .onPlayPauseCommand {
                guard let id = focusedEpisodeId, episode(id) != nil else { return }
                onPlayEpisode(id)
            }
            .onChange(of: playTarget?.contentId, initial: true) { _, _ in
                prepareEntry(proxy)
            }
            .onChange(of: isActionRowFocused) { _, focused in
                guard focused else { return }
                isEnteringFromHero = true
                prepareEntry(proxy)
            }
            .onChange(of: seasons.map(\.contentId)) { _, _ in
                prepareEntry(proxy)
            }
            .onChange(of: shownEpisodeIds, initial: true) { _, _ in
                episodesChanged(proxy)
            }
            .onChange(of: focusedPillId) { oldValue, newValue in
                pillFocusChanged(from: oldValue, to: newValue, proxy: proxy)
            }
            .onChange(of: focusedEpisodeId) { oldValue, newValue in
                episodeFocusChanged(from: oldValue, to: newValue)
            }
        }
    }

    // MARK: Pills

    private func pills(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(pillEntries, id: \.season.contentId) { entry in
                    let season = entry.season
                    let isShown = entry.range == nil && season.contentId == shownSeasonId
                    Button {
                        selectPill(season, proxy: proxy)
                    } label: {
                        TVSeasonPillLabel(
                            title: entry.range ?? Self.pillTitle(season),
                            shortTitle: entry.range ?? Self.pillShortTitle(season),
                            isExpanded: isShown,
                            isRange: entry.range != nil
                        )
                    }
                    .buttonStyle(TVSeasonPillStyle(isHighlighted: isShown))
                    .accessibilityLabel(Text(verbatim: entry.range ?? Self.pillTitle(season)))
                    .focused($focusedPillId, equals: season.contentId)
                    .modifier(SeasonWatchedContextMenu(season: season, isEnabled: entry.range == nil))
                }
            }
            .padding(4)
            .vividGlass(in: Capsule(), tint: .black.opacity(0.26))
            // Opening another section swaps the pills in one step, with no
            // animation. Animated, the old section's pills were removed only
            // when it ended, and that took focus off the pill just landed
            // on, sending it back to Specials or down to the episodes.
        }
        .scrollClipDisabled()
        .focusSection()
        .focusScope(pillScope)
        .defaultFocus(
            $focusedPillId,
            referenceSeasonId,
            priority: focusedPillId == nil ? .userInitiated : .automatic
        )
    }

    /// One button in the season pill: a season, or a closed range standing
    /// in for its seasons ("S13 - S29"). A range uses the identity of the
    /// season beside the open section, so focusing it opens that season's
    /// section with focus on it.
    private struct PillEntry {
        let season: Season
        let range: String?
    }

    /// Specials on their own, then the numbered seasons in sections of six
    /// once there are more than six. A lone season left at the end joins
    /// the section before it.
    private var pillSections: [[Season]] {
        let specials = seasons.filter { $0.seasonNumber == 0 }
        let numbered = seasons.filter { $0.seasonNumber != 0 }
        var sections: [[Season]] = specials.isEmpty ? [] : [specials]
        guard numbered.count > Self.seasonsPerSection else {
            if !numbered.isEmpty { sections.append(numbered) }
            return sections
        }
        var chunks = stride(from: 0, to: numbered.count, by: Self.seasonsPerSection).map {
            Array(numbered[$0..<min($0 + Self.seasonsPerSection, numbered.count)])
        }
        if chunks.count > 1, let last = chunks.last, last.count == 1 {
            chunks.removeLast()
            chunks[chunks.count - 1].append(contentsOf: last)
        }
        sections.append(contentsOf: chunks)
        return sections
    }

    private static let seasonsPerSection = 6

    /// The numbered section shown open: the one holding the shown season,
    /// else the one the page is on, else the first.
    private var openSectionIndex: Int? {
        let sections = pillSections
        let numbered = sections.indices.filter { sections[$0].first?.seasonNumber != 0 }
        let candidates = [shownSeasonId, referenceSeasonId, selectedSeason?.contentId]
        for id in candidates {
            guard let id else { continue }
            if let index = numbered.first(where: { sections[$0].contains { $0.contentId == id } }) {
                return index
            }
        }
        return numbered.first
    }

    /// The open section's seasons, with everything before it as one range
    /// and everything after it as another, so a long series never shows
    /// more than a few closed groups. Each range takes the identity of the
    /// season next to the open section (the previous section's last season,
    /// or the next section's first), so moving onto it opens that section
    /// on the neighbouring season and left and right step through every
    /// season in order.
    private var pillEntries: [PillEntry] {
        let sections = pillSections
        let specials = sections.filter { $0.first?.seasonNumber == 0 }.flatMap { $0 }
        let numbered = sections.filter { $0.first?.seasonNumber != 0 }
        var entries = specials.map { PillEntry(season: $0, range: nil) }
        guard numbered.count > 1, let openIndex = openSectionIndex,
              let open = numbered.firstIndex(where: { $0.first?.contentId == sections[openIndex].first?.contentId }) else {
            entries += numbered.flatMap { $0 }.map { PillEntry(season: $0, range: nil) }
            return entries
        }
        if open > 0, let first = numbered[0].first, let adjacent = numbered[open - 1].last {
            entries.append(PillEntry(season: adjacent, range: Self.rangeTitle(first, adjacent)))
        }
        entries += numbered[open].map { PillEntry(season: $0, range: nil) }
        if open < numbered.count - 1, let adjacent = numbered[open + 1].first,
           let last = numbered[numbered.count - 1].last {
            entries.append(PillEntry(season: adjacent, range: Self.rangeTitle(adjacent, last)))
        }
        return entries
    }

    private static func rangeTitle(_ first: Season, _ last: Season) -> String {
        String(
            localized: "S\(String(first.seasonNumber)) - S\(String(last.seasonNumber))",
            comment: "A closed group of seasons on the season pill, from its first to its last season"
        )
    }

    /// The collapsed pill's label: the season number, or "SP" for specials.
    static func pillShortTitle(_ season: Season) -> String {
        season.seasonNumber == 0
            ? String(localized: "SP", comment: "Short label for the Specials season on a collapsed season pill")
            : String(season.seasonNumber)
    }

    /// "Specials" or "Season N"; a season's own title isn't used here.
    static func pillTitle(_ season: Season) -> String {
        season.seasonNumber == 0
            ? String(localized: "Specials")
            : String(localized: "Season \(String(season.seasonNumber))")
    }

    // MARK: Episode row

    private func episodeRow(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 40) {
                ForEach(seasons, id: \.contentId) { season in
                    if let page = pages[season.seasonNumber] {
                        ForEach(page, id: \.contentId) { episode in
                            TVSeriesShelfCard(
                                episode: episode,
                                isCurrent: episode.contentId == currentEpisodeId,
                                isFavorite: favoriteStates[episode.contentId] ?? false,
                                focus: $focusedEpisodeId,
                                onPlay: { onPlayEpisode(episode.contentId) },
                                onSetWatched: { await onSetWatched(episode.contentId, $0) },
                                onSetFavorite: { await onSetFavorite(episode.contentId, $0) }
                            )
                            .id(episode.contentId)
                        }
                    } else {
                        Button {
                            pendingSeasonJump = season.seasonNumber
                            onSelectSeason(season)
                        } label: {
                            Text("Load Season \(String(season.seasonNumber))")
                        }
                        .frame(width: 400, height: 225)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .focusSection()
        // Acts only when the season in view changes to a known one, so
        // scrolling never clears the reported season.
        .onScrollGeometryChange(for: String?.self) { geometry in
            seasonInView(geometry.visibleRect)
        } action: { _, seasonId in
            guard let seasonId, !isActionRowFocused, !isEnteringFromHero, focusedPillId == nil else { return }
            scrollSeasonId = seasonId
        }
    }

    private func episode(_ id: String) -> EpisodeListItem? {
        for season in seasons {
            if let match = pages[season.seasonNumber]?.first(where: { $0.contentId == id }) { return match }
        }
        return nil
    }

    // MARK: Entry from the hero

    private func prepareEntry(_ proxy: ScrollViewProxy) {
        guard isEnteringFromHero, let playTarget, let season = targetSeason else { return }
        scrollSeasonId = nil
        browseSeasonId = season.contentId
        pendingSeasonJump = season.seasonNumber
        pendingEpisodeJump = playTarget.contentId
        if selectedSeason?.contentId != season.contentId {
            onSelectSeason(season)
        }
        jumpWhenReady(proxy)
    }

    private func episodesChanged(_ proxy: ScrollViewProxy) {
        if isEnteringFromHero, playTarget != nil {
            prepareEntry(proxy)
            return
        }
        if !isSeeded, pendingSeasonJump == nil, let selectedSeason, let page = pages[selectedSeason.seasonNumber] {
            isSeeded = true
            if let target = currentEpisodeId ?? page.first?.contentId {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(target, anchor: .leading)
                }
            }
        }
        jumpWhenReady(proxy)
    }

    /// Scrolls to a pending season (and episode) once its page is loaded.
    private func jumpWhenReady(_ proxy: ScrollViewProxy) {
        guard let seasonNumber = pendingSeasonJump, let page = pages[seasonNumber] else { return }
        let targetId: String
        if let episodeId = pendingEpisodeJump {
            guard page.contains(where: { $0.contentId == episodeId }) else { return }
            targetId = episodeId
        } else {
            guard let first = page.first else { return }
            targetId = first.contentId
        }
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(targetId, anchor: .leading)
        }
        isSeeded = true
        pendingSeasonJump = nil
        pendingEpisodeJump = nil
    }

    // MARK: Pills and dwell

    private func selectPill(_ season: Season, proxy: ScrollViewProxy) {
        isEnteringFromHero = false
        browseSeasonId = season.contentId
        pendingEpisodeJump = nil
        pendingSeasonJump = season.seasonNumber
        if selectedSeason?.contentId != season.contentId {
            onSelectSeason(season)
        }
        jumpWhenReady(proxy)
    }

    private func pillFocusChanged(from oldId: String?, to newId: String?, proxy: ScrollViewProxy) {
        dwellTask?.cancel()
        dwellTask = nil
        guard let newId, let season = seasons.first(where: { $0.contentId == newId }) else { return }

        if oldId == nil, isEnteringFromHero, let target = targetSeason {
            prepareEntry(proxy)
            if newId != target.contentId {
                focusedPillId = target.contentId
                return
            }
        }

        scrollSeasonId = nil
        if newId != referenceSeasonId {
            isEnteringFromHero = false
            pendingSeasonJump = nil
            pendingEpisodeJump = nil
        }

        guard dwellSelects(newId) else { return }
        dwellTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard focusedPillId == newId, dwellSelects(newId) else { return }
            selectPill(season, proxy: proxy)
        }
    }

    private func dwellSelects(_ seasonId: String) -> Bool {
        guard seasonId != referenceSeasonId else { return false }
        return !isEnteringFromHero || seasonId == targetSeason?.contentId
    }

    // MARK: Episode focus and scroll season

    private func episodeFocusChanged(from oldId: String?, to newId: String?) {
        guard let newId else { return }
        if oldId == nil, isEnteringFromHero, let playTarget,
           pages[playTarget.seasonNumber]?.contains(where: { $0.contentId == playTarget.contentId }) == true,
           newId != playTarget.contentId {
            focusedEpisodeId = playTarget.contentId
            return
        }
        guard let season = seasons.first(where: { season in
            pages[season.seasonNumber]?.contains(where: { $0.contentId == newId }) == true
        }) else { return }
        isEnteringFromHero = false
        pendingSeasonJump = nil
        pendingEpisodeJump = nil
        scrollSeasonId = nil
        browseSeasonId = season.contentId
        if selectedSeason?.contentId != season.contentId {
            onSelectSeason(season)
        }
        onEpisodeFocus(newId)
    }

    /// Works out which season is in view from the fixed slot geometry, so
    /// the pill highlight can follow the scroll without moving focus.
    private func seasonInView(_ visible: CGRect) -> String? {
        var slot = 0
        var firstSlots: [(season: Season, start: CGFloat)] = []
        var focusedCentre: (season: Season, centre: CGFloat)?
        for season in seasons {
            let page = pages[season.seasonNumber]
            let count: Int
            if let page {
                guard !page.isEmpty else { continue }
                count = page.count
                if let focusedEpisodeId, let index = page.firstIndex(where: { $0.contentId == focusedEpisodeId }) {
                    focusedCentre = (season, CGFloat(slot + index) * Self.slotWidth + Self.cardCentre)
                }
            } else {
                count = 1
            }
            firstSlots.append((season, CGFloat(slot) * Self.slotWidth))
            slot += count
        }

        if let focusedCentre, focusedCentre.centre >= visible.minX, focusedCentre.centre <= visible.maxX {
            return focusedCentre.season.contentId
        }
        let leadingCentre = max(0, visible.minX) + Self.cardCentre
        return firstSlots.last(where: { $0.start <= leadingCentre })?.season.contentId
    }
}

/// A season pill's text: the full name while it's the season shown, and
/// just its number in a circle otherwise.
private struct TVSeasonPillLabel: View {
    let title: String
    let shortTitle: String
    let isExpanded: Bool
    /// A closed group of seasons: padded like an expanded pill and a
    /// little dimmer, so it reads as a group rather than a season.
    var isRange = false

    static let height: CGFloat = 48

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(verbatim: isExpanded ? title : shortTitle)
            .font(.system(size: 22, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.opacity)
            .opacity(isRange ? 0.72 : 1)
            .padding(.horizontal, isExpanded || isRange ? 20 : 0)
            .frame(minWidth: Self.height, minHeight: Self.height)
            .animation(reduceMotion ? nil : TVDetailActionRowLayout.resize, value: isExpanded)
    }
}

/// A button inside the season pill, which carries the tinted glass of the
/// action row. The season shown stays highlighted, and the focused button
/// takes the bright rim.
private struct TVSeasonPillStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVSeasonPillBody(configuration: configuration, isHighlighted: isHighlighted)
    }
}

private struct TVSeasonPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isHighlighted: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .foregroundStyle(Color.white)
            .background(Capsule().fill(Color.white.opacity(isHighlighted ? 0.18 : 0)))
            .overlay {
                Capsule()
                    .strokeBorder(LinearGradient.vividPrimaryRim, lineWidth: 2.5)
                    .opacity(isFocused ? 1 : 0)
            }
            .shadow(
                color: .black.opacity(isFocused ? 0.34 : 0),
                radius: isFocused ? 12 : 0,
                y: isFocused ? 4 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .focusEffectDisabled()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHighlighted)
    }
}

/// One episode on the series shelf: a fixed 400 by 225 still with its
/// status, and the episode's number, title, overview and air date below.
private struct TVSeriesShelfCard: View {
    let episode: EpisodeListItem
    /// Spoken by VoiceOver; the shelf draws no current-episode outline.
    let isCurrent: Bool
    let isFavorite: Bool
    var focus: FocusState<String?>.Binding
    let onPlay: () -> Void
    let onSetWatched: (Bool) async -> Bool
    let onSetFavorite: (Bool) async -> Bool

    private static let stillSize = CGSize(width: 400, height: 225)

    @State private var watchedOverride: Bool?
    @State private var favoriteOverride: Bool?

    private var isWatched: Bool { watchedOverride ?? episode.userData?.played ?? false }
    private var isFavoriteShown: Bool { favoriteOverride ?? isFavorite }

    private var resumeProgress: (fraction: Double, duration: Double)? {
        guard watchedOverride == nil,
              let duration = episode.userData?.durationSeconds, duration > 0,
              let position = episode.userData?.positionSeconds, position > 0, position < duration else { return nil }
        return (position / duration, duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onPlay) {
                still
            }
            .buttonStyle(.card)
            .focused(focus, equals: episode.contentId)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityLabel))
            .modifier(TVEpisodeCardMenu(
                isEnabled: true,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber,
                isWatched: isWatched,
                isFavorite: isFavoriteShown,
                onPlay: onPlay,
                onToggleWatched: toggleWatched,
                onToggleFavorite: toggleFavorite
            ))

            caption
                .accessibilityHidden(true)
                .frame(width: Self.stillSize.width, alignment: .leading)
        }
        .onChange(of: episode.userData?.played) { _, played in
            if let played, played == watchedOverride { watchedOverride = nil }
        }
        .onChange(of: isFavorite) { _, favorite in
            if favorite == favoriteOverride { favoriteOverride = nil }
        }
    }

    private var still: some View {
        let hidesSpoilers = episode.hidesSpoilers
        let progress = resumeProgress
        return CachedAsyncImage(
            url: episode.stillUrl ?? "",
            targetSize: hidesSpoilers ? EpisodeSpoilerPolicy.coveredStillDecodeSize : Self.stillSize,
            contentMode: .fill,
            softening: hidesSpoilers ? EpisodeSpoilerPolicy.coveredStillSoftening : nil
        )
        .frame(width: Self.stillSize.width, height: Self.stillSize.height)
        .spoilerCovered(hidesSpoilers, symbolSize: 40)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .bottomLeading) {
            statusCapsule
                .padding(12)
                .opacity(progress == nil ? 1 : 0)
        }
        .overlay(alignment: .bottomLeading) {
            if let progress {
                HStack(spacing: 12) {
                    statusCapsule
                    ResumeProgressBar(value: progress.fraction, duration: progress.duration, height: 8, inset: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(width: Self.stillSize.width, height: Self.stillSize.height, alignment: .bottom)
                .allowsHitTesting(false)
            }
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
            }
            if let runtime = episode.runtime, runtime > 0 {
                Text("\(runtime)m")
            }
        }
        .font(.system(size: 18))
        .foregroundStyle(.white)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EPISODE \(String(episode.episodeNumber))")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            titleText
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
            Text(verbatim: episode.overview ?? "")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 52, alignment: .top)
            Text(verbatim: DetailDateFormatting.abbreviatedDate(episode.airDate) ?? "")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }

    private var titleText: Text {
        // A missing or empty title falls back to the episode number.
        if let title = episode.title, !title.isEmpty {
            return Text(verbatim: title)
        }
        return Text("Episode \(String(episode.episodeNumber))")
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let aired = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(aired)
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append(TVHeroMetadata.shortRuntime(runtime))
        }
        return episodeRailAccessibilityLabel(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title,
            metadata: parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  "),
            isCurrent: isCurrent,
            isPlayed: isWatched
        )
    }

    private func toggleWatched() {
        let played = !isWatched
        watchedOverride = played
        Task {
            let succeeded = await onSetWatched(played)
            if !succeeded { watchedOverride = nil }
        }
    }

    private func toggleFavorite() {
        let favorite = !isFavoriteShown
        favoriteOverride = favorite
        Task {
            let succeeded = await onSetFavorite(favorite)
            if !succeeded { favoriteOverride = nil }
        }
    }
}
#endif
