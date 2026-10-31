import Foundation

/// What the request page's main button does and shows.
enum RequestPrimaryAction: Equatable {
    case loading
    case submitting
    case status(RequestBadge)
    case request
}

/// Loads one Seerr title for its request page and submits a request for it.
@MainActor
@Observable
final class RequestDetailModel {
    let mediaType: RequestMediaType
    let tmdbId: Int

    private(set) var detail: RequestMediaDetail?
    private(set) var error: ErrorState?
    private(set) var isSubmitting = false
    private(set) var actionMessage: String?

    /// The Seerr connection the shown detail was loaded through.
    @ObservationIgnored private var loadedIdentity: String?
    @ObservationIgnored private var broadcastReload: Task<Void, Never>?

    init(mediaType: RequestMediaType, tmdbId: Int) {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
    }

    var primaryAction: RequestPrimaryAction {
        guard let detail else { return .loading }
        if isSubmitting { return .submitting }
        if let badge = RequestBadge.forCard(availability: detail.availability, request: detail.request) {
            return .status(badge)
        }
        return .request
    }

    /// Fetches the title. A detail already shown stays until a fetch succeeds.
    func load() async {
        error = nil
        let identity = TVSeerrConnectionStore.shared.identity
        do {
            let loaded = try await TVSeerrConnectionStore.shared.detail(type: mediaType, id: tmdbId)
            guard !Task.isCancelled else { return }
            detail = loaded
            loadedIdentity = identity
        } catch {
            guard !Task.isCancelled, detail == nil else { return }
            self.error = Self.loadFailureState(for: error)
        }
    }

    func retry() {
        Task { await load() }
    }

    /// Reloads when another screen's request was for this title.
    func handleBroadcast(_ record: MediaRequest) {
        guard let detail, !isSubmitting,
              record.mediaType == detail.mediaType, record.tmdbId == detail.tmdbId else { return }
        broadcastReload?.cancel()
        broadcastReload = Task { await load() }
    }

    func requestTapped() {
        guard primaryAction == .request else { return }
        Task { await submit() }
    }

    func submit() async {
        guard primaryAction == .request, let detail else { return }
        isSubmitting = true
        actionMessage = nil
        defer { isSubmitting = false }

        guard TVSeerrConnectionStore.shared.identity == loadedIdentity else {
            actionMessage = Self.connectionChangedMessage
            return
        }
        let input = CreateRequestInput(
            mediaType: detail.mediaType,
            tmdbId: detail.tmdbId,
            tvdbId: detail.tvdbId,
            imdbId: detail.imdbId,
            title: detail.title,
            year: detail.year,
            overview: detail.overview,
            posterPath: detail.posterPath,
            backdropPath: detail.backdropPath
        )
        let record: MediaRequest
        do {
            record = try await TVSeerrConnectionStore.shared.create(input)
        } catch {
            actionMessage = Self.submitFailureMessage(for: error)
            return
        }
        RequestsEventBus.shared.publish(record)
        await load()
    }

    static var connectionChangedMessage: String {
        String(localized: "This account's connection changed. Open the title again from Search.")
    }

    /// A fetch that fails because the Seerr connection changed mid-call reads
    /// as a connection change, never as the system's cancellation text.
    static func loadFailureState(for error: Error) -> ErrorState {
        if isCancellation(error) {
            return ErrorState(TVSeerrError(message: connectionChangedMessage))
        }
        return ErrorState(error)
    }

    /// A submit is never cancelled itself, so a cancellation means the
    /// connection changed while it was sending.
    static func submitFailureMessage(for error: Error) -> String {
        if isCancellation(error) { return connectionChangedMessage }
        return error.localizedDescription
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

/// The facts line under a request page's title.
enum RequestMetaLine {
    static func text(for detail: RequestMediaDetail) -> String {
        var parts: [String] = []
        if let year = detail.year, year > 0 {
            parts.append(String(year))
        }
        if let genres = detail.genres, !genres.isEmpty {
            parts.append(genres.prefix(3).joined(separator: ", "))
        }
        if detail.mediaType == .series {
            if let seasons = detail.numberOfSeasons, seasons > 0 {
                parts.append(String(localized: "\(seasons) seasons"))
            }
        } else if let runtime = detail.runtime, runtime > 0 {
            parts.append(String(localized: "\(runtime) min", comment: "Runtime in minutes"))
        }
        if let creators = detail.creators, !creators.isEmpty {
            parts.append(creators.prefix(2).joined(separator: ", "))
        }
        if let rating = detail.voteAverage, rating > 0 {
            parts.append("TMDB " + rating.formatted(.number.precision(.fractionLength(1))))
        }
        return parts.joined(separator: " · ")
    }
}
