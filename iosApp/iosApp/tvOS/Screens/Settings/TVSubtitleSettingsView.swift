#if os(tvOS)
import SwiftUI

/// Embedded track preferences and text-subtitle styling saved locally in Vivid.
struct TVSubtitleSettingsPane: View {
    @Bindable var viewModel: TVSettingsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    let presentPicker: (TVSettingsPickerRequest) -> Void
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            profileSection
            appearanceSection
        }
        .alert("Reset Custom Appearance?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                Task { await viewModel.resetSubtitleAppearance() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores all custom subtitle appearance options to their defaults.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var profileSection: some View {
        TVSettingsSectionHeader("EMBEDDED SUBTITLES")

        TVSettingsGroup {
            TVSettingsPickerRow(
                title: "Language",
                value: TVSettingsOptions.label(
                    for: viewModel.editorSubtitleLanguage,
                    in: TVSettingsOptions.subtitleLanguage(viewModel.subtitleLanguageOptions)
                )
            ) { showPicker(.language) }
            .focused(detailFocus, equals: .top)
            .disabled(viewModel.subtitleMatchesSystemAppearance)

            TVSettingsPickerRow(
                title: "Behavior",
                value: TVSettingsOptions.label(for: viewModel.editorSubtitleMode, in: TVSettingsOptions.subtitleMode)
            ) { showPicker(.mode) }
            .focused(detailFocus, equals: .subtitleBehavior)
            .disabled(viewModel.subtitleMatchesSystemAppearance)

            TVSettingsToggleRow(
                title: "Show Forced Subtitles",
                isOn: viewModel.editorShowForcedSubtitles == "on"
            ) {
                viewModel.editorShowForcedSubtitles =
                    viewModel.editorShowForcedSubtitles == "on" ? "off" : "on"
            }
            .disabled(viewModel.subtitleMatchesSystemAppearance || viewModel.editorSubtitleMode == "off")

        }
        if viewModel.subtitleMatchesSystemAppearance {
            TVSettingsFooter("Language, display behavior, forced captions, and CC/SDH preference follow this Apple TV's Accessibility settings.")
        } else {
            TVSettingsFooter("Subtitles are read from the media. Preferences are saved in Vivid for this profile on this Apple TV.")
        }

    }

    @ViewBuilder
    private var appearanceSection: some View {
        TVSettingsSectionHeader("APPEARANCE")

        TVSettingsGroup {
            TVSettingsSubtitlePreview(appearance: viewModel.effectiveSubtitleAppearance)
                .padding(24)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 24)

            TVSettingsToggleRow(
                title: "Use Device Settings",
                isOn: viewModel.subtitleMatchesSystemAppearance
            ) {
                let enabled = !viewModel.subtitleMatchesSystemAppearance
                Task { await viewModel.setSubtitleMatchesSystemAppearance(enabled) }
            }
            .focused(detailFocus, equals: .subtitleUseDeviceSettings)

            TVSettingsToggleRow(
                title: "Custom Subtitle Appearance",
                isOn: viewModel.subtitleUsesDeviceAppearanceOverride
            ) {
                let enabled = !viewModel.subtitleUsesDeviceAppearanceOverride
                Task { await viewModel.setSubtitleDeviceOverrideEnabled(enabled) }
            }
            .disabled(viewModel.subtitleMatchesSystemAppearance)

            TVSettingsNestedGroup(enabled: viewModel.subtitleUsesDeviceAppearanceOverride && !viewModel.subtitleMatchesSystemAppearance) {
                pickerRow("Font Size", options: TVSettingsOptions.subtitleSize,
                          selection: viewModel.subtitleAppearance.fontSize.rawValue, kind: .fontSize)
                pickerRow("Font Color", options: TVSettingsOptions.fontColor,
                          selection: viewModel.subtitleAppearance.fontColor.lowercased(), kind: .fontColor)

                pickerRow("Background Style", options: TVSettingsOptions.backgroundStyle,
                          selection: viewModel.subtitleAppearance.backgroundStyle.rawValue, kind: .backgroundStyle)

                TVSettingsPickerRow(
                    title: "Background Opacity",
                    value: viewModel.subtitleAppearance.backgroundStyle == .box
                        ? "\(viewModel.subtitleAppearance.backgroundOpacity)%"
                        : "—"
                ) {
                    guard viewModel.subtitleUsesDeviceAppearanceOverride, !viewModel.subtitleMatchesSystemAppearance else { return }
                    showPicker(.backgroundOpacity)
                }
                .focused(detailFocus, equals: .subtitleBackgroundOpacity)

                TVSettingsPickerRow(
                    title: "Background Color",
                    value: viewModel.subtitleAppearance.backgroundStyle == .box
                        ? TVSettingsOptions.label(
                            for: viewModel.subtitleAppearance.backgroundColor.lowercased(),
                            in: TVSettingsOptions.backgroundColor
                        )
                        : "—"
                ) {
                    guard viewModel.subtitleUsesDeviceAppearanceOverride, !viewModel.subtitleMatchesSystemAppearance else { return }
                    showPicker(.backgroundColor)
                }
                .focused(detailFocus, equals: .subtitleBackgroundColor)

                pickerRow("Position", options: TVSettingsOptions.position,
                          selection: viewModel.subtitleAppearance.position.rawValue, kind: .position)

                Button(role: .destructive) {
                    guard viewModel.subtitleUsesDeviceAppearanceOverride, !viewModel.subtitleMatchesSystemAppearance else { return }
                    showResetConfirmation = true
                } label: { TVSettingsRowLabel(title: "Reset Custom Appearance") }
                .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
            }

        }
        if !viewModel.subtitleMatchesSystemAppearance
            && viewModel.subtitleAppearance.isLowLegibilityRisk {
            TVSettingsFooter("Low contrast — dark text without a box or outline can be hard to read.")
        }

        TVSettingsFooter(appearanceFooterText)
    }

    private var appearanceFooterText: String {
        let source: String
        if viewModel.subtitleMatchesSystemAppearance {
            source = "Following this Apple TV's caption language, display behavior, CC/SDH preference, font, colors, opacity, edges, size, and caption window from Settings → Accessibility."
        } else if viewModel.subtitleUsesDeviceAppearanceOverride {
            source = "Appearance is saved in Vivid for this profile on this Apple TV."
        } else {
            source = "Using Vivid’s default subtitle appearance."
        }
        return source + " Appearance controls apply to text subtitles. Styled ASS and image-based subtitles retain their authored appearance and placement."
    }

    // MARK: - Rows

    private func pickerRow(
        _ title: String,
        options: [TVSettingsOption],
        selection: String,
        kind: PickerKind
    ) -> some View {
        TVSettingsPickerRow(
            title: title,
            value: TVSettingsOptions.label(for: selection, in: options)
        ) {
            guard viewModel.subtitleUsesDeviceAppearanceOverride, !viewModel.subtitleMatchesSystemAppearance else { return }
            showPicker(kind)
        }
        .focused(detailFocus, equals: kind.returnFocus)
    }

    // MARK: - Pickers

    private func showPicker(_ kind: PickerKind) {
        presentPicker(pickerRequest(for: kind))
    }

    private func pickerRequest(for kind: PickerKind) -> TVSettingsPickerRequest {
        switch kind {
        case .language:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Language",
                options: TVSettingsOptions.subtitleLanguage(viewModel.subtitleLanguageOptions),
                selection: $viewModel.editorSubtitleLanguage,
                returnFocus: kind.returnFocus
            )
        case .mode:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Behavior",
                options: TVSettingsOptions.subtitleMode,
                selection: $viewModel.editorSubtitleMode,
                returnFocus: kind.returnFocus
            )
        case .fontSize:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Font Size",
                options: TVSettingsOptions.subtitleSize,
                selection: appearanceEnumBinding(\.fontSize, SubtitleFontSizePreset.self),
                returnFocus: kind.returnFocus
            )
        case .fontColor:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Font Color",
                options: TVSettingsOptions.fontColor,
                selection: appearanceStringBinding(\.fontColor),
                returnFocus: kind.returnFocus
            )
        case .backgroundStyle:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Background Style",
                options: TVSettingsOptions.backgroundStyle,
                selection: backgroundStyleBinding,
                returnFocus: kind.returnFocus
            )
        case .backgroundOpacity:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Background Opacity",
                options: TVSettingsOptions.backgroundOpacity,
                selection: backgroundOpacityBinding,
                returnFocus: kind.returnFocus
            )
        case .backgroundColor:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Background Color",
                options: TVSettingsOptions.backgroundColor,
                selection: backgroundColorBinding,
                returnFocus: kind.returnFocus
            )
        case .position:
            TVSettingsPickerRequest(
                id: kind.id,
                title: "Position",
                options: TVSettingsOptions.position,
                selection: appearanceEnumBinding(\.position, SubtitlePositionPreset.self),
                returnFocus: kind.returnFocus
            )
        }
    }

    enum PickerKind: String, Identifiable {
        case language
        case mode
        case fontSize
        case fontColor
        case backgroundStyle
        case backgroundOpacity
        case backgroundColor
        case position

        var id: String { rawValue }

        var returnFocus: TVSettingsDetailFocus {
            switch self {
            case .language: .top
            case .mode: .subtitleBehavior
            case .fontSize: .subtitleFontSize
            case .fontColor: .subtitleFontColor
            case .backgroundStyle: .subtitleBackgroundStyle
            case .backgroundOpacity: .subtitleBackgroundOpacity
            case .backgroundColor: .subtitleBackgroundColor
            case .position: .subtitlePosition
            }
        }
    }

    // MARK: - Appearance bindings

    /// Picking a background color or opacity switches the style to Box.

    private var backgroundStyleBinding: Binding<String> {
        Binding(
            get: { viewModel.subtitleAppearance.backgroundStyle.rawValue },
            set: { rawValue in
                guard let style = SubtitleBackgroundStylePreset(rawValue: rawValue) else { return }
                var next = viewModel.subtitleAppearance
                next.backgroundStyle = style
                if style == .box && next.backgroundOpacity == 0 {
                    next.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private var backgroundOpacityBinding: Binding<String> {
        Binding(
            get: { String(viewModel.subtitleAppearance.backgroundOpacity) },
            set: { value in
                guard let opacity = Int(value) else { return }
                var next = viewModel.subtitleAppearance
                next.backgroundOpacity = opacity
                if opacity > 0 {
                    next.backgroundStyle = .box
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private var backgroundColorBinding: Binding<String> {
        Binding(
            get: { viewModel.subtitleAppearance.backgroundColor.lowercased() },
            set: { value in
                var next = viewModel.subtitleAppearance
                next.backgroundColor = value
                next.backgroundStyle = .box
                if next.backgroundOpacity == 0 {
                    next.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                }
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private func appearanceStringBinding(_ keyPath: WritableKeyPath<SubtitleAppearance, String>) -> Binding<String> {
        Binding(
            get: { viewModel.subtitleAppearance[keyPath: keyPath].lowercased() },
            set: { value in
                var next = viewModel.subtitleAppearance
                next[keyPath: keyPath] = value
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }

    private func appearanceEnumBinding<Value>(
        _ keyPath: WritableKeyPath<SubtitleAppearance, Value>,
        _ type: Value.Type
    ) -> Binding<String> where Value: RawRepresentable, Value.RawValue == String {
        Binding(
            get: { viewModel.subtitleAppearance[keyPath: keyPath].rawValue },
            set: { rawValue in
                guard let value = Value(rawValue: rawValue) else { return }
                var next = viewModel.subtitleAppearance
                next[keyPath: keyPath] = value
                Task { await viewModel.setSubtitleAppearance(next) }
            }
        )
    }
}
#endif
