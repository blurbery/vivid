import Foundation
import Observation
import SwiftUI

/// The app's navigation state: where sign-in stands, the main stack, and on
/// iPhone and iPad the item detail sheet and its own stack, plus the player.
@Observable
final class AppRouter {
    enum AuthState: Equatable {
        case loading
        case needsServerSetup
        case needsLogin
        case needsProfile
        case authenticated

        var diagnosticsState: String {
            switch self {
            case .loading: "loading"
            case .needsServerSetup: "needsServerSetup"
            case .needsLogin: "needsLogin"
            case .needsProfile: "needsProfile"
            case .authenticated: "authenticated"
            }
        }
    }

    /// Opens a series at the episode a Continue Watching card was playing.
    struct ItemDetailResumeContext: Equatable {
        let seriesContentId: String
        let episodeContentId: String
        let seasonNumber: Int?

        init?(continueWatching item: SectionItem) {
            let isEpisode = item.type.lowercased() == "episode" || item.episodeNumber != nil
            let seriesId = item.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard isEpisode, !seriesId.isEmpty else { return nil }
            seriesContentId = seriesId
            episodeContentId = item.contentId
            seasonNumber = item.seasonNumber
        }
    }

    struct ItemDetailPresentation: Identifiable, Equatable {
        let id = UUID()
        var contentId: String
        let resumeContext: ItemDetailResumeContext?
        let zoomSourceID: String?
    }

    struct PlayerPresentation: Identifiable, Equatable {
        let id = UUID()
        let contentId: String
        let fileId: Int?
        let audioTrackIndex: Int?
        let subtitleTrackIndex: Int?
        let startFromBeginning: Bool
        let resumePosition: Double?
        let prefersLastUsedVersion: Bool
        let returnToContentId: String?
        var offlineDownloadId: String? = nil
        /// The detail sheet that opened the player; nil for the root.
        var detailPresentationID: UUID? = nil
        let posterURL: String?
        let backdropURL: String?
    }

    struct SearchRequest: Equatable {
        let id = UUID()
        let query: String
    }

    var authState: AuthState = .loading {
        didSet { authStateDidChange(from: oldValue) }
    }
    var path = NavigationPath()
    /// Written by a card just before it opens a detail; never redraws.
    @ObservationIgnored var pendingZoomSourceID: String?
    var presentedPlayer: PlayerPresentation?
    var requestedTab: AppTab?

    #if os(iOS)
    var presentedItemDetail: ItemDetailPresentation? {
        didSet { if presentedItemDetail != nil { isItemDetailPresentationActive = true } }
    }
    /// Stays true until the sheet has finished going away.
    private(set) var isItemDetailPresentationActive = false
    var itemDetailPath = NavigationPath()
    #endif

    #if os(tvOS)
    var requestedSearch: SearchRequest?
    #endif

    /// Why the next sign-in state change happens, for its breadcrumb.
    @ObservationIgnored private var stagedReason: String?

    init() {}

    // MARK: Sign-in state

    private func setAuthState(_ state: AuthState, reason: String) {
        stagedReason = reason
        authState = state
    }

    private func authStateDidChange(from previous: AuthState) {
        let reason = stagedReason ?? "external"
        stagedReason = nil
        guard authState != previous else { return }

        #if os(iOS)
        presentedItemDetail = nil
        itemDetailPath = NavigationPath()
        isItemDetailPresentationActive = false
        #endif

        #if os(tvOS)
        switch authState {
        case .needsLogin where previous == .loading:
            path = NavigationPath()
        case .needsLogin where path.isEmpty:
            path = NavigationPath([Route.serverSetup, Route.login])
        case .needsServerSetup where previous != .loading:
            path = NavigationPath([Route.serverSetup])
        default:
            break
        }
        #endif

        DiagTrace.breadcrumb(
            .essential, category: .lifecycle, tag: "Auth",
            message: "auth state changed \(previous.diagnosticsState) -> \(authState.diagnosticsState)",
            attrs: ["state": .string(authState.diagnosticsState), "reason": .string(reason)]
        )

        if authState != .authenticated {
            PlayerIdentityBoundary.endEngagedVideoPictureInPicture()
            dismissItemDetail()
        }
    }

    private func recordScreen(_ target: String, action: String) {
        DiagTrace.breadcrumb(
            .essential, category: .focus, tag: "Navigation", message: "screen changed",
            attrs: ["target": .string(target), "action": .string(action)]
        )
    }

    private func recordRefused(_ reason: String) {
        DiagTrace.breadcrumb(
            .essential, category: .lifecycle, tag: "Auth", message: "auth action completed",
            attrs: ["reason": .string(reason), "outcome": .string("refused")]
        )
    }

    func resetToLogin() {
        recordScreen("login", action: "reset")
        #if os(tvOS)
        path = NavigationPath([Route.serverSetup, Route.login])
        #else
        path = NavigationPath()
        #endif
        setAuthState(.needsLogin, reason: "resetToLogin")
    }

    func showProfileSelection() {
        recordScreen("profileSelection", action: "reset")
        path = NavigationPath()
        setAuthState(.needsProfile, reason: "showProfileSelection")
    }

    func resetToHome() {
        recordScreen("home", action: "reset")
        path = NavigationPath()
        setAuthState(.authenticated, reason: "resetToHome")
    }

    func resetToServerSetup() {
        recordScreen("serverSetup", action: "reset")
        #if os(tvOS)
        path = NavigationPath([Route.serverSetup])
        #else
        path = NavigationPath()
        #endif
        setAuthState(.needsServerSetup, reason: "resetToServerSetup")
    }

    func expiredSession() {
        path = NavigationPath()
        if ServerRegistry.shared.hasActiveServer {
            recordScreen("login", action: "sessionExpired")
            setAuthState(.needsLogin, reason: "sessionExpired")
        } else {
            recordScreen("serverSetup", action: "sessionExpired")
            setAuthState(.needsServerSetup, reason: "sessionExpiredNoServer")
        }
    }

    func switchProfile() {
        Task {
            guard await AuthService.shared.beginExplicitProfileSelection() else {
                recordRefused("switchProfile")
                return
            }
            await MainActor.run { showProfileSelection() }
        }
    }

    func signOutAndReset() {
        Task {
            guard await AuthService.shared.signOut() else {
                recordRefused("signOut")
                return
            }
            await MainActor.run {
                if ServerRegistry.shared.hasActiveServer { resetToLogin() } else { resetToServerSetup() }
            }
        }
    }

    // MARK: Main stack

    func navigate(to route: Route) {
        #if os(iOS)
        if case .itemDetail(let contentId, _) = route {
            presentItemDetail(contentId: contentId)
            return
        }
        #endif
        recordScreen(route.diagnosticsName, action: "navigate")
        #if os(iOS)
        if case .personDetail = route, presentedItemDetail != nil {
            itemDetailPath.append(route)
            return
        }
        #endif
        path.append(route)
    }

    func replaceCurrent(with route: Route) {
        recordScreen(route.diagnosticsName, action: "replace")
        if !path.isEmpty { path.removeLast() }
        path.append(route)
    }

    func goBack() {
        guard !path.isEmpty else { return }
        recordScreen("previous", action: "back")
        path.removeLast()
    }

    func popToRoot() {
        recordScreen("root", action: "popToRoot")
        path = NavigationPath()
    }

    func switchTab(to tab: AppTab) {
        requestedTab = tab
    }

    #if os(tvOS)
    func requestSearch(query: String) {
        requestedSearch = SearchRequest(query: query)
    }

    /// Search alone on the stack, in one step, so the shell never sees an
    /// empty stack on the way and moves focus to the top level.
    func showSearchReplacingStack() {
        recordScreen("search", action: "siri")
        path = NavigationPath([Route.search])
    }
    #endif

    // MARK: Item detail

    func presentItemDetail(
        contentId: String,
        browseSource: ItemDetailBrowseSource? = nil,
        resumeContext: ItemDetailResumeContext? = nil
    ) {
        #if os(iOS)
        let zoomSourceID = pendingZoomSourceID
        pendingZoomSourceID = nil
        recordScreen("itemDetail", action: "present")
        if presentedItemDetail == nil {
            itemDetailPath = NavigationPath()
            presentedItemDetail = ItemDetailPresentation(
                contentId: contentId, resumeContext: resumeContext, zoomSourceID: zoomSourceID
            )
        } else {
            itemDetailPath.append(Route.itemDetail(contentId: contentId))
        }
        #else
        navigate(to: .itemDetail(contentId: contentId))
        #endif
    }

    /// An episode with a usable series opens the series at that episode;
    /// anything else opens itself.
    func presentContinueWatchingDetail(for item: SectionItem, browseSource: ItemDetailBrowseSource? = nil) {
        #if os(iOS)
        if let context = ItemDetailResumeContext(continueWatching: item) {
            presentItemDetail(contentId: context.seriesContentId, resumeContext: context)
            return
        }
        #endif
        presentItemDetail(contentId: item.contentId, browseSource: browseSource)
    }

    func dismissItemDetail() {
        #if os(iOS)
        presentedItemDetail = nil
        itemDetailPath = NavigationPath()
        #endif
    }

    #if os(iOS)
    /// The sheet has finished going away. A late report after a newer detail
    /// opened changes nothing.
    func itemDetailPresentationDidDismiss() {
        guard presentedItemDetail == nil else { return }
        itemDetailPath = NavigationPath()
        isItemDetailPresentationActive = false
    }

    func goBackInItemDetail() {
        guard presentedItemDetail != nil, !itemDetailPath.isEmpty else { return }
        itemDetailPath.removeLast()
    }
    #endif

    // MARK: Players

    @MainActor
    func presentPlayer(
        contentId: String,
        fileId: Int? = nil,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool = false,
        resumePosition: Double? = nil,
        prefersLastUsedVersion: Bool = false,
        returnToContentId: String? = nil,
        posterURL: String? = nil,
        backdropURL: String? = nil
    ) {
        DiagTrace.breadcrumb(
            .essential, category: .focus, tag: "Navigation", message: "player presented",
            attrs: ["target": .string("player"), "action": .string("present")]
        )
        presentedPlayer = PlayerPresentation(
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            prefersLastUsedVersion: prefersLastUsedVersion,
            returnToContentId: returnToContentId,
            detailPresentationID: currentDetailID,
            posterURL: posterURL,
            backdropURL: backdropURL
        )
    }

    @MainActor
    func presentOfflinePlayer(
        downloadId: String,
        contentId: String,
        startFromBeginning: Bool = false,
        resumePosition: Double? = nil
    ) {
        DiagTrace.breadcrumb(
            .essential, category: .focus, tag: "Navigation", message: "offline player presented",
            attrs: ["target": .string("offlinePlayer"), "action": .string("present")]
        )
        presentedPlayer = PlayerPresentation(
            contentId: contentId,
            fileId: nil,
            audioTrackIndex: nil,
            subtitleTrackIndex: nil,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            prefersLastUsedVersion: false,
            returnToContentId: nil,
            offlineDownloadId: downloadId,
            detailPresentationID: currentDetailID,
            posterURL: nil,
            backdropURL: nil
        )
    }

    /// The detail sheet a new player belongs to.
    private var currentDetailID: UUID? {
        #if os(iOS)
        presentedItemDetail?.id
        #else
        nil
        #endif
    }

    #if os(iOS)
    /// The player for one presentation site: the root (nil) or one detail sheet.
    func playerPresentation(forDetailID detailID: UUID?) -> PlayerPresentation? {
        guard let presentedPlayer, presentedPlayer.detailPresentationID == detailID else { return nil }
        return presentedPlayer
    }

    /// An outgoing cover can't close a newer player.
    func dismissPlayerPresentation(id: UUID) {
        if presentedPlayer?.id == id { presentedPlayer = nil }
    }
    #endif
}

/// The cards around an opened item. Cards build and pass it; nothing reads
/// it back yet.
struct ItemDetailBrowseSource: Equatable {
    init(originID: String, contentIDs: [String]) {}
}

extension EnvironmentValues {
    @Entry var itemDetailBrowseSource: ItemDetailBrowseSource? = nil
}

extension Notification.Name {
    static let vividSessionExpired = Notification.Name("vividSessionExpired")
    static let vividProfileSelectionRequired = Notification.Name("vividProfileSelectionRequired")
}
