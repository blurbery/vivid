#if os(tvOS)
import SwiftUI

// Subtitle controls in the Apple TV player HUD: the Subtitles pane, its
// appearance dialog, and the subtitle-only menu the Subtitles shortcut opens.

extension TVPlayerInfoHUD {
    // MARK: - Subtitles pane

    struct SubtitlesPane: View {
        let viewModel: PlayerViewModel
        @State private var showAppearanceDialog = false
        @State private var picker = HUDPickerState<Option>()
        @FocusState private var focusedOption: Option?
        @FocusState private var entryTrackFocused: Bool

        /// The Options column rows, so focus can go back to one when a
        /// picker or the appearance dialog closes.
        private enum Option: Hashable {
            case delay
            case customAppearance
            case size
            case position
            case appearance
        }

        private var overlayActive: Bool {
            showAppearanceDialog || picker.isPresented
        }

        var body: some View {
            ZStack {
                HStack(alignment: .top, spacing: 58) {
                    PaneColumn("Tracks") { trackRows }
                        .frame(width: 470, alignment: .topLeading)
                        .focusSection()
                    PaneColumn("Options") { optionRows }
                        .frame(width: 440, alignment: .topLeading)
                        .focusSection()
                }
                // The Subtitles pill sits nearest the Options column, so Down
                // is routed into Tracks to match the other track panes.
                .defaultFocus($entryTrackFocused, true, priority: .userInitiated)
                .disabled(overlayActive)
                .opacity(overlayActive ? 0.28 : 1)

                if showAppearanceDialog {
                    SubtitleAppearanceDialog(
                        viewModel: viewModel,
                        onClose: closeAppearanceDialog
                    )
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }

                if let presentation = picker.presentation {
                    HUDPickerDialog(presentation, onClose: closePicker)
                }
            }
            .animation(.easeOut(duration: VividTheme.fastDuration), value: showAppearanceDialog)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: picker.presentation?.id)
        }

        private var trackRows: some View {
            ScrollView(showsIndicators: false) {
                // Not lazy: every row stays in one stable focus graph, and the
                // scroll view does its own keep-visible scrolling.
                VStack(alignment: .leading, spacing: 2) {
                    HUDTrackRow(
                        name: String(localized: "Off"),
                        attributes: nil,
                        isSelected: viewModel.selectedSubtitleId == nil
                    ) {
                        viewModel.disableSubtitles()
                    }
                    .focused($entryTrackFocused)
                    if viewModel.openSubtitleContext != nil {
                        OpenSubtitlesMenu(viewModel: viewModel).padding(.vertical, 12)
                    }
                    ForEach(viewModel.orderedSubtitleTracks) { track in
                        HUDTrackRow(
                            name: track.primaryLabel,
                            attributes: track.attributesLabel,
                            isSelected: viewModel.selectedSubtitleId == track.trackId
                        ) {
                            viewModel.selectSubtitle(track)
                        }
                    }

                    if viewModel.supportsSecondarySubtitles,
                       viewModel.selectedSubtitleId != nil,
                       !viewModel.availableSecondarySubtitleTracks.isEmpty {
                        secondaryTrackRows
                    }
                }
            }
            .task { OpenSubtitlesStore.shared.reload() }
        }

        @ViewBuilder
        private var secondaryTrackRows: some View {
            Text("SECONDARY")
                .font(.system(size: 14, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 20)
                .padding(.bottom, 4)
                .padding(.leading, 14)
            HUDTrackRow(
                name: String(localized: "Off"),
                attributes: nil,
                isSelected: viewModel.selectedSecondarySubtitleId == nil
            ) {
                viewModel.disableSecondarySubtitles()
            }
            ForEach(viewModel.availableSecondarySubtitleTracks) { track in
                HUDTrackRow(
                    name: track.primaryLabel,
                    attributes: track.attributesLabel,
                    isSelected: viewModel.selectedSecondarySubtitleId == track.trackId,
                    isDisabled: track.trackId == viewModel.selectedSubtitleId
                ) {
                    viewModel.selectSecondarySubtitle(track)
                }
            }
        }

        private var optionRows: some View {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    if viewModel.backendCapabilities.supportsSubtitleDelay {
                        HUDSettingRow(label: "Delay", value: HUDPickerOptions.delayLabel(viewModel.subtitleDelayMs)) {
                            picker.present(
                                HUDPickerPresentation(
                                    title: "Subtitle Delay",
                                    options: HUDPickerOptions.subtitleDelayOptions(including: viewModel.subtitleDelayMs),
                                    selection: String(viewModel.subtitleDelayMs),
                                    onSelect: { value in
                                        if let ms = Int(value) {
                                            viewModel.setSubtitleSyncMilliseconds(ms)
                                        }
                                    }
                                ),
                                returningTo: .delay
                            )
                        }
                        .focused($focusedOption, equals: .delay)
                        .id(Option.delay)
                    }
                    if viewModel.backendCapabilities.supportsSubtitleStyling {
                        stylingRows
                    }
                }
            }
        }

        /// The size and position rows only apply with Custom Appearance on,
        /// and none of the custom rows apply while the device's caption style
        /// is in charge.
        @ViewBuilder
        private var stylingRows: some View {
            let followsDevice = viewModel.settings.subtitleMatchesSystemAppearance
            let customRowsDisabled = followsDevice || !viewModel.settings.subtitleUsesDeviceAppearanceOverride
            HUDToggleRow(
                label: "Custom Appearance",
                isOn: viewModel.settings.subtitleUsesDeviceAppearanceOverride
            ) { enabled in
                Task {
                    await viewModel.setSubtitleDeviceOverrideEnabled(enabled)
                }
            }
            .focused($focusedOption, equals: .customAppearance)
            .id(Option.customAppearance)
            .disabled(followsDevice)
            HUDSettingRow(
                label: "Size",
                value: viewModel.settings.subtitleAppearance.fontSize.label
            ) {
                picker.present(
                    HUDPickerPresentation(
                        title: "Subtitle Size",
                        options: HUDPickerOptions.subtitleSizeOptions,
                        selection: viewModel.settings.subtitleAppearance.fontSize.rawValue,
                        onSelect: { value in
                            if let size = SubtitleFontSizePreset(rawValue: value) {
                                updateSubtitleAppearance(viewModel) { $0.fontSize = size }
                            }
                        }
                    ),
                    returningTo: .size
                )
            }
            .focused($focusedOption, equals: .size)
            .id(Option.size)
            .disabled(customRowsDisabled)
            HUDSettingRow(
                label: "Position",
                value: viewModel.settings.subtitleAppearance.position.label
            ) {
                picker.present(
                    HUDPickerPresentation(
                        title: "Subtitle Position",
                        options: HUDPickerOptions.subtitlePositionOptions,
                        selection: viewModel.settings.subtitleAppearance.position.rawValue,
                        onSelect: { value in
                            if let position = SubtitlePositionPreset(rawValue: value) {
                                updateSubtitleAppearance(viewModel) { $0.position = position }
                            }
                        }
                    ),
                    returningTo: .position
                )
            }
            .focused($focusedOption, equals: .position)
            .id(Option.position)
            .disabled(customRowsDisabled)
            HUDSettingRow(
                label: "Appearance",
                value: appearanceSummary,
                systemImage: "textformat"
            ) {
                showAppearanceDialog = true
            }
            .focused($focusedOption, equals: .appearance)
            .id(Option.appearance)
        }

        private var appearanceSummary: String {
            let appearance = viewModel.settings.subtitleAppearance
            return String(
                localized: "\(appearance.backgroundStyle.label), \(appearance.fontSize.label), \(appearance.position.label)",
                comment: "Subtitle appearance summary: background style, size and position"
            )
        }

        private func closePicker() {
            if let option = picker.close() {
                focusedOption = option
            }
        }

        private func closeAppearanceDialog() {
            showAppearanceDialog = false
            focusedOption = .appearance
        }
    }

    // MARK: - Appearance dialog

    struct SubtitleAppearanceDialog: View {
        let viewModel: PlayerViewModel
        let onClose: () -> Void

        @State private var picker = HUDPickerState<Field>()
        @FocusState private var focusedField: Field?

        private enum Field: Hashable {
            case close
            case matchSystem
            case style
            case font
            case size
            case textColor
            case outlineToggle
            case outlineColor
            case backgroundColor
            case opacity
            case position
        }

        private var appearance: SubtitleAppearance {
            viewModel.settings.subtitleAppearance
        }

        var body: some View {
            ZStack {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SUBTITLE APPEARANCE")
                                .font(.system(size: 14, weight: .semibold))
                                .tracking(1.6)
                                .foregroundStyle(.white.opacity(0.55))
                            Text("Style and colors")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        closeButton
                    }

                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 2) {
                            HUDToggleRow(
                                label: "Use device settings",
                                isOn: viewModel.settings.subtitleMatchesSystemAppearance
                            ) { enabled in
                                viewModel.setSubtitleMatchesSystemAppearance(enabled)
                            }
                            .focused($focusedField, equals: .matchSystem)
                            .id(Field.matchSystem)

                            // The device's caption style is in charge while Use
                            // Device Settings is on; editing here would quietly
                            // turn it off, so these rows wait, as in Settings.
                            Group {
                                styleRows
                            }
                            .disabled(viewModel.settings.subtitleMatchesSystemAppearance)
                        }
                        .padding(.trailing, 8)
                    }
                    .frame(maxHeight: 560)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .frame(width: 720, alignment: .topLeading)
                .vividPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 26, y: 14)
                .focusSection()
                .defaultFocus($focusedField, viewModel.settings.subtitleMatchesSystemAppearance ? .matchSystem : .style)
                .disabled(picker.isPresented)
                .opacity(picker.isPresented ? 0.28 : 1)

                if let presentation = picker.presentation {
                    HUDPickerDialog(presentation, onClose: closePicker)
                }
            }
            .animation(.easeOut(duration: VividTheme.fastDuration), value: picker.presentation?.id)
            // The picker's own exit handler takes Menu while it has focus.
            // If focus ever escapes it, Menu should still close the picker,
            // not the whole dialog.
            .onExitCommand(perform: picker.isPresented ? closePicker : onClose)
        }

        @ViewBuilder
        private var styleRows: some View {
            pickerRow(
                .style,
                label: "Style",
                value: appearance.backgroundStyle.label,
                title: "Subtitle Style",
                options: Self.backgroundStyleOptions,
                selection: appearance.backgroundStyle.rawValue
            ) { value in
                if let style = SubtitleBackgroundStylePreset(rawValue: value) {
                    update {
                        $0.backgroundStyle = style
                        if style == .box && $0.backgroundOpacity == 0 {
                            $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                        }
                    }
                }
            }

            pickerRow(
                .font,
                label: "Font",
                value: appearance.fontFamily.label,
                title: "Subtitle Font",
                options: Self.fontFamilyOptions,
                selection: appearance.fontFamily.rawValue
            ) { value in
                if let font = SubtitleFontFamilyPreset(rawValue: value) {
                    update { $0.fontFamily = font }
                }
            }

            pickerRow(
                .size,
                label: "Size",
                value: appearance.fontSize.label,
                title: "Subtitle Size",
                options: HUDPickerOptions.subtitleSizeOptions,
                selection: appearance.fontSize.rawValue
            ) { value in
                if let size = SubtitleFontSizePreset(rawValue: value) {
                    update { $0.fontSize = size }
                }
            }

            pickerRow(
                .textColor,
                label: "Text",
                value: label(for: appearance.fontColor, in: Self.fontColorOptions),
                colorHex: appearance.fontColor,
                title: "Text Color",
                options: Self.fontColorOptions,
                selection: appearance.fontColor
            ) { value in
                update { $0.fontColor = value }
            }

            HUDToggleRow(
                label: "Text outline",
                isOn: appearance.textOutline
            ) { enabled in
                update { $0.textOutline = enabled }
            }
            .focused($focusedField, equals: .outlineToggle)
            .id(Field.outlineToggle)

            pickerRow(
                .outlineColor,
                label: "Outline",
                value: appearance.textOutline
                    ? label(for: appearance.textOutlineColor, in: Self.outlineColorOptions)
                    : "—",
                colorHex: appearance.textOutline ? appearance.textOutlineColor : nil,
                title: "Outline Color",
                options: Self.outlineColorOptions,
                selection: appearance.textOutlineColor
            ) { value in
                // Picking a colour turns the outline on.
                update {
                    $0.textOutlineColor = value
                    $0.textOutline = true
                }
            }

            pickerRow(
                .backgroundColor,
                label: "Background",
                value: appearance.backgroundStyle == .box
                    ? label(for: appearance.backgroundColor, in: Self.backgroundColorOptions)
                    : "—",
                colorHex: appearance.backgroundStyle == .box ? appearance.backgroundColor : nil,
                title: "Background Color",
                options: Self.backgroundColorOptions,
                selection: appearance.backgroundColor
            ) { value in
                // Picking a colour switches the style to Box.
                update {
                    $0.backgroundColor = value
                    $0.backgroundStyle = .box
                    if $0.backgroundOpacity == 0 {
                        $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                    }
                }
            }

            pickerRow(
                .opacity,
                label: "Opacity",
                value: opacityLabel,
                title: "Background Opacity",
                options: Self.opacityOptions,
                selection: String(appearance.backgroundOpacity)
            ) { value in
                if let opacity = Int(value) {
                    update {
                        $0.backgroundOpacity = opacity
                        if opacity > 0 {
                            $0.backgroundStyle = .box
                        }
                    }
                }
            }

            pickerRow(
                .position,
                label: "Position",
                value: appearance.position.label,
                title: "Subtitle Position",
                options: HUDPickerOptions.subtitlePositionOptions,
                selection: appearance.position.rawValue
            ) { value in
                if let position = SubtitlePositionPreset(rawValue: value) {
                    update { $0.position = position }
                }
            }
        }

        /// A row that opens a picker and takes focus back when it closes.
        private func pickerRow(
            _ field: Field,
            label: LocalizedStringKey,
            value: String,
            colorHex: String? = nil,
            title: LocalizedStringKey,
            options: [HUDDropdownOption],
            selection: String,
            onSelect: @escaping (String) -> Void
        ) -> some View {
            HUDSettingRow(label: label, value: value, colorHex: colorHex) {
                picker.present(
                    HUDPickerPresentation(title: title, options: options, selection: selection, onSelect: onSelect),
                    returningTo: field
                )
            }
            .focused($focusedField, equals: field)
            .id(field)
        }

        private var closeButton: some View {
            Button(action: onClose) {
                HUDCloseButtonLabel()
            }
            .buttonStyle(HUDCircleButtonStyle())
            .focused($focusedField, equals: .close)
            .accessibilityLabel("Close subtitle appearance")
        }

        private func closePicker() {
            if let field = picker.close() {
                focusedField = field
            }
        }

        private func update(_ mutate: @escaping (inout SubtitleAppearance) -> Void) {
            updateSubtitleAppearance(viewModel, mutate)
        }

        private var opacityLabel: String {
            guard appearance.backgroundStyle == .box, appearance.backgroundOpacity > 0 else {
                return String(localized: "Off")
            }
            return String(localized: "\(appearance.backgroundOpacity)%", comment: "Subtitle background opacity as a percentage")
        }

        private func label(for id: String, in options: [HUDDropdownOption]) -> String {
            options.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.label ?? id
        }

        private static let backgroundStyleOptions: [HUDDropdownOption] =
            SubtitleBackgroundStylePreset.selectableCases.map { .init(id: $0.rawValue, label: $0.label) }

        private static let fontFamilyOptions: [HUDDropdownOption] =
            SubtitleFontFamilyPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

        private static let opacityOptions: [HUDDropdownOption] =
            stride(from: 0, through: 100, by: 25).map {
                .init(id: String($0), label: $0 == 0
                    ? String(localized: "Off")
                    : String(localized: "\($0)%", comment: "Subtitle background opacity as a percentage"))
            }

        private static let fontColorOptions: [HUDDropdownOption] =
            SubtitleAppearance.fontColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }

        private static let outlineColorOptions: [HUDDropdownOption] =
            SubtitleAppearance.outlineColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }

        private static let backgroundColorOptions: [HUDDropdownOption] =
            SubtitleAppearance.backgroundColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }
    }

    // MARK: - Subtitle-only menu

    /// What the Subtitles shortcut opens: Off, the tracks and OpenSubtitles
    /// search. Picking a track closes it.
    struct TVPlayerSubtitleMenu: View {
        let viewModel: PlayerViewModel
        let onDismiss: () -> Void

        var body: some View {
            VStack(spacing: 16) {
                Text("Subtitles").font(.title3.weight(.semibold))
                ScrollView {
                    VStack(spacing: 12) {
                        Button(viewModel.selectedSubtitleId == nil ? "✓ Off" : "Off") {
                            viewModel.disableSubtitles()
                            onDismiss()
                        }
                        ForEach(viewModel.orderedSubtitleTracks) { track in
                            Button(trackLabel(track)) {
                                viewModel.selectSubtitle(track)
                                onDismiss()
                            }
                        }
                        if viewModel.openSubtitleContext != nil {
                            OpenSubtitlesMenu(viewModel: viewModel)
                        }
                    }
                    .buttonStyle(SubtitleMenuButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
                .frame(maxHeight: 300)
            }
            .padding(28)
            .frame(width: 760)
            .vividPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { OpenSubtitlesStore.shared.reload() }
            .onExitCommand(perform: onDismiss)
        }

        private func trackLabel(_ track: PlayerTrack) -> String {
            let selected = viewModel.selectedSubtitleId == track.trackId ? "✓ " : ""
            let attributes = track.attributesLabel.map { " (\($0))" } ?? ""
            return selected + track.primaryLabel + attributes
        }
    }

    private struct SubtitleMenuButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            SubtitleMenuButtonBody(configuration: configuration)
        }
    }

    private struct SubtitleMenuButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFocused ? Color.white : Color.black.opacity(0.28))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .focusEffectDisabled()
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

/// Saves a changed copy of the subtitle appearance.
@MainActor
private func updateSubtitleAppearance(
    _ viewModel: PlayerViewModel,
    _ mutate: @escaping (inout SubtitleAppearance) -> Void
) {
    var next = viewModel.settings.subtitleAppearance
    mutate(&next)
    Task { await viewModel.setSubtitleAppearance(next) }
}
#endif
