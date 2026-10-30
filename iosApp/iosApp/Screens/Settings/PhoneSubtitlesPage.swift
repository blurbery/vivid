#if os(iOS)
import SwiftUI

extension SettingsView {
    /// Settings > Subtitles: which embedded subtitles play, and how they
    /// look.
    struct SubtitlesPage: View {
        let model: SettingsViewModel
        @State private var opacityDraft: Double?

        /// Appearance controls apply only with a custom appearance that
        /// isn't following the device.
        private var editsAppearance: Bool { model.usesCustomSubtitleAppearance && !model.followsDeviceCaptions }
        private var appearance: SubtitleAppearance { model.subtitleAppearance }
        private var usesBox: Bool { appearance.backgroundStyle == .box }

        var body: some View {
            List {
                SettingsPageHeader(title: "Subtitles", subtitle: "Language, behavior, and on-screen appearance.",
                                   systemImage: "captions.bubble", tint: .pink)
                    .settingsPageHeaderRow()
                embeddedSection
                Section {
                    SubtitleAppearancePreview(appearance: model.effectiveSubtitleAppearance)
                        .listRowInsets(EdgeInsets())
                } header: {
                    PhoneSettingsSectionHeader("Appearance")
                } footer: {
                    if editsAppearance && appearance.isLowLegibilityRisk {
                        Text("Low contrast — dark text without a box or outline can be hard to read.")
                            .foregroundStyle(Color.vividError)
                    }
                }
                sourceSection
                textSection
                backgroundSection
                Section {
                    Picker("Position", selection: appearanceValue(\.position)) {
                        ForEach(SubtitlePositionPreset.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    .foregroundStyle(Color.vividOnSurface)
                } header: {
                    Text("Layout").foregroundStyle(Color.vividSecondaryText)
                }
                .disabled(!editsAppearance)
                .opacity(editsAppearance ? 1 : 0.45)
            }
            .settingsListChrome()
            .navigationTitle("")
            .vividNavigationTitleDisplayMode(.inline)
            .vividToolbarColorSchemeDark()
        }

        private var embeddedSection: some View {
            Section {
                Picker("Language", selection: Binding(get: { model.editorSubtitleLanguage },
                                                      set: { model.editorSubtitleLanguage = $0 })) {
                    Text("No preference").tag(PlaybackPrefSentinel.none)
                    ForEach(model.subtitleLanguageOptions) { Text(verbatim: $0.label).tag($0.code) }
                }
                Picker("Backup Language", selection: Binding(get: { model.subtitleBackupLanguage },
                                                             set: { model.subtitleBackupLanguage = $0 })) {
                    Text("None").tag(PlaybackPrefSentinel.none)
                    ForEach(model.backupLanguageOptions) { Text(verbatim: $0.label).tag($0.code) }
                }
                .disabled(!model.backupApplies)
                Picker("Behavior", selection: Binding(get: { model.subtitleMode }, set: { model.subtitleMode = $0 })) {
                    ForEach(SubtitleMode.allCases, id: \.self) { Text(verbatim: $0.displayLabel).tag($0.rawValue) }
                }
                Toggle("Show Forced Subtitles", isOn: Binding(get: { model.showsForcedSubtitles },
                                                              set: { model.showsForcedSubtitles = $0 }))
                    .tint(.white)
                    .disabled(model.subtitleMode == SubtitleMode.off.rawValue)
            } header: {
                PhoneSettingsSectionHeader("Embedded Subtitles")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.followsDeviceCaptions
                         ? "Language, display behavior, forced captions, and CC/SDH preference follow this device's Accessibility settings."
                         : "Selects matching subtitles embedded in the media. Backup Language is used when full subtitles would play but the title has none in your language. Preferences are saved on this device for the current profile.")
                }
                .foregroundStyle(Color.vividSecondaryText)
            }
            .pickerStyle(.navigationLink)
            .foregroundStyle(Color.vividOnSurface)
            .disabled(model.followsDeviceCaptions)
        }

        private var sourceSection: some View {
            Section {
                Toggle("Use Device Settings", isOn: Binding(get: { model.followsDeviceCaptions }, set: { follows in
                    model.followsDeviceCaptions = follows
                    Task { model.setFollowsDeviceCaptions(follows) }
                }))
                .tint(.white)
                Toggle("Custom Appearance", isOn: Binding(get: { model.usesCustomSubtitleAppearance }, set: { custom in
                    model.usesCustomSubtitleAppearance = custom
                    Task { await model.setUsesCustomSubtitleAppearance(custom) }
                }))
                .tint(.white)
                .disabled(model.followsDeviceCaptions)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.followsDeviceCaptions
                         ? "Following this device's caption language, display behavior, CC/SDH preference, font, colors, opacity, edges, size, and caption window from Accessibility → Subtitles & Captioning."
                         : model.usesCustomSubtitleAppearance
                         ? "Saved in Vivid for this profile on this device."
                         : "Using Vivid’s default appearance. Turn on Custom Appearance to adjust it.")
                    Text("Appearance controls apply to text subtitles. Styled ASS and image-based subtitles retain their authored appearance and placement.")
                }
                .foregroundStyle(Color.vividSecondaryText)
            }
            .foregroundStyle(Color.vividOnSurface)
        }

        private var textSection: some View {
            Section {
                Picker("Font Size", selection: appearanceValue(\.fontSize)) {
                    ForEach(SubtitleFontSizePreset.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                .foregroundStyle(Color.vividOnSurface)
                ColourPicker(title: "Font Color", options: SubtitleAppearance.fontColors, hex: appearance.fontColor) { hex in
                    change { $0.fontColor = hex }
                }
            } header: {
                Text("Text").foregroundStyle(Color.vividSecondaryText)
            }
            .disabled(!editsAppearance)
            .opacity(editsAppearance ? 1 : 0.45)
        }

        private var backgroundSection: some View {
            Section {
                Picker("Style", selection: Binding(get: { appearance.backgroundStyle }, set: { style in
                    change {
                        $0.backgroundStyle = style
                        if style == .box && $0.backgroundOpacity == 0 {
                            $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                        }
                    }
                })) {
                    ForEach(SubtitleBackgroundStylePreset.selectableCases) { Text(verbatim: $0.label).tag($0) }
                }
                .foregroundStyle(Color.vividOnSurface)
                opacityRow
                    .disabled(!usesBox)
                    .opacity(usesBox ? 1 : 0.45)
                ColourPicker(title: "Color", options: SubtitleAppearance.backgroundColors, hex: appearance.backgroundColor) { hex in
                    change { $0.backgroundColor = hex }
                }
                .disabled(!usesBox)
                .opacity(usesBox ? 1 : 0.45)
            } header: {
                Text("Background").foregroundStyle(Color.vividSecondaryText)
            }
            .disabled(!editsAppearance)
            .opacity(editsAppearance ? 1 : 0.45)
        }

        private var opacityRow: some View {
            let value = opacityDraft ?? Double(appearance.backgroundOpacity)
            return HStack(spacing: 12) {
                Text("Opacity").foregroundStyle(Color.vividOnSurface)
                Slider(value: Binding(get: { value }, set: { opacityDraft = $0 }), in: 0...100, step: 5, onEditingChanged: { editing in
                    guard !editing, let draft = opacityDraft else { return }
                    opacityDraft = nil
                    let opacity = Int(draft.rounded(.down))
                    change { $0.backgroundOpacity = opacity }
                })
                .tint(.white)
                Text((value / 100).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(Color.vividSecondaryText)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Background Opacity")
            .accessibilityValue(Text("\(Int(value)) percent"))
        }

        private func appearanceValue<Value: Equatable>(_ keyPath: WritableKeyPath<SubtitleAppearance, Value>) -> Binding<Value> {
            Binding(get: { appearance[keyPath: keyPath] }, set: { value in change { $0[keyPath: keyPath] = value } })
        }

        /// Saves a copy of the appearance with one change, unless nothing
        /// changed.
        private func change(_ edit: (inout SubtitleAppearance) -> Void) {
            var updated = appearance
            edit(&updated)
            guard updated != appearance else { return }
            model.subtitleAppearance = updated
            Task { await model.setSubtitleAppearance(updated) }
        }
    }

    /// A colour choice with a swatch beside each name.
    struct ColourPicker: View {
        let title: LocalizedStringKey
        let options: [(hex: String, label: String)]
        let hex: String
        let choose: (String) -> Void

        /// The matching option, ignoring case. A colour that matches none
        /// selects nothing in the list.
        private var selection: String {
            options.first { $0.hex.lowercased() == hex.lowercased() }?.hex ?? hex.lowercased()
        }

        var body: some View {
            Picker(selection: Binding(get: { selection }, set: choose)) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: option.hex))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.vividSecondaryText.opacity(0.35), lineWidth: 1))
                        Text(verbatim: option.label)
                    }
                    .tag(option.hex)
                }
            } label: {
                Text(title).foregroundStyle(Color.vividOnSurface)
            }
            .pickerStyle(.navigationLink)
        }
    }
}
#endif
