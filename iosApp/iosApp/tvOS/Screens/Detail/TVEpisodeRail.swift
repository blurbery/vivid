#if os(tvOS)
import SwiftUI

/// A horizontal row of episode cards for one season, used on the season page
/// and on an episode that couldn't open its series.
///
/// The initialiser is frozen for now. `seriesId`, `seriesTitle`,
/// `cardHeightRatio`, `onMoveUp`, `onMoveDown` and `focusRequest` are
/// accepted and ignored until a later cleanup removes them.
struct TVEpisodeRail: View {
    private let episodes: [EpisodeListItem]
    private let onSelect: (String) -> Void
    private let spoilerSeasons: [Season]
    private let onPlay: ((String) -> Void)?
    private let onFocusedEpisodeChange: ((String?) -> Void)?
    private let onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)?
    private let onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)?
    private let currentContentId: String?
    private let currentContentIsFavorite: Bool
    private let favoriteStates: [String: Bool]
    private let prefersCurrentContentFocus: Bool
    private let baseCardWidth: CGFloat
    private let cardSpacing: CGFloat
    private let anchorsFocusedCard: Bool

    @State private var preferences = UICustomizationPreferences.shared
    @FocusState private var focusedId: String?

    init(
        episodes: [EpisodeListItem],
        onSelect: @escaping (String) -> Void,
        spoilerSeasons: [Season] = [],
        onPlay: ((String) -> Void)? = nil,
        onFocusedEpisodeChange: ((String?) -> Void)? = nil,
        onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)? = nil,
        onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)? = nil,
        currentContentId: String? = nil,
        currentContentIsFavorite: Bool = false,
        favoriteStates: [String: Bool] = [:],
        seriesId: String? = nil,
        seriesTitle: String? = nil,
        prefersCurrentContentFocus: Bool = false,
        baseCardWidth: CGFloat = 480,
        cardHeightRatio: CGFloat = 9 / 16,
        cardSpacing: CGFloat = 54,
        anchorsFocusedCard: Bool = false,
        onMoveUp: (() -> Void)? = nil,
        onMoveDown: (() -> Void)? = nil,
        focusRequest: Int = 0
    ) {
        self.episodes = episodes
        self.onSelect = onSelect
        self.spoilerSeasons = spoilerSeasons
        self.onPlay = onPlay
        self.onFocusedEpisodeChange = onFocusedEpisodeChange
        self.onSetWatched = onSetWatched
        self.onSetFavorite = onSetFavorite
        self.currentContentId = currentContentId
        self.currentContentIsFavorite = currentContentIsFavorite
        self.favoriteStates = favoriteStates
        self.prefersCurrentContentFocus = prefersCurrentContentFocus
        self.baseCardWidth = baseCardWidth
        self.cardSpacing = cardSpacing
        self.anchorsFocusedCard = anchorsFocusedCard
    }

    /// The episodes as shown, with Hide Episode Spoilers applied.
    private var shownEpisodes: [EpisodeListItem] {
        guard PlayerSettings.shared.hideFutureEpisodeSpoilers, let first = episodes.first else { return episodes }
        let position = EpisodeSpoilerPolicy.currentPosition(
            seasons: spoilerSeasons,
            pages: [first.seasonNumber: episodes]
        )
        return EpisodeSpoilerPolicy.cover(episodes, after: position)
    }

    var body: some View {
        let presentation = preferences.cardPresentation
        let cardWidth = baseCardWidth * presentation.posterSize.scale
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(shownEpisodes, id: \.contentId) { episode in
                        card(for: episode, width: cardWidth, caption: presentation.caption)
                            .id(episode.contentId)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .modifier(TVEpisodeRailTargeting(viewAligned: anchorsFocusedCard))
            .scrollClipDisabled()
            .focusSection()
            .modifier(TVEpisodeRailDefaultFocus(
                focus: $focusedId,
                currentId: prefersCurrentContentFocus ? currentContentId : nil
            ))
            .onChange(of: focusedId) { _, newValue in
                onFocusedEpisodeChange?(newValue)
            }
            .onAppear {
                guard let currentContentId else { return }
                let anchor: UnitPoint = anchorsFocusedCard ? .leading : .center
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: VividTheme.normalDuration)) {
                        proxy.scrollTo(currentContentId, anchor: anchor)
                    }
                }
            }
            .onDisappear {
                onFocusedEpisodeChange?(nil)
            }
        }
    }

    private func card(for episode: EpisodeListItem, width: CGFloat, caption: CardCaptionStyle) -> some View {
        let id = episode.contentId
        let isCurrent = id == currentContentId
        return TVEpisodeRailCard(
            episode: episode,
            cardWidth: width,
            caption: caption,
            isCurrent: isCurrent,
            isFavorite: isCurrent ? currentContentIsFavorite : (favoriteStates[id] ?? false),
            focus: $focusedId,
            onSelect: { onSelect(id) },
            onPlay: onPlay.map { play in { play(id) } },
            onSetWatched: onSetWatched.map { action in { played in await action(id, played) } },
            onSetFavorite: onSetFavorite.map { action in { favorite in await action(id, favorite) } }
        )
    }
}

private struct TVEpisodeRailTargeting: ViewModifier {
    let viewAligned: Bool

    func body(content: Content) -> some View {
        if viewAligned {
            content.scrollTargetBehavior(.viewAligned)
        } else {
            content
        }
    }
}

private struct TVEpisodeRailDefaultFocus: ViewModifier {
    var focus: FocusState<String?>.Binding
    let currentId: String?

    func body(content: Content) -> some View {
        if let currentId {
            content.defaultFocus(focus, currentId, priority: .userInitiated)
        } else {
            content
        }
    }
}

/// One episode in the rail: its still with watched and progress marks, and
/// the interface's caption choice below.
private struct TVEpisodeRailCard: View {
    let episode: EpisodeListItem
    let cardWidth: CGFloat
    let caption: CardCaptionStyle
    let isCurrent: Bool
    let isFavorite: Bool
    var focus: FocusState<String?>.Binding
    let onSelect: () -> Void
    let onPlay: (() -> Void)?
    let onSetWatched: ((Bool) async -> Bool)?
    let onSetFavorite: ((Bool) async -> Bool)?

    @State private var watchedOverride: Bool?
    @State private var favoriteOverride: Bool?

    private var isFocused: Bool { focus.wrappedValue == episode.contentId }
    private var stillSize: CGSize { CGSize(width: cardWidth, height: cardWidth * 9 / 16) }
    private var isWatched: Bool { watchedOverride ?? episode.userData?.played ?? false }
    private var isFavoriteShown: Bool { favoriteOverride ?? isFavorite }
    private var hasMenu: Bool { onPlay != nil || onSetWatched != nil || onSetFavorite != nil }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 18) {
                still
                if caption.showsTitle {
                    captionView
                }
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .buttonStyle(.card)
        .focused(focus, equals: episode.contentId)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .modifier(TVEpisodeCardMenu(
            isEnabled: hasMenu,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            isWatched: isWatched,
            isFavorite: isFavoriteShown,
            onPlay: onPlay,
            onToggleWatched: onSetWatched.map { _ in toggleWatched },
            onToggleFavorite: onSetFavorite.map { _ in toggleFavorite }
        ))
        .onChange(of: episode.userData?.played) { _, played in
            if let played, played == watchedOverride { watchedOverride = nil }
        }
        .onChange(of: isFavorite) { _, favorite in
            if favorite == favoriteOverride { favoriteOverride = nil }
        }
    }

    private var still: some View {
        let hidesSpoilers = episode.hidesSpoilers
        return ZStack(alignment: .bottom) {
            Color.vividSurfaceElevated
            if let url = episode.stillUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: hidesSpoilers ? EpisodeSpoilerPolicy.coveredStillDecodeSize : stillSize,
                    thumbhash: episode.stillThumbhash,
                    contentMode: .fill,
                    softening: hidesSpoilers ? EpisodeSpoilerPolicy.coveredStillSoftening : nil
                )
                .frame(width: stillSize.width, height: stillSize.height)
                .spoilerCovered(hidesSpoilers, symbolSize: 40)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.vividSecondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if isWatched {
                Color.black.opacity(0.35)
            }
            if let progress = resumeProgress {
                ResumeProgressBar(value: progress.fraction, duration: progress.duration)
            }
        }
        .frame(width: stillSize.width, height: stillSize.height)
        .overlay(alignment: .topTrailing) {
            if isWatched {
                TVWatchedBadge()
                    .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            if isCurrent, !isFocused {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.7), lineWidth: 2)
            }
        }
    }

    private var resumeProgress: (fraction: Double, duration: Double)? {
        guard let duration = episode.userData?.durationSeconds, duration > 0,
              let position = episode.userData?.positionSeconds, position > 0, position < duration else { return nil }
        return (position / duration, duration)
    }

    private var captionView: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                titleText
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent || isFocused ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.92))
                Spacer(minLength: 8)
                if caption.showsMetadata, let runtime = episode.runtime, runtime > 0 {
                    Text(verbatim: TVHeroMetadata.shortRuntime(runtime))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private var titleText: Text {
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
        guard let onSetWatched else { return }
        let played = !isWatched
        watchedOverride = played
        Task {
            let succeeded = await onSetWatched(played)
            if !succeeded { watchedOverride = nil }
        }
    }

    private func toggleFavorite() {
        guard let onSetFavorite else { return }
        let favorite = !isFavoriteShown
        favoriteOverride = favorite
        Task {
            let succeeded = await onSetFavorite(favorite)
            if !succeeded { favoriteOverride = nil }
        }
    }
}

/// The long-press menu of an episode card, attached only when it has rows.
struct TVEpisodeCardMenu: ViewModifier {
    let isEnabled: Bool
    let seasonNumber: Int
    let episodeNumber: Int
    let isWatched: Bool
    let isFavorite: Bool
    let onPlay: (() -> Void)?
    let onToggleWatched: (() -> Void)?
    let onToggleFavorite: (() -> Void)?

    func body(content: Content) -> some View {
        if isEnabled {
            content.contextMenu {
                if let onPlay {
                    Button(action: onPlay) {
                        Label("Play S\(String(seasonNumber)):E\(String(episodeNumber))", systemImage: "play.fill")
                    }
                }
                if let onToggleWatched {
                    Button(action: onToggleWatched) {
                        if isWatched {
                            Label("Mark as Unwatched", systemImage: "circle")
                        } else {
                            Label("Mark as Watched", systemImage: "checkmark.circle")
                        }
                    }
                }
                if let onToggleFavorite {
                    Button(action: onToggleFavorite) {
                        if isFavorite {
                            Label("Remove from Favorites", systemImage: "heart.slash")
                        } else {
                            Label("Add to Favorites", systemImage: "heart")
                        }
                    }
                }
            }
        } else {
            content
        }
    }
}
#endif
