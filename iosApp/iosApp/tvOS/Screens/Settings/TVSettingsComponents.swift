#if os(tvOS)
import SwiftUI

/// Settings keep their original design values in code and draw them through
/// `scale`, so the whole screen grows in proportion: fonts, spacing, radii
/// and widths together. 1.25 lifts row text towards Apple's tvOS sizes
/// (29pt body, 23pt minimum) so it reads from across the room.
enum TVSettingsLayout {
    static let scale: CGFloat = 1.25
    static let contentWidth: CGFloat = scaled(812)
    static let pageWidth: CGFloat = contentWidth + scaled(48)

    /// An original design value at the settings scale, in whole points.
    static func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
}

extension Font {
    /// System font at an original settings design size, drawn at the
    /// settings scale.
    static func tvSettings(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: TVSettingsLayout.scaled(size), weight: weight, design: design)
    }
}

enum TVSettingsPalette {
    static let groupFill = Color(hex: "#1C1C1E")
    static let selectedFill = Color(hex: "#2C2C2E")
    static let iconFill = Color.white.opacity(0.06)
    static let separator = Color.white.opacity(0.08)
    static let sectionText = Color(white: 0.68)
}

struct TVSettingsPageHeader<Actions: View>: View {
    private let title: Text
    private let subtitle: Text?
    @ViewBuilder let actions: () -> Actions

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) }, actions: actions)
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(title: S, subtitle: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) }, actions: actions)
    }

    /// Mixes a localised and a verbatim string, e.g. `Text("Title")` and `Text(value)`.
    init(title: Text, subtitle: Text? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: TVSettingsLayout.scaled(24)) {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                title
                    .font(.tvSettings(40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let subtitle {
                    subtitle
                        .font(.tvSettings(20))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }
            Spacer(minLength: 0)
            actions()
        }
        .padding(.horizontal, TVSettingsLayout.scaled(24))
        .padding(.vertical, TVSettingsLayout.scaled(8))
    }
}

extension TVSettingsPageHeader where Actions == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }

    init(title: Text, subtitle: Text? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct TVSettingsOverview<Profiles: View, Categories: View>: View {
    @ViewBuilder let profiles: () -> Profiles
    @ViewBuilder let categories: () -> Categories

    var body: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
            TVSettingsPageHeader(title: "Settings")
                .padding(.bottom, TVSettingsLayout.scaled(16))
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsSectionHeader("PROFILES", topInset: 0)
                profiles()
            }
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsSectionHeader("SETTINGS", topInset: 0)
                TVSettingsGroup { categories() }
            }
        }
    }
}

extension View {
    func tvSettingsPageSurface() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { SettingsBackdrop() }
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
    }
}

private struct TVSettingsJoinedRowsKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var tvSettingsJoinedRows: Bool {
        get { self[TVSettingsJoinedRowsKey.self] }
        set { self[TVSettingsJoinedRowsKey.self] = newValue }
    }
}

struct TVSettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .environment(\.tvSettingsJoinedRows, true)
            .background(TVSettingsPalette.groupFill)
            .clipShape(RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(30), style: .continuous))
    }
}

struct TVSettingsFieldRow<Content: View>: View {
    private let label: TVSettingsRowLabel
    private let content: Content

    init(title: LocalizedStringResource, detail: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        label = TVSettingsRowLabel(title: title, detail: detail)
        self.content = content()
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(title: S, detail: String, @ViewBuilder content: () -> Content) {
        label = TVSettingsRowLabel(title: title, detail: detail)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
            label
            content
        }
        .padding(TVSettingsLayout.scaled(24))
        .overlay(alignment: .bottom) { Rectangle().fill(TVSettingsPalette.separator).frame(height: 1).padding(.leading, TVSettingsLayout.scaled(24)) }
    }
}

struct TVSettingsRowLabel: View {
    private let title: Text
    private let detail: Text?

    /// Takes a `LocalizedStringResource` rather than a `LocalizedStringKey` so
    /// the English key can still find the row's built-in description.
    init(title: LocalizedStringResource, detail: LocalizedStringResource? = nil) {
        self.title = Text(title)
        self.detail = (detail ?? Self.descriptions[title.key]).map { Text($0) }
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(title: S, detail: String? = nil) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) } ?? Self.descriptions[String(title)].map { Text($0) }
    }

    /// Mixes a localised and a verbatim string, e.g. `Text("Title")` and
    /// `Text(value)`. Built-in descriptions don't apply.
    init(title: Text, detail: Text?) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(6)) {
            title.font(.tvSettings(26, weight: .medium))
            if let detail {
                detail.font(.tvSettings(19)).opacity(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private static let descriptions: [String: LocalizedStringResource] = [
        "Spotlight": "Choose up to three rows for your discovery spotlight.",
        "Home Sections": "Choose which rows appear on Home and arrange their order.",
        "Poster Size": "Adjust card sizes on Home only.",
        "Captions": "Choose titles and years, titles only, or artwork only.",
        "Use Profile Default": "Restore Large Home posters and Title & Year captions.",
        "Customise Tab Bar": "Reorder or hide tabs. Changes save automatically.",
        "Quality": "Preferred playback resolution and bitrate.",
        "Audio Language": "Prefer a matching audio track when available.",
        "Buffer Ahead": "Lucid manages buffering automatically.",
        "Volume Boost": "Play louder than Vivid’s standard volume.",
        "Boost Level": "Choose how much louder Volume Boost plays.",
        "Enhanced Dialogue": "Lower music and effects so voices are easier to hear.",
        "Auto-Play Next Episode": "Start the following episode automatically.",
        "Show Next Up": "Choose when the next-episode prompt appears.",
        "Auto-Skip Intros & Recaps": "Skip intros and recaps automatically when timestamps are available.",
        "Auto-Skip Credits": "Skip credits automatically when timestamps are available.",
        "Language": "Prefer a matching subtitle track when available.",
        "Behavior": "Choose when subtitles should appear.",
        "Show Forced Subtitles": "Allow forced subtitles for translated dialogue and signs. Not used when Behavior is Off.",
        "Use Device Settings": "Follow this Apple TV’s Accessibility caption settings.",
        "Custom Subtitle Appearance": "Use a custom subtitle style on this Apple TV.",
        "Font Size": "Adjust subtitle text size.",
        "Font Color": "Choose subtitle text colour.",
        "Background Style": "Choose how the subtitle background is drawn.",
        "Background Opacity": "Adjust the opacity of the subtitle box.",
        "Background Color": "Choose the subtitle box colour.", "Position": "Adjust where subtitles appear.",
        "Manage Servers": "View saved connections or add another server.",
        "Privacy Policy": "Read how Vivid handles your information.",
        "Open Source Licenses": "View acknowledgements and dependency licences.",
        "Paired Silo Profile": "Choose the viewing profile used by this server account.",
        "Update Login": "Save updated credentials for this server account.",
        "Sign Out": "Keep this profile saved and require credentials next time.",
        "Add Server": "Connect another media server.",
        "Set PIN": "Require four digits when entering this account.",
        "Change PIN": "Replace the four-digit account PIN.",
        "Remove PIN": "Allow entry without a local account PIN.",
        "Reset Custom Appearance": "Restore custom subtitle styling to its defaults."
    ]
}

// MARK: - Option model

/// Option model shared by native Settings menus.
struct TVSettingsOption: Identifiable, Hashable {
    let id: String
    let label: String
    var detail: String? = nil
}

/// Canonical option sets shared by the tvOS settings sub-screens.
enum TVSettingsOptions {
    /// Tag for the "stored pair matches no preset" entry. Not a preset id, so
    /// selecting it is a no-op rather than a write.
    static let customQualityId = "__custom__"

    /// The shared cross-client quality presets, optionally led by a
    /// description of a stored pair no preset covers.
    ///
    /// These are the settings vocabulary, not the in-player switcher's finer
    /// ladder: what is stored is a (resolution, bitrate) pair, so the two
    /// tables can label it differently without either reinterpreting it.
    static func quality(including customLabel: String? = nil) -> [TVSettingsOption] {
        let presets = VividQualityPresets.selectable.map {
            TVSettingsOption(id: $0.id, label: $0.menuLabel, detail: $0.description)
        }
        guard let customLabel else { return presets }
        return [.init(id: customQualityId, label: customLabel)] + presets
    }

    static func audioLanguage(_ languages: [PlaybackLanguageOption]) -> [TVSettingsOption] {
        languageOptions(
            languages,
            unsetID: "",
            unsetLabel: String(localized: "No preference")
        )
    }

    static let bufferAhead: [TVSettingsOption] =
        BufferAheadMode.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let volumeBoostLevel: [TVSettingsOption] =
        VividAudioEnhancement.boostLevels.map { .init(id: String($0), label: String(localized: "\($0)%")) }

    static let nextUpPrompt: [TVSettingsOption] = [
        .init(id: "0", label: String(localized: "At end")),
        .init(id: "10", label: String(localized: "10 seconds before end")),
        .init(id: "30", label: String(localized: "30 seconds before end")),
        .init(id: "60", label: String(localized: "1 minute before end")),
        .init(id: "120", label: String(localized: "2 minutes before end")),
    ]

    static func subtitleLanguage(_ languages: [PlaybackLanguageOption]) -> [TVSettingsOption] {
        languageOptions(
            languages,
            unsetID: PlaybackPrefSentinel.none,
            unsetLabel: String(localized: "No preference")
        )
    }

    static func subtitleBackupLanguage(_ languages: [PlaybackLanguageOption]) -> [TVSettingsOption] {
        languageOptions(
            languages,
            unsetID: PlaybackPrefSentinel.none,
            unsetLabel: String(localized: "None")
        )
    }

    private static func languageOptions(
        _ languages: [PlaybackLanguageOption],
        unsetID: String,
        unsetLabel: String
    ) -> [TVSettingsOption] {
        return [.init(id: unsetID, label: unsetLabel)]
            + languages.map { .init(id: $0.code, label: $0.label) }
    }

    static let subtitleMode: [TVSettingsOption] =
        SubtitleMode.allCases.map { .init(id: $0.rawValue, label: $0.displayLabel) }

    static let subtitleSize: [TVSettingsOption] = [
        .init(id: "small",   label: String(localized: "Small")),
        .init(id: "medium",  label: String(localized: "Medium")),
        .init(id: "large",   label: String(localized: "Large")),
        .init(id: "xlarge",  label: String(localized: "X-Large")),
        .init(id: "xxlarge", label: String(localized: "XX-Large")),
    ]

    static let fontColor: [TVSettingsOption] =
        SubtitleAppearance.fontColors.map { .init(id: $0.hex, label: $0.label) }

    static let backgroundStyle: [TVSettingsOption] =
        SubtitleBackgroundStylePreset.selectableCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let backgroundOpacity: [TVSettingsOption] =
        stride(from: 0, through: 100, by: 5).map { .init(id: String($0), label: String(localized: "\($0)%")) }

    static let backgroundColor: [TVSettingsOption] =
        SubtitleAppearance.backgroundColors.map { .init(id: $0.hex, label: $0.label) }

    static let position: [TVSettingsOption] =
        SubtitlePositionPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    static func label(for id: String, in options: [TVSettingsOption]) -> String {
        options.first(where: { $0.id == id })?.label ?? "—"
    }
}

// MARK: - Rail row style

/// Settings destination row with a neutral selected fill and a white
/// focus surface, preserving the TV's existing focus target and geometry.
struct TVSettingsRailRowStyle: ButtonStyle {
    var isSelected: Bool = false
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVSettingsRailRowBody(
            configuration: configuration,
            isSelected: isSelected,
            isDestructive: isDestructive
        )
    }
}

private struct TVSettingsRailRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let isDestructive: Bool
    @Environment(\.tvSettingsJoinedRows) private var joined
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, TVSettingsLayout.scaled(20))
            .padding(.vertical, TVSettingsLayout.scaled(15))
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(foreground)
            .background(
                RoundedRectangle(cornerRadius: joined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: joined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
                    .strokeBorder(
                        isSelected && !isFocused
                            ? Color.vividChromeSelectedBorder
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.vividOnSurface)
                    .frame(width: TVSettingsLayout.scaled(4))
                    .padding(.vertical, TVSettingsLayout.scaled(12))
                    .opacity(isSelected && !isFocused ? 1 : 0)
            }
            .scaleEffect(joined ? 1 : (configuration.isPressed ? 0.98 : (isFocused ? 1.012 : 1)))
            .shadow(
                color: isFocused && !joined ? Color.black.opacity(0.2) : .clear,
                radius: TVSettingsLayout.scaled(18)
            )
            .overlay(alignment: .bottom) {
                if joined { Rectangle().fill(TVSettingsPalette.separator).frame(height: 1).padding(.leading, TVSettingsLayout.scaled(24)) }
            }
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }

    private var foreground: Color {
        if isDestructive {
            return isFocused ? .white : .vividError
        }
        return isFocused ? .vividBackground : .vividOnSurface
    }

    private var fill: Color {
        if isDestructive && isFocused { return .vividError }
        if isFocused { return .vividOnSurface }
        if isSelected { return TVSettingsPalette.selectedFill }
        return joined ? .clear : TVSettingsPalette.groupFill
    }
}

// MARK: - Pane row style

/// Settings control row with a neutral grouped surface at rest and a white
/// focus surface with dark content.
struct TVSettingsPaneRowStyle: ButtonStyle {
    var isDestructive: Bool = false
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVSettingsPaneRowBody(
            configuration: configuration,
            isDestructive: isDestructive,
            isSelected: isSelected
        )
    }
}

private struct TVSettingsPaneRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isDestructive: Bool
    let isSelected: Bool
    @Environment(\.tvSettingsJoinedRows) private var joined
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, TVSettingsLayout.scaled(24))
            .padding(.vertical, TVSettingsLayout.scaled(17))
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(foreground)
            .background(
                RoundedRectangle(cornerRadius: joined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: joined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
                    .strokeBorder(
                        borderColor,
                        lineWidth: 1
                    )
            )
            .scaleEffect(joined ? 1 : (configuration.isPressed ? 0.98 : (isFocused ? 1.012 : 1)))
            .shadow(
                color: isFocused && !joined ? Color.black.opacity(0.2) : .clear,
                radius: TVSettingsLayout.scaled(18)
            )
            .focusEffectDisabled()
            .overlay(alignment: .bottom) {
                if joined { Rectangle().fill(TVSettingsPalette.separator).frame(height: 1).padding(.leading, TVSettingsLayout.scaled(24)) }
            }
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }

    private var foreground: Color {
        if isDestructive {
            return isFocused ? Color(hex: "#D22F3F") : .vividError
        }
        return isFocused ? .vividBackground : .vividOnSurface
    }

    private var backgroundFill: Color {
        if isFocused { return .vividOnSurface }
        if isSelected { return TVSettingsPalette.selectedFill }
        return joined ? .clear : TVSettingsPalette.groupFill
    }

    private var borderColor: Color {
        if joined { return .clear }
        if isFocused { return .clear }
        if isSelected { return .vividChromeSelectedBorder }
        return .vividChromeRestingBorder
    }
}

// MARK: - Pane rows

/// Picker row: title, current value, chevron. Activating it presents the
/// option sheet.
struct TVSettingsPickerRow: View {
    private let label: TVSettingsRowLabel
    private let value: Text
    let action: () -> Void

    init(title: LocalizedStringResource, value: LocalizedStringResource, detail: LocalizedStringResource? = nil,
         action: @escaping () -> Void) {
        label = TVSettingsRowLabel(title: title, detail: detail)
        self.value = Text(value)
        self.action = action
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<T: StringProtocol, V: StringProtocol>(title: T, value: V, detail: String? = nil, action: @escaping () -> Void) {
        label = TVSettingsRowLabel(title: title, detail: detail)
        self.value = Text(value)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: TVSettingsLayout.scaled(16)) {
                label
                Spacer(minLength: TVSettingsLayout.scaled(16))
                value
                    .font(.tvSettings(24))
                    .opacity(0.68)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.right")
                    .font(.tvSettings(18, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
    }
}

/// The system owns option presentation, selection and focus return.
struct TVSettingsOptionMenu: View {
    private let label: TVSettingsRowLabel
    let value: String
    let options: [TVSettingsOption]
    let selection: Binding<String>

    /// `value` is the current option's label, shown verbatim like a
    /// `LabeledContent` value.
    init<V: StringProtocol>(title: LocalizedStringResource, value: V, detail: LocalizedStringResource? = nil,
                            options: [TVSettingsOption], selection: Binding<String>) {
        label = TVSettingsRowLabel(title: title, detail: detail)
        self.value = String(value)
        self.options = options
        self.selection = selection
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<T: StringProtocol, V: StringProtocol>(title: T, value: V, detail: String? = nil,
                                               options: [TVSettingsOption], selection: Binding<String>) {
        label = TVSettingsRowLabel(title: title, detail: detail)
        self.value = String(value)
        self.options = options
        self.selection = selection
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button { selection.wrappedValue = option.id } label: {
                    let label = option.detail.map { "\(option.label)\n\($0)" } ?? option.label
                    if selection.wrappedValue == option.id {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            HStack(spacing: TVSettingsLayout.scaled(16)) {
                label
                Spacer(minLength: TVSettingsLayout.scaled(16))
                Text(value)
                    .font(.tvSettings(24))
                    .opacity(0.68)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.tvSettings(16, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .menuStyle(.button)
        .buttonStyle(TVSettingsPaneRowStyle())
    }
}

/// One-press boolean row in the system-Settings idiom: click flips the
/// value, the trailing text reads On / Off. (Same pattern as the player
/// info HUD — no `Toggle`, whose system chrome fights the custom layout.)
struct TVSettingsToggleRow: View {
    private let label: TVSettingsRowLabel
    let isOn: Bool
    let action: () -> Void

    init(title: LocalizedStringResource, isOn: Bool, detail: LocalizedStringResource? = nil, action: @escaping () -> Void) {
        label = TVSettingsRowLabel(title: title, detail: detail)
        self.isOn = isOn
        self.action = action
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(title: S, isOn: Bool, detail: String? = nil, action: @escaping () -> Void) {
        label = TVSettingsRowLabel(title: title, detail: detail)
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: TVSettingsLayout.scaled(16)) {
                label
                Spacer(minLength: TVSettingsLayout.scaled(16))
                Text(isOn ? "On" : "Off")
                    .font(.tvSettings(24, weight: isOn ? .semibold : .regular))
                    .opacity(isOn ? 0.9 : 0.55)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Visually groups controls owned by a parent setting. Inactive groups
/// stay in the focus graph so their values remain inspectable, but the
/// owner is responsible for ignoring edits until `enabled` is true.
struct TVSettingsNestedGroup<Content: View>: View {
    let enabled: Bool
    let content: Content

    init(enabled: Bool, @ViewBuilder content: () -> Content) {
        self.enabled = enabled
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
        .opacity(enabled ? 1 : 0.42)
        .accessibilityHint(enabled ? "" : "Turn on the parent setting to make changes")
    }
}

/// Read-only fact row (server name, version). It is deliberately not a
/// focus target; focus should land only on actionable settings rows.
struct TVSettingsInfoRow: View {
    private let title: Text
    let value: String
    var showsConnectedDot = false

    /// `value` is shown verbatim like a `LabeledContent` value.
    init<V: StringProtocol>(title: LocalizedStringKey, value: V, showsConnectedDot: Bool = false) {
        self.title = Text(title)
        self.value = String(value)
        self.showsConnectedDot = showsConnectedDot
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<T: StringProtocol, V: StringProtocol>(title: T, value: V, showsConnectedDot: Bool = false) {
        self.title = Text(title)
        self.value = String(value)
        self.showsConnectedDot = showsConnectedDot
    }

    @Environment(\.tvSettingsJoinedRows) private var joined
    var body: some View {
        HStack(spacing: TVSettingsLayout.scaled(16)) {
            title
                .font(.tvSettings(26))
                .lineLimit(1)
            Spacer(minLength: TVSettingsLayout.scaled(16))
            if showsConnectedDot {
                Circle().fill(.green).frame(width: TVSettingsLayout.scaled(10), height: TVSettingsLayout.scaled(10)).accessibilityHidden(true)
            }
            Text(value)
                .font(.tvSettings(24))
                .opacity(0.68)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, TVSettingsLayout.scaled(24))
        .padding(.vertical, TVSettingsLayout.scaled(17))
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(.vividOnSurface)
        .background(
            RoundedRectangle(cornerRadius: joined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
                .fill(joined ? Color.clear : TVSettingsPalette.groupFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: joined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
                .strokeBorder(joined ? Color.clear : Color.vividChromeRestingBorder, lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if joined { Rectangle().fill(TVSettingsPalette.separator).frame(height: 1).padding(.leading, TVSettingsLayout.scaled(24)) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section header / footer

/// Mono uppercase section eyebrow, matching the Skyline dropdown and
/// filter-panel header grammar.
struct TVSettingsSectionHeader: View {
    private let title: Text
    var topInset: CGFloat = 26

    init(_ title: LocalizedStringKey, topInset: CGFloat = 26) { self.title = Text(title); self.topInset = topInset }
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, topInset: CGFloat = 26) { self.title = Text(title); self.topInset = topInset }

    var body: some View {
        title
            .font(.tvSettings(18, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(TVSettingsPalette.sectionText)
            .padding(.horizontal, TVSettingsLayout.scaled(24))
            .padding(.top, TVSettingsLayout.scaled(topInset))
            .padding(.bottom, TVSettingsLayout.scaled(6))
    }
}

/// Explanatory caption under a section's rows.
struct TVSettingsFooter: View {
    private let text: Text

    init(_ text: LocalizedStringKey) { self.text = Text(text) }
    @_disfavoredOverload init<S: StringProtocol>(_ text: S) { self.text = Text(text) }

    var body: some View {
        text
            .font(.tvSettings(19))
            .foregroundColor(.vividSecondaryText)
            .padding(.horizontal, TVSettingsLayout.scaled(24))
            .padding(.top, TVSettingsLayout.scaled(4))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Confirmation overlay

/// Settings-styled destructive confirmation used instead of the native tvOS
/// alert, whose app-wide tint can leave focused Cancel text without contrast.
struct TVSettingsConfirmationOverlay: View {
    private let title: Text
    private let message: Text
    private let confirmTitle: Text
    private let additionalDestructiveTitle: Text?
    let cancel: () -> Void
    let confirm: () -> Void
    private let additionalDestructiveAction: (() -> Void)?

    @FocusState private var focusedAction: Action?

    init(title: LocalizedStringResource, message: LocalizedStringResource, confirmTitle: LocalizedStringResource,
         additionalDestructiveTitle: LocalizedStringResource? = nil,
         cancel: @escaping () -> Void, confirm: @escaping () -> Void,
         additionalDestructiveAction: (() -> Void)? = nil) {
        self.title = Text(title)
        self.message = Text(message)
        self.confirmTitle = Text(confirmTitle)
        self.additionalDestructiveTitle = additionalDestructiveTitle.map { Text($0) }
        self.cancel = cancel
        self.confirm = confirm
        self.additionalDestructiveAction = additionalDestructiveAction
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init(title: String, message: String, confirmTitle: String, additionalDestructiveTitle: String? = nil,
         cancel: @escaping () -> Void, confirm: @escaping () -> Void,
         additionalDestructiveAction: (() -> Void)? = nil) {
        self.title = Text(title)
        self.message = Text(message)
        self.confirmTitle = Text(confirmTitle)
        self.additionalDestructiveTitle = additionalDestructiveTitle.map { Text($0) }
        self.cancel = cancel
        self.confirm = confirm
        self.additionalDestructiveAction = additionalDestructiveAction
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)

            VStack(spacing: TVSettingsLayout.scaled(28)) {
                VStack(spacing: TVSettingsLayout.scaled(12)) {
                    title
                        .font(.tvSettings(38, weight: .semibold))
                        .foregroundColor(.vividOnSurface)

                    message
                        .font(.tvSettings(22))
                        .foregroundColor(.vividSecondaryText)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: TVSettingsLayout.scaled(16)) {
                    Button(action: cancel) {
                        Text("Cancel")
                            .font(.tvSettings(24, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .frame(width: buttonWidth)
                        .focused($focusedAction, equals: .cancel)

                    Button(action: confirm) {
                        confirmTitle
                            .font(.tvSettings(24, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                        .frame(width: buttonWidth)
                        .focused($focusedAction, equals: .confirm)

                    if let additionalDestructiveTitle,
                       let additionalDestructiveAction {
                        Button(action: additionalDestructiveAction) {
                            additionalDestructiveTitle
                                .font(.tvSettings(24, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                        .frame(width: buttonWidth)
                        .focused($focusedAction, equals: .additionalDestructive)
                    }
                }
            }
            .padding(.horizontal, TVSettingsLayout.scaled(48))
            .padding(.vertical, TVSettingsLayout.scaled(42))
            .background(
                RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(30), style: .continuous)
                    .fill(TVSettingsPalette.groupFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(30), style: .continuous)
                    .strokeBorder(Color.vividChromeRestingBorder, lineWidth: 1)
            )
            .focusSection()
            .defaultFocus($focusedAction, .cancel, priority: .userInitiated)
            .onExitCommand(perform: cancel)
        }
        .onAppear { focusedAction = .cancel }
    }

    private enum Action: Hashable {
        case cancel
        case confirm
        case additionalDestructive
    }

    private var buttonWidth: CGFloat {
        TVSettingsLayout.scaled(additionalDestructiveTitle == nil ? 260 : 320)
    }
}

// MARK: - Vivid privacy policy

struct TVPrivacyPolicyPage: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedSection: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(24)) {
                TVSettingsPageHeader(title: "Privacy Policy", subtitle: "App privacy information · Updated 19 October 2026")
                policySection("Your accounts and media server", "Vivid connects to the media servers you choose. Your server receives the sign-in details and requests needed to provide your account, library, artwork and playback. Depending on the provider, requests also identify this device by its name, a generated client identifier, platform and app version/build. If you press the Siri button to search, Apple turns what you say into text under its own privacy policy, and Vivid receives only that text and searches your server with it, as it does a typed search. The server operator controls that information and may keep its own logs and records. Vivid’s policy does not replace your server operator’s privacy policy.")
                policySection("Optional Emby Connect sign-in", "If you choose Use Emby Connect when signing in to an Emby server, Vivid asks Emby’s Emby Connect service (connect.emby.media) for a PIN, sending a generated device identifier and the app name and version. You enter the PIN on emby.media with your Emby Connect email and password, which Vivid never receives. Vivid then receives an Emby Connect sign-in token and the list of servers linked to your Emby Connect account, uses them once to sign in to the server you chose, and doesn’t keep them. Emby Connect also receives normal connection information, including your IP address, and handles it under Emby’s own privacy policy. Signing in with a password doesn’t contact Emby Connect.")
                policySection("Information on this Apple TV", "Vivid saves preferences, Home metadata, artwork and playback buffers on this Apple TV. Saved account session tokens and optional Vivid PIN records use Keychain. The saved-account feature does not retain the media-server password you enter.")
                policySection("Private iCloud account sync", "When iCloud is available, Vivid stores saved server addresses, account and viewing-profile details (including any server name you give a profile), login sessions, optional Vivid PIN records and profile order in encrypted fields in your private iCloud database. Shared browsing, navigation, metadata and download preferences, plus configured MDBList, OpenSubtitles and Seerr connection details, also sync between your iPhone, iPad and Apple TV for the matching server account and viewing profile. Playback and subtitle preferences, downloaded media, artwork and metadata caches stay on the device. Playback history and resume positions stay with your media server. Optional MDBList completed-watch exports and watchlist sync are described below.")
                policySection("Playback and connected features", "Vivid sends playback position, pause state and watched-progress updates to the selected server, and tells Emby and Jellyfin which audio and subtitle tracks are playing. Subtitles and chapters are read from the opened media on this device, along with subtitle files a Silo, Emby or Jellyfin server keeps beside it and subtitles a Silo server stores for it. If you connect OpenSubtitles in Plugins, searches send the title, language, media type, season number and episode number to OpenSubtitles. The subtitle file you choose is downloaded to this device and kept with that title, along with any subtitle delay you set for it, for your 40 most recent titles, so it usually comes back when you resume; Apple TV may clear it to free space. Choosing another subtitle, Off or Auto, or disconnecting, removes it. A small, limited memory cache reuses recent downloads during the app session and clears when the connection changes. Your API key stays in Keychain, separate for each server account and profile, and syncs through the encrypted private iCloud account vault. Searches send the key only to the OpenSubtitles API. Subtitles are not uploaded to your media server. Subtitle translation is not provided. Vivid uses TMDb for trailers, ratings, movie collections and missing Emby and Jellyfin metadata IDs, and Studios & Networks asks it for studio and network logos and their most popular titles. These lookups go through Vivid’s TMDb relay (tmdb.vividapp.co, on Cloudflare), which sends them to TMDb with Vivid’s own key. The relay receives media identifiers and the lists requested, and uses your network address only to limit requests, without storing it or passing it to TMDb. Vivid doesn’t use a TMDb key of yours, and deletes one saved by an earlier version from your devices and the iCloud vault. Your library and watch history are matched on this device and are not sent to TMDb or the relay. When a page has trailers, Vivid loads their preview images from YouTube, and opening a trailer hands it to the YouTube app or website. Seerr request artwork loads from TMDb’s image service. These services receive normal connection information and apply their own privacy policies.")
                policySection("Skip timestamp lookups", "With Intro & Credit Skipper enabled in Playback settings, Vivid can look up missing intro, recap and credits timestamps. IntroDB (api.introdb.app) receives the series IMDb ID and season and episode numbers. TheIntroDB (api.theintrodb.org) receives the series TMDb ID when available, otherwise its IMDb ID, plus season and episode numbers. These services also receive normal connection information such as your IP address. Vivid does not send your media-server credentials. The skipper is enabled by default, can be turned off in Playback settings, and does not require an API key.")
                policySection("Calendar", "The Calendar finds new episodes of series in your Continue Watching, Watchlist and history. Vivid looks up their air times from TVmaze and their next air date from TMDb through Vivid’s relay (tmdb.vividapp.co, on Cloudflare), which receives only the TVDB, IMDb or TMDb IDs of those series and uses your network address only to limit requests, without storing it or passing it on. TVmaze never sees your address. Trending asks TMDb through the same relay for popular titles coming soon. Upcoming posters load from your server, and Trending posters load from TMDb’s image service, which receives normal connection information. Your library, watch history and account aren’t sent to TVmaze, TMDb or the relay. Vivid keeps the Calendar’s list of your series with their air dates, and Trending, on this device for each profile, so it doesn’t look them all up on every visit. Deleting the saved account removes them.")
                policySection("Optional MDBList connection", "If you connect MDBList in Settings → Plugins, Vivid keeps your personal API key in this device’s Keychain. It sends movie and episode identifiers and watched dates for new completions or titles you explicitly mark watched in Vivid, only after your media server confirms the watched update. Neither service’s existing watched history is scanned or imported, and MDBList does not replace server watched indicators or resume positions. Movie and series watchlist additions and removals sync in both directions for matching titles on the active media server. Media-server credentials are never sent to MDBList. The connection syncs through the encrypted private iCloud account vault for the same server account and viewing profile. Pending exports and confirmed sync checkpoints remain on each device across connection failures. Reconnecting the same MDBList account reuses those checkpoints; watchlist sync reads fresh remote lists. Old local watched-import records are discarded without changing either service’s history. Disconnecting stops syncing without deleting watched history or watchlists.")
                policySection("Optional Seerr connection", "If you configure Seerr, Vivid stores its URL, username and password in Keychain to restore your connection, and they sync through the encrypted private iCloud account vault for the matching server account and viewing profile. Seerr receives your login, search queries and media requests. Disconnect in Settings → Seerr to remove the saved connection. Your Seerr operator controls records kept on that server.")
                policySection("Diagnostics", "Vivid keeps reports of crashes, freezes, unexpected exits, playback failures and app errors on this Apple TV to help fix problems. A report contains the app version, device model, system version, technical details, whether the app was launching, browsing or playing, and a short log of recent app events such as screens opened, playback steps and errors, with addresses, file names and identifiers removed. The reports Vivid writes contain no titles, account details or server addresses and are kept for up to 14 days, or less if the system needs the space. It also keeps a record of the latest playback only, replaced each time something new plays: the server type and play method, the audio output and display setup, the video and audio formats, and counts of dropped frames, buffering, audio faults and sync drift, time spent paused or waiting to load, and Vivid’s memory use each minute, with no titles, item IDs, account details or server addresses. Vivid never uploads them automatically. In Settings → Diagnostics you can view and delete them, or choose to send them. Sending them delivers them to Vivid’s diagnostics service at diagnostics.vividapp.co, which runs on Cloudflare, emails them to diagnostics@vividapp.co through the Resend email service and keeps a copy on Cloudflare for 30 days. To have a report you’ve sent deleted, email admin@vividapp.co with the reference shown after sending it. If you add a note saying what happened, it’s sent with them as you wrote it, apart from removing spaces at the ends and control or text-direction characters, and keeping it to 500 characters. Vivid doesn’t check a note for personal details, so leave out passwords and server addresses. The device’s network address is used only to limit how often reports can be sent and isn’t stored. Show QR Code instead opens an email to diagnostics@vividapp.co on your phone with a short summary of each problem report, which you review before sending; it doesn't include the latest playback record. Detailed development logs are only written by development builds and stay on the device. Apple’s TestFlight service separately collects beta usage, crash information and submitted feedback under its own privacy terms.")
                policySection("Your controls", "You can clear Home metadata and unused artwork from Settings → Metadata, and delete diagnostics reports from Settings → Diagnostics. Manual Sign Out clears the current saved-account session while keeping its profile card for later sign-in, and that signed-out state syncs through iCloud. Deleting a saved account on this Apple TV or another Vivid device records the deletion in the private vault so a stale device cannot add it back; signing in again later can restore it. Removing Vivid clears data stored by this Apple TV but does not delete the private iCloud vault, data on another device or records held by your media server. Contact the server operator about information stored there.")
                policySection("Contact and changes", "For questions about Vivid, contact admin@vividapp.co. Vivid is in development; this information will be updated as its features and data handling change.")
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, TVSettingsLayout.scaled(24)).padding(.vertical, TVSettingsLayout.scaled(48))
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
        .defaultFocus($focusedSection, "Your accounts and media server")
        .onExitCommand { dismiss() }
    }

    private func policySection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
            Text(title).font(.tvSettings(27, weight: .semibold))
            Text(text).font(.tvSettings(22)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TVSettingsLayout.scaled(18))
        .overlay {
            RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(14))
                .strokeBorder(.white.opacity(focusedSection == title ? 0.85 : 0), lineWidth: 2)
        }
        .focusable()
        .focused($focusedSection, equals: title)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Subtitle preview

/// Thin wrapper over the shared cross-platform preview so tvOS settings
/// screens keep the Skyline rounded-card look. (The old bespoke preview
/// drew "outline" as a stroked rectangle around the caption block, which
/// is not what the setting does to glyphs.)
struct TVSettingsSubtitlePreview: View {
    let appearance: SubtitleAppearance

    var body: some View {
        SubtitleAppearancePreview(appearance: appearance)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
#endif
