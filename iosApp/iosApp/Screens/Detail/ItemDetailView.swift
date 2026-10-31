import SwiftUI

/// An item's detail page. Apple TV shows its own page; iPhone and iPad show
/// the movie, episode, series or season page for the item's type.
struct ItemDetailView: View {
    let contentId: String
    let tvSeed: TVItemDetailRouteSeed?
    let onClose: (() -> Void)?
    let resumeContext: AppRouter.ItemDetailResumeContext?

    init(
        contentId: String,
        tvSeed: TVItemDetailRouteSeed? = nil,
        onClose: (() -> Void)? = nil,
        resumeContext: AppRouter.ItemDetailResumeContext? = nil
    ) {
        self.contentId = contentId
        self.tvSeed = tvSeed
        self.onClose = onClose
        self.resumeContext = resumeContext
    }

    var body: some View {
        #if os(tvOS)
        TVItemDetailView(contentId: contentId, seed: tvSeed)
            .background(VividAppBackdrop())
        #else
        MobileDetailPage(contentId: contentId, onClose: onClose, resumeContext: resumeContext)
        #endif
    }
}

private struct SeasonWatchedActionKey: EnvironmentKey {
    static let defaultValue: ((String, Bool) async -> Bool)? = nil
}

extension EnvironmentValues {
    /// Marks a season watched or unwatched: the season's content id and the
    /// new state. The result says whether the change was saved. Nil hides
    /// the season context menu.
    var seasonWatchedAction: ((String, Bool) async -> Bool)? {
        get { self[SeasonWatchedActionKey.self] }
        set { self[SeasonWatchedActionKey.self] = newValue }
    }
}

/// A long-press menu on a season that marks the whole season watched or
/// unwatched, with an alert when that fails.
struct SeasonWatchedContextMenu: ViewModifier {
    let season: Season

    @Environment(\.seasonWatchedAction) private var setWatched
    @State private var showsFailure = false

    init(season: Season) {
        self.season = season
    }

    func body(content: Content) -> some View {
        if let setWatched {
            let isPlayed = season.userData?.played == true
            content
                .contextMenu {
                    Button {
                        let seasonId = season.contentId
                        Task {
                            if await !setWatched(seasonId, !isPlayed) {
                                showsFailure = true
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
                .alert("Couldn’t update season", isPresented: $showsFailure) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Please try again.")
                }
        } else {
            content
        }
    }
}

#if !os(tvOS)
private struct MobileEpisodeWatchedActionKey: EnvironmentKey {
    static let defaultValue: ((String, Bool) async -> Bool)? = nil
}

extension EnvironmentValues {
    /// Marks one episode watched or unwatched from a card's context menu.
    var mobileEpisodeWatchedAction: ((String, Bool) async -> Bool)? {
        get { self[MobileEpisodeWatchedActionKey.self] }
        set { self[MobileEpisodeWatchedActionKey.self] = newValue }
    }
}

/// A long-press menu on an episode card or row that flips its watched state.
struct MobileEpisodeWatchedMenu: ViewModifier {
    let episode: EpisodeListItem

    @Environment(\.mobileEpisodeWatchedAction) private var setWatched

    func body(content: Content) -> some View {
        if let setWatched {
            let isPlayed = episode.userData?.played == true
            content.contextMenu {
                Button {
                    let episodeId = episode.contentId
                    Task { _ = await setWatched(episodeId, !isPlayed) }
                } label: {
                    if isPlayed {
                        Label("Mark Episode as Unwatched", systemImage: "circle")
                    } else {
                        Label("Mark Episode as Watched", systemImage: "checkmark.circle")
                    }
                }
            }
        } else {
            content
        }
    }
}
#endif
