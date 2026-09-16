#if os(tvOS)
import SwiftUI

/// Android-parity playback controls for the hero action row. Each choice is a
/// native tvOS `Menu`, so the focus engine owns lateral movement and returns
/// focus to the same circular trigger after a selection.
struct TVPlaybackActionSelectors: View {
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    var subtitleMode: String? = nil
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void

    var subtitleContext: OpenSubtitlePlaybackContext? = nil

    @State private var subtitleTracks: [PlayerTrack] = []
    @State private var subtitleLoading = false
    @State private var subtitleError = false
    @State private var subtitleRetry = 0
    @State private var subtitleReadGeneration = 0

    var body: some View {
        HStack(spacing: 18) {
            audioMenu
            subtitleMenu
        }
    }

    private var audioMenu: some View {
        TVCircleMenuButton(
            icon: "speaker.wave.2",
            title: "Audio Tracks",
            accessibilityLabel: "Audio, \(audioValue)",
            stabilizesFocusMotion: true
        ) {
            Button { onSelectAudioTrack(nil) } label: {
                menuItem(
                    title: "Auto",
                    detail: "Use your Playback audio preference",
                    isSelected: selectedAudioTrackIndex == nil
                )
            }
            ForEach(audioOptions) { option in
                Button { onSelectAudioTrack(option.ordinal) } label: {
                    menuItem(
                        title: option.title,
                        detail: option.detail,
                        isSelected: option.isSelected
                    )
                }
            }
        }
        .disabled(currentVersion == nil || audioOptions.isEmpty)
    }

    private var fileSubtitleContext: OpenSubtitlePlaybackContext? {
        guard var context = subtitleContext, let file = currentVersion?.fileId else { return nil }
        context.fileID = file
        return context
    }

    private var subtitleFallback: String {
        selectedSubtitleTrackIndex == -1 || (selectedSubtitleTrackIndex == nil && (subtitleMode ?? PlayerSettings.shared.preferredSubtitleMode) == "off")
            ? "Off" : selectedSubtitleTrackIndex == nil ? "Auto" : "On"
    }

    private var subtitleMenu: some View {
        TVCircleMenuButton(icon: "captions.bubble", title: "Subtitles",
                           accessibilityLabel: "Subtitles, \(LucidSubtitleInventory.shared.selectionLabel(context: fileSubtitleContext, fallback: subtitleFallback))", stabilizesFocusMotion: true) {
            Button {
                if let context = fileSubtitleContext {
                    LucidSubtitleInventory.shared.clearChoice(context: context)
                    OpenSubtitlesStore.shared.clearStaged(context: context)
                }
                onSelectSubtitleTrack(nil)
            } label: {
                let label = LucidSubtitleInventory.shared.selectionLabel(context: fileSubtitleContext, fallback: subtitleFallback)
                if label == "Auto" { Label("Auto", systemImage: "checkmark") }
                else { Text("Auto") }
            }
            if subtitleLoading {
                Text("Reading subtitles…")
            } else if subtitleError {
                Button("Retry Reading Subtitles") { subtitleRetry += 1 }
            } else {
                Button {
                    if let context = fileSubtitleContext { LucidSubtitleInventory.shared.choose(nil, context: context) }
                } label: {
                    let choice = fileSubtitleContext.flatMap { LucidSubtitleInventory.shared.choice(context: $0) }
                    let isOff = choice.map { $0.trackID == nil } ?? (subtitleFallback == "Off")
                    if isOff && fileSubtitleContext.flatMap({ OpenSubtitlesStore.shared.stagedLabel(context: $0) }) == nil { Label("Off", systemImage: "checkmark") }
                    else { Text("Off") }
                }
                ForEach(LucidSubtitleInventory.ordered(subtitleTracks)) { track in
                    Button {
                        if let context = fileSubtitleContext { LucidSubtitleInventory.shared.choose(track.trackId, context: context) }
                    } label: {
                        let chosen = fileSubtitleContext.flatMap { LucidSubtitleInventory.shared.choice(context: $0) }
                        menuItem(title: track.languageFirstPrimaryLabel,
                                 detail: ([track.languageFirstDetailLabel].compactMap { $0 } + track.attributePillLabels(includeLanguage: false)).joined(separator: " · "),
                                 isSelected: chosen?.trackID == track.trackId)
                    }
                }
                if subtitleTracks.isEmpty { Text("No embedded subtitles") }
            }
            Divider()
            OpenSubtitlesMenu(context: { fileSubtitleContext }) { result, data, expected in
                guard expected == fileSubtitleContext else { throw OpenSubtitlesError.context }
                try OpenSubtitlesStore.shared.stage(result, data: data, context: expected)
                LucidSubtitleInventory.shared.clearChoice(context: expected)
            }
        }
        .disabled(fileSubtitleContext == nil)
        .task(id: "\(fileSubtitleContext?.contentID ?? ""):\(currentVersion?.fileId ?? -1):\(subtitleRetry)") {
            subtitleReadGeneration += 1
            let generation = subtitleReadGeneration
            subtitleTracks = []; subtitleError = false
            guard let context = fileSubtitleContext else { return }
            subtitleLoading = true
            defer { if subtitleReadGeneration == generation { subtitleLoading = false } }
            do {
                let tracks = try await LucidSubtitleInventory.shared.read(context: context)
                try Task.checkCancellation()
                subtitleTracks = tracks
            } catch is CancellationError { }
            catch { if subtitleReadGeneration == generation && !Task.isCancelled { subtitleError = true } }
        }

    }

    private var versionValue: String {
        let value = DetailPlaybackFormatting.versionCompactLabel(currentVersion)
        return selectedVersionFileId == nil ? "Auto, \(value)" : value
    }

    private var audioValue: String {
        DetailPlaybackFormatting.audioValueLabel(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            annotateAuto: true
        )
    }

    private var audioOptions: [DetailPlaybackFormatting.AudioOption] {
        DetailPlaybackFormatting.audioOptions(
            version: currentVersion,
            selectedAudioTrackIndex: selectedAudioTrackIndex
        )
    }

    private func versionDetail(_ version: FileVersion) -> String {
        DetailPlaybackFormatting.versionDetailLabel(version)
    }

    @ViewBuilder
    private func menuItem(title: String, detail: String, isSelected: Bool) -> some View {
        let label = detail.isEmpty ? title : "\(title) — \(detail)"
        if isSelected {
            Label(label, systemImage: "checkmark")
        } else {
            Text(label)
        }
    }
}

struct TVDetailVersionMenu: View {
    let versions: [FileVersion]
    let selectedFileId: Int?
    let onSelect: (Int?) -> Void

    var body: some View {
        Menu {
            Button { onSelect(nil) } label: {
                if selectedFileId == nil { Label("Auto", systemImage: "checkmark") }
                else { Text("Auto") }
            }
            ForEach(versions) { version in
                Button { onSelect(version.fileId) } label: {
                    let label = DetailPlaybackFormatting.versionShortLabel(version)
                        + " · " + DetailPlaybackFormatting.versionDetailLabel(version)
                    if selectedFileId == version.fileId { Label(label, systemImage: "checkmark") }
                    else { Text(label) }
                }
            }
        } label: {
            Label("Version", systemImage: "square.stack")
        }
        .disabled(versions.isEmpty)
    }
}

/// Compact passive disclosure paired with the circular action menus. This
/// preserves the selected values that used to live inside the lower selector
/// capsule without adding another focus destination.
struct TVPlaybackSelectionSummary: Equatable {
    let version: String?
    let audio: String?
    let subtitles: String?

    @MainActor static func make(
        currentVersion: FileVersion?,
        selectedVersionFileId: Int?,
        selectedAudioTrackIndex: Int?,
        selectedSubtitleTrackIndex: Int?,
        subtitleMode: String?,
        subtitleContext: OpenSubtitlePlaybackContext? = nil
    ) -> TVPlaybackSelectionSummary {
        guard let currentVersion else {
            return TVPlaybackSelectionSummary(
                version: nil,
                audio: nil,
                subtitles: nil
            )
        }

        let resolution = currentVersion.resolution?.lowercased() ?? ""
        let height = Int((resolution.components(separatedBy: "x").last ?? resolution).filter(\.isNumber))
        let quality: String?
        if resolution.contains("4k") || resolution.contains("uhd") || (height ?? 0) >= 2160 {
            quality = "4K"
        } else if (height ?? 0) >= 1080 || resolution.contains("fhd") {
            quality = "FHD"
        } else if !resolution.isEmpty {
            quality = "HD"
        } else {
            quality = nil
        }
        let range = DetailPlaybackFormatting.dynamicRangeLabel(currentVersion)
        let codec = DetailPlaybackFormatting.normalizedVideoCodec(currentVersion.codecVideo)
        let versionParts = [quality, range ?? codec].compactMap { $0 }
        let version = versionParts.isEmpty ? "Auto" : versionParts.joined(separator: " · ")
        let audio = DetailPlaybackFormatting.audioTechnicalSummary(
            version: currentVersion, selectedAudioTrackIndex: selectedAudioTrackIndex
        ) ?? "Auto"

        var context = subtitleContext
        context?.fileID = currentVersion.fileId
        let fallback = selectedSubtitleTrackIndex == -1 || (selectedSubtitleTrackIndex == nil && (subtitleMode ?? PlayerSettings.shared.preferredSubtitleMode) == "off")
            ? "Off" : selectedSubtitleTrackIndex == nil ? "Auto" : "On"
        let subtitle = LucidSubtitleInventory.shared.selectionLabel(context: context, fallback: fallback)

        return TVPlaybackSelectionSummary(
            version: version,
            audio: audio,
            subtitles: subtitle
        )
    }

}
#endif
