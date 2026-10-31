import SwiftUI

#if !os(tvOS)
/// Edition, Version, Audio and Subtitles for the file that will play: tiles
/// under the overview, or circles beside Play in the iPad hero.
struct MobilePlaybackSelectors: View {
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let chosenVersionId: Int?
    let chosenAudioIndex: Int?
    let onChooseVersion: (Int?) -> Void
    let onChooseAudio: (Int?) -> Void

    @State private var showsSubtitles = false
    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle
    @Environment(\.openSubtitleDetailContext) private var subtitleContext

    private enum Kind: CaseIterable {
        case edition, version, audio, subtitles

        var title: String {
            switch self {
            case .edition: String(localized: "Edition")
            case .version: String(localized: "Version")
            case .audio: String(localized: "Audio")
            case .subtitles: String(localized: "Subtitles")
            }
        }

        var icon: String {
            switch self {
            case .edition: "rectangle.stack"
            case .version: "square.stack"
            case .audio: "speaker.wave.2"
            case .subtitles: "captions.bubble"
            }
        }
    }

    var body: some View {
        if let currentVersion {
            let kinds = kinds(for: currentVersion)
            if !kinds.isEmpty {
                row(kinds: kinds, version: currentVersion)
                    .task { _ = await ProfilePrefsStore.shared.hydrateIfNeeded() }
                    .task(id: currentVersion.fileId) {
                        await SiloStoredSubtitles.shared.load(fileID: currentVersion.fileId)
                    }
                    .openSubtitlesDetailSearch(
                        fileID: currentVersion.fileId,
                        serverSubtitles: currentVersion.subtitleTracks,
                        automaticSubtitle: DetailPlaybackFormatting.automaticSubtitleOutcome(
                            version: currentVersion,
                            selectedAudioTrackIndex: chosenAudioIndex
                        ),
                        isPresented: $showsSubtitles
                    )
            }
        }
    }

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    private func kinds(for version: FileVersion) -> [Kind] {
        var kinds: [Kind] = []
        if editions.count > 1 { kinds.append(.edition) }
        kinds.append(.version)
        if DetailPlaybackFormatting.shouldShowAudioValue(version: version) { kinds.append(.audio) }
        if DetailPlaybackFormatting.shouldShowSubtitleValue(version: version) { kinds.append(.subtitles) }
        return kinds
    }

    private func canChange(_ kind: Kind, version: FileVersion) -> Bool {
        switch kind {
        case .edition:
            true
        case .version:
            DetailPlaybackFormatting.shouldEnableVersionSelector(versions: versions, currentVersion: version)
        case .audio:
            DetailPlaybackFormatting.shouldEnableAudioSelector(version: version)
        case .subtitles:
            false
        }
    }

    @ViewBuilder
    private func row(kinds: [Kind], version: FileVersion) -> some View {
        if usesTVStyle {
            HStack(spacing: 14) {
                ForEach(kinds.filter { kind in
                    !((kind == .edition || kind == .version) && !canChange(kind, version: version))
                }, id: \.self) { kind in
                    control(kind, version: version)
                }
            }
        } else {
            HStack(spacing: 6) {
                ForEach(kinds, id: \.self) { kind in
                    control(kind, version: version)
                }
            }
        }
    }

    @ViewBuilder
    private func control(_ kind: Kind, version: FileVersion) -> some View {
        let value = value(of: kind, version: version)
        if kind == .subtitles {
            Button {
                showsSubtitles = true
            } label: {
                face(kind, value: value)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Subtitles, \(value)"))
        } else if canChange(kind, version: version) {
            Menu {
                Section {
                    menuItems(kind, version: version)
                }
            } label: {
                face(kind, value: value)
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(kind.title), \(value)"))
        } else {
            face(kind, value: value)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(kind.title), \(value)"))
        }
    }

    @ViewBuilder
    private func face(_ kind: Kind, value: String) -> some View {
        if usesTVStyle {
            MobileActionCircle(icon: kind.icon, isActive: false)
        } else {
            MobileSelectorTile(icon: kind.icon) {
                Text(verbatim: value)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
        }
    }

    private func value(of kind: Kind, version: FileVersion) -> String {
        switch kind {
        case .edition:
            return DetailPlaybackFormatting.currentEdition(versions: versions, currentVersion: version)?.label
                ?? Optional(version).map(PlaybackEditions.displayLabel(for:))
                ?? String(localized: "Standard")
        case .version:
            return DetailPlaybackFormatting.mobileVersionSummary(version)
        case .audio:
            return DetailPlaybackFormatting.audioTechnicalSummary(
                version: version,
                selectedAudioTrackIndex: chosenAudioIndex
            ) ?? String(localized: "Auto")
        case .subtitles:
            var context = subtitleContext
            context?.fileID = version.fileId
            return LucidSubtitleInventory.shared.selectionLabel(
                context: context,
                fallback: DetailPlaybackFormatting.automaticSubtitleLabel(
                    version: version,
                    selectedAudioTrackIndex: chosenAudioIndex
                )
            )
        }
    }

    @ViewBuilder
    private func menuItems(_ kind: Kind, version: FileVersion) -> some View {
        switch kind {
        case .edition:
            let current = DetailPlaybackFormatting.currentEdition(versions: versions, currentVersion: version)
            ForEach(editions) { edition in
                MobileSelectorMenuEntry(
                    title: edition.label,
                    detail: String(localized: "\(edition.versions.count) versions"),
                    isChecked: edition.id == current?.id
                ) {
                    onChooseVersion(
                        DetailVersionSelection.displayVersion(
                            versions: edition.versions,
                            selectedFileId: nil,
                            lastFileId: nil,
                            preferredQualityId: PlayerSettings.shared.preferredQuality
                        )?.fileId
                    )
                }
            }
        case .version:
            MobileSelectorMenuEntry(
                title: String(localized: "Auto"),
                detail: String(localized: "Best match for this device"),
                isChecked: chosenVersionId == nil
            ) {
                onChooseVersion(nil)
            }
            ForEach(DetailPlaybackFormatting.versionSelectorVersions(versions: versions, currentVersion: version)) { file in
                MobileSelectorMenuEntry(
                    title: DetailPlaybackFormatting.versionPrimaryText(file),
                    detail: DetailPlaybackFormatting.versionSecondaryText(file),
                    isChecked: chosenVersionId == file.fileId
                ) {
                    onChooseVersion(file.fileId)
                }
            }
        case .audio:
            MobileSelectorMenuEntry(
                title: String(localized: "Auto"),
                detail: String(localized: "Use your Playback audio preference"),
                isChecked: chosenAudioIndex == nil
            ) {
                onChooseAudio(nil)
            }
            let options = DetailPlaybackFormatting.audioOptions(version: version, selectedAudioTrackIndex: chosenAudioIndex)
            if options.isEmpty {
                MobileSelectorMenuEntry(
                    title: String(localized: "Unknown"),
                    detail: String(localized: "No audio metadata"),
                    isChecked: false
                ) {}
                .disabled(true)
            } else {
                ForEach(options) { option in
                    MobileSelectorMenuEntry(
                        title: option.title,
                        detail: option.detail,
                        isChecked: option.ordinal == chosenAudioIndex
                    ) {
                        onChooseAudio(option.ordinal)
                    }
                }
            }
        case .subtitles:
            EmptyView()
        }
    }
}

/// One menu row: title and detail on a line, with a check when chosen.
private struct MobileSelectorMenuEntry: View {
    let title: String
    let detail: String?
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        let text = [title, detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        Button(action: action) {
            if isChecked {
                Label(text, systemImage: "checkmark")
            } else {
                Text(verbatim: text)
            }
        }
    }
}

/// A selector tile: the kind's icon over its value.
private struct MobileSelectorTile<Value: View>: View {
    let icon: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
            value()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(shape.fill(Color.white.opacity(0.10)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
    }
}

/// Grey tiles that hold the selectors' place while a new episode's
/// playback options load.
struct MobileSelectorSkeleton: View {
    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle

    var body: some View {
        if !usesTVStyle {
            HStack(spacing: 6) {
                ForEach(["square.stack", "speaker.wave.2", "captions.bubble"], id: \.self) { icon in
                    MobileSelectorTile(icon: icon) {
                        Text("\u{2014}")
                            .font(.system(size: 12, weight: .regular))
                    }
                }
            }
            .foregroundStyle(Color.white.opacity(0.40))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
