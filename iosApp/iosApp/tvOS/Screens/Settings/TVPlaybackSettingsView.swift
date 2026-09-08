#if os(tvOS)
import SwiftUI

/// Playback pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`. The root view owns modal picker
/// presentation so only one focus graph is active at a time.
struct TVPlaybackSettingsPane: View {
    @Bindable var viewModel: TVSettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    let presentPicker: (TVSettingsPickerRequest) -> Void

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
            TVSettingsPickerRow(
                title: "Quality",
                value: viewModel.preferredQualityLabel
            ) { showPicker(.quality) }
            .focused(detailFocus, equals: .top)

            TVSettingsPickerRow(
                title: "Audio Language",
                value: TVSettingsOptions.label(
                    for: viewModel.preferredAudioLanguage,
                    in: TVSettingsOptions.audioLanguage(viewModel.audioLanguageOptions)
                )
            ) { showPicker(.audioLanguage) }
            .focused(detailFocus, equals: .playbackAudioLanguage)

            TVSettingsPickerRow(
                title: "Buffer Ahead",
                value: viewModel.bufferAhead.label
            ) { showPicker(.bufferAhead) }
            .focused(detailFocus, equals: .playbackBufferAhead)

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

            TVSettingsPickerRow(
                title: "Show Next Up",
                value: TVSettingsOptions.label(for: String(viewModel.nextUpPromptSeconds), in: TVSettingsOptions.nextUpPrompt)
            ) { showPicker(.nextUpPrompt) }
            .focused(detailFocus, equals: .playbackNextUpPrompt)

            TVSettingsToggleRow(
                title: "IntroDB",
                isOn: PlayerSettings.shared.introDBEnabled,
                detail: "Toggle on for native intro & credit skips."
            ) {
                PlayerSettings.shared.introDBEnabled.toggle()
            }

            TVSettingsToggleRow(
                title: "Auto-Skip Intros",
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

    private func showPicker(_ kind: PickerKind) {
        presentPicker(pickerRequest(for: kind))
    }

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
                ),
                returnFocus: .top
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
                ),
                returnFocus: .playbackAudioLanguage
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
                ),
                returnFocus: .playbackBufferAhead
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
                ),
                returnFocus: .playbackNextUpPrompt
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
