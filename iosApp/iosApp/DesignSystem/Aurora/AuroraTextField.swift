#if !os(tvOS)
import SwiftUI

// MARK: - Field content classification (platform-neutral)

/// Mirrors the small enum pattern in the old Vivid forms so the shared
/// component carries no UIKit types in its signature — macOS has no
/// `UITextContentType`.
enum AuroraFieldContentType { case username, password, email, oneTimeCode, url }
enum AuroraFieldKeyboard { case `default`, url, email, number }

// MARK: - Field label

struct AuroraFieldLabel: View {
    private let text: Text
    init(_ text: LocalizedStringKey) { self.text = Text(text) }
    @_disfavoredOverload init<S: StringProtocol>(_ text: S) { self.text = Text(text) }
    init(_ text: Text) { self.text = text }
    var body: some View {
        text
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(Color.auroraInkTertiary)
            .textCase(.uppercase)
    }
}

// MARK: - Inline error row

struct AuroraErrorLabel: View {
    private let text: Text
    init(_ text: LocalizedStringKey) { self.text = Text(text) }
    @_disfavoredOverload init<S: StringProtocol>(_ text: S) { self.text = Text(text) }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            text
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.vividCaption)
        .foregroundStyle(Color.requestRose)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(text)")
    }
}

// MARK: - Editable first-run field (iOS/macOS)
//
// The placeholder is a controlled overlay so its contrast remains predictable;
// the live `TextField`/`SecureField` owns caret, selection, and keyboard.

struct AuroraTextField<F: Hashable>: View {
    private let label: Text
    @Binding var text: String
    private let placeholder: Text
    var focus: FocusState<F?>.Binding
    var equals: F
    var isSecure: Bool = false
    var showsRevealToggle: Bool = false
    var contentType: AuroraFieldContentType? = nil
    var keyboard: AuroraFieldKeyboard = .default
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    init(label: LocalizedStringKey, text: Binding<String>, placeholder: LocalizedStringKey? = nil,
         focus: FocusState<F?>.Binding, equals: F, isSecure: Bool = false, showsRevealToggle: Bool = false,
         contentType: AuroraFieldContentType? = nil, keyboard: AuroraFieldKeyboard = .default,
         submitLabel: SubmitLabel = .next, onSubmit: @escaping () -> Void = {}) {
        self.init(label: Text(label), text: text, placeholder: placeholder.map { Text($0) } ?? Text(verbatim: ""),
                  focus: focus, equals: equals, isSecure: isSecure, showsRevealToggle: showsRevealToggle,
                  contentType: contentType, keyboard: keyboard, submitLabel: submitLabel, onSubmit: onSubmit)
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(label: S, text: Binding<String>, placeholder: String = "",
                            focus: FocusState<F?>.Binding, equals: F, isSecure: Bool = false, showsRevealToggle: Bool = false,
                            contentType: AuroraFieldContentType? = nil, keyboard: AuroraFieldKeyboard = .default,
                            submitLabel: SubmitLabel = .next, onSubmit: @escaping () -> Void = {}) {
        self.init(label: Text(label), text: text, placeholder: Text(placeholder),
                  focus: focus, equals: equals, isSecure: isSecure, showsRevealToggle: showsRevealToggle,
                  contentType: contentType, keyboard: keyboard, submitLabel: submitLabel, onSubmit: onSubmit)
    }

    /// Mixes a localised and a verbatim string, e.g. `Text("Label")` and `Text(value)`.
    init(label: Text, text: Binding<String>, placeholder: Text = Text(verbatim: ""),
         focus: FocusState<F?>.Binding, equals: F, isSecure: Bool = false, showsRevealToggle: Bool = false,
         contentType: AuroraFieldContentType? = nil, keyboard: AuroraFieldKeyboard = .default,
         submitLabel: SubmitLabel = .next, onSubmit: @escaping () -> Void = {}) {
        self.label = label
        self._text = text
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

    @State private var reveal = false
    private var isFocused: Bool { focus.wrappedValue == equals }
    private var effectiveSecure: Bool { isSecure && !reveal }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuroraFieldLabel(label)
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        placeholder
                            .foregroundStyle(isFocused ? AuroraControl.activePlaceholder : Color.auroraInkTertiary)
                            .allowsHitTesting(false)
                    }
                    inputField
                        .accessibilityLabel(label)
                        .focused(focus, equals: equals)
                        .foregroundStyle(isFocused ? AuroraControl.activeInk : Color.auroraInk)
                        .tint(isFocused ? AuroraControl.activeInk : Color.auroraAccent)
                        .submitLabel(submitLabel)
                        .onSubmit(onSubmit)
                        #if !os(macOS)
                        .textContentType(uiContentType)
                        .keyboardType(uiKeyboard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                if showsRevealToggle {
                    Button {
                        reveal.toggle()
                    } label: {
                        Image(systemName: reveal ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(isFocused ? AuroraControl.activeInk.opacity(0.7) : Color.auroraInkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? "Hide password" : "Show password")
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .frame(height: AuroraControl.height)
            .background(
                    RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .fill(isFocused ? AuroraControl.activeFill : Color.vividSurfaceElevated.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .stroke(isFocused ? Color.auroraAccent : Color.white.opacity(0.16),
                            lineWidth: isFocused ? 2 : 1)
            )
            .shadow(color: isFocused ? Color.auroraAccent.opacity(0.22) : .clear,
                    radius: isFocused ? 12 : 0)
            .animation(VividTheme.springAnimation, value: isFocused)
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if effectiveSecure {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }

    #if !os(macOS)
    private var uiContentType: UITextContentType? {
        switch contentType {
        case .username: .username
        case .password: .password
        case .email: .emailAddress
        case .oneTimeCode: .oneTimeCode
        case .url: .URL
        case .none: nil
        }
    }
    private var uiKeyboard: UIKeyboardType {
        switch keyboard {
        case .default: .default
        case .url: .URL
        case .email: .emailAddress
        case .number: .numberPad
        }
    }
    #endif
}

// MARK: - Screen scaffold

/// Vivid backdrop + a vertically scrollable, keyboard-friendly column capped
/// to a comfortable reading width. Callers supply the wordmark + content.
struct AuroraScreen<Content: View>: View {
    var variant: AuroraVariant
    var scrim: AuroraScrim = .soft
    var maxContentWidth: CGFloat = 480
    @ViewBuilder var content: () -> Content

    init(variant: AuroraVariant,
         scrim: AuroraScrim = .soft,
         maxContentWidth: CGFloat = 480,
         @ViewBuilder content: @escaping () -> Content) {
        self.variant = variant
        self.scrim = scrim
        self.maxContentWidth = maxContentWidth
        self.content = content
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) { content() }
                        .frame(maxWidth: maxContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 32)
                        .frame(minHeight: geo.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
