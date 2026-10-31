import Foundation

/// Carries the most recent request Seerr accepted in this process, so open
/// request screens can catch up with it.
@MainActor
@Observable
final class RequestsEventBus {
    static let shared = RequestsEventBus()

    /// The last published record; nil before the first request and after a reset.
    private(set) var latest: MediaRequest?

    private init() {}

    func publish(_ record: MediaRequest) {
        latest = record
    }

    /// Forgets the last record, so the next account never sees it.
    func reset() {
        latest = nil
    }
}

/// Applies a published request record to the request state of search results.
enum RequestRecordPatch {
    static func state(for record: MediaRequest) -> RequestState {
        switch record.outcome {
        case .cancelled:
            RequestState(status: nil, requestable: true, reason: nil, requestId: nil)
        case .declined, .failed:
            RequestState(status: record.status, requestable: true, reason: nil, requestId: record.id)
        case .active, .unknown:
            RequestState(status: record.status, requestable: false, reason: nil, requestId: record.id)
        }
    }

    static func apply(_ record: MediaRequest, to result: RequestMediaResult) -> RequestMediaResult {
        guard result.mediaType == record.mediaType, result.tmdbId == record.tmdbId else { return result }
        return RequestMediaResult(
            mediaType: result.mediaType,
            tmdbId: result.tmdbId,
            title: result.title,
            year: result.year,
            overview: result.overview,
            posterPath: result.posterPath,
            backdropPath: result.backdropPath,
            releaseDate: result.releaseDate,
            voteAverage: result.voteAverage,
            availability: result.availability,
            libraryContentId: result.libraryContentId,
            request: state(for: record)
        )
    }

    static func apply(_ record: MediaRequest, to results: [RequestMediaResult]) -> [RequestMediaResult] {
        results.map { apply(record, to: $0) }
    }
}
