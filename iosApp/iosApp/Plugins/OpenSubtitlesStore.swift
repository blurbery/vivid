#if os(iOS) || os(tvOS)
import Foundation
import CryptoKit
import Observation

@Observable @MainActor
final class OpenSubtitlesStore {
    static let shared = OpenSubtitlesStore()
    private let keychain = SharedKeychain(audience: .currentUser)
    private let client = OpenSubtitlesClient()
    private var loadedScope: String?
    private var key = ""
    private var downloads = OpenSubtitleDownloadCache()
    private(set) var revision = UUID()
    private(set) var isConnected = false
    var scope: String? {
        guard let account = VividCloudPreferences.matchingActiveAccount,
              let profile = account.profile?.id else { return nil }
        return VividCloudPreferences.pluginScope(server: account.serverID, user: account.userID, profile: profile)
    }
    private func storageKey(_ scope: String) -> String { "vivid.opensubtitles.key.v1." + scope }
    func reload() {
        let storedKey = scope.flatMap { keychain.get(storageKey($0)) } ?? ""
        guard loadedScope != scope || key != storedKey else { return }
        downloads = OpenSubtitleDownloadCache()
        loadedScope = scope
        key = storedKey
        isConnected = !key.isEmpty
        revision = UUID()
    }
    func connect(_ input: String) async throws {
        reload()
        guard let scope else { throw OpenSubtitlesError.context }
        let generation = revision
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 4096, !candidate.contains(where: \.isWhitespace) else { throw OpenSubtitlesError.credentials }
        try await client.validate(key: candidate)
        try Task.checkCancellation()
        guard self.scope == scope, revision == generation else { throw OpenSubtitlesError.context }
        try VividCloudPreferences.shared.setPluginCredential(candidate, for: storageKey(scope))
        if key != candidate { downloads = OpenSubtitleDownloadCache() }
        key = candidate
        isConnected = true
        revision = UUID()
        VividCloudPreferences.shared.schedule()
    }
    func disconnect() throws {
        reload()
        guard let scope else { throw MDBListFailure.storage }
        try VividCloudPreferences.shared.setPluginCredential(nil, for: storageKey(scope))
        downloads = OpenSubtitleDownloadCache()
        key = ""
        isConnected = false
        revision = UUID()
        VividCloudPreferences.shared.schedule()
    }
    func search(_ query: OpenSubtitleQuery, language: String) async throws -> [OpenSubtitleResult] {
        reload()
        guard isConnected else { throw OpenSubtitlesError.notConfigured }
        guard let scope else { throw OpenSubtitlesError.context }
        let generation = revision
        let results = try await client.search(query, language: language, key: key)
        guard self.scope == scope, revision == generation else { throw OpenSubtitlesError.context }
        return results
    }
    func download(_ result: OpenSubtitleResult, expectedRevision: UUID) async throws -> Data {
        reload()
        guard isConnected, let scope, revision == expectedRevision else { throw OpenSubtitlesError.context }
        if let cached = downloads.value(for: result.id) { return cached }
        let data = try await client.download(result, key: key)
        guard self.scope == scope, revision == expectedRevision else { throw OpenSubtitlesError.context }
        downloads.insert(data, for: result.id)
        return data
    }
}
#endif
