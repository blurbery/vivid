import Foundation

/// Episodes Silo refused because the account was at its download limit.
/// Silo counts the downloads being prepared and transferred on every device
/// and doesn't tell apps the limit, so Vivid learns it from the refusal. The
/// rest wait here, in the order they were asked for, and are asked for again
/// while any are left: on a timer, when the app comes back or refreshes in
/// the background, and after a download is removed.
extension DownloadManager {
    // MARK: The list

    var waitingDownloads: [WaitingDownload] { file.waitingDownloads ?? [] }

    /// Waiting episodes as rows for the in-progress list.
    var waitingRecords: [DownloadRecord] { waitingDownloads.map(\.displayRecord) }

    func isWaiting(contentId: String) -> Bool {
        waitingDownloads.contains { $0.id == contentId }
    }

    /// Adds the episodes not already waiting, after the others, and starts
    /// asking for them.
    func addWaiting(_ items: [WaitingDownload]) {
        let known = Set(waitingDownloads.map(\.id))
        let added = items.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return }
        file.waitingDownloads = waitingDownloads + added
        persist()
        scheduleWaitingDownloads()
    }

    func cancelWaiting(id: String) {
        removeWaiting { $0.id == id }
    }

    func cancelWaiting(seriesId: String) {
        removeWaiting { $0.seriesId == seriesId }
    }

    func cancelAllWaiting() {
        removeWaiting { _ in true }
    }

    /// Saves the list without the matching episodes, when any match.
    private func removeWaiting(where matches: (WaitingDownload) -> Bool) {
        let kept = waitingDownloads.filter { !matches($0) }
        guard kept.count != waitingDownloads.count else { return }
        file.waitingDownloads = kept
        persist()
    }

    // MARK: Asking again

    /// A removed download frees a slot once the server has deleted it, so
    /// the waiting episodes are tried shortly after rather than at the next
    /// timer.
    func nudgeWaitingDownloads() {
        guard !waitingDownloads.isEmpty else { return }
        waitingTask?.cancel()
        waitingTask = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self.startWaitingDownloads()
            self.scheduleWaitingDownloads()
        }
    }

    /// Asks for the waiting episodes every 20 seconds while the server takes
    /// some, backing off to every two minutes while it keeps refusing.
    func scheduleWaitingDownloads() {
        guard waitingTask == nil, !waitingDownloads.isEmpty else { return }
        waitingTask = Task { @MainActor in
            // A cancelled loop has already been replaced (or the scope left),
            // so only a loop that ran out clears the slot.
            defer { if !Task.isCancelled { self.waitingTask = nil } }
            var delaySeconds: UInt64 = 20
            while !Task.isCancelled, !self.waitingDownloads.isEmpty {
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                let before = self.waitingDownloads.count
                await self.startWaitingDownloads()
                delaySeconds = self.waitingDownloads.count < before ? 20 : min(delaySeconds * 2, 120)
            }
        }
    }

    /// Registers the waiting episodes in order until the server refuses again
    /// or can't be reached. An episode is only asked for at the quality it
    /// was chosen at: if the server no longer offers that, it's dropped
    /// rather than downloaded at another size.
    func startWaitingDownloads() async {
        guard !isStartingWaiting, !waitingDownloads.isEmpty else { return }
        isStartingWaiting = true
        defer { isStartingWaiting = false }
        guard await prepareForDownload() else { return }
        let scope = await DownloadScope.current()
        for item in waitingDownloads {
            guard !Task.isCancelled, await DownloadScope.current() == scope else { return }
            // Cancelled while an earlier episode was being asked for.
            guard isWaiting(contentId: item.id) else { continue }
            guard canStillAsk(for: item) else {
                cancelWaiting(id: item.id)
                continue
            }
            do {
                try await downloadEpisode(
                    seriesId: item.seriesId,
                    episodeId: item.id,
                    displayTitle: item.title,
                    displaySubtitle: item.subtitle,
                    seriesTitle: item.seriesTitle,
                    posterThumbhash: item.posterThumbhash,
                    preferredPosterPath: item.preferredPosterPath,
                    fileId: item.fileId,
                    quality: item.quality,
                    scope: scope
                )
                if isWaiting(contentId: item.id) {
                    cancelWaiting(id: item.id)
                } else {
                    // Cancelled while its request was in flight.
                    deleteDownload(forContentId: item.id)
                }
            } catch DownloadError.registrationAlreadyInFlight {
                continue
            } catch DownloadError.scopeChangedDuringRegistration {
                return
            } catch where DownloadError.isAccountLimit(error) {
                return
            } catch {
                // The list now belongs to whichever account is active.
                guard await DownloadScope.current() == scope else { return }
                // Offline, a timeout or a server error: try again later.
                if DownloadFailureReport.isRetryable(error) { return }
                // Registration reports its own failures.
                cancelWaiting(id: item.id)
            }
        }
    }

    /// The episode has no download, or only a failed one, and the server
    /// still offers the quality it was chosen at.
    private func canStillAsk(for item: WaitingDownload) -> Bool {
        let existing = record(forContentId: item.id)
        return (existing == nil || existing?.localStatus == .failed)
            && capability?.qualityPresets.contains(item.quality) == true
    }
}
