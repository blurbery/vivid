#if os(tvOS)
import SwiftUI

/// The series page's season selector, the shown season's synopsis and
/// poster, and one continuous row of every loaded season's episodes.
///
/// Coming down from the hero, the shelf opens on the Play target's season
/// and episode. After that, the browsed season follows the pills and the
/// focused episode, and the pill highlight follows the scroll position.
struct TVSeriesEpisodeShelf: View {
    let seasons: [Season]
    /// Loaded episode pages by season number, spoilers already covered.
    let pages: [Int: [EpisodeListItem]]
    let selectedSeason: Season?
    /// Stands in for a season that has no poster of its own.
    let seriesPosterUrl: String?
    /// With spoilers hidden, the season the viewer is up to: later seasons
    /// show no synopsis. Nil shows them all.
    let spoilerSeasonNumber: Int?
    /// The episode Play targets, marked as current.
    let currentEpisodeId: String?
    /// Where focus lands when it comes down from the hero.
    let playTarget: EpisodeListItem?
    let isActionRowFocused: Bool
    let favoriteStates: [String: Bool]
    let onSelectSeason: (Season) -> Void
    let onPlayEpisode: (String) -> Void
    let onSetWatched: (String, Bool) async -> Bool
    let onSetFavorite: (String, Bool) async -> Bool

    private static let slotWidth: CGFloat = 440
    private static let cardCentre: CGFloat = 200
    /// Taller than the pills, season name and synopsis need, so the poster
    /// beside them is large and the episode row fills the rest of the
    /// screen, with the next shelf's heading below the bottom edge.
    private static let headerHeight: CGFloat = 310

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var selectorFocused: Bool
    @FocusState private var focusedEpisodeId: String?

    @State private var browseSeasonId: String?
    @State private var scrollSeasonId: String?
    @State private var isEnteringFromHero = true
    @State private var pendingSeasonJump: Int?
    @State private var pendingEpisodeJump: String?
    @State private var isSeeded = false
    @State private var dwellTask: Task<Void, Never>?
    /// The season stepped to on the selector, shown before it loads.
    @State private var stepSeasonId: String?
    @State private var showsWatchedFailure = false
    @Environment(\.seasonWatchedAction) private var setSeasonWatched

    private var shownSeasonId: String? {
        stepSeasonId ?? scrollSeasonId ?? browseSeasonId ?? selectedSeason?.contentId
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
                header(proxy)
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
            .onChange(of: selectorFocused) { _, focused in
                selectorFocusChanged(focused, proxy: proxy)
            }
            .onChange(of: focusedEpisodeId) { oldValue, newValue in
                episodeFocusChanged(from: oldValue, to: newValue)
            }
        }
    }

    // MARK: Season header

    private var shownSeason: Season? {
        seasons.first { $0.contentId == shownSeasonId } ?? selectedSeason
    }

    /// The season selector, fixed at the top, over the shown season's
    /// facts and synopsis, with its poster
    /// on the trailing side. The poster rises into the space beside the
    /// pinned logo without adding height, and never takes focus.
    private func header(_ proxy: ScrollViewProxy) -> some View {
        let season = shownSeason
        return VStack(alignment: .leading, spacing: 10) {
            // The section spans the shelf, so focus reaches the name from
            // any episode below it and from anywhere on the action row.
            selector(proxy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            if let season {
                TVSeasonSummary(
                    season: season,
                    showsSynopsis: spoilerSeasonNumber.map { season.seasonNumber <= $0 } ?? true
                )
            }
        }
        .frame(height: Self.headerHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            TVSeasonPosterCard(season: season, seriesPosterUrl: seriesPosterUrl)
        }
    }

    // MARK: Season selector

    /// Specials first, then the numbered seasons, as Left and Right step
    /// through them.
    private var orderedSeasons: [Season] {
        seasons.filter { $0.seasonNumber == 0 } + seasons.filter { $0.seasonNumber != 0 }
    }

    /// The shown season's name, always in the same place over its synopsis.
    /// It is the one season control: Left and Right step through the
    /// seasons, and Select opens the list of them, which also holds the
    /// shown season's watched action.
    @ViewBuilder
    private func selector(_ proxy: ScrollViewProxy) -> some View {
        if let season = shownSeason {
            let ordered = orderedSeasons
            let index = ordered.firstIndex { $0.contentId == season.contentId }
            Menu {
                ForEach(ordered, id: \.contentId) { entry in
                    Button {
                        jump(to: entry, proxy: proxy)
                    } label: {
                        TVDetailMenuRow.label(
                            TVDetailMenuRow.text(Self.pillTitle(entry), detail: Self.episodeCount(entry)),
                            isSelected: entry.contentId == season.contentId
                        )
                    }
                }
                if let setSeasonWatched {
                    let isPlayed = season.userData?.played == true
                    Divider()
                    Button {
                        let seasonId = season.contentId
                        Task {
                            if await !setSeasonWatched(seasonId, !isPlayed) {
                                showsWatchedFailure = true
                            }
                        }
                    } label: {
                        if isPlayed {
                            Label("Mark Season Unwatched", systemImage: "checkmark.circle")
                        } else {
                            Label("Mark Season Watched", systemImage: "checkmark.circle")
                        }
                    }
                }
            } label: {
                TVSeasonSelectorLabel(
                    title: Self.pillTitle(season),
                    isFocused: selectorFocused,
                    hasPrevious: (index ?? 0) > 0,
                    hasNext: index.map { $0 < ordered.count - 1 } ?? false
                )
            }
            .menuStyle(.button)
            .buttonStyle(TVSeasonSelectorStyle())
            .focusEffectDisabled()
            .accessibilityLabel(Text(verbatim: Self.pillTitle(season)))
            .focused($selectorFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left: step(by: -1, proxy: proxy)
                case .right: step(by: 1, proxy: proxy)
                default: break
                }
            }
            .alert("Couldn’t update season", isPresented: $showsWatchedFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please try again.")
            }
        }
    }

    private static func episodeCount(_ season: Season) -> String? {
        season.episodeCount > 0 ? String(localized: "\(season.episodeCount) Episodes") : nil
    }

    /// Goes straight to a season picked from the list.
    private func jump(to season: Season, proxy: ScrollViewProxy) {
        dwellTask?.cancel()
        dwellTask = nil
        stepSeasonId = nil
        scrollSeasonId = nil
        selectPill(season, proxy: proxy)
    }

    /// Shows the next or previous season straight away, and loads it once
    /// the stepping pauses, so holding a direction doesn't load every
    /// season on the way.
    private func step(by offset: Int, proxy: ScrollViewProxy) {
        let ordered = orderedSeasons
        guard ordered.count > 1, let current = shownSeason,
              let index = ordered.firstIndex(where: { $0.contentId == current.contentId }) else { return }
        let next = index + offset
        guard ordered.indices.contains(next) else { return }
        let id = ordered[next].contentId
        isEnteringFromHero = false
        pendingSeasonJump = nil
        pendingEpisodeJump = nil
        scrollSeasonId = nil
        stepSeasonId = id
        dwellTask?.cancel()
        dwellTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard stepSeasonId == id else { return }
            commitStep(proxy)
        }
    }

    private func commitStep(_ proxy: ScrollViewProxy) {
        dwellTask?.cancel()
        dwellTask = nil
        guard let id = stepSeasonId, let season = seasons.first(where: { $0.contentId == id }) else { return }
        selectPill(season, proxy: proxy)
        stepSeasonId = nil
    }

    private func selectorFocusChanged(_ focused: Bool, proxy: ScrollViewProxy) {
        if focused {
            if isEnteringFromHero { prepareEntry(proxy) }
            scrollSeasonId = nil
        } else {
            commitStep(proxy)
        }
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
            .scrollTargetLayout()
            .padding(.vertical, 20)
        }
        // Focus scrolls the row a card at a time, with a card always at
        // the leading edge. Without this, landing on an episode that has
        // others before it nudges the row to show a strip of the previous
        // one, so the row only stayed put on a season's very first episode.
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .focusSection()
        // Acts only when the season in view changes to a known one, so
        // scrolling never clears the reported season.
        .onScrollGeometryChange(for: String?.self) { geometry in
            seasonInView(geometry.visibleRect)
        } action: { _, seasonId in
            guard let seasonId, !isActionRowFocused, !isEnteringFromHero, !selectorFocused else { return }
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

    // MARK: Selecting a season

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

/// The shown season's own title (when it has one), episode count, year and
/// synopsis. The selector above already names the season.
private struct TVSeasonSummary: View {
    let season: Season
    let showsSynopsis: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var facts: String {
        var parts: [String] = []
        let title = season.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, title != TVSeriesEpisodeShelf.pillTitle(season) {
            parts.append(title)
        }
        if season.episodeCount > 0 {
            parts.append(String(localized: "\(season.episodeCount) Episodes"))
        }
        if let year = season.airDate?.prefix(4), year.count == 4, year.allSatisfy(\.isNumber) {
            parts.append(String(year))
        }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    private var synopsis: String {
        guard showsSynopsis else { return "" }
        return season.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: facts)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: synopsis)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: 1100, alignment: .leading)
        }
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: season.contentId)
        .accessibilityElement(children: .combine)
    }
}

/// The shown season's poster. It turns over to the next season's poster
/// when the season changes, and can't be focused or opened.
private struct TVSeasonPosterCard: View {
    let season: Season?
    let seriesPosterUrl: String?

    static let size = CGSize(width: 360, height: 540)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Season?
    @State private var angle: Double = 0
    @State private var turn: Task<Void, Never>?

    private var seasonPosterUrl: String? {
        let url = shown?.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return url.isEmpty ? nil : url
    }

    var body: some View {
        let url = seasonPosterUrl ?? seriesPosterUrl ?? ""
        CachedAsyncImage(
            url: url,
            targetSize: Self.size,
            thumbhash: seasonPosterUrl == nil ? nil : shown?.posterThumbhash,
            contentMode: .fill
        )
        .id(url)
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .opacity(url.isEmpty ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: season?.contentId, initial: true) { _, _ in
            show(season)
        }
        .onDisappear { turn?.cancel() }
    }

    private func show(_ season: Season?) {
        turn?.cancel()
        guard shown != nil, !reduceMotion else {
            angle = 0
            shown = season
            return
        }
        turn = Task { @MainActor in
            withAnimation(.easeIn(duration: 0.16)) { angle = 90 }
            do {
                try await Task.sleep(for: .milliseconds(160))
            } catch {
                return
            }
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) {
                shown = season
                angle = -90
            }
            // A frame apart, so the turn back starts from the far side.
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.22)) { angle = 0 }
        }
    }
}

/// The season selector's text: the season's name with a pair of arrows
/// after it. Focused, it takes a bar under the name and the arrows
/// brighten, each dimmed when there's no season that way.
private struct TVSeasonSelectorLabel: View {
    let title: String
    let isFocused: Bool
    let hasPrevious: Bool
    let hasNext: Bool

    static let height: CGFloat = 68

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Text(verbatim: title)
                .font(.system(size: 46, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .foregroundStyle(Color.white)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white)
                        .frame(height: 4)
                        .opacity(isFocused ? 1 : 0)
                }
            if hasPrevious || hasNext {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                        .opacity(hasPrevious ? 1 : 0.3)
                    Image(systemName: "chevron.right")
                        .opacity(hasNext ? 1 : 0.3)
                }
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.white.opacity(isFocused ? 1 : 0.45))
            }
        }
        .frame(height: Self.height, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: title)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
    }
}

private struct TVSeasonSelectorStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1, anchor: .leading)
            .focusEffectDisabled()
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
