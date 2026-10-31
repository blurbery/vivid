#if os(iOS)
import SwiftUI
import UIKit

enum AuroraFieldContentType {
    case username
    case password
    case url

    var textContentType: UITextContentType {
        switch self {
        case .username: .username
        case .password: .password
        case .url: .URL
        }
    }
}

enum AuroraFieldKeyboard {
    case `default`
    case url
    case number

    var keyboardType: UIKeyboardType {
        switch self {
        case .default: .default
        case .url: .URL
        case .number: .numberPad
        }
    }
}

/// A labelled first-run text field. It draws its own placeholder and lights
/// up while focused; secure fields can offer a reveal button.
struct AuroraTextField<F: Hashable>: View {
    private let label: Text
    @Binding private var text: String
    private let placeholder: Text
    private let focus: FocusState<F?>.Binding
    private let equals: F
    private let isSecure: Bool
    private let showsRevealToggle: Bool
    private let contentType: AuroraFieldContentType?
    private let keyboard: AuroraFieldKeyboard
    private let submitLabel: SubmitLabel
    private let onSubmit: () -> Void

    @State private var isRevealed = false

    init(
        label: LocalizedStringKey,
        text: Binding<String>,
        placeholder: LocalizedStringKey? = nil,
        focus: FocusState<F?>.Binding,
        equals: F,
        isSecure: Bool = false,
        showsRevealToggle: Bool = false,
        contentType: AuroraFieldContentType? = nil,
        keyboard: AuroraFieldKeyboard = .default,
        submitLabel: SubmitLabel = .next,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.init(
            label: Text(label),
            text: text,
            placeholder: placeholder.map { Text($0) } ?? Text(verbatim: ""),
            focus: focus,
            equals: equals,
            isSecure: isSecure,
            showsRevealToggle: showsRevealToggle,
            contentType: contentType,
            keyboard: keyboard,
            submitLabel: submitLabel,
            onSubmit: onSubmit
        )
    }

    init(
        label: Text,
        text: Binding<String>,
        placeholder: Text = Text(verbatim: ""),
        focus: FocusState<F?>.Binding,
        equals: F,
        isSecure: Bool = false,
        showsRevealToggle: Bool = false,
        contentType: AuroraFieldContentType? = nil,
        keyboard: AuroraFieldKeyboard = .default,
        submitLabel: SubmitLabel = .next,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        _text = text
        self.placeholder = placeholder
        self.focus = focus
        self.equals = equals
        self.isSecure = isSecure
        self.showsRevealToggle = showsRevealToggle
        self.contentType = contentType
        self.keyboard = keyboard
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    private var isFocused: Bool { focus.wrappedValue == equals }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        VStack(alignment: .leading, spacing: 8) {
            FirstRunFieldCaption(label: label)
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        placeholder
                            .foregroundStyle(isFocused ? FirstRunMetrics.activePlaceholder : Color.auroraInkTertiary)
                            .allowsHitTesting(false)
                    }
                    entry
                }
                if showsRevealToggle {
                    revealButton
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background {
                shape.fill(isFocused ? FirstRunMetrics.activeFill : Color.vividSurfaceElevated.opacity(0.82))
            }
            .overlay {
                shape.stroke(isFocused ? Color.auroraAccent : Color.white.opacity(0.16), lineWidth: isFocused ? 2 : 1)
            }
            .shadow(color: Color.auroraAccent.opacity(isFocused ? 0.22 : 0), radius: 12)
            .animation(VividTheme.springAnimation, value: isFocused)
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure && !isRevealed {
            SecureField(text: $text) { Text(verbatim: "") }
        } else {
            TextField(text: $text) { Text(verbatim: "") }
        }
    }

    private var entry: some View {
        field
            .focused(focus, equals: equals)
            .textContentType(contentType?.textContentType)
            .keyboardType(keyboard.keyboardType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
            .foregroundStyle(isFocused ? FirstRunMetrics.activeInk : Color.auroraInk)
            .tint(isFocused ? FirstRunMetrics.activeInk : Color.auroraAccent)
            .accessibilityLabel(label)
    }

    private var revealButton: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                .foregroundStyle(isFocused ? FirstRunMetrics.activeInk.opacity(0.7) : Color.auroraInkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRevealed ? Text("Hide password") : Text("Show password"))
    }
}
#endif
