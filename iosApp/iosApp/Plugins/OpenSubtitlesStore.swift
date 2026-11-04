#if os(iOS) || os(tvOS)
import Foundation
import CryptoKit
import Observation

/// The OpenSubtitles key for the active server account and profile, its
/// searches and downloads, and the subtitle each title will use next.
///
/// The key is kept in Keychain and syncs through the iCloud vault. Every
/// change of account, profile or key gives a new `revision`, and an answer
/// started under an older one is dropped.
@Observable @MainActor
final class OpenSubtitlesStore {
    static let shared = OpenSubtitlesStore()

    private(set) var revision = UUID()
    private(set) var isConnected = false

    private let keychain = SharedKeychain(audience: .currentUser)
    private let client = OpenSubtitlesClient()
    private var loadedScope: String?
    private var key = ""
    private var downloads = OpenSubtitleDownloadCache()
    private var pendingSelection: PendingSelection?

    /// A subtitle picked on a detail page, used when that item next plays
    /// within half an hour.
    private struct PendingSelection {
        let context: OpenSubtitlePlaybackContext
        let result: OpenSubtitleResult
        let data: Data
        let revision: UUID
        let expires: Date

        func isFor(contentID: String, fileID: Int?) -> Bool {
            context.contentID == contentID && context.fileID == fileID
        }
    }

    var scope: String? {
        guard let account = VividCloudPreferences.matchingActiveAccount,
              let profile = account.profile?.id else { return nil }
        return VividCloudPreferences.pluginScope(server: account.serverID, user: account.userID, profile: profile)
    }

    private func storageKey(_ scope: String) -> String { "vivid.opensubtitles.key.v1." + scope }

    /// Picks up a change of account, profile or saved key, clearing the
    /// downloads and the staged pick that belonged to the old one.
    func reload() {
        let storedKey = scope.flatMap { keychain.get(storageKey($0)) } ?? ""
        guard loadedScope != scope || key != storedKey else { return }
        downloads = OpenSubtitleDownloadCache()
        pendingSelection = nil
        loadedScope = scope
        key = storedKey
        isConnected = !key.isEmpty
        revision = UUID()
    }

    // MARK: Connection

    /// Checks the key with OpenSubtitles before saving it.
    func connect(_ input: String) async throws {
        reload()
        guard let scope else { throw OpenSubtitlesError.context }
        let generation = revision
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 4096, !candidate.contains(where: \.isWhitespace) else {
            throw OpenSubtitlesError.credentials
        }
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

    /// Removes the key here and, through the vault, on the person's other
    /// devices, and forgets the subtitles remembered for this profile.
    func disconnect() throws {
        reload()
        guard let scope else { throw OpenSubtitlesError.context }
        try VividCloudPreferences.shared.setPluginCredential(nil, for: storageKey(scope))
        downloads = OpenSubtitleDownloadCache()
        pendingSelection = nil
        OpenSubtitlesSelectionMemory.shared.clear(scope: scope)
        key = ""
        isConnected = false
        revision = UUID()
        VividCloudPreferences.shared.schedule()
    }

    // MARK: Search and download

    func search(_ query: OpenSubtitleQuery, language: String) async throws -> [OpenSubtitleResult] {
        reload()
        guard isConnected else { throw OpenSubtitlesError.notConfigured }
        guard let scope else { throw OpenSubtitlesError.context }
        let generation = revision
        let results = try await client.search(query, language: language, key: key)
        guard self.scope == scope, revision == generation else { throw OpenSubtitlesError.context }
        return results
    }

    /// A file downloaded earlier this session is reused, so it doesn't count
    /// against the download limit again.
    func download(_ result: OpenSubtitleResult, expectedRevision: UUID) async throws -> Data {
        reload()
        guard isConnected, let scope, revision == expectedRevision else { throw OpenSubtitlesError.context }
        if let cached = downloads.value(for: result.id) { return cached }
        let data = try await client.download(result, key: key)
        guard self.scope == scope, revision == expectedRevision else { throw OpenSubtitlesError.context }
        downloads.insert(data, for: result.id)
        return data
    }

    // MARK: Picks from the detail page

    /// Keeps a downloaded subtitle for when this item plays. Only a file
    /// that parses as subtitles is kept.
    func stage(_ result: OpenSubtitleResult, data: Data, context: OpenSubtitlePlaybackContext) throws {
        reload()
        guard isConnected, context.fileID != nil else { throw OpenSubtitlesError.context }
        guard OpenSubtitlesClient.isSubtitle(data), let text = String(data: data, encoding: .utf8),
              !VividSubtitleLoader.parse(text).isEmpty else { throw OpenSubtitlesError.file }
        pendingSelection = PendingSelection(context: context, result: result, data: data,
                                            revision: revision, expires: Date().addingTimeInterval(1800))
    }

    func clearStaged(context: OpenSubtitlePlaybackContext) {
        if pendingSelection?.isFor(contentID: context.contentID, fileID: context.fileID) == true {
            pendingSelection = nil
        }
    }

    /// The OpenSubtitles file this item will use when it next plays: a pick
    /// staged on the detail page, or the one remembered from earlier playback.
    func stagedLabel(context: OpenSubtitlePlaybackContext) -> String? {
        guard loadedScope == scope else { return nil }
        if let pending = pendingSelection, pending.revision == revision, pending.expires > Date(),
           pending.isFor(contentID: context.contentID, fileID: context.fileID) {
            return pending.result.name
        }
        guard isConnected, let scope else { return nil }
        return OpenSubtitlesSelectionMemory.shared.record(scope: scope,
            contentID: context.contentID, fileID: context.fileID)?.name
    }

    /// The staged pick for this item, handed over once. An expired pick, or
    /// one from an older key or profile, is dropped.
    func takeStaged(contentID: String, fileID: Int?) -> (result: OpenSubtitleResult, data: Data)? {
        reload()
        guard let pending = pendingSelection else { return nil }
        guard pending.revision == revision, pending.expires > Date() else {
            pendingSelection = nil
            return nil
        }
        guard pending.isFor(contentID: contentID, fileID: fileID) else { return nil }
        pendingSelection = nil
        return (pending.result, pending.data)
    }

    // MARK: Remembered subtitles

    func rememberSelection(_ result: OpenSubtitleResult, data: Data, contentID: String, fileID: Int?) {
        // A file still open in the player after Disconnect must not be saved again.
        reload()
        guard isConnected, let scope else { return }
        OpenSubtitlesSelectionMemory.shared.remember(result, data: data, scope: scope, contentID: contentID, fileID: fileID)
    }

    func rememberedSelection(contentID: String, fileID: Int?) -> (result: OpenSubtitleResult, data: Data)? {
        reload()
        guard isConnected, let scope else { return nil }
        return OpenSubtitlesSelectionMemory.shared.restore(scope: scope, contentID: contentID, fileID: fileID)
    }

    func rememberedOffset(contentID: String, fileID: Int?, resultID: Int) -> Int {
        reload()
        guard isConnected, let scope else { return 0 }
        return OpenSubtitlesSelectionMemory.shared.offset(scope: scope, contentID: contentID, fileID: fileID, resultID: resultID)
    }

    func rememberOffset(_ milliseconds: Int, contentID: String, fileID: Int?, resultID: Int) {
        // Never saved under an account or profile that has since changed.
        reload()
        guard isConnected, let scope else { return }
        OpenSubtitlesSelectionMemory.shared.setOffset(milliseconds, scope: scope, contentID: contentID,
                                                      fileID: fileID, resultID: resultID)
    }

    func forgetSelection(contentID: String, fileID: Int?) {
        guard let scope else { return }
        OpenSubtitlesSelectionMemory.shared.forget(scope: scope, contentID: contentID, fileID: fileID)
    }
}
#endif
