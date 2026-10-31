#if os(tvOS)
import SwiftUI

/// What the audio and subtitle circles in the action row are built from.
struct TVDetailSelectorInputs {
    /// The version playback will start with, if any.
    var version: FileVersion?
    /// The page's subtitle context, before the file is set.
    var subtitleContext: OpenSubtitlePlaybackContext?
    var audioPick: Int?
    var subtitlePick: Int?
    var onAudio: (Int?) -> Void
    var onSubtitle: (Int?) -> Void

    /// The page's context for the shown file; nil without a version.
    var fileContext: OpenSubtitlePlaybackContext? {
        guard var context = subtitleContext, let version else { return nil }
        context.fileID = version.fileId
        return context
    }

    /// "Off" for an explicit off pick, the automatic choice when nothing is
    /// picked, and "On" for any other pick.
    @MainActor
    var subtitleFallback: String {
        switch subtitlePick {
        case .some(-1):
            return String(localized: "Off")
        case nil:
            return DetailPlaybackFormatting.automaticSubtitleLabel(version: version, selectedAudioTrackIndex: audioPick)
        default:
            return String(localized: "On")
        }
    }
}

/// "<title> \u{2014} <detail>", or the title alone.
@MainActor
enum TVDetailMenuRow {
    static func text(_ title: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        return "\(title) \u{2014} \(detail)"
    }

    @ViewBuilder
    static func label(_ text: String, isSelected: Bool) -> some View {
        if isSelected {
            Label {
                Text(verbatim: text)
            } icon: {
                Image(systemName: "checkmark")
            }
        } else {
            Text(verbatim: text)
        }
    }
}

/// The audio and subtitle circles side by side.
struct TVDetailSelectorCircles: View {
    let inputs: TVDetailSelectorInputs
    var focus: FocusState<TVDetailHeroFocus?>.Binding

    var body: some View {
        HStack(spacing: 18) {
            TVDetailAudioMenu(inputs: inputs, focus: focus)
            TVDetailSubtitleMenu(inputs: inputs, focus: focus)
        }
        .task(id: inputs.version?.fileId) {
            await SiloStoredSubtitles.shared.load(fileID: inputs.version?.fileId)
        }
        .onAppear {
            OpenSubtitlesStore.shared.reload()
        }
    }
}

private struct TVDetailAudioMenu: View {
    let inputs: TVDetailSelectorInputs
    var focus: FocusState<TVDetailHeroFocus?>.Binding

    var body: some View {
        let options: [DetailPlaybackFormatting.AudioOption] = DetailPlaybackFormatting.audioOptions(
            version: inputs.version,
            selectedAudioTrackIndex: inputs.audioPick
        )
        let value = DetailPlaybackFormatting.audioValueLabel(
            version: inputs.version,
            selectedAudioTrackIndex: inputs.audioPick,
            annotateAuto: inputs.audioPick == nil
        )
        TVDetailCircleButton(
            title: "Audio Tracks",
            systemImage: "speaker.wave.2",
            isFocused: focus.wrappedValue == .audio,
            isPressed: false
        ) {
            Menu {
                Button {
                    inputs.onAudio(nil)
                } label: {
                    TVDetailMenuRow.label(
                        TVDetailMenuRow.text(
                            String(localized: "Auto"),
                            detail: String(localized: "Use your Playback audio preference")
                        ),
                        isSelected: inputs.audioPick == nil
                    )
                }
                ForEach(options) { option in
                    Button {
                        inputs.onAudio(option.ordinal)
                    } label: {
                        TVDetailMenuRow.label(
                            TVDetailMenuRow.text(option.title, detail: option.detail),
                            isSelected: option.isSelected
                        )
                    }
                }
            } label: {
                TVDetailCircleHitArea()
            }
            .menuStyle(.button)
            .buttonStyle(TVDetailInvisibleControlStyle())
            .focusEffectDisabled()
            .disabled(inputs.version == nil || options.isEmpty)
            .focused(focus, equals: .audio)
            .accessibilityLabel(Text("Audio, \(value)"))
        }
    }
}

/// The subtitle menu. The file's own tracks are read only once the circle
/// has had focus, because reading them opens the file.
private struct TVDetailSubtitleMenu: View {
    let inputs: TVDetailSelectorInputs
    var focus: FocusState<TVDetailHeroFocus?>.Binding

    @State private var requestedContext: OpenSubtitlePlaybackContext?
    @State private var readTracks: [PlayerTrack] = []
    @State private var readFailed = false
    @State private var isReading = false
    @State private var readGeneration = 0
    @State private var retryCount = 0

    private struct ReadKey: Hashable {
        let contentId: String?
        let fileId: Int
        let retry: Int
        let isRequested: Bool
    }

    private var isFocused: Bool { focus.wrappedValue == .subtitles }

    var body: some View {
        let fileContext = inputs.fileContext
        let inventory = LucidSubtitleInventory.shared
        let label = inventory.selectionLabel(context: fileContext, fallback: inputs.subtitleFallback)
        TVDetailCircleButton(
            title: "Subtitles",
            systemImage: "captions.bubble",
            isFocused: isFocused,
            isPressed: false
        ) {
            Menu {
                menuRows(fileContext)
            } label: {
                TVDetailCircleHitArea()
            }
            .menuStyle(.button)
            .buttonStyle(TVDetailInvisibleControlStyle())
            .focusEffectDisabled()
            .disabled(fileContext == nil)
            .focused(focus, equals: .subtitles)
            .accessibilityLabel(Text("Subtitles, \(label)"))
        }
        .onChange(of: isFocused) { _, focused in
            if focused { requestedContext = fileContext }
        }
        .onChange(of: fileContext) { _, context in
            if isFocused { requestedContext = context }
        }
        .task(id: ReadKey(
            contentId: fileContext?.contentID,
            fileId: inputs.version?.fileId ?? -1,
            retry: retryCount,
            isRequested: requestedContext != nil && requestedContext == fileContext
        )) {
            await loadTracks(for: fileContext)
        }
    }

    private func loadTracks(for fileContext: OpenSubtitlePlaybackContext?) async {
        readGeneration += 1
        let generation = readGeneration
        readTracks = []
        readFailed = false
        isReading = false
        guard let fileContext, requestedContext == fileContext else { return }
        isReading = true
        do {
            let tracks = try await LucidSubtitleInventory.shared.read(context: fileContext)
            // A read that finished after its file changed is dropped.
            if !Task.isCancelled { readTracks = tracks }
        } catch is CancellationError {
            // A newer read replaces this one.
        } catch {
            if generation == readGeneration, !Task.isCancelled {
                readFailed = true
            }
        }
        if generation == readGeneration {
            isReading = false
        }
    }

    @ViewBuilder
    private func menuRows(_ fileContext: OpenSubtitlePlaybackContext?) -> some View {
        let inventory = LucidSubtitleInventory.shared
        let store = OpenSubtitlesStore.shared
        let choice = fileContext.flatMap { inventory.choice(context: $0) }
        let staged = fileContext.flatMap { store.stagedLabel(context: $0) }
        let serverRows = ServerSubtitleSidecars.detailRows(
            inputs.version?.subtitleTracks,
            fileID: inputs.version?.fileId
        )

        Button {
            if let fileContext {
                inventory.clearChoice(context: fileContext)
                store.clearStaged(context: fileContext)
            }
            inputs.onSubtitle(nil)
        } label: {
            TVDetailMenuRow.label(
                TVDetailMenuRow.text(
                    String(localized: "Auto"),
                    detail: DetailPlaybackFormatting.automaticSubtitleOutcome(
                        version: inputs.version,
                        selectedAudioTrackIndex: inputs.audioPick
                    )
                ),
                isSelected: choice == nil && staged == nil
            )
        }

        if isReading {
            stagedRow(staged)
            Text("Reading subtitles…")
        } else if readFailed {
            Button {
                retryCount += 1
            } label: {
                Text("Retry Reading Subtitles")
            }
            offRow(fileContext, choice: choice, staged: staged)
            stagedRow(staged)
            trackRows(LucidSubtitleInventory.ordered(serverRows), choice: choice, fileContext: fileContext)
        } else {
            offRow(fileContext, choice: choice, staged: staged)
            stagedRow(staged)
            let tracks = LucidSubtitleInventory.ordered(readTracks + serverRows)
            if tracks.isEmpty {
                Text("No subtitles")
            } else {
                trackRows(tracks, choice: choice, fileContext: fileContext)
            }
        }

        Divider()

        OpenSubtitlesMenu(context: { fileContext }) { result, data, context in
            guard context == fileContext else { throw OpenSubtitlesError.context }
            try OpenSubtitlesStore.shared.stage(result, data: data, context: context)
            LucidSubtitleInventory.shared.clearChoice(context: context)
        }
    }

    private func offRow(
        _ fileContext: OpenSubtitlePlaybackContext?,
        choice: LucidSubtitleInventory.Choice?,
        staged: String?
    ) -> some View {
        Button {
            if let fileContext {
                LucidSubtitleInventory.shared.choose(nil, context: fileContext)
            }
        } label: {
            TVDetailMenuRow.label(
                String(localized: "Off"),
                isSelected: choice != nil && choice?.trackID == nil && staged == nil
            )
        }
    }

    @ViewBuilder
    private func stagedRow(_ staged: String?) -> some View {
        if let staged {
            Button {} label: {
                TVDetailMenuRow.label("OpenSubtitles \u{00B7} \(staged)", isSelected: true)
            }
        }
    }

    private func trackRows(
        _ tracks: [PlayerTrack],
        choice: LucidSubtitleInventory.Choice?,
        fileContext: OpenSubtitlePlaybackContext?
    ) -> some View {
        ForEach(tracks, id: \.trackId) { track in
            Button {
                guard let fileContext else { return }
                LucidSubtitleInventory.shared.choose(
                    track.trackId,
                    label: track.isExternal ? track.languageFirstPrimaryLabel : nil,
                    storedSubtitleID: ServerSubtitleSidecars.detailStoredSubtitleID(
                        track.trackId,
                        catalog: inputs.version?.subtitleTracks,
                        fileID: inputs.version?.fileId
                    ),
                    context: fileContext
                )
            } label: {
                let detail = ([track.languageFirstDetailLabel].compactMap { $0 }
                    + track.attributePillLabels(includeLanguage: false))
                    .filter { !$0.isEmpty }
                    .joined(separator: " \u{00B7} ")
                TVDetailMenuRow.label(
                    TVDetailMenuRow.text(track.languageFirstPrimaryLabel, detail: detail),
                    isSelected: choice?.trackID == track.trackId
                )
            }
        }
    }
}

/// The Version submenu inside More.
struct TVDetailVersionMenu: View {
    let versions: [FileVersion]
    let pick: Int?
    let onPick: (Int?) -> Void

    var body: some View {
        Menu {
            Button {
                onPick(nil)
            } label: {
                TVDetailMenuRow.label(String(localized: "Auto"), isSelected: pick == nil)
            }
            ForEach(versions, id: \.fileId) { version in
                Button {
                    onPick(version.fileId)
                } label: {
                    let text = DetailPlaybackFormatting.versionShortLabel(version)
                        + " \u{00B7} "
                        + DetailPlaybackFormatting.versionDetailLabel(version)
                    TVDetailMenuRow.label(text, isSelected: pick == version.fileId)
                }
            }
        } label: {
            Label("Version", systemImage: "square.stack")
        }
        .disabled(versions.isEmpty)
    }
}

/// Rows shared by the pages' More menus.
@MainActor
enum TVDetailMoreMenuRows {
    static func favorite(isFavorite: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isFavorite {
                Label("Remove from Favorites", systemImage: "heart.fill")
            } else {
                Label("Add to Favorites", systemImage: "heart")
            }
        }
    }

    static func startOver(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Start Over", systemImage: "backward.end.fill")
        }
    }

    /// "Mark Episode Watched" or "Mark Episode Unwatched".
    static func episodeWatched(isWatched: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isWatched {
                Label("Mark Episode Unwatched", systemImage: "checkmark.circle.fill")
            } else {
                Label("Mark Episode Watched", systemImage: "checkmark.circle")
            }
        }
    }

    /// "Mark as Watched" or "Mark as Unwatched".
    static func titleWatched(isWatched: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isWatched {
                Label("Mark as Unwatched", systemImage: "checkmark.circle.fill")
            } else {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
        }
    }

    static func seasonWatched(isWatched: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isWatched {
                Label("Mark Season Unwatched", systemImage: "checkmark.circle.fill")
            } else {
                Label("Mark Season Watched", systemImage: "checkmark.circle")
            }
        }
    }

    static func seriesWatched(isWatched: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isWatched {
                Label("Mark Series Unwatched", systemImage: "checkmark.circle.fill")
            } else {
                Label("Mark Series Watched", systemImage: "checkmark.circle")
            }
        }
    }

    static func goToSeason(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Go to Season", systemImage: "square.stack")
        }
    }

    static func goToSeries(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Go to Series", systemImage: "tv")
        }
    }
}

/// The episode code under a Resume label, such as "S1 E2".
enum TVDetailEpisodeCode {
    static func spaced(season: Int, episode: Int) -> String {
        let seasonPart = String(localized: "S\(String(season))", comment: "Season number in an episode code, e.g. S1")
        let episodePart = String(localized: "E\(String(episode))", comment: "Episode number in an episode code, e.g. E2")
        return seasonPart + " " + episodePart
    }
}
#endif
