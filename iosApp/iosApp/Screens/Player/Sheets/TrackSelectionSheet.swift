#if os(iOS)
import SwiftUI

/// Scrollable audio, subtitle, and secondary-subtitle picker for iPhone and
/// iPad, presented in an anchored system popover with a scrollable inventory.
struct TrackSelectionSheet: View {
    let viewModel: PlayerViewModel
    enum Scope { case all, audio, subtitles }
    var scope: Scope = .all
    let onDismiss: () -> Void
    @State private var showOpenSubtitles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(scope == .audio ? "Audio" : scope == .subtitles ? "Subtitles" : "Audio & Subtitles")
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
                    if scope != .subtitles && !viewModel.audioTracks.isEmpty {
                        audioRows
                    }
                    if scope != .audio {
                        if OpenSubtitlesStore.shared.isConnected, viewModel.openSubtitleContext != nil {
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
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.visible)
        }
        .task { OpenSubtitlesStore.shared.reload() }
        .sheet(isPresented: $showOpenSubtitles) { OpenSubtitlesSearchView(viewModel: viewModel) }
    }

    @ViewBuilder
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
    private func subtitleRows(isSecondary: Bool) -> some View {
        let isOffSelected = isSecondary
            ? viewModel.selectedSecondarySubtitleId == nil
            : viewModel.selectedSubtitleId == nil

        TrackSelectionRow(
            name: "Off",
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

private struct TrackSelectionRow: View {
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
#endif
