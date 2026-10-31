#if os(iOS)
import SwiftUI

extension DownloadScreens {
    /// Download options for one movie or episode: version, quality and the
    /// Download button. Starting calls `onStart` with the file id (nil for
    /// Auto) and the quality's raw value.
    struct OptionsSheet: View {
        let title: String
        let versions: [FileVersion]
        let selectedVersionFileId: Int?
        let lastVersionFileId: Int?
        let isEpisode: Bool
        let onStart: (Int?, String) -> Void

        @State private var chosenFileId: Int?
        @State private var quality = DownloadFormat.original.rawValue
        @Environment(\.dismiss) private var dismiss

        private var manager: DownloadManager { .shared }

        init(
            title: String,
            versions: [FileVersion],
            selectedVersionFileId: Int?,
            lastVersionFileId: Int?,
            isEpisode: Bool,
            onStart: @escaping (Int?, String) -> Void
        ) {
            self.title = title
            self.versions = versions
            self.selectedVersionFileId = selectedVersionFileId
            self.lastVersionFileId = lastVersionFileId
            self.isEpisode = isEpisode
            self.onStart = onStart
            _chosenFileId = State(initialValue: selectedVersionFileId)
        }

        var body: some View {
            NavigationStack {
                Form {
                    if !versions.isEmpty || offered.count > 1 {
                        versionAndQualitySection
                    }
                    downloadSection
                }
                .navigationTitle(Text(verbatim: title))
                .navigationBarTitleDisplayMode(.inline)
                .vividScrollContentBackgroundHidden()
                .background(Color.clear)
                .toolbar {
                    VividSheetCloseItem { dismiss() }
                }
            }
            .vividGlassSheet()
            .onAppear(perform: keepChoiceValid)
            .onChange(of: quality) {
                if isEmbyConversion { chosenFileId = nil }
            }
            .task {
                await manager.refreshDownloadCheck()
                keepChoiceValid()
            }
        }

        // MARK: Sections

        private var versionAndQualitySection: some View {
            Section {
                if !versions.isEmpty {
                    NavigationLink {
                        VersionPage(
                            versions: versions,
                            lastVersionFileId: lastVersionFileId,
                            storedQuality: quality,
                            isEmbyConversion: isEmbyConversion,
                            chosenFileId: $chosenFileId
                        )
                    } label: {
                        OptionRow(title: "Choose Version", detail: chooseVersionDetail, symbol: "square.stack")
                    }
                    .disabled(isEmbyConversion)
                }
                if showsQualityMenu {
                    QualityMenu(selection: $quality, versionHeight: versionHeight)
                }
            } footer: {
                if showsQualityMenu {
                    Text(verbatim: DownloadScreens.qualityFooter(for: qualityUsed, versionHeight: versionHeight, scopeLine: nil))
                } else if offered.count > 1 {
                    Text(verbatim: DownloadScreens.cantShrinkNote)
                }
            }
        }

        private var downloadSection: some View {
            Section {
                Button {
                    onStart(isEmbyConversion ? nil : chosenFileId, qualityUsed.rawValue)
                    dismiss()
                } label: {
                    OptionRow(
                        title: isEpisode ? "Download Episode" : "Download Movie",
                        detail: downloadDetail,
                        symbol: "arrow.down.to.line"
                    )
                }
                .buttonStyle(.plain)
            } header: {
                Text("Download")
            } footer: {
                let lines = footerLines
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let warning = lines.warning {
                            Text(verbatim: warning)
                                .foregroundStyle(Color.orange)
                        }
                        if let note = lines.note {
                            Text(verbatim: note)
                        }
                    }
                }
            }
        }

        // MARK: Derived

        private var offered: [DownloadFormat] { DownloadScreens.offeredQualities() }

        private var isEmbyConversion: Bool { DownloadScreens.isEmbyConversion(storedQuality: quality) }

        private var effectiveVersion: FileVersion? {
            DetailVersionSelection.displayVersion(
                versions: versions,
                selectedFileId: chosenFileId,
                lastFileId: lastVersionFileId,
                preferredQualityId: PlayerSettings.shared.preferredQuality
            )
        }

        private var versionHeight: Int? {
            guard chosenFileId != nil, !isEmbyConversion else { return nil }
            return DownloadVersionPreference.heightClass(of: effectiveVersion?.resolution)
        }

        private var qualitiesForVersion: [DownloadFormat] {
            DownloadScreens.qualities(forVersionHeight: versionHeight)
        }

        private var showsQualityMenu: Bool { qualitiesForVersion.count > 1 }

        private var qualityUsed: DownloadFormat {
            DownloadScreens.qualityUsed(stored: quality, among: qualitiesForVersion)
        }

        private var scopedVersions: [FileVersion] {
            let editions = PlaybackEditions.editions(from: versions)
            guard editions.count > 1,
                  let current = DetailPlaybackFormatting.currentEdition(versions: versions, currentVersion: effectiveVersion) else {
                return versions
            }
            return current.versions
        }

        private var chooseVersionDetail: String {
            if isEmbyConversion {
                return String(localized: "Emby chooses the version for smaller downloads")
            }
            guard chosenFileId != nil, let version = effectiveVersion else {
                var seen = Set<String>()
                let names = scopedVersions
                    .map(DetailPlaybackFormatting.versionPrimaryText)
                    .filter { seen.insert($0).inserted }
                    .prefix(3)
                    .joined(separator: ", ")
                let auto = String(localized: "Auto")
                return names.isEmpty ? auto : "\(auto) · \(names)"
            }
            return [
                DetailPlaybackFormatting.versionPrimaryText(version),
                DetailPlaybackFormatting.versionSecondaryText(version),
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
        }

        private var downloadDetail: String {
            var parts = [manager.qualityTitle(for: qualityUsed)]
            if chosenFileId == nil {
                parts.append(String(localized: "Auto version"))
            } else {
                parts.append(effectiveVersion.map(DetailPlaybackFormatting.versionPrimaryText)
                    ?? String(localized: "Selected version"))
            }
            if qualityUsed == .original,
               let estimate = SizeEstimate.make(versions: versions, fileId: chosenFileId) {
                parts.append(estimate.isRange
                    ? String(localized: "\(estimate.label) depending on server choice")
                    : estimate.label)
            }
            return parts.joined(separator: " · ")
        }

        private var footerLines: (warning: String?, note: String?, isEmpty: Bool) {
            var warning: String?
            if !isEmbyConversion, quality == DownloadFormat.original.rawValue {
                warning = SizeEstimate.make(versions: versions, fileId: chosenFileId)?
                    .warning(available: DeviceStorage.read().available)
            }
            let note = offered.count <= 1 ? DownloadScreens.originalOnlyNote : nil
            return (warning, note, warning == nil && note == nil)
        }

        private func keepChoiceValid() {
            if isEmbyConversion { chosenFileId = nil }
            if !offered.contains(where: { $0.rawValue == quality }) {
                quality = DownloadFormat.original.rawValue
            }
        }
    }
}

// MARK: - Choose Version

extension DownloadScreens {
    /// The options sheet's Choose Version page: editions, versions and what
    /// audio and subtitles come with the file.
    struct VersionPage: View {
        let versions: [FileVersion]
        let lastVersionFileId: Int?
        let storedQuality: String
        let isEmbyConversion: Bool
        @Binding var chosenFileId: Int?

        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Form {
                if editions.count > 1 {
                    Section {
                        ForEach(editions) { edition in
                            DownloadChoiceRow(
                                title: edition.label,
                                detail: String(localized: "\(edition.versions.count) versions"),
                                isSelected: edition.id == currentEdition?.id
                            ) {
                                chosenFileId = DetailVersionSelection.displayVersion(
                                    versions: edition.versions,
                                    selectedFileId: nil,
                                    lastFileId: lastVersionFileId,
                                    preferredQualityId: PlayerSettings.shared.preferredQuality
                                )?.fileId
                            }
                        }
                    } header: {
                        Text("Edition")
                    }
                    .disabled(isEmbyConversion)
                }
                if !versions.isEmpty {
                    versionSection
                }
                includedMediaSection
            }
            .navigationTitle("Choose Version")
            .navigationBarTitleDisplayMode(.inline)
            .vividScrollContentBackgroundHidden()
            .background(Color.clear)
        }

        private var versionSection: some View {
            Section {
                DownloadChoiceRow(
                    title: String(localized: "Auto"),
                    detail: autoDetail,
                    isSelected: chosenFileId == nil
                ) {
                    chosenFileId = nil
                    dismiss()
                }
                ForEach(versionRows, id: \.fileId) { row in
                    DownloadChoiceRow(
                        title: row.title,
                        detail: row.detail,
                        isSelected: chosenFileId == row.fileId
                    ) {
                        chosenFileId = row.fileId
                        dismiss()
                    }
                }
            } header: {
                Text("Version")
            } footer: {
                if isEmbyConversion {
                    Text("Emby chooses the source version when preparing a smaller download.")
                } else if let warning = sizeWarning {
                    Text(verbatim: warning)
                        .foregroundStyle(Color.orange)
                }
            }
            .disabled(isEmbyConversion)
        }

        private var includedMediaSection: some View {
            let media = includedMedia
            return Section {
                mediaRow("Audio", detail: media.audio)
                mediaRow("Subtitles", detail: media.subtitles)
            } header: {
                Text("Included Media")
            } footer: {
                Text("Audio and subtitles are chosen automatically for the selected file. Available subtitles are saved for offline playback.")
            }
        }

        private func mediaRow(_ title: LocalizedStringKey, detail: String) -> some View {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text(verbatim: detail)
                    .foregroundStyle(Color.vividSecondaryText)
                    .multilineTextAlignment(.trailing)
            }
        }

        // MARK: Derived

        private var editions: [PlaybackEditions.Edition] { PlaybackEditions.editions(from: versions) }

        private var effectiveVersion: FileVersion? {
            DetailVersionSelection.displayVersion(
                versions: versions,
                selectedFileId: chosenFileId,
                lastFileId: lastVersionFileId,
                preferredQualityId: PlayerSettings.shared.preferredQuality
            )
        }

        private var currentEdition: PlaybackEditions.Edition? {
            DetailPlaybackFormatting.currentEdition(versions: versions, currentVersion: effectiveVersion)
        }

        private var scopedVersions: [FileVersion] {
            guard editions.count > 1, let currentEdition else { return versions }
            return currentEdition.versions
        }

        private struct VersionRow {
            let fileId: Int
            let title: String
            let detail: String?
        }

        /// One row per version. Rows that would read the same get told apart
        /// by edition, file name or file id.
        private var versionRows: [VersionRow] {
            let plain = scopedVersions.map { version in
                (version, DetailPlaybackFormatting.versionPrimaryText(version), DetailPlaybackFormatting.versionSecondaryText(version))
            }
            var counts: [String: Int] = [:]
            for (_, title, detail) in plain {
                counts[Self.sameness(title, detail), default: 0] += 1
            }
            return plain.map { version, title, detail in
                guard counts[Self.sameness(title, detail), default: 0] > 1 else {
                    return VersionRow(fileId: version.fileId, title: title, detail: detail)
                }
                let marker = Self.disambiguator(for: version)
                let combined = detail.map { "\($0) · \(marker)" } ?? marker
                return VersionRow(fileId: version.fileId, title: title, detail: combined)
            }
        }

        private static func sameness(_ title: String, _ detail: String?) -> String {
            title + "\u{0}" + (detail ?? "")
        }

        private static func disambiguator(for version: FileVersion) -> String {
            let raw = version.editionRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let legacy = version.edition?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !raw.isEmpty || !legacy.isEmpty, version.editionDisplayLabel != "Standard" {
                return version.editionDisplayLabel
            }
            let fileName = version.fileName?
                .components(separatedBy: "/")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !fileName.isEmpty { return fileName }
            return String(localized: "File \(String(version.fileId))")
        }

        private var autoDetail: String {
            guard let estimate = SizeEstimate.make(versions: versions, fileId: nil) else {
                return String(localized: "Let the server choose the file")
            }
            return estimate.isRange
                ? String(localized: "\(estimate.label) depending on server choice")
                : String(localized: "\(estimate.label) · Let the server choose the file")
        }

        private var sizeWarning: String? {
            guard storedQuality == DownloadFormat.original.rawValue else { return nil }
            return SizeEstimate.make(versions: versions, fileId: chosenFileId)?
                .warning(available: DeviceStorage.read().available)
        }

        private var includedMedia: (audio: String, subtitles: String) {
            if storedQuality != DownloadFormat.original.rawValue {
                return (String(localized: "Prepared by the server"), String(localized: "Available tracks"))
            }
            guard let version = effectiveVersion else {
                return (String(localized: "File default"), String(localized: "Available tracks"))
            }
            return (
                DetailPlaybackFormatting.audioValueLabel(version: version, selectedAudioTrackIndex: nil),
                Self.subtitleSummary(version.subtitleTracks ?? [])
            )
        }

        /// "English, French, German +2 more", by language name.
        private static func subtitleSummary(_ tracks: [SubtitleTrack]) -> String {
            guard !tracks.isEmpty else { return String(localized: "None") }
            var seen = Set<String>()
            var names: [String] = []
            for track in tracks {
                let language = track.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !language.isEmpty else { continue }
                let name: String
                if language.count <= 3 {
                    let code = language.lowercased()
                    name = Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
                } else {
                    name = language
                }
                if seen.insert(name).inserted { names.append(name) }
            }
            guard !names.isEmpty else { return String(localized: "\(tracks.count) tracks") }
            let shown = names.prefix(3).joined(separator: ", ")
            guard names.count > 3 else { return shown }
            return String(localized: "\(shown) +\(names.count - 3) more")
        }
    }
}
#endif
