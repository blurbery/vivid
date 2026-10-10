#if !os(tvOS)
import SwiftUI

struct DownloadRequestOptions: Hashable {
    let fileId: Int?
    let quality: String
}

struct DownloadOptionsSheet: View {
    let title: String
    let versions: [FileVersion]
    let selectedVersionFileId: Int?
    let lastVersionFileId: Int?
    /// Names the Download row ("Download Episode" or "Download Movie").
    let isEpisode: Bool
    let onStart: (DownloadRequestOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var fileId: Int?
    @State private var quality: String

    init(
        title: String,
        versions: [FileVersion],
        selectedVersionFileId: Int?,
        lastVersionFileId: Int?,
        isEpisode: Bool,
        onStart: @escaping (DownloadRequestOptions) -> Void
    ) {
        self.title = title
        self.versions = versions
        self.selectedVersionFileId = selectedVersionFileId
        self.lastVersionFileId = lastVersionFileId
        self.isEpisode = isEpisode
        self.onStart = onStart

        _fileId = State(initialValue: selectedVersionFileId)
        _quality = State(initialValue: DownloadFormat.original.rawValue)
    }

    private var formats: [DownloadFormat] {
        let available = manager.availableFormats
        return available.isEmpty ? [.original] : available
    }

    /// Emby's conversion service, for accounts that can't transcode
    /// playback, picks its own source for a smaller download.
    private var isEmbyConversion: Bool {
        MediaServerProvider.active == .emby && quality != DownloadFormat.original.rawValue
            && manager.capability?.versionTranscodes == false
    }

    /// The chosen version's resolution class, which decides the smaller
    /// qualities on offer; nil for Auto.
    private var versionHeight: Int? {
        guard fileId != nil, !isEmbyConversion else { return nil }
        return choices.effectiveVersion.flatMap { DownloadVersionPreference.heightClass(of: $0.resolution) }
    }

    private var choices: DownloadVersionChoices {
        DownloadVersionChoices(versions: versions, fileId: fileId, lastVersionFileId: lastVersionFileId)
    }

    var body: some View {
        NavigationStack {
            form
            .vividScrollContentBackgroundHidden()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.clear)
            #else
            .vividPageBackground()
            #endif
            .toolbar {
                VividSheetCloseItem { dismiss() }
            }
            .onAppear(perform: clampQuality)
            .onChange(of: quality) { _, _ in
                if isEmbyConversion { fileId = nil }
            }
            .task {
                // Permissions and server-side download settings can change at
                // any time; re-fetch so the quality list reflects them now
                // rather than after the next app foreground.
                await manager.refreshCapability()
                clampQuality()
            }
        }
        .vividGlassSheet()
    }

    private func start() {
        onStart(DownloadRequestOptions(fileId: isEmbyConversion ? nil : fileId, quality: quality))
        dismiss()
    }

    // MARK: - Layout

    /// The layout every download sheet shares: Choose Version, then a
    /// Quality menu for that version, over the Download row.
    private var form: some View {
        Form {
            if !versions.isEmpty || formats.count > 1 {
                Section {
                    if !versions.isEmpty {
                        NavigationLink {
                            DownloadVersionPage(
                                versions: versions,
                                lastVersionFileId: lastVersionFileId,
                                quality: quality,
                                isEmbyConversion: isEmbyConversion,
                                fileId: $fileId
                            )
                        } label: {
                            DownloadOptionRow(title: "Choose Version", detail: chooseVersionDetail, icon: "square.stack")
                        }
                        .disabled(isEmbyConversion)
                    }
                    if formats.count > 1 {
                        DownloadQualityPicker(quality: $quality, versionHeight: versionHeight)
                    }
                } footer: {
                    if formats.count > 1 {
                        Text(DownloadQualityPicker.footer(quality: quality, versionHeight: versionHeight))
                    }
                }
            }

            Section {
                Button(action: start) {
                    DownloadOptionRow(title: isEpisode ? "Download Episode" : "Download Movie", detail: downloadDetail, icon: "arrow.down.to.line")
                }
                .buttonStyle(.plain)
            } header: {
                Text("Download")
            } footer: {
                downloadFooter
            }
        }
        .navigationTitle(title)
    }

    private var downloadDetail: String {
        var parts = [manager.qualityLabel(rawValue: quality), choices.versionLabel]
        if let estimate = choices.estimate(quality: quality) {
            parts.append(estimate.isRange ? "\(estimate.sizeLabel) depending on server choice" : estimate.sizeLabel)
        }
        return parts.joined(separator: " · ")
    }

    private var chooseVersionDetail: String {
        if isEmbyConversion { return "Emby chooses the version for smaller downloads" }
        guard fileId != nil, let version = choices.effectiveVersion else {
            let candidates = choices.scopedVersions.map(DetailPlaybackFormatting.versionPrimaryText).uniqued()
            return (["Auto"] + [candidates.prefix(3).joined(separator: ", ")].filter { !$0.isEmpty })
                .joined(separator: " · ")
        }
        return [DetailPlaybackFormatting.versionPrimaryText(version), DetailPlaybackFormatting.versionSecondaryText(version)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var downloadFooter: some View {
        let warning = isEmbyConversion ? nil : choices.sizeWarning(quality: quality)
        let note = formats.count > 1 ? nil : "Downloads use original quality. Smaller qualities appear when the server allows download transcoding."
        if warning != nil || note != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let warning {
                    Text(warning).foregroundColor(.orange)
                }
                if let note {
                    Text(note)
                }
            }
        }
    }

    private func clampQuality() {
        if isEmbyConversion { fileId = nil }
        guard !formats.contains(where: { $0.rawValue == quality }) else { return }
        quality = DownloadFormat.original.rawValue
    }
}

// MARK: - Versions

/// Which file Auto or a picked version resolves to, its edition and the size
/// it implies. Shared by both sheet layouts and the Choose Version page.
private struct DownloadVersionChoices {
    let versions: [FileVersion]
    let fileId: Int?
    let lastVersionFileId: Int?

    var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    var effectiveVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: fileId,
            lastFileId: lastVersionFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    var currentEdition: PlaybackEditions.Edition? {
        DetailPlaybackFormatting.currentEdition(
            versions: versions,
            currentVersion: effectiveVersion
        )
    }

    var scopedVersions: [FileVersion] {
        if editions.count > 1, let currentEdition {
            return currentEdition.versions
        }
        return versions
    }

    var versionLabel: String {
        fileId == nil
            ? "Auto version"
            : (effectiveVersion.map(DetailPlaybackFormatting.versionPrimaryText) ?? "Selected version")
    }

    /// Size expectation for what the current selection would download:
    /// candidate range for Auto, exact size for a chosen version.
    func estimate(quality: String) -> DownloadSizeEstimate? {
        guard quality == DownloadFormat.original.rawValue else { return nil }
        return DownloadSizeEstimate.estimate(versions: versions, fileId: fileId)
    }

    /// Over-threshold / insufficient-space caveat for the current selection,
    /// mirroring the one-tap confirmation so switching versions keeps the
    /// warning honest.
    func sizeWarning(quality: String) -> String? {
        estimate(quality: quality)?.warningMessage(
            availableBytes: DownloadFilePaths.deviceStorage().available
        )
    }

    /// Auto spans every version the server might pick, so disclose the full
    /// candidate range rather than pretending the size is unknown.
    var autoVersionDetail: String {
        guard let estimate = DownloadSizeEstimate.estimate(versions: versions, fileId: nil) else {
            return "Let the server choose the file"
        }
        if estimate.isRange {
            return "\(estimate.sizeLabel) depending on server choice"
        }
        return "\(estimate.sizeLabel) · Let the server choose the file"
    }

    /// Version rows with a disambiguator appended when two distinct files
    /// would otherwise render identical primary/secondary text (same
    /// resolution/codec/size), so every row stays tellable-apart.
    var versionRows: [(version: FileVersion, title: String, detail: String?)] {
        let rows = scopedVersions.map { version in
            (
                version: version,
                title: DetailPlaybackFormatting.versionPrimaryText(version),
                detail: DetailPlaybackFormatting.versionSecondaryText(version)
            )
        }
        var counts: [String: Int] = [:]
        for row in rows {
            counts["\(row.title)|\(row.detail ?? "")", default: 0] += 1
        }
        return rows.map { row in
            guard counts["\(row.title)|\(row.detail ?? "")", default: 0] > 1 else { return row }
            let detail = [row.detail, Self.disambiguator(for: row.version)]
                .compactMap { $0 }
                .joined(separator: " · ")
            return (row.version, row.title, detail)
        }
    }

    /// Edition name when the file has one, else a filename fragment — just
    /// enough to tell apart two files whose technical summary reads the same.
    private static func disambiguator(for version: FileVersion) -> String {
        let edition = version.editionDisplayLabel
        if edition != "Standard" { return edition }
        if let fragment = version.fileName?
            .components(separatedBy: "/").last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fragment.isEmpty {
            return fragment
        }
        return "File \(version.fileId)"
    }
}

/// The movie sheet's Choose Version page. Picking a version goes back to the
/// sheet; picking an edition stays so its versions can be chosen.
private struct DownloadVersionPage: View {
    let versions: [FileVersion]
    let lastVersionFileId: Int?
    let quality: String
    let isEmbyConversion: Bool
    @Binding var fileId: Int?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            DownloadVersionSections(
                versions: versions,
                lastVersionFileId: lastVersionFileId,
                quality: quality,
                isEmbyConversion: isEmbyConversion,
                fileId: $fileId,
                onPickVersion: { dismiss() }
            )
            DownloadIncludedMediaSection(
                choices: DownloadVersionChoices(versions: versions, fileId: fileId, lastVersionFileId: lastVersionFileId),
                quality: quality
            )
        }
        .navigationTitle("Choose Version")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .vividScrollContentBackgroundHidden()
        #if os(iOS)
        .background(Color.clear)
        #else
        .vividPageBackground()
        #endif
    }
}

/// Edition and version rows.
private struct DownloadVersionSections: View {
    let versions: [FileVersion]
    let lastVersionFileId: Int?
    let quality: String
    let isEmbyConversion: Bool
    @Binding var fileId: Int?
    var onPickVersion: () -> Void = {}

    private var choices: DownloadVersionChoices {
        DownloadVersionChoices(versions: versions, fileId: fileId, lastVersionFileId: lastVersionFileId)
    }

    var body: some View {
        if choices.editions.count > 1 {
            editionSection
                .disabled(isEmbyConversion)
        }

        if !versions.isEmpty {
            versionSection
        }
    }

    private var editionSection: some View {
        Section("Edition") {
            ForEach(choices.editions) { edition in
                DownloadChoiceRow(
                    title: edition.label,
                    detail: "\(edition.versions.count) version\(edition.versions.count == 1 ? "" : "s")",
                    isSelected: choices.currentEdition?.id == edition.id
                ) {
                    let best = DetailVersionSelection.displayVersion(
                        versions: edition.versions,
                        selectedFileId: nil,
                        lastFileId: lastVersionFileId,
                        preferredQualityId: PlayerSettings.shared.preferredQuality
                    )
                    fileId = best?.fileId
                }
            }
        }
    }

    private var versionSection: some View {
        Section {
            DownloadChoiceRow(
                title: "Auto",
                detail: choices.autoVersionDetail,
                isSelected: fileId == nil
            ) {
                fileId = nil
                onPickVersion()
            }
            ForEach(choices.versionRows, id: \.version.fileId) { row in
                DownloadChoiceRow(
                    title: row.title,
                    detail: row.detail,
                    isSelected: fileId == row.version.fileId
                ) {
                    fileId = row.version.fileId
                    onPickVersion()
                }
            }
        } header: {
            Text("Version")
        } footer: {
            if isEmbyConversion {
                Text("Emby chooses the source version when preparing a smaller download.")
            } else if let warning = choices.sizeWarning(quality: quality) {
                Text(warning)
                    .foregroundColor(.orange)
            }
        }
        .disabled(isEmbyConversion)
    }
}

/// Audio and subtitles the selected file brings with it.
private struct DownloadIncludedMediaSection: View {
    let choices: DownloadVersionChoices
    let quality: String

    var body: some View {
        Section {
            if quality != DownloadFormat.original.rawValue {
                row(title: "Audio", detail: "Prepared by the server")
                row(title: "Subtitles", detail: "Available tracks")
            } else if let version = choices.effectiveVersion {
                row(
                    title: "Audio",
                    detail: DetailPlaybackFormatting.audioValueLabel(
                        version: version,
                        selectedAudioTrackIndex: nil
                    )
                )
                row(title: "Subtitles", detail: subtitleSummary(for: version))
            } else {
                row(title: "Audio", detail: "File default")
                row(title: "Subtitles", detail: "Available tracks")
            }
        } header: {
            Text("Included Media")
        } footer: {
            Text("Audio and subtitles are chosen automatically for the selected file. Available subtitles are saved for offline playback.")
        }
    }

    /// Capped at three languages — a file with dozens of tracks would
    /// otherwise render a wall of language names in one row.
    private static let subtitleLanguageDisplayCap = 3

    private func subtitleSummary(for version: FileVersion) -> String {
        let tracks = version.subtitleTracks ?? []
        guard !tracks.isEmpty else { return "None" }
        let languages = tracks
            .compactMap { languageDisplayName($0.language) }
            .uniqued()
        if languages.isEmpty {
            return "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
        }
        let shown = languages.prefix(Self.subtitleLanguageDisplayCap).joined(separator: ", ")
        let remainder = languages.count - Self.subtitleLanguageDisplayCap
        return remainder > 0 ? "\(shown) +\(remainder) more" : shown
    }

    private func languageDisplayName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.count <= 3 {
            let locale = Locale.current
            return locale.localizedString(forLanguageCode: value.lowercased()) ?? value.uppercased()
        }
        return value
    }

    private func row(title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(detail)
                .foregroundColor(.vividSecondaryText)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A selectable row with a checkmark when chosen.
struct DownloadChoiceRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.vividOnSurface)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.vividCaption)
                            .foregroundColor(.vividSecondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.vividOnSurface)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.56)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
#endif
