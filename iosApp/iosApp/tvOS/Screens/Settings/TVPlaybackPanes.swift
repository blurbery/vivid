#if os(tvOS)
import SwiftUI

extension TVSettingsView {
    /// Settings > Playback on Apple TV.
    struct PlaybackPane: View {
        let model: TVSettingsViewModel
        let focus: FocusState<Focus?>.Binding
        @State private var player = PlayerSettings.shared

        /// The menu entry for a stored quality Settings doesn't offer.
        private static let storedQualityID = "vivid.quality.stored"

        private var qualityOptions: [MenuOption] {
            let presets = VividQualityPresets.selectable.map {
                MenuOption(id: $0.id, label: $0.menuLabel, detail: $0.description)
            }
            guard model.qualityPresetID == nil else { return presets }
            return [MenuOption(id: Self.storedQualityID, label: model.qualityLabel)] + presets
        }

        private var audioOptions: [MenuOption] {
            [MenuOption(id: "", label: String(localized: "No preference"))]
                + model.audioLanguageOptions.map { MenuOption(id: $0.code, label: $0.label) }
        }

        private static var boostOptions: [MenuOption] {
            VividAudioEnhancement.boostLevels.map { MenuOption(id: String($0), label: String(localized: "\($0)%")) }
        }

        private static var nextUpOptions: [MenuOption] {
            [
                MenuOption(id: "0", label: String(localized: "At end")),
                MenuOption(id: "10", label: String(localized: "10 seconds before end")),
                MenuOption(id: "30", label: String(localized: "30 seconds before end")),
                MenuOption(id: "60", label: String(localized: "1 minute before end")),
                MenuOption(id: "120", label: String(localized: "2 minutes before end")),
            ]
        }

        var body: some View {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsSectionHeader("PLAYBACK")
                TVSettingsGroup {
                    OptionMenu(title: "Quality", value: model.qualityLabel, options: qualityOptions,
                               selection: model.qualityPresetID ?? Self.storedQualityID) { id in
                        guard id != Self.storedQualityID else { return }
                        model.qualityPresetID = id
                        Task { model.selectQuality(id) }
                    }
                    .focused(focus, equals: .top)
                    TVSettingsInfoRow(title: "Buffer Ahead", value: String(localized: "Automatic"))
                }
                TVSettingsFooter("Lucid manages buffering automatically. Preferences are saved for this profile on this Apple TV.")
                TVSettingsSectionHeader("AUDIO")
                TVSettingsGroup {
                    OptionMenu(title: "Audio Language", value: TVSettingsView.optionLabel(audioOptions, model.audioLanguage),
                               options: audioOptions, selection: model.audioLanguage) { code in
                        model.audioLanguage = code
                        Task { model.setAudioLanguage(code) }
                    }
                    .focused(focus, equals: .audioLanguage)
                    TVSettingsToggleRow(title: "Volume Boost", isOn: model.volumeBoostEnabled) {
                        let enabled = !model.volumeBoostEnabled
                        model.volumeBoostEnabled = enabled
                        Task { model.setVolumeBoostEnabled(enabled) }
                    }
                    DependentGroup(isEnabled: model.volumeBoostEnabled) {
                        OptionMenu(title: "Boost Level",
                                   value: TVSettingsView.optionLabel(Self.boostOptions, String(model.volumeBoostPercent)),
                                   options: Self.boostOptions, selection: String(model.volumeBoostPercent)) { id in
                            guard let level = Int(id) else { return }
                            model.volumeBoostPercent = level
                            Task { model.setVolumeBoostPercent(level) }
                        }
                        .disabled(!model.volumeBoostEnabled)
                        .focused(focus, equals: .boostLevel)
                    }
                    TVSettingsToggleRow(title: "Enhanced Dialogue", isOn: model.enhancedDialogueEnabled) {
                        let enabled = !model.enhancedDialogueEnabled
                        model.enhancedDialogueEnabled = enabled
                        Task { model.setEnhancedDialogueEnabled(enabled) }
                    }
                }
                TVSettingsFooter("Changes apply the next time a video starts. While Volume Boost or Enhanced Dialogue is on, Dolby Atmos plays as standard surround sound, and the loudest moments can distort at higher boost levels.")
                TVSettingsSectionHeader("EPISODES")
                episodesGroup
            }
        }

        private var episodesGroup: some View {
            TVSettingsGroup {
                TVSettingsToggleRow(title: "Auto-Play Next Episode", isOn: model.autoPlayNextEpisode) {
                    let enabled = !model.autoPlayNextEpisode
                    model.autoPlayNextEpisode = enabled
                    Task { model.setAutoPlayNextEpisode(enabled) }
                }
                OptionMenu(title: "Show Next Up",
                           value: TVSettingsView.optionLabel(Self.nextUpOptions, String(model.nextUpPromptSeconds)),
                           options: Self.nextUpOptions, selection: String(model.nextUpPromptSeconds)) { id in
                    guard let seconds = Int(id) else { return }
                    model.nextUpPromptSeconds = seconds
                    Task { model.setNextUpPromptSeconds(seconds) }
                }
                .focused(focus, equals: .showNextUp)
                TVSettingsToggleRow(title: "Intro & Credit Skipper", isOn: player.introDBEnabled,
                                    detail: "Show intro and credit skip prompts when timestamps are available.") {
                    player.introDBEnabled.toggle()
                }
                TVSettingsToggleRow(title: "Auto-Skip Intros & Recaps", isOn: model.autoSkipIntro) {
                    let enabled = !model.autoSkipIntro
                    model.autoSkipIntro = enabled
                    Task { model.setAutoSkipIntro(enabled) }
                }
                .disabled(!player.introDBEnabled)
                TVSettingsToggleRow(title: "Auto-Skip Credits", isOn: model.autoSkipCredits) {
                    let enabled = !model.autoSkipCredits
                    model.autoSkipCredits = enabled
                    Task { model.setAutoSkipCredits(enabled) }
                }
                .disabled(!player.introDBEnabled)
                TVSettingsToggleRow(title: "Hide Episode Spoilers", isOn: player.hideFutureEpisodeSpoilers,
                                    detail: "Blur the preview and scramble the description of episodes you haven’t reached yet.") {
                    player.hideFutureEpisodeSpoilers.toggle()
                }
            }
        }
    }

    /// Settings > Subtitles on Apple TV.
    struct SubtitlesPane: View {
        let model: TVSettingsViewModel
        let focus: FocusState<Focus?>.Binding
        @State private var asksToReset = false

        private var followsDevice: Bool { model.followsDeviceCaptions }
        /// Appearance controls apply only with a custom appearance that
        /// isn't following the device.
        private var editsAppearance: Bool { model.usesCustomSubtitleAppearance && !followsDevice }
        private var appearance: SubtitleAppearance { model.subtitleAppearance }
        private var usesBox: Bool { appearance.backgroundStyle == .box }

        private var languageOptions: [MenuOption] {
            [MenuOption(id: PlaybackPrefSentinel.none, label: String(localized: "No preference"))]
                + model.subtitleLanguageOptions.map { MenuOption(id: $0.code, label: $0.label) }
        }

        private var backupOptions: [MenuOption] {
            [MenuOption(id: PlaybackPrefSentinel.none, label: String(localized: "None"))]
                + model.backupLanguageOptions.map { MenuOption(id: $0.code, label: $0.label) }
        }

        private static var modeOptions: [MenuOption] {
            SubtitleMode.allCases.map { MenuOption(id: $0.rawValue, label: $0.displayLabel) }
        }

        private static var fontSizeOptions: [MenuOption] {
            SubtitleFontSizePreset.allCases.map { MenuOption(id: $0.rawValue, label: $0.label) }
        }

        private static var fontColorOptions: [MenuOption] {
            SubtitleAppearance.fontColors.map { MenuOption(id: $0.hex.lowercased(), label: $0.label) }
        }

        private static var styleOptions: [MenuOption] {
            SubtitleBackgroundStylePreset.selectableCases.map { MenuOption(id: $0.rawValue, label: $0.label) }
        }

        private static var opacityOptions: [MenuOption] {
            stride(from: 0, through: 100, by: 5).map { MenuOption(id: String($0), label: String(localized: "\($0)%")) }
        }

        private static var backgroundColorOptions: [MenuOption] {
            SubtitleAppearance.backgroundColors.map { MenuOption(id: $0.hex.lowercased(), label: $0.label) }
        }

        private static var positionOptions: [MenuOption] {
            SubtitlePositionPreset.allCases.map { MenuOption(id: $0.rawValue, label: $0.label) }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsSectionHeader("EMBEDDED SUBTITLES")
                embeddedGroup
                TVSettingsFooter(followsDevice
                                 ? "Language, display behavior, forced captions, and CC/SDH preference follow this Apple TV's Accessibility settings."
                                 : "Subtitles are read from the media. Backup Language is used when full subtitles would play but the title has none in your language. Preferences are saved in Vivid for this profile on this Apple TV.")
                TVSettingsSectionHeader("APPEARANCE")
                appearanceGroup
                if editsAppearance && appearance.isLowLegibilityRisk {
                    TVSettingsFooter("Low contrast \u{2014} dark text without a box or outline can be hard to read.")
                }
                TVSettingsFooter("\(appearanceSource) Appearance controls apply to text subtitles. Styled ASS and image-based subtitles retain their authored appearance and placement.")
            }
            .tvSystemAlert("Reset Custom Appearance?", isPresented: $asksToReset,
                           message: "This restores all custom subtitle appearance options to their defaults.",
                           buttons: [
                               .destructive("Reset") { Task { await model.resetCustomAppearance() } },
                               .cancel("Cancel"),
                           ])
        }

        private var appearanceSource: String {
            if followsDevice {
                return String(localized: "Following this Apple TV's caption language, display behavior, CC/SDH preference, font, colors, opacity, edges, size, and caption window from Settings → Accessibility.")
            }
            if model.usesCustomSubtitleAppearance {
                return String(localized: "Appearance is saved in Vivid for this profile on this Apple TV.")
            }
            return String(localized: "Using Vivid’s default subtitle appearance.")
        }

        private var embeddedGroup: some View {
            TVSettingsGroup {
                OptionMenu(title: "Language", value: TVSettingsView.optionLabel(languageOptions, model.editorSubtitleLanguage),
                           options: languageOptions, selection: model.editorSubtitleLanguage) { model.editorSubtitleLanguage = $0 }
                    .disabled(followsDevice)
                    .focused(focus, equals: .top)
                OptionMenu(title: "Backup Language", value: TVSettingsView.optionLabel(backupOptions, model.subtitleBackupLanguage),
                           options: backupOptions, selection: model.subtitleBackupLanguage) { model.subtitleBackupLanguage = $0 }
                    .disabled(followsDevice || !model.backupApplies)
                    .focused(focus, equals: .backupLanguage)
                OptionMenu(title: "Behavior", value: TVSettingsView.optionLabel(Self.modeOptions, model.subtitleMode),
                           options: Self.modeOptions, selection: model.subtitleMode) { model.subtitleMode = $0 }
                    .disabled(followsDevice)
                    .focused(focus, equals: .behavior)
                TVSettingsToggleRow(title: "Show Forced Subtitles", isOn: model.showsForcedSubtitles) {
                    model.showsForcedSubtitles.toggle()
                }
                .disabled(followsDevice || model.subtitleMode == SubtitleMode.off.rawValue)
            }
        }

        private var appearanceGroup: some View {
            TVSettingsGroup {
                SubtitlePreview(appearance: model.effectiveSubtitleAppearance)
                    .padding(TVSettingsLayout.scaled(24))
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.horizontal, TVSettingsLayout.scaled(24))
                TVSettingsToggleRow(title: "Use Device Settings", isOn: followsDevice) {
                    let follows = !followsDevice
                    model.followsDeviceCaptions = follows
                    Task { model.setFollowsDeviceCaptions(follows) }
                }
                .focused(focus, equals: .useDeviceSettings)
                TVSettingsToggleRow(title: "Custom Subtitle Appearance", isOn: model.usesCustomSubtitleAppearance) {
                    let custom = !model.usesCustomSubtitleAppearance
                    model.usesCustomSubtitleAppearance = custom
                    Task { await model.setUsesCustomSubtitleAppearance(custom) }
                }
                .disabled(followsDevice)
                DependentGroup(isEnabled: editsAppearance) {
                    appearanceMenus
                    Button { if editsAppearance { asksToReset = true } } label: {
                        TVSettingsRowLabel(title: "Reset Custom Appearance")
                    }
                    .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                    .disabled(!editsAppearance)
                }
            }
        }

        @ViewBuilder
        private var appearanceMenus: some View {
            OptionMenu(title: "Font Size", value: TVSettingsView.optionLabel(Self.fontSizeOptions, appearance.fontSize.rawValue),
                       options: Self.fontSizeOptions, selection: appearance.fontSize.rawValue) { id in
                guard let size = SubtitleFontSizePreset(rawValue: id) else { return }
                save { $0.fontSize = size }
            }
            .disabled(!editsAppearance)
            .focused(focus, equals: .fontSize)
            OptionMenu(title: "Font Color", value: TVSettingsView.optionLabel(Self.fontColorOptions, appearance.fontColor.lowercased()),
                       options: Self.fontColorOptions, selection: appearance.fontColor.lowercased()) { hex in
                save { $0.fontColor = hex }
            }
            .disabled(!editsAppearance)
            .focused(focus, equals: .fontColor)
            OptionMenu(title: "Background Style",
                       value: TVSettingsView.optionLabel(Self.styleOptions, appearance.backgroundStyle.rawValue),
                       options: Self.styleOptions, selection: appearance.backgroundStyle.rawValue) { id in
                guard let style = SubtitleBackgroundStylePreset(rawValue: id) else { return }
                save {
                    $0.backgroundStyle = style
                    if style == .box && $0.backgroundOpacity == 0 {
                        $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                    }
                }
            }
            .disabled(!editsAppearance)
            .focused(focus, equals: .backgroundStyle)
            OptionMenu(title: "Background Opacity",
                       value: usesBox ? String(localized: "\(appearance.backgroundOpacity)%") : "\u{2014}",
                       options: Self.opacityOptions, selection: String(appearance.backgroundOpacity)) { id in
                guard let opacity = Int(id) else { return }
                save {
                    $0.backgroundOpacity = opacity
                    if opacity > 0 { $0.backgroundStyle = .box }
                }
            }
            .disabled(!editsAppearance)
            .focused(focus, equals: .backgroundOpacity)
            OptionMenu(title: "Background Color",
                       value: usesBox ? TVSettingsView.optionLabel(Self.backgroundColorOptions, appearance.backgroundColor.lowercased()) : "\u{2014}",
                       options: Self.backgroundColorOptions, selection: appearance.backgroundColor.lowercased()) { hex in
                save {
                    $0.backgroundColor = hex
                    $0.backgroundStyle = .box
                    if $0.backgroundOpacity == 0 {
                        $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                    }
                }
            }
            .disabled(!editsAppearance)
            .focused(focus, equals: .backgroundColor)
            OptionMenu(title: "Position", value: TVSettingsView.optionLabel(Self.positionOptions, appearance.position.rawValue),
                       options: Self.positionOptions, selection: appearance.position.rawValue) { id in
                guard let position = SubtitlePositionPreset(rawValue: id) else { return }
                save { $0.position = position }
            }
            .disabled(!editsAppearance)
            .focused(focus, equals: .position)
        }

        /// Saves a copy of the appearance with one change. A choice equal to
        /// the current value is saved again.
        private func save(_ edit: (inout SubtitleAppearance) -> Void) {
            var updated = appearance
            edit(&updated)
            model.subtitleAppearance = updated
            Task { await model.setSubtitleAppearance(updated) }
        }
    }
}
#endif
