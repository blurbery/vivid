import SwiftUI

#if !os(tvOS)
/// Where a detail page's people and titles lead.
struct MobileDetailNavigation {
    let openPerson: (String) -> Void
    let openItem: (String) -> Void
}

/// An iPhone or iPad detail page: loads the item, shows the page for its
/// type under the close or back control, and handles playing, reloading
/// after playback, and the offline and unreachable-server prompts.
struct MobileDetailPage: View {
    let contentId: String
    let onClose: (() -> Void)?
    let resumeContext: AppRouter.ItemDetailResumeContext?

    @State private var session = MobileDetailSession()
    @State private var scrollState = PhoneDetailScrollState()
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let model = session.model
        pageContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.openSubtitleDetailContext, subtitleContext)
            .environment(\.seasonWatchedAction, { seasonId, played in
                await model.setSeasonWatched(contentId: seasonId, played: played)
            })
            .environment(\.mobileEpisodeWatchedAction, { episodeId, played in
                await model.setEpisodeWatched(contentId: episodeId, played: played)
            })
            .background(Color.vividBackground.ignoresSafeArea())
            .tint(.white)
            .vividNavigationTitleDisplayMode(.inline)
            .vividNavigationBarBackgroundHidden()
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                topChrome
            }
            .task(id: contentId) {
                await session.load(contentId: contentId, resumeContext: resumeContext, scrollState: scrollState)
            }
            .onChange(of: router.presentedPlayer?.id) { previous, current in
                guard previous != nil, current == nil, session.refreshesWhenPlayerCloses else { return }
                session.refreshesWhenPlayerCloses = false
                Task {
                    await model.loadDetail(contentId: contentId)
                    session.movieAudioIndex = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidCommit)) { notification in
                guard let event = notification.object as? PlaybackProgressCommittedEvent,
                      event.contentIds.contains(contentId) else { return }
                let completed = event.completedContentIds
                model.applyCompletedPlayback(contentIds: completed)
                Task {
                    await model.loadDetail(contentId: contentId, coalescesMetadataRequests: false)
                    // Some servers briefly return the old episode list.
                    model.applyCompletedPlayback(contentIds: completed)
                    session.movieAudioIndex = nil
                }
            }
            .alert(
                "Downloaded on This Device",
                isPresented: Binding(
                    get: { session.pendingOffline != nil },
                    set: { if !$0 { session.pendingOffline = nil } }
                ),
                presenting: session.pendingOffline
            ) { choice in
                Button(choice.label) { session.playOffline(choice, router: router) }
                Button("Stream from Server") { session.stream(choice.request, router: router) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Play the copy saved on this device, or stream from the server.")
            }
            .alert(
                "Can't Reach Server",
                isPresented: Binding(
                    get: { session.pendingUnreachable != nil },
                    set: { if !$0 { session.pendingUnreachable = nil } }
                ),
                presenting: session.pendingUnreachable
            ) { request in
                Button("Try Anyway") {
                    Task { _ = await ConnectionMonitor.shared.probeServer() }
                    session.stream(request, router: router)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                if ConnectionMonitor.shared.isDeviceOnline {
                    Text("Streaming needs a connection to your server, which isn't responding right now. Downloaded titles can still be played.")
                } else {
                    Text("You're offline. Connect to a network to stream, or play a downloaded title.")
                }
            }
            .onDisappear {
                model.stopEpisodePagePrefetch()
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        if let detail = session.model.detail {
            switch detail.type {
            case "season":
                MobileSeasonPage(contentId: contentId, detail: detail, session: session, navigation: navigation)
            case "series":
                MobileSeriesPage(
                    contentId: contentId,
                    detail: detail,
                    session: session,
                    scrollState: scrollState,
                    navigation: navigation
                )
            default:
                MobileMoviePage(
                    contentId: contentId,
                    detail: detail,
                    session: session,
                    scrollState: scrollState,
                    navigation: navigation
                )
            }
        } else if let error = session.model.error {
            ErrorView(state: error) {
                Task { await session.model.loadDetail(contentId: contentId) }
            }
        } else {
            Color.clear
        }
    }

    private var navigation: MobileDetailNavigation {
        let router = router
        return MobileDetailNavigation(
            openPerson: { personId in
                guard let id = Int(personId) else { return }
                router.navigate(to: .personDetail(personId: id))
            },
            openItem: { itemId in
                router.navigate(to: .itemDetail(contentId: itemId))
            }
        )
    }

    // MARK: Top controls

    private var topChrome: some View {
        let control = leadingControl
        return PhoneDetailTopChrome(
            title: session.model.detail?.title ?? "",
            isScrollGlassEnabled: isScrollGlassEnabled,
            scrollState: scrollState,
            leadingSystemName: control?.systemName,
            leadingAccessibilityLabel: control?.label,
            onLeadingTap: control?.action ?? {}
        )
    }

    /// Close on the cover's first page, Back on pages pushed inside it.
    private var leadingControl: (systemName: String, label: String, action: () -> Void)? {
        if let onClose {
            return ("xmark", String(localized: "Close details"), onClose)
        }
        if !router.itemDetailPath.isEmpty {
            let router = router
            return ("chevron.left", String(localized: "Back"), {
                if !router.itemDetailPath.isEmpty {
                    router.itemDetailPath.removeLast()
                }
            })
        }
        return nil
    }

    /// The glass title bar is for iPhone movie and series pages.
    private var isScrollGlassEnabled: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              PhoneDuo.usesPhoneDetailLayout(horizontalSizeClass),
              let type = session.model.detail?.type else { return false }
        return VividMediaType.isMovieLibrary(type) || VividMediaType.isSeries(type)
    }

    // MARK: Subtitles

    /// What the subtitle sheet searches for: the next episode on series and
    /// season pages, otherwise the movie or episode itself.
    private var subtitleContext: OpenSubtitlePlaybackContext? {
        if let next = session.nextUpDetail, !session.isLoadingNextUp {
            return OpenSubtitlePlaybackContext(
                contentID: next.contentId,
                generation: 0,
                query: OpenSubtitleQuery(
                    title: next.seriesTitle ?? next.title,
                    type: next.type,
                    season: next.seasonNumber,
                    episode: next.episodeNumber
                )
            )
        }
        guard let detail = session.model.detail, detail.type == "movie" || detail.type == "episode" else { return nil }
        let title = detail.type == "episode" ? (detail.seriesTitle ?? detail.title) : detail.title
        return OpenSubtitlePlaybackContext(
            contentID: detail.contentId,
            generation: 0,
            query: OpenSubtitleQuery(
                title: title,
                type: detail.type,
                season: detail.seasonNumber,
                episode: detail.episodeNumber
            )
        )
    }
}

/// The controls, menus and buttons the three page types share.
enum MobileDetailControls {
    /// Plain digits, for episode codes and play titles.
    static func digits(_ number: Int) -> String {
        String(number)
    }

    /// "S1 E2" under a resuming Play button.
    static func episodeCode(season: Int, episode: Int) -> String {
        String(
            localized: "S\(digits(season)) E\(digits(episode))",
            comment: "Spaced episode code with zero-padded season and episode numbers, e.g. S01 E02"
        )
    }

    static func resumeProgress(for episode: EpisodeListItem?) -> ResumePresentation? {
        guard let episode else { return nil }
        return ResumePresentation(
            position: MobileDetailSession.displayResumePosition(episode.userData),
            duration: episode.userData?.durationSeconds,
            episodeLabel: episodeCode(season: episode.seasonNumber, episode: episode.episodeNumber)
        )
    }

    /// The stopped-at time for the resume alert.
    static func stoppedAt(_ position: Double?) -> String {
        position.map(PlayerTimeFormatter.formatHMS) ?? "0:00"
    }
}

/// The Favorite button used in every page's More menu.
struct MobileFavoriteMenuButton: View {
    let isFavorite: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            if isFavorite {
                Label("Remove from Favorites", systemImage: "heart.fill")
            } else {
                Label("Add to Favorites", systemImage: "heart")
            }
        }
    }
}

/// "Mark Season 2 as Watched" for the season that's showing.
struct MobileSeasonWatchedButton: View {
    let season: Season
    let toggle: () -> Void

    var body: some View {
        let name = season.downloadDisplayName
        if season.userData?.played == true {
            Button("Mark \(name) as Unwatched", action: toggle)
        } else {
            Button("Mark \(name) as Watched", action: toggle)
        }
    }
}
#endif
