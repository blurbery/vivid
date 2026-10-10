import Foundation

/// Episodes Silo refused because the account was at its download limit.
/// Silo counts preparing and transferring downloads from every device, and
/// doesn't tell apps the limit, so Vivid learns it from the refusal: the
/// rest wait here, in the order asked for, and are asked for again while
/// any are left, when the app comes back or refreshes in the background,
/// and after a download is removed.
extension DownloadManager {
    var waitingDownloads: [WaitingDownload] { file.waitingDownloads ?? [] }

    /// Waiting episodes as rows for the in-progress list.
    var waitingRecords: [DownloadRecord] { waitingDownloads.map(\.displayRecord) }

    func isWaiting(contentId: String) -> Bool {
        waitingDownloads.contains { $0.id == contentId }
    }

    func addWaiting(_ items: [WaitingDownload]) {
        let known = Set(waitingDownloads.map(\.id))
        let new = items.filter { !known.contains($0.id) }
        guard !new.isEmpty else { return }
        file.waitingDownloads = waitingDownloads + new
        persist()
        scheduleWaitingDownloads()
    }

    func cancelWaiting(id: String) {
        guard isWaiting(contentId: id) else { return }
        file.waitingDownloads = waitingDownloads.filter { $0.id != id }
        persist()
    }

    func cancelWaiting(seriesId: String) {
        guard waitingDownloads.contains(where: { $0.seriesId == seriesId }) else { return }
        file.waitingDownloads = waitingDownloads.filter { $0.seriesId != seriesId }
        persist()
    }

    func cancelAllWaiting() {
        guard !waitingDownloads.isEmpty else { return }
        file.waitingDownloads = []
        persist()
    }

    /// A removed download frees a slot once the server has deleted it, so
    /// try the waiting episodes shortly after rather than at the next retry.
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

    /// Asks for waiting episodes again while the server has room, every 20
    /// seconds and less often (up to two minutes) while it keeps refusing.
    func scheduleWaitingDownloads() {
        guard waitingTask == nil, !waitingDownloads.isEmpty else { return }
        waitingTask = Task { @MainActor in
            defer { self.waitingTask = nil }
            var delay: UInt64 = 20
            while !Task.isCancelled, !self.waitingDownloads.isEmpty {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled else { break }
                let before = self.waitingDownloads.count
                await self.startWaitingDownloads()
                delay = self.waitingDownloads.count < before ? 20 : min(delay * 2, 120)
            }
        }
    }

    /// Registers waiting episodes in order until the server refuses again.
    /// An episode is only asked for at the quality it was chosen at: if the
    /// server no longer offers that, it's dropped rather than downloaded at
    /// another size.
    func startWaitingDownloads() async {
        guard !isStartingWaiting, !waitingDownloads.isEmpty else { return }
        isStartingWaiting = true
        defer { isStartingWaiting = false }
        guard await prepareForDownload() else { return }
        let scope = await DownloadScope.current()
        for item in waitingDownloads {
            guard !Task.isCancelled, await DownloadScope.current() == scope else { return }
            let existing = record(forContentId: item.id)
            guard existing == nil || existing?.localStatus == .failed,
                  capability?.qualityPresets.contains(item.quality) == true else {
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
                cancelWaiting(id: item.id)
            } catch DownloadError.registrationAlreadyInFlight {
                continue
            } catch DownloadError.scopeChangedDuringRegistration {
                return
            } catch where DownloadError.isAccountLimit(error) {
                return
            } catch {
                // Registration reports its own failures.
                cancelWaiting(id: item.id)
            }
        }
    }
}
