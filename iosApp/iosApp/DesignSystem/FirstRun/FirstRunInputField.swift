#if os(tvOS)
import SwiftUI
import UIKit

/// A first-run text field for Apple TV. The view draws the text itself; the
/// real field sits invisibly on top so the remote can focus it and open the
/// system keyboard. Submit labels and actions come from the caller.
struct AuroraInputField<F: Hashable>: View {
    @Binding private var text: String
    private let placeholder: Text
    private let title: Text
    private let focus: FocusState<F?>.Binding
    private let equals: F
    private let isSecure: Bool
    private let contentType: UITextContentType?
    private let keyboard: UIKeyboardType

    init(
        text: Binding<String>,
        placeholder: LocalizedStringKey,
        inputTitle: LocalizedStringKey? = nil,
        focus: FocusState<F?>.Binding,
        equals: F,
        isSecure: Bool = false,
        contentType: UITextContentType? = nil,
        keyboard: UIKeyboardType = .default
    ) {
        _text = text
        self.placeholder = Text(placeholder)
        title = Text(inputTitle ?? placeholder)
        self.focus = focus
        self.equals = equals
        self.isSecure = isSecure
        self.contentType = contentType
        self.keyboard = keyboard
    }

    @_disfavoredOverload
    init<S: StringProtocol>(
        text: Binding<String>,
        placeholder: S,
        inputTitle: String? = nil,
        focus: FocusState<F?>.Binding,
        equals: F,
        isSecure: Bool = false,
        contentType: UITextContentType? = nil,
        keyboard: UIKeyboardType = .default
    ) {
        _text = text
        self.placeholder = Text(verbatim: String(placeholder))
        title = Text(verbatim: inputTitle ?? String(placeholder))
        self.focus = focus
        self.equals = equals
        self.isSecure = isSecure
        self.contentType = contentType
        self.keyboard = keyboard
    }

    private var isFocused: Bool { focus.wrappedValue == equals }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        ZStack(alignment: .leading) {
            shownText
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            field
                .textFieldStyle(.plain)
                .focused(focus, equals: equals)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .opacity(0.02)
                .tint(.clear)
                .accessibilityLabel(title)
        }
        .font(.system(size: 26))
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 72)
        .background {
            shape.fill(isFocused ? FirstRunMetrics.activeFill : Color.vividSurfaceElevated.opacity(0.82))
        }
        .overlay {
            shape.stroke(isFocused ? Color.auroraAccent : Color.white.opacity(0.16), lineWidth: isFocused ? 3 : 1)
        }
        .shadow(color: Color.auroraAccent.opacity(isFocused ? 0.28 : 0), radius: 16)
        .animation(VividTheme.springAnimation, value: isFocused)
    }

    @ViewBuilder
    private var shownText: some View {
        if text.isEmpty {
            placeholder
                .foregroundStyle(isFocused ? FirstRunMetrics.activePlaceholder : Color.auroraInkTertiary)
        } else {
            Text(verbatim: isSecure ? String(repeating: "\u{2022}", count: text.count) : text)
                .foregroundStyle(isFocused ? FirstRunMetrics.activeInk : Color.auroraInk)
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(text: $text) { title }
        } else {
            TextField(text: $text) { title }
        }
    }
}
#endif
