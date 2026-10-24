#if os(tvOS)
import SwiftUI
import UIKit

// MARK: - First-run text field
//
// A controlled field so we own the placeholder contrast and focus treatment
// in both states. On tvOS a focused TextField gets a light system platter, so
// the focused state deliberately mirrors that high-contrast treatment.

struct AuroraInputField<F: Hashable>: View {
    @Binding var text: String
    private let placeholder: FieldText
    private let inputTitle: FieldText?
    var focus: FocusState<F?>.Binding
    var equals: F
    var isSecure: Bool = false
    var height: CGFloat = AuroraControl.height
    var contentType: UITextContentType? = nil
    var keyboard: UIKeyboardType = .default

    init(text: Binding<String>, placeholder: LocalizedStringKey, inputTitle: LocalizedStringKey? = nil,
         focus: FocusState<F?>.Binding, equals: F, isSecure: Bool = false, height: CGFloat = AuroraControl.height,
         contentType: UITextContentType? = nil, keyboard: UIKeyboardType = .default) {
        self.init(text: text, placeholder: FieldText.key(placeholder), inputTitle: inputTitle.map { FieldText.key($0) },
                  focus: focus, equals: equals, isSecure: isSecure, height: height,
                  contentType: contentType, keyboard: keyboard)
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(text: Binding<String>, placeholder: S, inputTitle: String? = nil,
                            focus: FocusState<F?>.Binding, equals: F, isSecure: Bool = false, height: CGFloat = AuroraControl.height,
                            contentType: UITextContentType? = nil, keyboard: UIKeyboardType = .default) {
        self.init(text: text, placeholder: FieldText.verbatim(String(placeholder)), inputTitle: inputTitle.map { FieldText.verbatim($0) },
                  focus: focus, equals: equals, isSecure: isSecure, height: height,
                  contentType: contentType, keyboard: keyboard)
    }

    private init(text: Binding<String>, placeholder: FieldText, inputTitle: FieldText?,
                 focus: FocusState<F?>.Binding, equals: F, isSecure: Bool, height: CGFloat,
                 contentType: UITextContentType?, keyboard: UIKeyboardType) {
        self._text = text
        self.placeholder = placeholder
        self.inputTitle = inputTitle
        self.focus = focus
        self.equals = equals
        self.isSecure = isSecure
        self.height = height
        self.contentType = contentType
        self.keyboard = keyboard
    }

    /// A String Catalog key, or a runtime string shown verbatim. The real
    /// field takes its title through the matching SwiftUI initialiser.
    private enum FieldText {
        case key(LocalizedStringKey)
        case verbatim(String)

        var text: Text {
            switch self {
            case .key(let key): Text(key)
            case .verbatim(let string): Text(verbatim: string)
            }
        }
    }

    private var isFocused: Bool { focus.wrappedValue == equals }

    var body: some View {
        ZStack(alignment: .leading) {
            // Visible, fully-controlled content so the field reads as a clean
            // square in every state.
            displayText
                .foregroundStyle(displayColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)

            // The real field drives focus + the on-screen keyboard, but is
            // rendered nearly invisible so the tvOS focus platter — the rounded
            // "pill" that sat inside our square box, and that neither
            // .focusEffectDisabled() nor .textFieldStyle(.plain) can remove —
            // never shows.
            fieldView
                .textFieldStyle(.plain)
                .focused(focus, equals: equals)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .tint(.clear)
                .opacity(0.02)
                .accessibilityLabel((inputTitle ?? placeholder).text)
        }
        .font(.system(size: 26))
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: AuroraControl.corner)
                .fill(isFocused ? AuroraControl.activeFill : Color.vividSurfaceElevated.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuroraControl.corner)
                .stroke(isFocused ? Color.auroraAccent : Color.white.opacity(0.16),
                        lineWidth: isFocused ? 3 : 1)
        )
        .shadow(color: isFocused ? Color.auroraAccent.opacity(0.28) : .clear,
                radius: isFocused ? 16 : 0, y: 0)
        .animation(VividTheme.springAnimation, value: isFocused)
    }

    private var displayText: Text {
        if text.isEmpty { return placeholder.text }
        return Text(verbatim: isSecure ? String(repeating: "•", count: text.count) : text)
    }

    private var displayColor: Color {
        if text.isEmpty {
            return isFocused ? AuroraControl.activePlaceholder : Color.auroraInkTertiary
        }
        return isFocused ? AuroraControl.activeInk : Color.auroraInk
    }

    @ViewBuilder
    private var fieldView: some View {
        switch inputTitle ?? placeholder {
        case .key(let title):
            if isSecure {
                SecureField(title, text: $text)
            } else {
                TextField(title, text: $text)
            }
        case .verbatim(let title):
            if isSecure {
                SecureField(title, text: $text)
            } else {
                TextField(title, text: $text)
            }
        }
    }
}
#endif
