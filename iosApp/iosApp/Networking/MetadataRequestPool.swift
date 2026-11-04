import Foundation

/// Lets callers asking for the same thing at the same moment share one
/// request.
///
/// Nothing is kept once a request finishes, so this is not a cache: the next
/// caller starts a new request, a failure can be retried at once, and code
/// that must see the server's latest answer (writes, polling) goes straight
/// to `VividAPI` instead.
actor MetadataSingleFlight<Key: Hashable & Sendable, Value> {
    /// One running request and the callers waiting on it. Each caller holds
    /// a ticket, so a cancellation only ever withdraws the caller it belongs
    /// to, even if a newer request has since started under the same key.
    private struct Shared {
        let work: Task<Value, Error>
        var tickets: Set<UUID> = []
    }

    private var inFlight: [Key: Shared] = [:]

    func value(
        for key: Key,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let ticket = UUID()
        let work = join(key, ticket: ticket, startingWith: operation)
        let outcome = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            Task { await self.leave(key, ticket: ticket, stoppingWorkIfLast: true) }
        }
        leave(key, ticket: ticket, stoppingWorkIfLast: false)
        try Task.checkCancellation()
        return try outcome.get()
    }

    private func join(
        _ key: Key,
        ticket: UUID,
        startingWith operation: @escaping () async throws -> Value
    ) -> Task<Value, Error> {
        var shared = inFlight[key] ?? Shared(work: Task { try await operation() })
        shared.tickets.insert(ticket)
        inFlight[key] = shared
        return shared.work
    }

    /// Withdraws one caller. A request keeps running while anyone still
    /// waits for it; when a cancelled caller was the last one, it's stopped.
    private func leave(_ key: Key, ticket: UUID, stoppingWorkIfLast: Bool) {
        guard var shared = inFlight[key], shared.tickets.remove(ticket) != nil else { return }
        guard shared.tickets.isEmpty else {
            inFlight[key] = shared
            return
        }
        inFlight[key] = nil
        if stoppingWorkIfLast {
            shared.work.cancel()
        }
    }
}

/// Shared requests for the everyday metadata reads that opt in.
///
/// Every key carries the signed-in account (its credential generation, never
/// the credential) and the profile, so nothing asked for after a server or
/// profile switch joins a request made for the previous one. An item detail
/// whose freshness depends on something outside it passes that revision as
/// `freshnessDiscriminator`. Pollers waiting on a write call `VividAPI`
/// directly.
final class MetadataRequestPool: @unchecked Sendable {
    static let shared = MetadataRequestPool()

    /// A request target tied to the identity it was asked for.
    private struct Scoped<Target: Hashable & Sendable>: Hashable, Sendable {
        let identity: RefreshAccountIdentity?
        let profile: String?
        let target: Target
    }

    private struct DetailTarget: Hashable, Sendable {
        let contentID: String
        let revision: String?
    }

    private struct SeasonTarget: Hashable, Sendable {
        let seriesID: String
        let season: Int
    }

    private let details = MetadataSingleFlight<Scoped<DetailTarget>, ItemDetail>()
    private let seasonLists = MetadataSingleFlight<Scoped<String>, SeasonsResponse>()
    private let episodeLists = MetadataSingleFlight<Scoped<SeasonTarget>, EpisodesResponse>()
    private let watchDetails = MetadataSingleFlight<Scoped<String>, WatchDetail>()

    private init() {}

    func itemDetail(contentId: String, freshnessDiscriminator: String? = nil) async throws -> ItemDetail {
        let key = await scoped(DetailTarget(contentID: contentId, revision: freshnessDiscriminator))
        return try await details.value(for: key) { try await VividAPI.shared.itemDetail(contentId: contentId) }
    }

    func seasons(seriesId: String) async throws -> SeasonsResponse {
        let key = await scoped(seriesId)
        return try await seasonLists.value(for: key) { try await VividAPI.shared.seasons(seriesId: seriesId) }
    }

    func episodes(seriesId: String, seasonNumber: Int) async throws -> EpisodesResponse {
        let key = await scoped(SeasonTarget(seriesID: seriesId, season: seasonNumber))
        return try await episodeLists.value(for: key) {
            try await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: seasonNumber)
        }
    }

    func watchDetail(contentId: String) async throws -> WatchDetail {
        let key = await scoped(contentId)
        return try await watchDetails.value(for: key) { try await VividAPI.shared.watchDetail(contentId: contentId) }
    }

    private func scoped<Target: Hashable & Sendable>(_ target: Target) async -> Scoped<Target> {
        let signIn = await TokenStore.shared.captureOrdinaryRequestAuth()
        return Scoped(identity: signIn?.account, profile: signIn?.profileId, target: target)
    }
}
