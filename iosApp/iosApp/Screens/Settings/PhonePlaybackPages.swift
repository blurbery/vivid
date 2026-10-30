#if os(iOS)
import SwiftUI

extension SettingsView {
    /// Settings > Playback: quality, audio and episode behaviour for this
    /// device and profile.
    struct PlaybackPage: View {
        let model: SettingsViewModel
        @State private var player = PlayerSettings.shared

        private var audioUnsetLabel: String {
            SettingPresentationMetadata.definitions[.playbackAudioLanguage]?.displayUnsetLabel ?? String(localized: "No preference")
        }

        private var audioOptions: [(value: String, label: String)] {
            [("", audioUnsetLabel)] + model.audioLanguageOptions.map { ($0.code, $0.label) }
        }

        private var boostOptions: [(value: Int, label: String)] {
            VividAudioEnhancement.boostLevels.map { ($0, Self.percent($0)) }
        }

        private static func percent(_ level: Int) -> String {
            (Double(level) / 100).formatted(.percent)
        }

        private static var nextUpOptions: [(value: Int, label: String)] {
            [
                (0, String(localized: "At end")),
                (10, String(localized: "10 seconds before end")),
                (30, String(localized: "30 seconds before end")),
                (60, String(localized: "1 minute before end")),
                (120, String(localized: "2 minutes before end")),
            ]
        }

        private var nextUpLabel: String {
            let seconds = model.nextUpPromptSeconds
            return Self.nextUpOptions.first { $0.value == seconds }?.label
                ?? String(localized: "\(seconds) seconds before end")
        }

        var body: some View {
            List {
                SettingsPageHeader(title: "Playback", subtitle: "Playback, buffering, and episode preferences saved on this device.",
                                   systemImage: "play.rectangle")
                    .settingsPageHeaderRow()
                streamingSection
                audioSection
                episodesSection
                Section {
                    Button(role: .destructive) {
                        Task { await model.resetPlaybackSettings() }
                    } label: {
                        Text("Reset Playback Settings").frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Restores Vivid’s playback defaults for this device and profile.")
                        .foregroundStyle(Color.vividSecondaryText)
                }
            }
            .settingsListChrome()
            .navigationTitle("")
            .vividNavigationTitleDisplayMode(.inline)
            .vividToolbarColorSchemeDark()
        }

        private var streamingSection: some View {
            Section {
                NavigationLink { QualityPage(model: model) } label: {
                    LabeledContent("Quality", value: model.qualityLabel)
                }
                .foregroundStyle(Color.vividOnSurface)
                LabeledContent("Buffer Ahead") { Text("Automatic") }
                    .foregroundStyle(Color.vividOnSurface)
                Text(BufferAheadMode.explanation)
                    .font(.footnote)
                    .foregroundStyle(Color.vividSecondaryText)
                Toggle("Background Playback", isOn: live(\.backgroundPlaybackEnabled, model.setBackgroundPlaybackEnabled))
                    .foregroundStyle(Color.vividOnSurface)
            } header: { PhoneSettingsSectionHeader("Streaming") }
        }

        private var audioSection: some View {
            Section {
                NavigationLink {
                    OptionPage(title: "Audio Language", options: audioOptions, selection: model.audioLanguage) { code in
                        model.audioLanguage = code
                        Task { model.setAudioLanguage(code) }
                    }
                } label: {
                    LabeledContent("Audio Language",
                                   value: audioOptions.first { $0.value == model.audioLanguage }?.label ?? audioUnsetLabel)
                }
                .foregroundStyle(Color.vividOnSurface)
                Toggle(isOn: live(\.volumeBoostEnabled, model.setVolumeBoostEnabled)) {
                    described("Volume Boost", "Play louder than Vivid’s standard volume.")
                }
                .foregroundStyle(Color.vividOnSurface)
                NavigationLink {
                    OptionPage(title: "Boost Level", options: boostOptions, selection: model.volumeBoostPercent) { level in
                        model.volumeBoostPercent = level
                        Task { model.setVolumeBoostPercent(level) }
                    }
                } label: {
                    LabeledContent("Boost Level", value: Self.percent(model.volumeBoostPercent))
                }
                .foregroundStyle(Color.vividOnSurface)
                .disabled(!model.volumeBoostEnabled)
                Toggle(isOn: live(\.enhancedDialogueEnabled, model.setEnhancedDialogueEnabled)) {
                    described("Enhanced Dialogue", "Lower music and effects so voices are easier to hear.")
                }
                .foregroundStyle(Color.vividOnSurface)
            } header: {
                PhoneSettingsSectionHeader("Audio")
            } footer: {
                Text("Changes apply the next time a video starts. While Volume Boost or Enhanced Dialogue is on, Dolby Atmos plays as standard surround sound, and the loudest moments can distort at higher boost levels.")
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }

        private var episodesSection: some View {
            Section {
                Toggle("Auto-Play Next Episode", isOn: live(\.autoPlayNextEpisode, model.setAutoPlayNextEpisode))
                    .foregroundStyle(Color.vividOnSurface)
                NavigationLink {
                    OptionPage(title: "Show Next Up", options: Self.nextUpOptions, selection: model.nextUpPromptSeconds) { seconds in
                        model.nextUpPromptSeconds = seconds
                        Task { model.setNextUpPromptSeconds(seconds) }
                    }
                } label: {
                    LabeledContent("Show Next Up", value: nextUpLabel)
                }
                .foregroundStyle(Color.vividOnSurface)
                Toggle(isOn: $player.introDBEnabled) {
                    described("Intro & Credit Skipper", "Show intro and credit skip prompts when timestamps are available.")
                }
                .foregroundStyle(Color.vividOnSurface)
                Toggle(isOn: live(\.autoSkipIntro, model.setAutoSkipIntro)) {
                    described("Auto-Skip Intros & Recaps", "Automatically skip intros and recaps when timestamps are available.")
                }
                .foregroundStyle(Color.vividOnSurface)
                .disabled(!player.introDBEnabled)
                Toggle(isOn: live(\.autoSkipCredits, model.setAutoSkipCredits)) {
                    described("Auto-Skip Credits", "Automatically skip credits when timestamps are available.")
                }
                .foregroundStyle(Color.vividOnSurface)
                .disabled(!player.introDBEnabled)
                Toggle(isOn: $player.hideFutureEpisodeSpoilers) {
                    described("Hide Episode Spoilers", "Blur the preview and scramble the description of episodes you haven’t reached yet.")
                }
                .foregroundStyle(Color.vividOnSurface)
            } header: { PhoneSettingsSectionHeader("Episodes") }
        }

        private func described(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }

        /// Shows a change at once, then stores it.
        private func live<Value>(_ keyPath: ReferenceWritableKeyPath<SettingsViewModel, Value>,
                                 _ store: @escaping @MainActor (Value) -> Void) -> Binding<Value> {
            Binding(get: { model[keyPath: keyPath] }, set: { value in
                model[keyPath: keyPath] = value
                Task { store(value) }
            })
        }
    }

    /// The preferred quality. Stays open after a choice.
    struct QualityPage: View {
        let model: SettingsViewModel
        private static let storedTag = "vivid.quality.stored"

        var body: some View {
            List {
                Picker("Quality", selection: selection) {
                    if model.qualityPresetID == nil {
                        Text(verbatim: model.qualityLabel)
                            .tag(Self.storedTag)
                            .disabled(true)
                    }
                    ForEach(VividQualityPresets.selectable) { preset in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: preset.menuLabel)
                            Text(verbatim: preset.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .tag(preset.id)
                    }
                }
                .pickerStyle(.inline)
            }
            .settingsListChrome()
            .navigationTitle("Quality")
            .vividNavigationTitleDisplayMode(.inline)
        }

        private var selection: Binding<String> {
            Binding(get: { model.qualityPresetID ?? Self.storedTag }, set: { id in
                guard id != Self.storedTag else { return }
                model.qualityPresetID = id
                Task { model.selectQuality(id) }
            })
        }
    }

    /// A list of choices that stores one and goes back.
    struct OptionPage<Value: Hashable>: View {
        let title: LocalizedStringKey
        let options: [(value: Value, label: String)]
        let selection: Value
        let choose: (Value) -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            List {
                Picker(title, selection: Binding(get: { selection }, set: { value in
                    choose(value)
                    dismiss()
                })) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(verbatim: options[index].label).tag(options[index].value)
                    }
                }
                .pickerStyle(.inline)
            }
            .settingsListChrome()
            .navigationTitle(title)
            .vividNavigationTitleDisplayMode(.inline)
        }
    }
}
#endif
