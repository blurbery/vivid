#if !os(tvOS)
import SwiftUI

enum PhonePlaybackSelectorKind: String, Identifiable {
    case edition
    case version
    case audio
    case subtitles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edition: return "Edition"
        case .version: return "Version"
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        }
    }

    var icon: String {
        switch self {
        case .edition: return "rectangle.stack"
        case .version: return "square.stack"
        case .audio: return "speaker.wave.2"
        case .subtitles: return "captions.bubble"
        }
    }
}

/// Opaque, low-cost placeholder for the common version/audio/subtitle card.
/// It deliberately mirrors `PhonePlaybackSelectorRow`'s three 44pt rows so an
/// episode change never removes or inserts vertical space while networking.
struct PhonePlaybackSelectorSkeleton: View {
    static let standardHeight: CGFloat = 52

    private let kinds: [PhonePlaybackSelectorKind] = [.version, .audio, .subtitles]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(kinds) { kind in
                VStack(spacing: 5) {
                    Image(systemName: kind.icon).font(.system(size: 15, weight: .bold))
                    Text("—").font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity).frame(height: Self.standardHeight)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.25), lineWidth: 1) }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PhonePlaybackSelectorRow: View {
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void

    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    var body: some View {
        if currentVersion != nil, !selectorKinds.isEmpty {
            selectorCard
                .task { await ProfilePrefsStore.shared.hydrateIfNeeded() }
        }
    }

    private func selectorPresentation(
        for kind: PhonePlaybackSelectorKind
    ) -> PhonePlaybackSelectorOptions {
        PhonePlaybackSelectorOptions(
            kinds: [kind],
            versions: versions,
            currentVersion: currentVersion,
            selectedVersionFileId: selectedVersionFileId,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            onSelectVersion: onSelectVersion,
            onSelectAudioTrack: onSelectAudioTrack,
            onSelectSubtitleTrack: onSelectSubtitleTrack
        )
    }

    /// Settings-style rows: icon and label lead, value trails, chevron last.
    ///
    /// Replaced a two-column `LazyVGrid` that stranded the third selector
    /// alone in the leading column, so the common version / audio /
    /// subtitles case always read as a broken form. A horizontally
    /// scrollable chip strip was tried first and was worse: three chips need
    /// more width than a phone has, so subtitles fell off the edge entirely
    /// and the most-hunted control became the invisible one. Rows never
    /// truncate, never go ragged, and absorb a fourth edition picker by
    /// simply growing.
    private var selectorCard: some View {
        HStack(spacing: 6) {
            ForEach(selectorKinds) { kind in
                selectorButton(kind) {
                    VStack(spacing: 5) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 15, weight: .bold))
                        Text(value(for: kind))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    /// Wraps a layout's row/column in a button when that selector can
    /// actually be changed, and leaves it inert when it cannot.
    @ViewBuilder
    private func selectorButton<Content: View>(
        _ kind: PhonePlaybackSelectorKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isInteractive(kind) {
            Menu { selectorPresentation(for: kind) } label: { content() }
                .menuOrder(.fixed)
                .buttonStyle(.plain)
                .accessibilityLabel("\(kind.title), \(value(for: kind))")
        } else {
            content()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(kind.title), \(value(for: kind))")
        }
    }

    private var selectorKinds: [PhonePlaybackSelectorKind] {
        var kinds: [PhonePlaybackSelectorKind] = []
        if shouldShowEditionSelector {
            kinds.append(.edition)
        }
        if shouldShowVersionValue {
            kinds.append(.version)
        }
        if shouldShowAudioValue {
            kinds.append(.audio)
        }
        if shouldShowSubtitleValue {
            kinds.append(.subtitles)
        }
        return kinds
    }

    private var shouldShowEditionSelector: Bool {
        editions.count > 1
    }

    private var shouldShowVersionValue: Bool {
        currentVersion != nil
    }

    private var shouldEnableVersionSelector: Bool {
        DetailPlaybackFormatting.shouldEnableVersionSelector(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    private var shouldShowAudioValue: Bool {
        DetailPlaybackFormatting.shouldShowAudioValue(version: currentVersion)
    }

    private var shouldEnableAudioSelector: Bool {
        DetailPlaybackFormatting.shouldEnableAudioSelector(version: currentVersion)
    }

    private var shouldShowSubtitleValue: Bool {
        DetailPlaybackFormatting.shouldShowSubtitleValue(version: currentVersion)
    }

    private var shouldEnableSubtitleSelector: Bool {
        DetailPlaybackFormatting.shouldEnableSubtitleSelector(version: currentVersion)
    }

    private func isInteractive(_ kind: PhonePlaybackSelectorKind) -> Bool {
        switch kind {
        case .edition:
            return shouldShowEditionSelector
        case .version:
            return shouldEnableVersionSelector
        case .audio:
            return shouldEnableAudioSelector
        case .subtitles:
            return shouldEnableSubtitleSelector
        }
    }

    private func value(for kind: PhonePlaybackSelectorKind) -> String {
        switch kind {
        case .edition:
            return DetailPlaybackFormatting.currentEdition(
                versions: versions,
                currentVersion: currentVersion
            )?.label ?? currentVersion?.editionDisplayLabel ?? "Standard"
        case .version:
            return DetailPlaybackFormatting.mobileVersionSummary(currentVersion)
        case .audio:
            return DetailPlaybackFormatting.audioTechnicalSummary(version: currentVersion, selectedAudioTrackIndex: selectedAudioTrackIndex) ?? "Auto"
        case .subtitles:
            return DetailPlaybackFormatting.subtitleLanguageSummary(
                version: currentVersion,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                autoContext: .init()
            )
        }
    }
}
private struct PhonePlaybackSelectorOptions: View {
    /// One entry when opened from a single control, all of them when opened
    /// from the `.summary` row.
    let kinds: [PhonePlaybackSelectorKind]
    let versions: [FileVersion]
    let currentVersion: FileVersion?
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void


    private var editions: [PlaybackEditions.Edition] {
        PlaybackEditions.editions(from: versions)
    }

    private var currentEdition: PlaybackEditions.Edition? {
        DetailPlaybackFormatting.currentEdition(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    var body: some View { optionContent }

    @ViewBuilder
    private var optionContent: some View {
        ForEach(kinds) { kind in
            switch kind {
            case .edition:
                editionOptions
            case .version:
                versionOptions
            case .audio:
                audioOptions
            case .subtitles:
                subtitleOptions
            }
        }
    }

    /// Section headers only earn their space when the sheet holds more than
    /// one selector; a single-selector sheet already says so in its title.
    @ViewBuilder
    private func sectionHeader(_ kind: PhonePlaybackSelectorKind) -> some View {
        if kinds.count > 1 {
            Text(kind.title)
        }
    }

    @ViewBuilder
    private var editionOptions: some View {
        Section {
            if editions.isEmpty {
                optionButton(title: "Standard", detail: nil, isSelected: true, isEnabled: false) {}
            } else {
                ForEach(editions) { edition in
                    optionButton(
                        title: edition.label,
                        detail: "\(edition.versions.count) version\(edition.versions.count == 1 ? "" : "s")",
                        isSelected: currentEdition?.id == edition.id
                    ) {
                        let best = DetailVersionSelection.displayVersion(
                            versions: edition.versions,
                            selectedFileId: nil,
                            lastFileId: nil,
                            preferredQualityId: PlayerSettings.shared.preferredQuality
                        )
                        onSelectVersion(best?.fileId)
                    }
                }
            }
        } header: {
            sectionHeader(.edition)
        }
    }

    @ViewBuilder
    private var versionOptions: some View {
        Section {
            optionButton(
                title: "Auto",
                detail: "Best match for this device",
                isSelected: selectedVersionFileId == nil
            ) {
                onSelectVersion(nil)
            }
            ForEach(scopedVersions) { version in
                optionButton(
                    title: DetailPlaybackFormatting.versionPrimaryText(version),
                    detail: DetailPlaybackFormatting.versionSecondaryText(version),
                    isSelected: selectedVersionFileId == version.fileId
                ) {
                    onSelectVersion(version.fileId)
                    }
            }
        } header: {
            sectionHeader(.version)
        }
    }

    private var scopedVersions: [FileVersion] {
        DetailPlaybackFormatting.versionSelectorVersions(
            versions: versions,
            currentVersion: currentVersion
        )
    }

    @ViewBuilder
    private var audioOptions: some View {
        Section {
            optionButton(
                title: "Auto",
                detail: "Use the file default track",
                isSelected: selectedAudioTrackIndex == nil
            ) {
                onSelectAudioTrack(nil)
            }
            let options = DetailPlaybackFormatting.audioOptions(
                version: currentVersion,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            )
            if options.isEmpty {
                optionButton(title: "Unknown", detail: "No audio metadata", isSelected: false, isEnabled: false) {}
            } else {
                ForEach(options) { option in
                    optionButton(
                        title: option.title,
                        detail: option.detail,
                        isSelected: selectedAudioTrackIndex == option.ordinal
                    ) {
                        onSelectAudioTrack(option.ordinal)
                    }
                }
            }
        } header: {
            sectionHeader(.audio)
        }
    }

    @ViewBuilder
    private var subtitleOptions: some View {
        Section {
            optionButton(
                title: "Auto",
                detail: "Use your subtitle preferences",
                isSelected: selectedSubtitleTrackIndex == nil
            ) {
                onSelectSubtitleTrack(nil)
            }
            optionButton(
                title: "Off",
                detail: "Start without subtitles",
                isSelected: selectedSubtitleTrackIndex == -1
            ) {
                onSelectSubtitleTrack(-1)
            }
            ForEach(DetailPlaybackFormatting.subtitleOptions(
                version: currentVersion,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                preferredLanguage: ProfilePrefsStore.shared.preferredSubtitleLanguage
            )) { option in
                optionButton(
                    title: option.title,
                    detail: option.detail,
                    isSelected: option.isSelected,
                    isEnabled: option.isSelectable
                ) {
                    if let selectionIndex = option.selectionIndex {
                        onSelectSubtitleTrack(selectionIndex)
                    }
                }
            }
        } header: {
            sectionHeader(.subtitles)
        }
    }

    @ViewBuilder
    private func optionButton(
        title: String,
        detail: String?,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            let label = [title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if isSelected { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
        .disabled(!isEnabled)
    }
}
#endif
