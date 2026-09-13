#if os(tvOS)
import SwiftUI

/// Playback preferences with native option menus.
struct TVPlaybackSettingsPane: View {
    @Bindable var viewModel: TVSettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            streamingSection
            episodesSection
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var streamingSection: some View {
        TVSettingsSectionHeader("PLAYBACK")

        TVSettingsGroup {
            TVSettingsOptionMenu(
                title: "Quality",
                value: viewModel.preferredQualityLabel,
                options: pickerRequest(for: .quality).options,
                selection: pickerRequest(for: .quality).selection
            )
            .focused(detailFocus, equals: .top)

            TVSettingsOptionMenu(
                title: "Audio Language",
                value: TVSettingsOptions.label(
                    for: viewModel.preferredAudioLanguage,
                    in: TVSettingsOptions.audioLanguage(viewModel.audioLanguageOptions)
                ),
                options: pickerRequest(for: .audioLanguage).options,
                selection: pickerRequest(for: .audioLanguage).selection
            )
            .focused(detailFocus, equals: .playbackAudioLanguage)

            TVSettingsOptionMenu(
                title: "Buffer Ahead",
                value: viewModel.bufferAhead.label,
                options: pickerRequest(for: .bufferAhead).options,
                selection: pickerRequest(for: .bufferAhead).selection
            )
            .focused(detailFocus, equals: .playbackBufferAhead)

            TVSettingsToggleRow(
                title: "Prefer Lossless Audio",
                isOn: PlayerSettings.shared.preferLosslessAudio,
                detail: "Requires multichannel PCM for surround; some TV or ARC connections output stereo. Applies to the next video."
            ) {
                PlayerSettings.shared.preferLosslessAudio.toggle()
            }
            .accessibilityIdentifier("settings.playback.preferLosslessAudio")

        }
        TVSettingsFooter("Preferences are saved in Vivid for this profile on this Apple TV.")
    }

    @ViewBuilder
    private var episodesSection: some View {
        TVSettingsSectionHeader("EPISODES")

        TVSettingsGroup {
            TVSettingsToggleRow(
                title: "Auto-Play Next Episode",
                isOn: viewModel.autoPlayNext
            ) {
                let value = !viewModel.autoPlayNext
                viewModel.autoPlayNext = value
                Task { await viewModel.setAutoPlayNext(value) }
            }

            TVSettingsOptionMenu(
                title: "Show Next Up",
                value: TVSettingsOptions.label(for: String(viewModel.nextUpPromptSeconds), in: TVSettingsOptions.nextUpPrompt),
                options: pickerRequest(for: .nextUpPrompt).options,
                selection: pickerRequest(for: .nextUpPrompt).selection
            )
            .focused(detailFocus, equals: .playbackNextUpPrompt)

            TVSettingsToggleRow(
                title: "Intro & Credit Skipper",
                isOn: PlayerSettings.shared.introDBEnabled,
                detail: "Show intro and credit skip prompts when timestamps are available."
            ) {
                PlayerSettings.shared.introDBEnabled.toggle()
            }

            TVSettingsToggleRow(
                title: "Auto-Skip Intros & Recaps",
                isOn: viewModel.skipIntros
            ) {
                let value = !viewModel.skipIntros
                viewModel.skipIntros = value
                Task { await viewModel.setSkipIntros(value) }
            }
            .disabled(!PlayerSettings.shared.introDBEnabled)

            TVSettingsToggleRow(
                title: "Auto-Skip Credits",
                isOn: viewModel.skipCredits
            ) {
                let value = !viewModel.skipCredits
                viewModel.skipCredits = value
                Task { await viewModel.setSkipCredits(value) }
            }
            .disabled(!PlayerSettings.shared.introDBEnabled)
        }
    }

    // MARK: - Pickers

    private func pickerRequest(for kind: PickerKind) -> TVSettingsPickerRequest {
        switch kind {
        case .quality:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Quality",
                options: TVSettingsOptions.quality(
                    // A stored pair no preset covers gets its own entry
                    // describing what is actually stored, so the sheet never
                    // highlights a preset the user did not choose.
                    including: !VividQualityPresets.selectable.contains(where: { $0.id == viewModel.preferredQualityPresetId })
                        ? viewModel.preferredQualityLabel
                        : nil
                ),
                selection: Binding(
                    get: {
                        VividQualityPresets.selectable.first(where: { $0.id == viewModel.preferredQualityPresetId })?.id
                            ?? TVSettingsOptions.customQualityId
                    },
                    set: { value in
                        guard value != TVSettingsOptions.customQualityId else { return }
                        Task { await viewModel.setQualityPreset(value) }
                    }
                )
            )
        case .audioLanguage:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Audio Language",
                options: TVSettingsOptions.audioLanguage(viewModel.audioLanguageOptions),
                selection: Binding(
                    get: { viewModel.preferredAudioLanguage },
                    set: { value in
                        viewModel.preferredAudioLanguage = value
                        Task { await viewModel.setPreferredAudioLanguage(value) }
                    }
                )
            )
        case .bufferAhead:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Buffer Ahead",
                options: TVSettingsOptions.bufferAhead,
                selection: Binding(
                    get: { viewModel.bufferAhead.rawValue },
                    set: { value in
                        guard let mode = BufferAheadMode(rawValue: value) else { return }
                        viewModel.bufferAhead = mode
                        Task { await viewModel.setBufferAhead(mode) }
                    }
                )
            )
        case .nextUpPrompt:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Show Next Up",
                options: TVSettingsOptions.nextUpPrompt,
                selection: Binding(
                    get: { String(viewModel.nextUpPromptSeconds) },
                    set: { value in
                        guard let seconds = Int(value) else { return }
                        viewModel.nextUpPromptSeconds = seconds
                        Task { await viewModel.setNextUpPromptSeconds(seconds) }
                    }
                )
            )
        }
    }

    enum PickerKind: String, Identifiable {
        case quality
        case audioLanguage
        case bufferAhead
        case nextUpPrompt

        var id: String { rawValue }
    }
}
#endif
