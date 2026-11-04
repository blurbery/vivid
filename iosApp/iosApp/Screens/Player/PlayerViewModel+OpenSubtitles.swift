import Foundation

#if os(iOS) || os(tvOS)
/// OpenSubtitles files the viewer downloads in the player.
///
/// Each file is written to temporary storage, mounted as an external track
/// with an ID above `openSubtitleTrackIDBase`, and kept with its selection
/// across replacement loads of the same item. Its offset and the item's
/// chosen file are remembered per file version in `OpenSubtitlesStore`.
extension PlayerViewModel {
    static let openSubtitleTrackIDBase: Int64 = 9_000_000_000

    var openSubtitleIDs: Set<Int64> { Set(openSubtitleFiles.entries.keys) }

    func removeOpenSubtitleFiles(_ files: [URL]) {
        for url in files { try? FileManager.default.removeItem(at: url) }
    }

    /// What a download is for: the item, the load it started in and the
    /// search to run. Nil while nothing can take a subtitle.
    var openSubtitleContext: OpenSubtitlePlaybackContext? {
        guard !isDisposed, !isAudioOnlyVividLoad, let detail = currentWatchDetail else { return nil }
        let title = detail.type == "episode" ? (detail.seriesTitle ?? detail.title) : detail.title
        return OpenSubtitlePlaybackContext(
            contentID: detail.contentId,
            generation: streamLoadGeneration,
            query: OpenSubtitleQuery(title: title, type: detail.type,
                                     season: detail.seasonNumber, episode: detail.episodeNumber)
        )
    }

    /// Mounts a downloaded file and selects it. Throws when playback moved on
    /// since the download started, or the data isn't a usable subtitle.
    func useOpenSubtitle(_ result: OpenSubtitleResult, data: Data, expected: OpenSubtitlePlaybackContext) throws {
        guard openSubtitleContext == expected else { throw OpenSubtitlesError.context }
        guard OpenSubtitlesClient.isSubtitle(data), let text = String(data: data, encoding: .utf8),
              !VividSubtitleLoader.parse(text).isEmpty else { throw OpenSubtitlesError.file }
        let id = Self.openSubtitleTrackIDBase + Int64(result.id)
        // Already mounted: just select it again.
        if openSubtitleIDs.contains(id), let track = subtitleTracks.first(where: { $0.trackId == id }),
           isSelectableSubtitle(track) {
            selectSubtitle(track)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivid-opensubtitles-" + UUID().uuidString + ".srt")
        try data.write(to: url, options: .atomic)
        removeOpenSubtitleFiles(openSubtitleFiles.prepare(contentID: expected.contentID))
        let offset = OpenSubtitlesStore.shared.rememberedOffset(
            contentID: expected.contentID, fileID: currentSelectedVersion?.fileId, resultID: result.id)
        let replaced = openSubtitleFiles.register(.init(
            id: id, url: url, name: result.name, language: result.language,
            hearingImpaired: result.hearingImpaired, offsetMs: offset))
        if let replaced { removeOpenSubtitleFiles([replaced]) }
        vividPlaybackController.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: url, name: "OpenSubtitles · " + result.name, language: result.language,
                                  isHearingImpaired: result.hearingImpaired, formatHint: "srt"),
            appTrackID: id)
        adoptVividInventory()
        if let track = subtitleTracks.first(where: { $0.trackId == id }) { selectSubtitle(track) }
    }

    /// The OpenSubtitles file shown as the main subtitle, if one is.
    var selectedOpenSubtitle: OpenSubtitleSessionFiles.Entry? {
        guard let id = selectedSubtitleId, openSubtitleFiles.selectedID == id else { return nil }
        return openSubtitleFiles.entries[id]
    }

    /// Offsets are saved per file version, so a version switch for the same
    /// item reloads each kept file's offset (zero when none was saved).
    func refreshOpenSubtitleOffsets(contentID: String, fileID: Int?) {
        for entry in openSubtitleFiles.entries.values {
            let offset = OpenSubtitlesStore.shared.rememberedOffset(
                contentID: contentID, fileID: fileID, resultID: Self.openSubtitleResultID(entry.id))
            openSubtitleFiles.setOffset(offset, for: entry.id)
        }
    }

    /// Changes the selected OpenSubtitles file's own offset, clamped to ten
    /// seconds either way. `save` also keeps it with the remembered file,
    /// once the change is committed.
    func setOpenSubtitleOffset(_ milliseconds: Int, save: Bool) {
        guard let entry = selectedOpenSubtitle else { return }
        let clamped = max(-10_000, min(milliseconds, 10_000))
        openSubtitleFiles.setOffset(clamped, for: entry.id)
        applySubtitleAppearanceToPlayer()
        guard save, let context = openSubtitleContext else { return }
        OpenSubtitlesStore.shared.rememberOffset(
            clamped, contentID: context.contentID, fileID: currentSelectedVersion?.fileId,
            resultID: Self.openSubtitleResultID(entry.id))
    }

    /// Keeps the item's remembered OpenSubtitles file in step with the latest
    /// explicit choice, so resuming later restores it. While the item has an
    /// OpenSubtitles context, nil or a pick that isn't an OpenSubtitles file
    /// forgets it; without one, or when the file can't be read, nothing changes.
    func rememberOpenSubtitleChoice(_ trackID: Int64?) {
        guard let context = openSubtitleContext else { return }
        let fileID = currentSelectedVersion?.fileId
        guard let trackID, let entry = openSubtitleFiles.entries[trackID] else {
            OpenSubtitlesStore.shared.forgetSelection(contentID: context.contentID, fileID: fileID)
            return
        }
        guard let data = try? Data(contentsOf: entry.url) else { return }
        let result = OpenSubtitleResult(id: Self.openSubtitleResultID(entry.id), name: entry.name,
                                        language: entry.language, hearingImpaired: entry.hearingImpaired)
        OpenSubtitlesStore.shared.rememberSelection(result, data: data, contentID: context.contentID, fileID: fileID)
    }

    /// Restores the OpenSubtitles file chosen when this item last played.
    func restoreRememberedOpenSubtitle() {
        guard openSubtitleFiles.entries.isEmpty, let context = openSubtitleContext else { return }
        let fileID = currentSelectedVersion?.fileId
        guard let saved = OpenSubtitlesStore.shared.rememberedSelection(contentID: context.contentID, fileID: fileID) else { return }
        do {
            try useOpenSubtitle(saved.result, data: saved.data, expected: context)
        } catch {
            OpenSubtitlesStore.shared.forgetSelection(contentID: context.contentID, fileID: fileID)
        }
    }

    /// The OpenSubtitles result a mounted track ID was made from.
    private static func openSubtitleResultID(_ trackID: Int64) -> Int {
        Int(trackID - openSubtitleTrackIDBase)
    }
}
#endif
