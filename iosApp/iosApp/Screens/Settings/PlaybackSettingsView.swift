#if !os(tvOS)
import SwiftUI

/// Playback preferences sub-screen — a native grouped list in the
/// style of the iOS Settings app: plain rows, navigation-link pickers,
/// and footers for the fine print.
struct PlaybackSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        List {
            SettingsPageHeader(
                title: "Playback",
                subtitle: "Playback, buffering, and episode preferences saved on this device.",
                systemImage: "play.rectangle"
            )
            .settingsPageHeaderRow()

            streamingSection
            audioSection
            behaviorSection
            resetSection
        }
        .settingsListChrome()
        .navigationTitle("")
        .vividNavigationTitleDisplayMode(.inline)
        .vividToolbarColorSchemeDark()
    }

    // MARK: - Streaming

    private var streamingSection: some View {
        Section {
            NavigationLink {
                qualityChoices
            } label: {
                LabeledContent("Quality", value: viewModel.preferredQualityLabel)
            }
            .foregroundStyle(Color.vividOnSurface)

            LabeledContent("Buffer Ahead", value: "Automatic")
                .foregroundStyle(Color.vividOnSurface)

            Text(BufferAheadMode.explanation)
                .font(.footnote)
                .foregroundStyle(Color.vividSecondaryText)

            #if os(iOS)
            Toggle("Background Playback", isOn: Binding(
                get: { viewModel.backgroundPlaybackEnabled },
                set: { enabled in
                    viewModel.backgroundPlaybackEnabled = enabled
                    Task { await viewModel.setBackgroundPlaybackEnabled(enabled) }
                }
            ))
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)
            #endif
        } header: {
            PhoneSettingsSectionHeader("Streaming")

        }

    }

    // MARK: - Audio

    private var audioSection: some View {
        Section {
            NavigationLink {
                audioLanguageChoices
            } label: {
                LabeledContent("Audio Language", value: audioLanguageLabel)
            }
            .foregroundStyle(Color.vividOnSurface)

            Toggle(isOn: Binding(
                get: { viewModel.volumeBoostEnabled },
                set: { enabled in
                    viewModel.volumeBoostEnabled = enabled
                    Task { await viewModel.setVolumeBoostEnabled(enabled) }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume Boost")
                    Text("Play louder than Vivid’s standard volume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)

            NavigationLink {
                boostLevelChoices
            } label: {
                LabeledContent("Boost Level", value: "\(viewModel.volumeBoostPercent)%")
            }
            .foregroundStyle(Color.vividOnSurface)
            .disabled(!viewModel.volumeBoostEnabled)

            Toggle(isOn: Binding(
                get: { viewModel.enhancedDialogueEnabled },
                set: { enabled in
                    viewModel.enhancedDialogueEnabled = enabled
                    Task { await viewModel.setEnhancedDialogueEnabled(enabled) }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enhanced Dialogue")
                    Text("Lower music and effects so voices are easier to hear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)
        } header: {
            PhoneSettingsSectionHeader("Audio")
        } footer: {
            Text("Changes apply the next time a video starts. While Volume Boost or Enhanced Dialogue is on, Dolby Atmos plays as standard surround sound, and the loudest moments can distort at higher boost levels.")
                .foregroundStyle(Color.vividSecondaryText)
        }
    }

    private var audioLanguageUnsetLabel: String {
        SettingPresentationMetadata.definitions[.playbackAudioLanguage]?.unsetLabel ?? "No preference"
    }

    private var audioLanguageLabel: String {
        viewModel.audioLanguageOptions.first { $0.code == viewModel.preferredAudioLanguage }?.label
            ?? audioLanguageUnsetLabel
    }

    private var audioLanguageChoices: some View {
        PlaybackOptionPage<String>(
            title: "Audio Language",
            options: [.init(value: "", label: audioLanguageUnsetLabel)]
                + viewModel.audioLanguageOptions.map { .init(value: $0.code, label: $0.label) },
            selection: Binding(
                get: { viewModel.preferredAudioLanguage },
                set: { newValue in
                    viewModel.preferredAudioLanguage = newValue
                    Task { await viewModel.setPreferredAudioLanguage(newValue) }
                }
            )
        )
    }

    private var boostLevelChoices: some View {
        PlaybackOptionPage<Int>(
            title: "Boost Level",
            options: VividAudioEnhancement.boostLevels.map { .init(value: $0, label: "\($0)%") },
            selection: Binding(
                get: { viewModel.volumeBoostPercent },
                set: { percent in
                    viewModel.volumeBoostPercent = percent
                    Task { await viewModel.setVolumeBoostPercent(percent) }
                }
            )
        )
    }

    private var nextUpPromptLabel: String {
        nextUpPromptOptions.first { $0.0 == viewModel.nextUpPromptSeconds }?.1
            ?? "\(viewModel.nextUpPromptSeconds) seconds before end"
    }

    private var nextUpPromptChoices: some View {
        PlaybackOptionPage<Int>(
            title: "Show Next Up",
            options: nextUpPromptOptions.map { .init(value: $0.0, label: $0.1) },
            selection: Binding(
                get: { viewModel.nextUpPromptSeconds },
                set: { newValue in
                    viewModel.nextUpPromptSeconds = newValue
                    Task { await viewModel.setNextUpPromptSeconds(newValue) }
                }
            )
        )
    }

    private var qualityChoices: some View {
        List {
            Picker("Quality", selection: Binding(
                get: {
                    VividQualityPresets.selectable.first(where: { $0.id == viewModel.preferredQualityPresetId })?.id
                        ?? Self.customPresetTag
                },
                set: { newValue in
                    guard newValue != Self.customPresetTag else { return }
                    Task { await viewModel.setQualityPreset(newValue) }
                }
            )) {
                if !VividQualityPresets.selectable.contains(where: { $0.id == viewModel.preferredQualityPresetId }) {
                    Text(viewModel.preferredQualityLabel).tag(Self.customPresetTag).disabled(true)
                }
                ForEach(VividQualityPresets.selectable) { preset in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.menuLabel)
                        Text(preset.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .tag(preset.id)
                }
            }
            .pickerStyle(.inline)
            .foregroundStyle(Color.vividOnSurface)

        }
        .settingsListChrome()
        .navigationTitle("Quality")
        .vividNavigationTitleDisplayMode(.inline)
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            Toggle("Auto-Play Next Episode", isOn: Binding(
                get: { viewModel.autoPlayNext },
                set: { enabled in
                    viewModel.autoPlayNext = enabled
                    Task { await viewModel.setAutoPlayNext(enabled) }
                }
            ))
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)

            NavigationLink {
                nextUpPromptChoices
            } label: {
                LabeledContent("Show Next Up", value: nextUpPromptLabel)
            }
            .foregroundStyle(Color.vividOnSurface)

            Toggle(isOn: Binding(
                get: { PlayerSettings.shared.introDBEnabled },
                set: { PlayerSettings.shared.introDBEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Intro & Credit Skipper")
                    Text("Show intro and credit skip prompts when timestamps are available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)

            Toggle(isOn: Binding(
                get: { viewModel.skipIntros },
                set: { enabled in
                    viewModel.skipIntros = enabled
                    Task { await viewModel.setSkipIntros(enabled) }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-Skip Intros & Recaps")
                    Text("Automatically skip intros and recaps when timestamps are available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)
            .disabled(!PlayerSettings.shared.introDBEnabled)

            Toggle(isOn: Binding(
                get: { viewModel.skipCredits },
                set: { enabled in
                    viewModel.skipCredits = enabled
                    Task { await viewModel.setSkipCredits(enabled) }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-Skip Credits")
                    Text("Automatically skip credits when timestamps are available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)
            .disabled(!PlayerSettings.shared.introDBEnabled)

            Toggle(isOn: Binding(
                get: { PlayerSettings.shared.hideFutureEpisodeSpoilers },
                set: { PlayerSettings.shared.hideFutureEpisodeSpoilers = $0 }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hide Episode Spoilers")
                    Text("Blur the preview and scramble the description of episodes you haven’t reached yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)
        } header: {
            PhoneSettingsSectionHeader("Episodes")
        }

    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await viewModel.resetPlaybackDeviceSettings() }
            } label: {
                Text("Reset Playback Settings")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } footer: {
            Text("Restores Vivid’s playback defaults for this device and profile.")
                .foregroundStyle(Color.vividSecondaryText)
        }

    }

    // MARK: - Options

    /// Tag for the "stored pair matches no preset" entry. Not a preset id, so
    /// selecting it is a no-op rather than a write.
    private static let customPresetTag = "__custom__"

    private var nextUpPromptOptions: [(Int, String)] {
        [
            (0, "At end"),
            (10, "10 seconds before end"),
            (30, "30 seconds before end"),
            (60, "1 minute before end"),
            (120, "2 minutes before end"),
        ]
    }
}

/// A single-choice page in the Settings theme, like Quality. Choosing an
/// option goes back to Playback, as the system navigation-link picker did.
private struct PlaybackOptionPage<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    private let title: Text
    let options: [Option]
    @Binding var selection: Value
    @Environment(\.dismiss) private var dismiss

    init(title: LocalizedStringKey, options: [Option], selection: Binding<Value>) {
        self.title = Text(title)
        self.options = options
        self._selection = selection
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, options: [Option], selection: Binding<Value>) {
        self.title = Text(title)
        self.options = options
        self._selection = selection
    }

    var body: some View {
        List {
            Picker(selection: Binding(
                get: { selection },
                set: { newValue in
                    selection = newValue
                    dismiss()
                }
            )) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                title
            }
            .pickerStyle(.inline)
            .foregroundStyle(Color.vividOnSurface)
        }
        .settingsListChrome()
        .navigationTitle(title)
        .vividNavigationTitleDisplayMode(.inline)
    }
}
#endif
