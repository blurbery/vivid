import SwiftUI

/// Sizes and colours shared by the sign-in, server setup and profile
/// preparation controls.
enum FirstRunMetrics {
    #if os(tvOS)
    static let controlHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 12
    #else
    static let controlHeight: CGFloat = 52
    static let cornerRadius: CGFloat = 10
    #endif

    /// Fill and text of a focused control.
    static let activeFill = Color.vividOnSurface
    static let activeInk = Color.vividBackground
    static let activePlaceholder = Color(.sRGB, red: 94 / 255, green: 98 / 255, blue: 105 / 255)

    static let cardTint = Color.vividSurfaceVariant
}

/// Which first-run screen is shown. The screens currently look the same.
enum AuroraVariant {
    case signIn
    case server
    case profile
}

enum AuroraScrim {
    case soft
}

// MARK: - Eyebrow

/// A small upper-case caption above a first-run title, always centred.
/// `centered` has no effect: every caller passes `true`, and the label stays
/// so those calls compile unchanged.
struct AuroraEyebrow: View {
    private let text: LocalizedStringKey

    init(text: LocalizedStringKey, centered: Bool = true) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: Self.fontSize, weight: .semibold, design: .monospaced))
            .tracking(Self.tracking)
            .textCase(.uppercase)
            .foregroundStyle(Color.auroraAccent)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }

    #if os(tvOS)
    private static let fontSize: CGFloat = 15
    private static let tracking: CGFloat = 2.6
    #else
    private static let fontSize: CGFloat = 11
    private static let tracking: CGFloat = 1.5
    #endif
}

// MARK: - Glass card

extension View {
    /// The glass card that holds a first-run form. Emphasised cards add a
    /// soft glow and a brighter rim.
    func auroraGlass(cornerRadius: CGFloat = 28, emphasized: Bool = false) -> some View {
        modifier(FirstRunCard(cornerRadius: cornerRadius, emphasized: emphasized))
    }
}

private struct FirstRunCard: ViewModifier {
    let cornerRadius: CGFloat
    let emphasized: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .vividGlass(in: shape, tint: FirstRunMetrics.cardTint.opacity(0.72))
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: rimColours, startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .background {
                if emphasized {
                    shape
                        .fill(Color.auroraAccent.opacity(0.10))
                        .padding(-4)
                        .blur(radius: 34)
                }
            }
            .shadow(color: .black.opacity(0.55), radius: 36, x: 0, y: 22)
    }

    private var rimColours: [Color] {
        emphasized
            ? [Color.auroraAccent.opacity(0.42), .white.opacity(0.12), .white.opacity(0.04)]
            : [.white.opacity(0.22), .white.opacity(0.08), .white.opacity(0.03)]
    }
}

// MARK: - Primary button

/// The full-width main action, with a spinner while `isLoading`.
struct AuroraPrimaryButtonStyle: ButtonStyle {
    private let isLoading: Bool

    init(isLoading: Bool = false) {
        self.isLoading = isLoading
    }

    func makeBody(configuration: Configuration) -> some View {
        FirstRunPrimaryButton(configuration: configuration, isLoading: isLoading)
    }
}

private struct FirstRunPrimaryButton: View {
    let configuration: ButtonStyleConfiguration
    let isLoading: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(tvOS)
    private static let fontSize: CGFloat = 24
    private static let sideInset: CGFloat = 30
    #else
    private static let fontSize: CGFloat = 17
    private static let sideInset: CGFloat = 20
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FirstRunMetrics.cornerRadius)
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .tint(FirstRunMetrics.activeInk)
                    .scaleEffect(0.8)
            }
            configuration.label
        }
        .font(.system(size: Self.fontSize, weight: .semibold))
        .foregroundStyle(FirstRunMetrics.activeInk)
        .padding(.horizontal, Self.sideInset)
        .frame(maxWidth: .infinity, minHeight: FirstRunMetrics.controlHeight)
        .background {
            shape.fill(FirstRunMetrics.activeFill)
        }
        .overlay {
            shape.stroke(Color.auroraAccent, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        }
        .overlay {
            shape.stroke(Color.auroraAccent.opacity(0.40), lineWidth: 6)
                .padding(-4)
                .blur(radius: 6)
                .opacity(isFocused ? 1 : 0)
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.035 : 1)
        .shadow(
            color: isFocused ? Color.auroraAccent.opacity(0.28) : Color.black.opacity(0.30),
            radius: isFocused ? 20 : 10,
            x: 0,
            y: 6
        )
        .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        .focusEffectDisabled()
        .animation(VividTheme.springAnimation, value: isFocused)
    }
}

// MARK: - Ghost button

/// A quiet secondary action that hugs its label.
struct AuroraGhostButtonStyle: ButtonStyle {
    init() {}

    func makeBody(configuration: Configuration) -> some View {
        FirstRunGhostButton(configuration: configuration)
    }
}

private struct FirstRunGhostButton: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused

    #if os(tvOS)
    private static let fontSize: CGFloat = 22
    private static let horizontalPadding: CGFloat = 22
    private static let verticalPadding: CGFloat = 12
    #else
    private static let fontSize: CGFloat = 15
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 9
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FirstRunMetrics.cornerRadius)
        configuration.label
            .font(.system(size: Self.fontSize, weight: .medium))
            .foregroundStyle(isFocused ? FirstRunMetrics.activeInk : Color.auroraInkSecondary)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background {
                shape.fill(isFocused ? Color.auroraInk : Color.white.opacity(0.06))
            }
            .overlay {
                shape.stroke(isFocused ? Color.white : Color.white.opacity(0.14), lineWidth: isFocused ? 2 : 1)
            }
            .scaleEffect(isFocused ? 1.025 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .focusEffectDisabled()
            .animation(VividTheme.springAnimation, value: isFocused)
    }
}

// MARK: - Segment

/// One of a row of equal-width choices, such as HTTP or HTTPS. The enclosing
/// button supplies the action and accessibility.
struct AuroraSegment: View {
    private let title: String
    private let isSelected: Bool
    private let isFocused: Bool

    init<S: StringProtocol>(title: S, isSelected: Bool, isFocused: Bool) {
        self.title = String(title)
        self.isSelected = isSelected
        self.isFocused = isFocused
    }

    #if os(tvOS)
    private static let checkmarkSize: CGFloat = 16
    private static let titleSize: CGFloat = 21
    #else
    private static let checkmarkSize: CGFloat = 11
    private static let titleSize: CGFloat = 15
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FirstRunMetrics.cornerRadius)
        HStack(spacing: 8) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: Self.checkmarkSize, weight: .bold))
            }
            Text(verbatim: title)
                .font(.system(size: Self.titleSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity)
        .frame(height: FirstRunMetrics.controlHeight)
        .background {
            shape.fill(fill)
        }
        .overlay {
            shape.stroke(outline, lineWidth: 1.5)
        }
        .animation(VividTheme.springAnimation, value: isFocused)
    }

    private var ink: Color {
        if isFocused { return FirstRunMetrics.activeInk }
        return isSelected ? Color.auroraInk : Color.auroraInkSecondary
    }

    private var fill: Color {
        if isFocused { return FirstRunMetrics.activeFill }
        return isSelected ? Color.auroraAccent.opacity(0.14) : Color.white.opacity(0.06)
    }

    private var outline: Color {
        if isFocused { return .clear }
        return isSelected ? Color.auroraAccent.opacity(0.52) : Color.white.opacity(0.14)
    }
}

#if os(iOS)
// MARK: - Labels

/// The small upper-case label above a first-run text field.
struct AuroraFieldLabel: View {
    private let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        FirstRunFieldCaption(label: Text(text))
    }
}

/// Shared by `AuroraFieldLabel` and the label inside `AuroraTextField`.
struct FirstRunFieldCaption: View {
    let label: Text

    var body: some View {
        label
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Color.auroraInkTertiary)
    }
}

/// An inline error under a first-run form.
struct AuroraErrorLabel: View {
    private let message: String

    init<S: StringProtocol>(_ text: S) {
        message = String(text)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.vividCaption)
        .foregroundStyle(Color.requestRose)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Error: \(message)"))
    }
}

// MARK: - Screen

/// The scaffold of a first-run screen on iPhone and iPad: a centred column
/// on black that scrolls when the keyboard or a long form needs it.
struct AuroraScreen<Content: View>: View {
    private let content: () -> Content

    init(variant: AuroraVariant, scrim: AuroraScrim = .soft, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        content()
                    }
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
