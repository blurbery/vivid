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
            Picker("Quality", selection: Binding(
                get: { viewModel.preferredQualityPresetId ?? Self.customPresetTag },
                set: { newValue in
                    guard newValue != Self.customPresetTag else { return }
                    Task { await viewModel.setQualityPreset(newValue) }
                }
            )) {
                // A pair no preset covers — set through the API, or written by
                // a client whose ladder has a rung this table does not — gets
                // its own disabled entry describing what is actually stored,
                // rather than the picker showing a preset the user never chose.
                if viewModel.preferredQualityPresetId == nil {
                    Text(viewModel.preferredQualityLabel)
                        .tag(Self.customPresetTag)
                }
                ForEach(VividQualityPresets.all) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Audio Language", selection: Binding(
                get: { viewModel.preferredAudioLanguage },
                set: { newValue in
                    viewModel.preferredAudioLanguage = newValue
                    Task { await viewModel.setPreferredAudioLanguage(newValue) }
                }
            )) {
                Text(
                    SettingPresentationMetadata.definitions[.playbackAudioLanguage]?.unsetLabel
                        ?? "No preference"
                ).tag("")
                ForEach(viewModel.audioLanguageOptions) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Buffer Ahead", selection: Binding(
                get: { viewModel.bufferAhead },
                set: { newValue in
                    viewModel.bufferAhead = newValue
                    Task { await viewModel.setBufferAhead(newValue) }
                }
            )) {
                ForEach(BufferAheadMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

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
        .listRowBackground(Color.vividSurfaceElevated)
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

            Picker("Show Next Up", selection: Binding(
                get: { viewModel.nextUpPromptSeconds },
                set: { newValue in
                    viewModel.nextUpPromptSeconds = newValue
                    Task { await viewModel.setNextUpPromptSeconds(newValue) }
                }
            )) {
                ForEach(nextUpPromptOptions, id: \.0) { seconds, label in
                    Text(label).tag(seconds)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Toggle(isOn: Binding(
                get: { PlayerSettings.shared.introDBEnabled },
                set: { PlayerSettings.shared.introDBEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IntroDB")
                    Text("Toggle on for native intro & credit skips.")
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
                    Text("Auto-Skip Intros")
                    Text("Automatically skip intros when IntroDB has timestamps.")
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
                    Text("Automatically skip credits when IntroDB has timestamps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            .tint(.green)
            .disabled(!PlayerSettings.shared.introDBEnabled)
        } header: {
            PhoneSettingsSectionHeader("Episodes")
        }
        .listRowBackground(Color.vividSurfaceElevated)
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button("Reset Playback Settings", role: .destructive) {
                Task { await viewModel.resetPlaybackDeviceSettings() }
            }
        } footer: {
            Text("Restores Vivid’s playback defaults for this device and profile.")
                .foregroundStyle(Color.vividSecondaryText)
        }
        .listRowBackground(Color.vividSurfaceElevated)
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
#endif
