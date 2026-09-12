#if !os(tvOS)
import SwiftUI

/// Subtitle preferences sub-screen — a native grouped list. The
/// language, behavior and appearance are saved locally for this profile.
struct SubtitleSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    /// Slider position while the user is dragging; committed (and saved
    /// locally) once the drag ends.
    @State private var draftOpacity: Double?

    var body: some View {
        List {
            SettingsPageHeader(
                title: "Subtitles",
                subtitle: "Language, behavior, and on-screen appearance.",
                systemImage: "captions.bubble",
                tint: .pink
            )
            .settingsPageHeaderRow()

            preferencesSection
            appearanceSection
        }
        .settingsListChrome()
        .navigationTitle("")
        .vividNavigationTitleDisplayMode(.inline)
        .vividToolbarColorSchemeDark()
    }

    // MARK: - Embedded subtitle preferences

    @ViewBuilder
    private var preferencesSection: some View {
        Section {
            Picker("Language", selection: $viewModel.editorSubtitleLanguage) {
                Text(
                    SettingPresentationMetadata.definitions[.playbackSubtitleLanguage]?.unsetLabel
                        ?? "None"
                ).tag(PlaybackPrefSentinel.none)
                ForEach(viewModel.subtitleLanguageOptions) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Picker("Behavior", selection: $viewModel.editorSubtitleMode) {
                ForEach(SubtitleMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayLabel).tag(mode.rawValue)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            Toggle(
                "Show Forced Subtitles",
                isOn: Binding(
                    get: { viewModel.editorShowForcedSubtitles == "on" },
                    set: { viewModel.editorShowForcedSubtitles = $0 ? "on" : "off" }
                )
            )
            .foregroundStyle(Color.vividOnSurface)
            .tint(.white)
        } header: {
            PhoneSettingsSectionHeader("Embedded Subtitles")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.subtitleMatchesSystemAppearance {
                    Text("Language, display behavior, forced captions, and CC/SDH preference follow this device's Accessibility settings.")
                } else {
                    Text("Selects matching subtitles embedded in the media. Preferences are saved on this device for the current profile.")
                }
            }
            .foregroundStyle(Color.vividSecondaryText)
        }
        .disabled(viewModel.subtitleMatchesSystemAppearance)

    }

    // MARK: - Appearance (per-device override)

    private var manualEditingDisabled: Bool {
        viewModel.subtitleMatchesSystemAppearance || !viewModel.subtitleUsesDeviceAppearanceOverride
    }

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            SubtitleAppearancePreview(appearance: viewModel.effectiveSubtitleAppearance)
                .listRowInsets(EdgeInsets())
        } header: {
            PhoneSettingsSectionHeader("Appearance")
        } footer: {
            if !manualEditingDisabled && viewModel.subtitleAppearance.isLowLegibilityRisk {
                Text("Low contrast — dark text without a box or outline can be hard to read.")
                    .foregroundStyle(Color.vividError)
            }
        }


        Section {
            Toggle(
                "Use Device Settings",
                isOn: Binding(
                    get: { viewModel.subtitleMatchesSystemAppearance },
                    set: { enabled in
                        Task { await viewModel.setSubtitleMatchesSystemAppearance(enabled) }
                    }
                )
            )
            .foregroundStyle(Color.vividOnSurface)
            .tint(.white)

            Toggle(
                "Custom Appearance",
                isOn: Binding(
                    get: { viewModel.subtitleUsesDeviceAppearanceOverride },
                    set: { enabled in
                        Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
                    }
                )
            )
            .foregroundStyle(Color.vividOnSurface)
            .tint(.white)
            .disabled(viewModel.subtitleMatchesSystemAppearance)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.subtitleMatchesSystemAppearance {
                    Text("Following this device's caption language, display behavior, CC/SDH preference, font, colors, opacity, edges, size, and caption window from Accessibility → Subtitles & Captioning.")
                } else if viewModel.subtitleUsesDeviceAppearanceOverride {
                    Text("Saved in Vivid for this profile on this device.")
                } else {
                    Text("Using Vivid’s default appearance. Turn on Custom Appearance to adjust it.")
                }
                if viewModel.subtitleMatchesSystemAppearance {
                    Text("Appearance controls apply to text subtitles. Styled ASS and image-based subtitles retain their authored appearance and placement.")
                } else {
                    Text("Appearance controls apply to text subtitles. Styled ASS and image-based subtitles retain their authored appearance and placement.")
                }
            }
            .foregroundStyle(Color.vividSecondaryText)
        }


        Section {
            Picker("Font Size", selection: appearanceBinding(\.fontSize)) {
                ForEach(SubtitleFontSizePreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            ColorChoicePicker(
                title: "Font Color",
                colors: SubtitleAppearance.fontColors,
                selection: appearanceBinding(\.fontColor)
            )

        } header: {
            Text("Text")
                .foregroundStyle(Color.vividSecondaryText)
        }

        .disabled(manualEditingDisabled)
        .opacity(manualEditingDisabled ? 0.45 : 1)

        Section {
            Picker("Style", selection: backgroundStyleBinding) {
                ForEach(SubtitleBackgroundStylePreset.selectableCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif

            opacityRow
                .disabled(viewModel.subtitleAppearance.backgroundStyle != .box)
                .opacity(viewModel.subtitleAppearance.backgroundStyle == .box ? 1 : 0.45)

            ColorChoicePicker(
                title: "Color",
                colors: SubtitleAppearance.backgroundColors,
                selection: appearanceBinding(\.backgroundColor)
            )
            .disabled(viewModel.subtitleAppearance.backgroundStyle != .box)
            .opacity(viewModel.subtitleAppearance.backgroundStyle == .box ? 1 : 0.45)
        } header: {
            Text("Background")
                .foregroundStyle(Color.vividSecondaryText)
        }

        .disabled(manualEditingDisabled)
        .opacity(manualEditingDisabled ? 0.45 : 1)

        Section {
            Picker("Position", selection: appearanceBinding(\.position)) {
                ForEach(SubtitlePositionPreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(Color.vividOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
        } header: {
            Text("Layout")
                .foregroundStyle(Color.vividSecondaryText)
        }

        .disabled(manualEditingDisabled)
        .opacity(manualEditingDisabled ? 0.45 : 1)
    }

    /// Choosing Box with a fully transparent background would render
    /// nothing; give it the default opacity so the choice takes effect.
    private var backgroundStyleBinding: Binding<SubtitleBackgroundStylePreset> {
        Binding(
            get: { viewModel.subtitleAppearance.backgroundStyle },
            set: { newValue in
                var next = viewModel.subtitleAppearance
                if next.backgroundStyle == newValue { return }
                next.backgroundStyle = newValue
                if newValue == .box && next.backgroundOpacity == 0 {
                    next.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private var opacityRow: some View {
        let committed = Double(viewModel.subtitleAppearance.backgroundOpacity)
        return HStack(spacing: 12) {
            Text("Opacity")
                .foregroundStyle(Color.vividOnSurface)
            Slider(
                value: Binding(
                    get: { draftOpacity ?? committed },
                    set: { draftOpacity = $0 }
                ),
                in: 0...100,
                step: 5
            ) { editing in
                guard !editing, let value = draftOpacity else { return }
                draftOpacity = nil
                var next = viewModel.subtitleAppearance
                let percent = Int(value)
                if next.backgroundOpacity == percent { return }
                next.backgroundOpacity = percent
                Task { await viewModel.setSubtitleAppearance(next) }
            }
            .tint(.white)
            Text("\(Int(draftOpacity ?? committed))%")
                .monospacedDigit()
                .foregroundStyle(Color.vividSecondaryText)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Background Opacity")
        .accessibilityValue("\(Int(draftOpacity ?? committed)) percent")
    }

    private func appearanceBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<SubtitleAppearance, Value>
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.subtitleAppearance[keyPath: keyPath] },
            set: { newValue in
                var next = viewModel.subtitleAppearance
                if next[keyPath: keyPath] == newValue { return }
                next[keyPath: keyPath] = newValue
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

}

// MARK: - Color choice row

/// A named-color picker rendered as a standard row (navigation link on
/// iOS, menu on macOS) so every option gets a full-size tap target,
/// unlike the previous row of 24pt swatches.
private struct ColorChoicePicker: View {
    let title: String
    let colors: [(hex: String, label: String)]
    @Binding var selection: String

    var body: some View {
        Picker(selection: normalizedSelection) {
            ForEach(colors, id: \.hex) { color in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(hex: color.hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(Color.vividSecondaryText.opacity(0.35), lineWidth: 1)
                        )
                    Text(color.label)
                }
                .tag(color.hex)
            }
        } label: {
            Text(title)
                .foregroundStyle(Color.vividOnSurface)
        }
        #if os(macOS)
        .pickerStyle(.menu)
        #else
        .pickerStyle(.navigationLink)
        #endif
    }

    /// Stored hex values may differ in case from the option list.
    private var normalizedSelection: Binding<String> {
        Binding(
            get: {
                colors.first(where: { $0.hex.caseInsensitiveCompare(selection) == .orderedSame })?.hex
                    ?? selection.lowercased()
            },
            set: { selection = $0 }
        )
    }
}
#endif
