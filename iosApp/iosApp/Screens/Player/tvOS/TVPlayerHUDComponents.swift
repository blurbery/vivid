#if os(tvOS)
import SwiftUI

// Shared building blocks for the Apple TV player HUD panes: column headers,
// the paging read-only pane, row chrome and the option picker dialog. They
// are nested in `TVPlayerInfoHUD` so they stay out of the app's namespace.

extension TVPlayerInfoHUD {
    // MARK: - Columns

    /// A pane column with a small uppercase header.
    struct PaneColumn<Content: View>: View {
        let header: Text
        let content: () -> Content

        init(_ header: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
            self.header = Text(header)
            self.content = content
        }

        @_disfavoredOverload
        init<S: StringProtocol>(_ header: S, @ViewBuilder content: @escaping () -> Content) {
            self.header = Text(header)
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                header
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A read-only pane that is one focus target. Up and Down page between
    /// `scrollTargetIDs`; Up at the first one hands focus to the tab row.
    struct HUDScrollablePane<Content: View>: View {
        let accessibilityLabel: LocalizedStringKey
        let scrollTargetIDs: [String]
        @Binding var isAtTop: Bool
        let onMoveToTabs: () -> Void
        let content: () -> Content

        @State private var scrollTargetIndex: Int = 0
        @FocusState private var isFocused: Bool

        init(
            accessibilityLabel: LocalizedStringKey,
            scrollTargetIDs: [String] = [],
            isAtTop: Binding<Bool>,
            onMoveToTabs: @escaping () -> Void,
            @ViewBuilder content: @escaping () -> Content
        ) {
            self.accessibilityLabel = accessibilityLabel
            self.scrollTargetIDs = scrollTargetIDs
            self._isAtTop = isAtTop
            self.onMoveToTabs = onMoveToTabs
            self.content = content
        }

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    content()
                        .padding(.trailing, 8)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focusable(true)
                .focused($isFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isFocused ? Color.white.opacity(0.86) : Color.clear, lineWidth: 2)
                        .padding(-10)
                )
                .scaleEffect(isFocused ? 1.01 : 1)
                .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
                .accessibilityLabel(accessibilityLabel)
                .onMoveCommand { direction in
                    handleMove(direction, proxy: proxy)
                }
                .onChange(of: scrollTargetIDs) { _, targets in
                    scrollTargetIndex = min(scrollTargetIndex, max(targets.count - 1, 0))
                }
                .onChange(of: scrollTargetIndex) { _, index in
                    isAtTop = index == 0
                }
                .onAppear {
                    isAtTop = scrollTargetIndex == 0
                }
                .onDisappear {
                    isAtTop = true
                }
            }
        }

        private func handleMove(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
            guard isFocused else { return }

            let nextIndex: Int
            switch direction {
            case .up:
                guard !scrollTargetIDs.isEmpty, scrollTargetIndex > 0 else {
                    onMoveToTabs()
                    return
                }
                nextIndex = scrollTargetIndex - 1
            case .down:
                guard !scrollTargetIDs.isEmpty else { return }
                nextIndex = min(scrollTargetIndex + 1, scrollTargetIDs.count - 1)
            default:
                return
            }

            guard nextIndex != scrollTargetIndex else { return }
            scrollTargetIndex = nextIndex
            withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
                proxy.scrollTo(scrollTargetIDs[nextIndex], anchor: .top)
            }
        }
    }

    /// A label on the left and its value on the right.
    struct LabelValueRow: View {
        let label: String
        let value: String

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 16)
                Text(value)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Row chrome

    /// Chrome for every interactive HUD row: a white fill when focused and a
    /// faint wash when the row is the current selection. It draws the whole
    /// focus look from `@Environment(\.isFocused)` and turns the system
    /// effect off.
    struct HUDRowButtonStyle: ButtonStyle {
        var cornerRadius: CGFloat = 10
        var isSelected: Bool = false

        func makeBody(configuration: Configuration) -> some View {
            HUDRowButtonBody(configuration: configuration, cornerRadius: cornerRadius, isSelected: isSelected)
        }
    }

    private struct HUDRowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let isSelected: Bool

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(background)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .focusEffectDisabled()
                .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
                .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
        }

        private var background: Color {
            if isFocused { return .white }
            if isSelected { return .white.opacity(0.14) }
            return .clear
        }
    }

    /// A row with a chevron that opens a picker.
    struct HUDSettingRow: View {
        let label: LocalizedStringKey
        let value: String
        var colorHex: String? = nil
        var systemImage: String? = nil
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HUDSettingRowLabel(
                    label: label,
                    value: value,
                    colorHex: colorHex,
                    systemImage: systemImage,
                    showsChevron: true
                )
            }
            .buttonStyle(HUDRowButtonStyle())
            .accessibilityLabel(label)
            .accessibilityValue(value)
        }
    }

    /// An On/Off row that flips with one Select.
    struct HUDToggleRow: View {
        let label: LocalizedStringKey
        let isOn: Bool
        let onToggle: (Bool) -> Void

        var body: some View {
            Button { onToggle(!isOn) } label: {
                HUDSettingRowLabel(
                    label: label,
                    value: HUDPickerOptions.boolLabel(isOn),
                    showsChevron: false
                )
            }
            .buttonStyle(HUDRowButtonStyle())
            .accessibilityLabel(label)
            .accessibilityValue(HUDPickerOptions.boolLabel(isOn))
            .accessibilityAddTraits(.isToggle)
        }
    }

    private struct HUDSettingRowLabel: View {
        let label: LocalizedStringKey
        let value: String
        var colorHex: String? = nil
        var systemImage: String? = nil
        let showsChevron: Bool

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            HStack(spacing: 14) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 22, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 18)
                HStack(spacing: 10) {
                    if let colorHex {
                        ColorSwatch(hex: colorHex)
                    }
                    Text(value)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isFocused ? .black.opacity(0.78) : .white.opacity(0.72))
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.45))
                    }
                }
            }
            .foregroundStyle(isFocused ? Color.black : Color.white)
        }
    }

    /// An audio or subtitle track, with a tick when selected.
    struct HUDTrackRow: View {
        let name: String
        let attributes: String?
        let isSelected: Bool
        var isDisabled: Bool = false
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HUDTrackRowLabel(name: name, attributes: attributes, isSelected: isSelected)
            }
            .buttonStyle(HUDRowButtonStyle(cornerRadius: 8))
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.35 : 1.0)
            .accessibilityLabel(name)
            .accessibilityValue(isSelected ? "Selected" : "")
        }
    }

    private struct HUDTrackRowLabel: View {
        let name: String
        let attributes: String?
        let isSelected: Bool

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isFocused ? .black : .white)
                        .lineLimit(1)
                    if let attributes {
                        Text(attributes)
                            .font(.system(size: 17))
                            .foregroundStyle(isFocused ? .black.opacity(0.62) : .white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isFocused ? .black : .white)
                }
            }
        }
    }

    /// The round close button on the subtitle appearance dialog.
    struct HUDCircleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            HUDCircleButtonBody(configuration: configuration)
        }
    }

    private struct HUDCircleButtonBody: View {
        let configuration: ButtonStyleConfiguration

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .frame(width: 46, height: 46)
                .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(0.14)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .focusEffectDisabled()
                .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
        }
    }

    struct HUDCloseButtonLabel: View {
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
        }
    }

    struct ColorSwatch: View {
        let hex: String

        var body: some View {
            Circle()
                .fill(Self.color(hex: hex))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
        }

        /// `#RRGGBB` or `RRGGBB`; anything else draws white.
        private static func color(hex: String) -> Color {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
                return .white
            }
            return Color(
                red: Double((value >> 16) & 0xFF) / 255.0,
                green: Double((value >> 8) & 0xFF) / 255.0,
                blue: Double(value & 0xFF) / 255.0
            )
        }
    }

    // MARK: - Pickers

    struct HUDDropdownOption: Identifiable, Hashable {
        let id: String
        let label: String
        var colorHex: String? = nil
        var detail: String? = nil
    }

    enum HUDPickerOptions {
        static func boolLabel(_ value: Bool) -> String {
            value ? String(localized: "On") : String(localized: "Off")
        }

        static func delayLabel(_ milliseconds: Int) -> String {
            if milliseconds > 0 {
                return String(localized: "+\(milliseconds) ms", comment: "Subtitle delay in milliseconds, later")
            }
            return String(localized: "\(milliseconds) ms", comment: "Subtitle delay in milliseconds")
        }

        /// Subtitle delay up to 10 seconds either way:
        /// 100 ms steps within 2 seconds and 500 ms steps beyond, since a
        /// downloaded file can be several seconds out. The current value is
        /// always on the list.
        static func subtitleDelayOptions(including currentValue: Int) -> [HUDDropdownOption] {
            let fine = Array(stride(from: -2_000, through: 2_000, by: 100))
            let coarse = Array(stride(from: 2_500, through: 10_000, by: 500))
            let values = fine + coarse + coarse.map { -$0 } + [currentValue]
            return Set(values).sorted().map { HUDDropdownOption(id: String($0), label: delayLabel($0)) }
        }

        static let subtitleSizeOptions: [HUDDropdownOption] =
            SubtitleFontSizePreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

        static let subtitlePositionOptions: [HUDDropdownOption] =
            SubtitlePositionPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }
    }

    struct HUDPickerPresentation: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let options: [HUDDropdownOption]
        let selection: String
        let onSelect: (String) -> Void
    }

    /// The open picker, if any, and the row that opened it, which takes
    /// focus back when the picker closes.
    struct HUDPickerState<Field: Hashable> {
        private(set) var presentation: HUDPickerPresentation?
        private var returnField: Field?

        var isPresented: Bool { presentation != nil }

        mutating func present(_ presentation: HUDPickerPresentation, returningTo field: Field) {
            returnField = field
            self.presentation = presentation
        }

        /// Closes the picker and returns the row to refocus.
        mutating func close() -> Field? {
            presentation = nil
            return returnField
        }
    }

    /// A modal option list over a dimmed, disabled pane; disabling the pane
    /// is what keeps focus in here. Movement and keep-visible scrolling are
    /// native, and focus starts on the current selection.
    struct HUDPickerDialog: View {
        let title: LocalizedStringKey
        let options: [HUDDropdownOption]
        let selection: String
        let onSelect: (String) -> Void
        let onClose: () -> Void

        @FocusState private var focusedOptionID: String?

        init(_ presentation: HUDPickerPresentation, onClose: @escaping () -> Void) {
            title = presentation.title
            options = presentation.options
            selection = presentation.selection
            onSelect = presentation.onSelect
            self.onClose = onClose
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: options.count > 7) {
                        VStack(spacing: 4) {
                            ForEach(options) { option in
                                HUDPickerOptionRow(
                                    option: option,
                                    isSelected: isSelected(option)
                                ) {
                                    onSelect(option.id)
                                    onClose()
                                }
                                .focused($focusedOptionID, equals: option.id)
                                .id(option.id)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .onAppear {
                        if let initialFocusID {
                            proxy.scrollTo(initialFocusID, anchor: .center)
                            focusedOptionID = initialFocusID
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(width: 620, alignment: .topLeading)
            .vividPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.62), radius: 26, y: 14)
            .focusSection()
            .defaultFocus($focusedOptionID, initialFocusID)
            .onExitCommand(perform: onClose)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }

        private func isSelected(_ option: HUDDropdownOption) -> Bool {
            option.id.caseInsensitiveCompare(selection) == .orderedSame
        }

        private var initialFocusID: String? {
            options.first(where: isSelected)?.id ?? options.first?.id
        }
    }

    private struct HUDPickerOptionRow: View {
        let option: HUDDropdownOption
        let isSelected: Bool
        let onSelect: () -> Void

        var body: some View {
            Button(action: onSelect) {
                HUDPickerOptionLabel(option: option, isSelected: isSelected)
            }
            .buttonStyle(HUDRowButtonStyle(isSelected: isSelected))
            .accessibilityLabel(option.label)
            .accessibilityValue(isSelected ? "Selected" : "")
        }
    }

    private struct HUDPickerOptionLabel: View {
        let option: HUDDropdownOption
        let isSelected: Bool

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            HStack(spacing: 14) {
                if let colorHex = option.colorHex {
                    ColorSwatch(hex: colorHex)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(option.label)
                        .font(.system(size: 24, weight: .medium))
                        .lineLimit(1)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 18))
                            .opacity(0.72)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                Spacer(minLength: 12)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                }
            }
            .foregroundStyle(isFocused ? Color.black : Color.white)
        }
    }
}
#endif
