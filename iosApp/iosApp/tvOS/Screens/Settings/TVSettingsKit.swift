#if os(tvOS)
import SwiftUI

/// Apple TV Settings draws every design value 25% larger, so rows and text
/// read comfortably from across the room.
enum TVSettingsLayout {
    static let scale: CGFloat = 1.25
    static let contentWidth: CGFloat = scaled(812)
    static let pageWidth: CGFloat = contentWidth + scaled(48)

    static func scaled(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded()
    }
}

extension Font {
    /// The system font at a settings design size.
    static func tvSettings(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: TVSettingsLayout.scaled(size), weight: weight, design: design)
    }
}

enum TVSettingsPalette {
    static let iconFill = Color.white.opacity(0.06)
    static let groupFill = Color(hex: "#1C1C1E")
    static let separator = Color.white.opacity(0.08)
    static let sectionText = Color(white: 0.68)
}

private struct JoinedRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by a group for its rows, which then drop their own corners and
    /// draw a separator instead.
    fileprivate var tvSettingsJoinedRows: Bool {
        get { self[JoinedRowsKey.self] }
        set { self[JoinedRowsKey.self] = newValue }
    }
}

/// The inset line under a joined row.
private struct RowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(TVSettingsPalette.separator)
            .frame(height: 1)
            .padding(.leading, TVSettingsLayout.scaled(24))
    }
}

// MARK: - Page

struct TVSettingsPageHeader<Actions: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let actions: () -> Actions

    init(title: Text, subtitle: Text? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) }, actions: actions)
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
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) }) { EmptyView() }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, subtitle: String? = nil) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) }) { EmptyView() }
    }

    init(title: Text, subtitle: Text? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    /// A full-screen settings page on the app's backdrop.
    func tvSettingsPageSurface() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsBackdrop())
            .environment(\.colorScheme, .dark)
            .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Groups and rows

/// Rows joined into one rounded panel.
struct TVSettingsGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .environment(\.tvSettingsJoinedRows, true)
        .background(TVSettingsPalette.groupFill)
        .clipShape(RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(30), style: .continuous))
    }
}

/// A label above a control, such as a text field.
struct TVSettingsFieldRow<Content: View>: View {
    private let title: LocalizedStringResource
    private let detail: LocalizedStringResource
    private let content: Content

    init(title: LocalizedStringResource, detail: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
            TVSettingsRowLabel(title: title, detail: detail)
            content
        }
        .padding(TVSettingsLayout.scaled(24))
        .overlay(alignment: .bottom) { RowSeparator() }
    }
}

/// A row's title with a description underneath. Without a description of
/// its own, a localised or plain-string title takes the standard one for
/// that title, if there is one.
struct TVSettingsRowLabel: View {
    private let title: Text
    private let detail: Text?

    init(title: LocalizedStringResource, detail: LocalizedStringResource? = nil) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) } ?? Self.standardDetail(for: title.key)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, detail: String? = nil) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) } ?? Self.standardDetail(for: String(title))
    }

    init(title: Text, detail: Text?) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(6)) {
            title
                .font(.tvSettings(26, weight: .medium))
            if let detail {
                detail
                    .font(.tvSettings(19))
                    .opacity(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func standardDetail(for title: String) -> Text? {
        switch title {
        case "Spotlight": Text("Choose up to three rows for your discovery spotlight.")
        case "Home Sections": Text("Choose which rows appear on Home and arrange their order.")
        case "Captions": Text("Choose titles and years, titles only, or artwork only.")
        case "Use Profile Default": Text("Restore Title & Year captions.")
        case "Customise Tab Bar": Text("Reorder or hide tabs. Changes save automatically.")
        case "Quality": Text("Preferred playback resolution and bitrate.")
        case "Audio Language": Text("Prefer a matching audio track when available.")
        case "Volume Boost": Text("Play louder than Vivid’s standard volume.")
        case "Boost Level": Text("Choose how much louder Volume Boost plays.")
        case "Enhanced Dialogue": Text("Lower music and effects so voices are easier to hear.")
        case "Auto-Play Next Episode": Text("Start the following episode automatically.")
        case "Show Next Up": Text("Choose when the next-episode prompt appears.")
        case "Auto-Skip Intros & Recaps": Text("Skip intros and recaps automatically when timestamps are available.")
        case "Auto-Skip Credits": Text("Skip credits automatically when timestamps are available.")
        case "Language": Text("Prefer a matching subtitle track when available.")
        case "Behavior": Text("Choose when subtitles should appear.")
        case "Show Forced Subtitles": Text("Allow forced subtitles for translated dialogue and signs. Not used when Behavior is Off.")
        case "Use Device Settings": Text("Follow this Apple TV’s Accessibility caption settings.")
        case "Custom Subtitle Appearance": Text("Use a custom subtitle style on this Apple TV.")
        case "Font Size": Text("Adjust subtitle text size.")
        case "Font Color": Text("Choose subtitle text colour.")
        case "Background Style": Text("Choose how the subtitle background is drawn.")
        case "Background Opacity": Text("Adjust the opacity of the subtitle box.")
        case "Background Color": Text("Choose the subtitle box colour.")
        case "Position": Text("Adjust where subtitles appear.")
        case "Manage Servers": Text("View saved connections or add another server.")
        case "Privacy Policy": Text("Read how Vivid handles your information.")
        case "Sign Out": Text("Keep this profile saved and require credentials next time.")
        case "Add Server": Text("Connect another media server.")
        case "Set PIN": Text("Require four digits when entering this account.")
        case "Change PIN": Text("Replace the four-digit account PIN.")
        case "Remove PIN": Text("Allow entry without a local account PIN.")
        case "Reset Custom Appearance": Text("Restore custom subtitle styling to its defaults.")
        default: nil
        }
    }
}

/// The settings row button: a platter that fills white when focused, or a
/// joined row inside a group.
struct TVSettingsPaneRowStyle: ButtonStyle {
    private let isDestructive: Bool

    init(isDestructive: Bool = false) {
        self.isDestructive = isDestructive
    }

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, isDestructive: isDestructive)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let isDestructive: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.tvSettingsJoinedRows) private var isJoined

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: isJoined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
            configuration.label
                .padding(.horizontal, TVSettingsLayout.scaled(24))
                .padding(.vertical, TVSettingsLayout.scaled(17))
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(foreground)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(isJoined || isFocused ? Color.clear : Color.vividChromeRestingBorder, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    if isJoined { RowSeparator() }
                }
                .scaleEffect(scale)
                .shadow(color: .black.opacity(isFocused && !isJoined ? 0.2 : 0),
                        radius: isFocused && !isJoined ? TVSettingsLayout.scaled(18) : 0)
                .focusEffectDisabled()
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }

        private var foreground: Color {
            if isDestructive { return isFocused ? Color(hex: "#D22F3F") : .vividError }
            return isFocused ? .vividBackground : .vividOnSurface
        }

        private var fill: Color {
            if isFocused { return .vividOnSurface }
            return isJoined ? .clear : TVSettingsPalette.groupFill
        }

        private var scale: CGFloat {
            guard !isJoined else { return 1 }
            if configuration.isPressed { return 0.98 }
            return isFocused ? 1.012 : 1
        }
    }
}

/// One press flips a setting; the trailing text says On or Off.
struct TVSettingsToggleRow: View {
    private let title: LocalizedStringResource
    private let isOn: Bool
    private let detail: LocalizedStringResource?
    private let action: () -> Void

    init(title: LocalizedStringResource, isOn: Bool, detail: LocalizedStringResource? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: TVSettingsLayout.scaled(16)) {
                TVSettingsRowLabel(title: title, detail: detail)
                Spacer(minLength: TVSettingsLayout.scaled(16))
                if isOn {
                    Text("On").font(.tvSettings(24, weight: .semibold)).opacity(0.9)
                } else {
                    Text("Off").font(.tvSettings(24)).opacity(0.55)
                }
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// A read-only title and value. Never takes focus.
struct TVSettingsInfoRow: View {
    private let title: Text
    private let value: String
    private let showsConnectedDot: Bool
    @Environment(\.tvSettingsJoinedRows) private var isJoined

    init<V: StringProtocol>(title: LocalizedStringKey, value: V, showsConnectedDot: Bool = false) {
        self.title = Text(title)
        self.value = String(value)
        self.showsConnectedDot = showsConnectedDot
    }

    @_disfavoredOverload
    init<T: StringProtocol, V: StringProtocol>(title: T, value: V, showsConnectedDot: Bool = false) {
        self.title = Text(title)
        self.value = String(value)
        self.showsConnectedDot = showsConnectedDot
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isJoined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
        HStack(spacing: TVSettingsLayout.scaled(16)) {
            title
                .font(.tvSettings(26))
                .lineLimit(1)
            Spacer(minLength: TVSettingsLayout.scaled(16))
            if showsConnectedDot {
                Circle()
                    .fill(.green)
                    .frame(width: TVSettingsLayout.scaled(10), height: TVSettingsLayout.scaled(10))
                    .accessibilityHidden(true)
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
        .foregroundStyle(Color.vividOnSurface)
        .background(shape.fill(isJoined ? Color.clear : TVSettingsPalette.groupFill))
        .overlay(shape.strokeBorder(isJoined ? Color.clear : Color.vividChromeRestingBorder, lineWidth: 1))
        .overlay(alignment: .bottom) {
            if isJoined { RowSeparator() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small capitals above a group. Callers pass the text already in capitals.
struct TVSettingsSectionHeader: View {
    private let title: Text
    private let topInset: CGFloat

    init(_ title: LocalizedStringKey, topInset: CGFloat = 26) {
        self.title = Text(title)
        self.topInset = topInset
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, topInset: CGFloat = 26) {
        self.title = Text(title)
        self.topInset = topInset
    }

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

/// A caption under a group.
struct TVSettingsFooter: View {
    private let text: Text

    init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) {
        self.text = Text(text)
    }

    var body: some View {
        text
            .font(.tvSettings(19))
            .foregroundStyle(Color.vividSecondaryText)
            .padding(.horizontal, TVSettingsLayout.scaled(24))
            .padding(.top, TVSettingsLayout.scaled(4))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Confirmation and control buttons

/// Asks before something destructive. Focus starts on Cancel, and Menu or
/// a press outside the panel cancels.
struct TVSettingsConfirmationOverlay: View {
    private let title: String
    private let message: String
    private let confirmTitle: String
    private let cancel: () -> Void
    private let confirm: () -> Void
    @FocusState private var cancelFocused: Bool

    init(title: String, message: String, confirmTitle: String,
         cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancel = cancel
        self.confirm = confirm
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)
            panel
        }
        .defaultFocus($cancelFocused, true, priority: .userInitiated)
        .onAppear { cancelFocused = true }
        .onExitCommand(perform: cancel)
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(30), style: .continuous)
        return VStack(spacing: TVSettingsLayout.scaled(28)) {
            VStack(spacing: TVSettingsLayout.scaled(12)) {
                Text(title)
                    .font(.tvSettings(38, weight: .semibold))
                    .foregroundStyle(Color.vividOnSurface)
                Text(message)
                    .font(.tvSettings(22))
                    .foregroundStyle(Color.vividSecondaryText)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: TVSettingsLayout.scaled(16)) {
                Button(action: cancel) {
                    Text("Cancel")
                        .font(.tvSettings(24, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .frame(width: TVSettingsLayout.scaled(260))
                .focused($cancelFocused)
                Button(action: confirm) {
                    Text(confirmTitle)
                        .font(.tvSettings(24, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                .frame(width: TVSettingsLayout.scaled(260))
            }
        }
        .padding(.horizontal, TVSettingsLayout.scaled(48))
        .padding(.vertical, TVSettingsLayout.scaled(42))
        .background {
            shape.fill(TVSettingsPalette.groupFill)
            shape.strokeBorder(Color.vividChromeRestingBorder, lineWidth: 1)
        }
        .focusSection()
    }
}

/// The compact platter used for page actions such as Done and Edit.
struct TVHomeSectionsControlButtonStyle: ButtonStyle {
    private let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        ControlBody(configuration: configuration, compact: compact)
    }

    private struct ControlBody: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12), style: .continuous)
            configuration.label
                .font(compact ? .tvSettings(24, weight: .semibold) : .tvSettings(20, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 0 : TVSettingsLayout.scaled(22))
                .frame(minWidth: TVSettingsLayout.scaled(compact ? 64 : 120), minHeight: TVSettingsLayout.scaled(64))
                .multilineTextAlignment(.center)
                .background(shape.fill(isFocused ? Color.vividOnSurface : TVSettingsPalette.groupFill))
                .overlay(shape.strokeBorder(isFocused ? Color.clear : Color.vividChromeRestingBorder, lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.97 : isFocused ? 1.04 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.2 : 0), radius: isFocused ? TVSettingsLayout.scaled(16) : 0)
                .focusEffectDisabled()
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }

        private var foreground: Color {
            if !isEnabled { return Color.vividSecondaryText.opacity(0.5) }
            return isFocused ? .vividBackground : .vividOnSurface
        }
    }
}

// MARK: - Pieces shared by the settings panes

extension TVSettingsView {
    /// The category rail's row: like the pane row, but never bordered and
    /// with the system focus effect left on.
    struct RailRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            RailRowBody(configuration: configuration)
        }

        private struct RailRowBody: View {
            let configuration: Configuration
            @Environment(\.isFocused) private var isFocused
            @Environment(\.tvSettingsJoinedRows) private var isJoined

            var body: some View {
                let shape = RoundedRectangle(cornerRadius: isJoined ? 0 : TVSettingsLayout.scaled(14), style: .continuous)
                configuration.label
                    .padding(.horizontal, TVSettingsLayout.scaled(20))
                    .padding(.vertical, TVSettingsLayout.scaled(15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(isFocused ? Color.vividBackground : Color.vividOnSurface)
                    .background(shape.fill(isFocused ? Color.vividOnSurface : isJoined ? Color.clear : TVSettingsPalette.groupFill))
                    .overlay(alignment: .bottom) {
                        if isJoined { RowSeparator() }
                    }
                    .scaleEffect(scale)
                    .shadow(color: .black.opacity(isFocused && !isJoined ? 0.2 : 0),
                            radius: isFocused && !isJoined ? TVSettingsLayout.scaled(18) : 0)
                    .animation(.easeOut(duration: 0.12), value: isFocused)
            }

            private var scale: CGFloat {
                guard !isJoined else { return 1 }
                if configuration.isPressed { return 0.98 }
                return isFocused ? 1.012 : 1
            }
        }
    }

    /// One choice in an option menu.
    struct MenuOption: Identifiable {
        let id: String
        let label: String
        var detail: String? = nil
    }

    /// The label of the option with `id`, or a dash when there's none.
    static func optionLabel(_ options: [MenuOption], _ id: String) -> String {
        options.first { $0.id == id }?.label ?? "—"
    }

    /// A row that opens a system menu of options, with a check on the
    /// current one.
    struct OptionMenu: View {
        let title: LocalizedStringResource
        var detail: LocalizedStringResource? = nil
        let value: String
        let options: [MenuOption]
        let selection: String
        let choose: (String) -> Void

        var body: some View {
            Menu {
                ForEach(options) { option in
                    Button { choose(option.id) } label: {
                        if option.id == selection {
                            Label { optionText(option) } icon: { Image(systemName: "checkmark") }
                        } else {
                            optionText(option)
                        }
                    }
                }
            } label: {
                HStack(spacing: TVSettingsLayout.scaled(16)) {
                    TVSettingsRowLabel(title: title, detail: detail)
                    Spacer(minLength: TVSettingsLayout.scaled(16))
                    Text(verbatim: value)
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

        @ViewBuilder
        private func optionText(_ option: MenuOption) -> some View {
            if let detail = option.detail {
                Text(verbatim: "\(option.label)\n\(detail)")
            } else {
                Text(verbatim: option.label)
            }
        }
    }

    /// A row that pushes a page, with its current value before the chevron.
    struct PickerRowLabel: View {
        let title: LocalizedStringResource
        let value: Text

        var body: some View {
            HStack(spacing: TVSettingsLayout.scaled(16)) {
                TVSettingsRowLabel(title: title)
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
    }

    /// Rows that depend on a parent setting, dimmed while it's off. Each
    /// pane disables the rows themselves.
    struct DependentGroup<Content: View>: View {
        let isEnabled: Bool
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .opacity(isEnabled ? 1 : 0.42)
            .accessibilityHint(isEnabled ? Text(verbatim: "") : Text("Turn on the parent setting to make changes"))
        }
    }

    /// The subtitle preview with the settings corners.
    struct SubtitlePreview: View {
        let appearance: SubtitleAppearance

        var body: some View {
            SubtitleAppearancePreview(appearance: appearance)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
#endif
