#if os(tvOS)
import SwiftUI

enum TVSettingsLayout {
    static let contentWidth: CGFloat = 812
    static let pageWidth: CGFloat = contentWidth + 48
}

enum TVSettingsPalette {
    static let groupFill = Color(hex: "#3B454C")
    static let selectedFill = Color(hex: "#4B5963")
    static let iconFill = Color.white.opacity(0.06)
    static let separator = Color.white.opacity(0.08)
    static let sectionText = Color(white: 0.68)
}

struct TVSettingsPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let actions: () -> Actions

    init(title: String, subtitle: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }
            Spacer(minLength: 0)
            actions()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}

extension TVSettingsPageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct TVSettingsOverview<Profiles: View, Categories: View>: View {
    @ViewBuilder let profiles: () -> Profiles
    @ViewBuilder let categories: () -> Categories

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TVSettingsPageHeader(title: "Settings")
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionHeader("PROFILES", topInset: 0)
                profiles()
            }
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionHeader("SETTINGS", topInset: 0)
                VStack(spacing: 10) { categories() }
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
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct TVSettingsFieldRow<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsRowLabel(title: title, detail: detail)
            content
        }
        .padding(24)
        .overlay(alignment: .bottom) { Rectangle().fill(TVSettingsPalette.separator).frame(height: 1).padding(.leading, 24) }
    }
}

struct TVSettingsRowLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .medium))
            if let text = detail ?? Self.descriptions[title] {
                Text(text).font(.system(size: 19)).opacity(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private static let descriptions: [String: String] = [
        "Home Screen": "Choose up to three rows for your discovery spotlight.",
        "Home Sections": "Choose which rows appear on Home and arrange their order.",
        "Poster Size": "Adjust card sizes on Home only.",
        "Captions": "Choose titles and years, titles only, or artwork only.",
        "Use Profile Default": "Restore Large Home posters and Title & Year captions.",
        "Customise Tab Bar": "Reorder or hide tabs. Changes save automatically.",
        "Quality": "Preferred playback resolution and bitrate.",
        "Audio Language": "Prefer a matching audio track when available.",
        "Buffer Ahead": "Automatic prepares about 40 seconds ahead. Larger buffers use more storage. Applies to the next video.",
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
            unsetLabel: "No preference"
        )
    }

    static let bufferAhead: [TVSettingsOption] =
        BufferAheadMode.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let nextUpPrompt: [TVSettingsOption] = [
        .init(id: "0", label: "At end"),
        .init(id: "10", label: "10 seconds before end"),
        .init(id: "30", label: "30 seconds before end"),
        .init(id: "60", label: "1 minute before end"),
        .init(id: "120", label: "2 minutes before end"),
    ]

    static func subtitleLanguage(_ languages: [PlaybackLanguageOption]) -> [TVSettingsOption] {
        languageOptions(
            languages,
            unsetID: PlaybackPrefSentinel.none,
            unsetLabel: "No preference"
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
        .init(id: "small",   label: "Small"),
        .init(id: "medium",  label: "Medium"),
        .init(id: "large",   label: "Large"),
        .init(id: "xlarge",  label: "X-Large"),
        .init(id: "xxlarge", label: "XX-Large"),
    ]

    static let fontColor: [TVSettingsOption] =
        SubtitleAppearance.fontColors.map { .init(id: $0.hex, label: $0.label) }

    static let backgroundStyle: [TVSettingsOption] =
        SubtitleBackgroundStylePreset.selectableCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let backgroundOpacity: [TVSettingsOption] =
        stride(from: 0, through: 100, by: 5).map { .init(id: String($0), label: "\($0)%") }

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
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(foreground)
            .background(
                RoundedRectangle(cornerRadius: joined ? 0 : 14, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: joined ? 0 : 14, style: .continuous)
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
                    .frame(width: 4)
                    .padding(.vertical, 12)
                    .opacity(isSelected && !isFocused ? 1 : 0)
            }
            .scaleEffect(joined ? 1 : (configuration.isPressed ? 0.98 : (isFocused ? 1.012 : 1)))
            .shadow(
                color: isFocused && !joined ? Color.black.opacity(0.2) : .clear,
                radius: 18
            )
            .overlay(alignment: .bottom) {
                if joined { Rectangle().fill(TVSettingsPalette.separator).frame(height: 1).padding(.leading, 24) }
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
            .padding(.horizontal, 24)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(foreground)
            .background(
                RoundedRectangle(cornerRadius: joined ? 0 : 14, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: joined ? 0 : 14, style: .continuous)
                    .strokeBorder(
                        borderColor,
                        lineWidth: 1
                    )
            )
            .scaleEffect(joined ? 1 : (configuration.isPressed ? 0.98 : (isFocused ? 1.012 : 1)))
            .shadow(
                color: isFocused && !joined ? Color.black.opacity(0.2) : .clear,
                radius: 18
            )
            .focusEffectDisabled()
            .overlay(alignment: .bottom) {
                if joined { Rectangle().fill(TVSettingsPalette.separator).frame(height: 1).padding(.leading, 24) }
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
    let title: String
    let value: String
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                TVSettingsRowLabel(title: title, detail: detail)
                Spacer(minLength: 16)
                Text(value)
                    .font(.system(size: 24))
                    .opacity(0.68)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
    }
}

/// The system owns option presentation, selection and focus return.
struct TVSettingsOptionMenu: View {
    let title: String
    let value: String
    var detail: String? = nil
    let options: [TVSettingsOption]
    let selection: Binding<String>

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
            HStack(spacing: 16) {
                TVSettingsRowLabel(title: title, detail: detail)
                Spacer(minLength: 16)
                Text(value)
                    .font(.system(size: 24))
                    .opacity(0.68)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 16, weight: .semibold))
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
    let title: String
    let isOn: Bool
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                TVSettingsRowLabel(title: title, detail: detail)
                Spacer(minLength: 16)
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 24, weight: isOn ? .semibold : .regular))
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
    let title: String
    let value: String
    var showsConnectedDot = false

    @Environment(\.tvSettingsJoinedRows) private var joined
    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 26))
                .lineLimit(1)
            Spacer(minLength: 16)
            if showsConnectedDot {
                Circle().fill(.green).frame(width: 10, height: 10).accessibilityHidden(true)
            }
            Text(value)
                .font(.system(size: 24))
                .opacity(0.68)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(.vividOnSurface)
        .background(
            RoundedRectangle(cornerRadius: joined ? 0 : 14, style: .continuous)
                .fill(joined ? Color.clear : TVSettingsPalette.groupFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: joined ? 0 : 14, style: .continuous)
                .strokeBorder(joined ? Color.clear : Color.vividChromeRestingBorder, lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if joined { Rectangle().fill(TVSettingsPalette.separator).frame(height: 1).padding(.leading, 24) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section header / footer

/// Mono uppercase section eyebrow, matching the Skyline dropdown and
/// filter-panel header grammar.
struct TVSettingsSectionHeader: View {
    let title: String
    var topInset: CGFloat = 26

    init(_ title: String, topInset: CGFloat = 26) { self.title = title; self.topInset = topInset }

    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(TVSettingsPalette.sectionText)
            .padding(.horizontal, 24)
            .padding(.top, topInset)
            .padding(.bottom, 6)
    }
}

/// Explanatory caption under a section's rows.
struct TVSettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 19))
            .foregroundColor(.vividSecondaryText)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Confirmation overlay

/// Settings-styled destructive confirmation used instead of the native tvOS
/// alert, whose app-wide tint can leave focused Cancel text without contrast.
struct TVSettingsConfirmationOverlay: View {
    let title: String
    let message: String
    let confirmTitle: String
    var additionalDestructiveTitle: String? = nil
    let cancel: () -> Void
    let confirm: () -> Void
    var additionalDestructiveAction: (() -> Void)? = nil

    @FocusState private var focusedAction: Action?

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)

            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.vividOnSurface)

                    Text(message)
                        .font(.system(size: 22))
                        .foregroundColor(.vividSecondaryText)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    Button(action: cancel) {
                        Text("Cancel")
                            .font(.system(size: 24, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .frame(width: buttonWidth)
                        .focused($focusedAction, equals: .cancel)

                    Button(action: confirm) {
                        Text(confirmTitle)
                            .font(.system(size: 24, weight: .semibold))
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
                            Text(additionalDestructiveTitle)
                                .font(.system(size: 24, weight: .semibold))
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
            .padding(.horizontal, 48)
            .padding(.vertical, 42)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(TVSettingsPalette.groupFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
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
        additionalDestructiveTitle == nil ? 260 : 320
    }
}

// MARK: - Vivid privacy policy

struct TVPrivacyPolicyOverlay: View {
    let dismiss: () -> Void
    @FocusState private var focusedSection: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                TVSettingsPageHeader(title: "Privacy Policy", subtitle: "App privacy information · Updated 11 September 2026")
                policySection("Your accounts and media server", "Vivid connects to the media servers you choose. Your server receives the sign-in details and requests needed to provide your account, library, artwork and playback. The server operator controls that information and may keep its own logs and records. Vivid’s policy does not replace your server operator’s privacy policy.")
                policySection("Information on this Apple TV", "Vivid saves preferences, Home metadata, artwork and playback buffers on this Apple TV. Saved account session tokens and optional Vivid PIN records use Keychain. The saved-account feature does not retain the media-server password you enter.")
                policySection("Private iCloud account sync", "When iCloud is available, Vivid stores saved server addresses, account and viewing-profile details, login sessions, optional Vivid PIN records and profile order in encrypted fields in your private iCloud database. Shared browsing, navigation, metadata and download preferences, plus configured Trailers, MDBList, OpenSubtitles and Seerr connection details, also sync between your iPhone, iPad and Apple TV for the matching server account and viewing profile. Playback and subtitle preferences, downloaded media, artwork and metadata caches stay on the device. Playback history and resume positions stay with your media server. Optional MDBList imports add local watched indicators, described below.")
                policySection("Playback and connected features", "Vivid sends playback position, pause state and watched-progress updates to the selected server. Subtitles and chapters are read from the opened media on this device. If you connect OpenSubtitles in Plugins, searches send the title, language, media type, season number and episode number to OpenSubtitles. Chosen subtitle files are downloaded temporarily to this device. A small, limited memory cache reuses recent downloads during the app session and clears when the connection changes. Your API key stays in Keychain, separate for each server account and profile, and syncs through the encrypted private iCloud account vault. Searches send the key only to the OpenSubtitles API. Subtitles are not uploaded to your media server. Subtitle translation is not provided. If you configure TMDb trailers, your personal API credential is stored in Keychain and sent to TMDb with media identifiers for trailers and missing Emby metadata IDs. Opening a trailer connects to YouTube. These services receive normal connection information and apply their own privacy policies.")
                policySection("Optional skip timestamp lookups", "With Intro & Credit Skipper enabled in Playback settings, Vivid can send the series IMDb ID, season and episode number to api.introdb.app and api.theintrodb.org to fill missing intro, recap and credits timestamps. These services also receive normal connection information such as your IP address. Vivid does not send your media-server credentials. The skipper is enabled by default, can be turned off in Playback settings, and does not require an API key.")
                policySection("Optional MDBList connection", "If you connect MDBList in Settings → Plugins, Vivid keeps your personal API key in this device’s Keychain. It reads watched history and sends completed movie and episode identifiers and watched dates to MDBList. Movie and series watchlist additions and removals also sync in both directions for matching titles on the active media server. Media-server credentials are never sent to MDBList. The connection syncs through the encrypted private iCloud account vault for the same server account and viewing profile. Imported watched indicators and sync checkpoints remain on each device, including after a connection failure. Reconnecting the same MDBList account reuses saved progress while checking for remote changes. Imports skip already-watched items, active watches and rewatches, and unknown or non-zero resume positions. They never overwrite server watch history or resume positions. Disconnecting stops syncing without deleting watched history or watchlists.")
                policySection("Optional Seerr connection", "If you configure Seerr, Vivid stores its URL, username and password in Keychain on this Apple TV to restore your connection. Seerr receives your login, search queries and media requests. Disconnect in Settings → Seerr to remove the saved connection. Your Seerr operator controls records kept on that server.")
                policySection("Diagnostics", "Vivid does not capture or upload in-app diagnostics reports. Technical logs used for development and troubleshooting stay local. Apple’s TestFlight service separately collects beta usage, crash information and submitted feedback under its own privacy terms.")
                policySection("Your controls", "You can clear Home metadata and unused artwork from Settings → Metadata. Manual Sign Out clears the current saved-account session while keeping its profile card for later sign-in, and that signed-out state syncs through iCloud. Deleting a saved account on this Apple TV or another Vivid device records the deletion in the private vault so a stale device cannot add it back; signing in again later can restore it. Removing Vivid clears data stored by this Apple TV but does not delete the private iCloud vault, data on another device or records held by your media server. Contact the server operator about information stored there.")
                policySection("Contact and changes", "For questions about Vivid, contact admin@vividapp.co. Vivid is in development; this information will be updated as its features and data handling change.")
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
        .defaultFocus($focusedSection, "Your accounts and media server")
        .onExitCommand(perform: dismiss)
    }

    private func policySection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 27, weight: .semibold))
            Text(text).font(.system(size: 22)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
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
