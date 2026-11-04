import SwiftUI

#if os(iOS)

/// The audio or subtitle list in the player's anchored popover on iPhone and
/// iPad. The subtitle list also offers OpenSubtitles search when the plugin
/// can search for this title, and secondary subtitles when the route
/// supports them and a main subtitle is on. Choosing a row closes the popover.
struct TrackSelectionSheet: View {
    enum Scope { case audio, subtitles }

    let viewModel: PlayerViewModel
    let scope: Scope
    let onDismiss: () -> Void
    @State private var showOpenSubtitles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(scope == .audio ? "Audio" : "Subtitles")
                    .font(.headline)
                if scope == .subtitles {
                    Text("Available subtitle tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch scope {
                    case .audio:
                        if !viewModel.audioTracks.isEmpty {
                            audioRows
                        }
                    case .subtitles:
                        subtitleList
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.visible)
        }
        .task { OpenSubtitlesStore.shared.reload() }
        .sheet(isPresented: $showOpenSubtitles) {
            OpenSubtitlesSearchView(viewModel: viewModel)
                .vividGlassSheet(startsTall: true, overVideo: true)
        }
    }

    private var audioRows: some View {
        ForEach(viewModel.audioTracks) { track in
            TrackSelectionRow(
                name: track.primaryLabel,
                attributes: track.attributesLabel,
                pills: track.attributePillLabels,
                isSelected: viewModel.selectedAudioId == track.trackId
            ) {
                viewModel.selectAudio(track)
                onDismiss()
            }
        }
    }

    @ViewBuilder
    private var subtitleList: some View {
        if viewModel.openSubtitleContext != nil {
            Button("Find on OpenSubtitles") { showOpenSubtitles = true }.padding(.vertical, 12)
        }
        subtitleRows(isSecondary: false)
        if viewModel.orderedSubtitleTracks.isEmpty {
            Text("This media file has no embedded subtitles.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
        if viewModel.supportsSecondarySubtitles,
           viewModel.selectedSubtitleId != nil,
           !viewModel.availableSecondarySubtitleTracks.isEmpty {
            DisclosureGroup("Secondary Subtitles") {
                subtitleRows(isSecondary: true)
            }
            .padding(.vertical, 12)
        }
    }

    /// Off, then the tracks. A secondary list greys out the main subtitle.
    @ViewBuilder
    private func subtitleRows(isSecondary: Bool) -> some View {
        let isOffSelected = isSecondary
            ? viewModel.selectedSecondarySubtitleId == nil
            : viewModel.selectedSubtitleId == nil

        TrackSelectionRow(
            name: String(localized: "Off"),
            attributes: nil,
            isSelected: isOffSelected
        ) {
            if isSecondary {
                viewModel.disableSecondarySubtitles()
            } else {
                viewModel.disableSubtitles()
            }
            onDismiss()
        }

        ForEach(
            isSecondary
                ? viewModel.availableSecondarySubtitleTracks
                : viewModel.orderedSubtitleTracks
        ) { track in
            let isSelected = isSecondary
                ? viewModel.selectedSecondarySubtitleId == track.trackId
                : viewModel.selectedSubtitleId == track.trackId
            let isDisabled = isSecondary && viewModel.selectedSubtitleId == track.trackId
            let pills = track.attributePillLabels(
                includeLanguage: track.normalizedLanguageCode == nil
            )

            TrackSelectionRow(
                name: track.languageFirstPrimaryLabel,
                detail: track.languageFirstDetailLabel,
                attributes: pills.isEmpty ? nil : pills.joined(separator: " · "),
                pills: pills,
                isSelected: isSelected,
                isDisabled: isDisabled
            ) {
                if isSecondary {
                    viewModel.selectSecondarySubtitle(track)
                } else {
                    viewModel.selectSubtitle(track)
                }
                onDismiss()
            }
        }
    }
}

#endif

/// One row in a track list: the name, an optional detail line, then the
/// attribute pills (or a plain attributes line), with a tick when selected.
/// OpenSubtitles' result list uses it too.
struct TrackSelectionRow: View {
    let name: String
    var detail: String? = nil
    let attributes: String?
    var pills: [String] = []
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !pills.isEmpty {
                        pillRow
                    } else if let attributes {
                        Text(attributes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .frame(minHeight: 44)
            .padding(.vertical, 8)
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }

    private var pillRow: some View {
        HStack(spacing: 4) {
            ForEach(pills, id: \.self) { pill in
                Text(pill.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                    )
            }
        }
    }
}
