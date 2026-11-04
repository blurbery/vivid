import Foundation

// Media request models, shared by Silo's `/api/v1/requests` feature probe and
// the Seerr connection. This file must compile on its own with Foundation
// (`scripts/ci/check-seerr-client.sh` builds it next to the Seerr client).

/// A string enum that reads any value it doesn't know as `unknown`, so a
/// newer server can't fail a whole reply by adding a case.
protocol RequestWireEnum: RawRepresentable, Decodable where RawValue == String {
    static var unknown: Self { get }
}

extension RequestWireEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

// MARK: - Wire enums

/// Movies and series only. `.all` is just a search filter value; results
/// never carry it.
enum RequestMediaType: String, Codable, Hashable, CaseIterable, Identifiable, RequestWireEnum {
    case movie
    case series
    case all
    case unknown

    var id: Self { self }

    var displayName: String {
        switch self {
        case .movie: String(localized: "Movie")
        case .series: String(localized: "series.typeLabel", defaultValue: "Series", comment: "Media type label for a single series")
        case .all: String(localized: "All")
        case .unknown: String(localized: "Title")
        }
    }
}

/// Where a request (or one of its targets) is up to. Only targets use
/// `failed`; a request shows failure through its `outcome`.
enum RequestStatus: String, Codable, Hashable, RequestWireEnum {
    case pending
    case approved
    case queued
    case downloading
    case completed
    case failed
    case unknown
}

/// Whether a request is still active. A declined or cancelled request keeps
/// its last status and changes only this.
enum RequestOutcome: String, Codable, Hashable, RequestWireEnum {
    case active
    case declined
    case cancelled
    case failed
    case unknown
}

enum RequestAvailability: String, Codable, Hashable, RequestWireEnum {
    case missing
    case available
    case unknown
}

// MARK: - Feature status

/// `GET /api/v1/requests/status`.
struct RequestsFeatureStatus: Codable {
    let requestsEnabled: Bool
}

// MARK: - Results

/// The signed-in user's request state for one title, worked out by the
/// server, so the app never reasons about duplicates or quotas itself.
struct RequestState: Codable, Hashable {
    let status: RequestStatus?
    let requestable: Bool
    /// The server's reason token (`already_requested`, `quota_exceeded` and
    /// so on) when the title can't be requested. Shown through
    /// `RequestErrorCopy`, never as is.
    let reason: String?
    let requestId: String?
}

/// One search result with its availability on this server and request state.
struct RequestMediaResult: Codable, Identifiable, Hashable {
    let mediaType: RequestMediaType
    let tmdbId: Int
    let title: String
    let year: Int?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    let availability: RequestAvailability
    let libraryContentId: String?
    let request: RequestState

    var id: String { "\(mediaType.rawValue):\(tmdbId)" }
}

struct RequestMediaPage: Codable {
    let page: Int
    let totalPages: Int
    let totalResults: Int
    let results: [RequestMediaResult]
}

// MARK: - Detail

/// Everything shown on a requestable title's page, with the same
/// availability and request state as a result.
struct RequestMediaDetail: Codable {
    let mediaType: RequestMediaType
    let tmdbId: Int
    let imdbId: String?
    let tvdbId: Int?
    let title: String
    let tagline: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let year: Int?
    let runtime: Int?
    let genres: [String]?
    let voteAverage: Double?
    let voteCount: Int?
    let contentRating: String?
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let networks: [String]?
    let director: String?
    let creators: [String]?
    let recommendations: [RequestMediaResult]?
    let availability: RequestAvailability
    let libraryContentId: String?
    let request: RequestState
}

// MARK: - Requests

/// One request sent to one integration at one quality.
struct RequestTarget: Codable, Hashable {
    let quality: String?
    let status: RequestStatus
    let lastError: String?
}

/// A request the user has made.
struct MediaRequest: Codable, Identifiable, Hashable {
    let id: String
    let mediaType: RequestMediaType
    let tmdbId: Int
    let title: String
    let year: Int?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let status: RequestStatus
    let outcome: RequestOutcome
    let targets: [RequestTarget]?
    let libraryContentId: String?
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
}

/// What the app sends to create a request.
struct CreateRequestInput: Encodable {
    let mediaType: RequestMediaType
    let tmdbId: Int
    let tvdbId: Int?
    let imdbId: String?
    let title: String
    let year: Int?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
}
