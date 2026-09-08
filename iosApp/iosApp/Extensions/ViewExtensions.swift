import SwiftUI

// MARK: - Common View Modifiers

/// The shared signed-in page canvas. On iOS it is a fixed, fully opaque
/// charcoal wash with static tonal depth; it never samples page artwork.
/// Other platforms retain their existing pure-black canvas.
struct VividPageBackdrop: View {
    var body: some View {
        #if os(iOS)
        ZStack {
            Color(hex: "#111111")

            RadialGradient(
                stops: [
                    .init(color: .white.opacity(0.035), location: 0),
                    .init(color: .white.opacity(0.018), location: 0.36),
                    .init(color: .clear, location: 1),
                ],
                center: UnitPoint(x: 0.46, y: 0.42),
                startRadius: 0,
                endRadius: 520
            )

            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.012), location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.045), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #else
        Color.vividBackground
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #endif
    }
}

enum VividNavigationTitleDisplayMode {
    case automatic
    case inline
    case large
}

extension View {
    /// Apply the original pure-black Vivid canvas.
    func vividBackground() -> some View {
        self.background(Color.vividBackground.ignoresSafeArea())
    }

    /// Apply the fixed charcoal page canvas without changing semantic black
    /// ink used by controls, artwork masks, Settings, or media surfaces.
    func vividPageBackground() -> some View {
        self.background {
            VividPageBackdrop()
        }
    }

    /// Card-style surface with rounded corners — zero elevation (Plezy style).
    func vividCard() -> some View {
        self
            .background(Color.vividSurface)
            .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
    }

    /// Standard content padding on all sides.
    func vividPadding() -> some View {
        self.padding(VividTheme.padding)
    }

    /// Hide the view conditionally.
    @ViewBuilder
    func hidden(_ isHidden: Bool) -> some View {
        if isHidden {
            self.hidden()
        } else {
            self
        }
    }

    @ViewBuilder
    func vividNavigationTitleDisplayMode(_ mode: VividNavigationTitleDisplayMode) -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        switch mode {
        case .automatic:
            self.navigationBarTitleDisplayMode(.automatic)
        case .inline:
            self.navigationBarTitleDisplayMode(.inline)
        case .large:
            self.navigationBarTitleDisplayMode(.large)
        }
        #endif
    }

    @ViewBuilder
    func vividScrollContentBackgroundHidden() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }

    /// Soft native scroll-edge blur at the top, where content passes under a
    /// floating bar. iOS 18 keeps its legacy edge treatment; tvOS remains a
    /// no-op because it has no floating bars in the 10-foot UI.
    @ViewBuilder
    func vividScrollEdgeEffect() -> some View {
        #if os(tvOS)
        self
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
        #else
        self.scrollEdgeEffectStyle(.soft, for: .top)
        #endif
    }

    /// Extends hero artwork through surrounding chrome on Apple 26+. Earlier
    /// iOS versions retain the legacy clipped artwork without the new system
    /// mirroring effect.
    @ViewBuilder
    func vividBackgroundExtensionEffect() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self.clipped()
        }
        #else
        self.backgroundExtensionEffect()
        #endif
    }

    /// Keeps the native minimizing tab bar on iOS 26 while leaving the fixed
    /// iOS 18 tab bar unchanged.
    @ViewBuilder
    func vividTabBarMinimizeOnScroll() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func vividStatusBarHidden() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.statusBarHidden()
        #endif
    }

    @ViewBuilder
    func vividToolbarColorSchemeDark() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func vividNavigationBarSurfaceBackground() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self
            .toolbarBackground(Color.vividSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func vividNavigationBarBackgroundHidden() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func vividSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(tvOS)
        self.searchable(text: text, prompt: prompt)
        #elseif os(macOS)
        self.searchable(text: text, prompt: prompt)
        #else
        // Keep the navigation bar's back button and title visible while the
        // field is focused, and drop the search bar's Cancel button so the
        // field's own clear button is the only way to empty the query.
        self.searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: prompt
        )
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .background(SearchCancelButtonSuppressor().frame(width: 0, height: 0))
        #endif
    }

    @ViewBuilder
    func vividGroupedListStyle() -> some View {
        #if os(tvOS)
        self.listStyle(.plain)
        #elseif os(macOS)
        self.listStyle(.inset)
        #else
        self.listStyle(.insetGrouped)
        #endif
    }

    func vividInputChrome(isFocused: Bool) -> some View {
        self
            .background(VividInputBackground(isFocused: isFocused))
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .shadow(
                color: isFocused ? Color.vividOnSurface.opacity(0.22) : .clear,
                radius: isFocused ? 18 : 0,
                y: 0
            )
            // On tvOS the system paints a bright white platter under the
            // TextField when it gains focus, which completely hides our dark
            // fill + placeholder. Suppressing it lets VividInputBackground
            // carry focus via the fill/stroke change instead.
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(VividTheme.springAnimation, value: isFocused)
    }
}

private struct VividInputBackground: View {
    let isFocused: Bool

    var body: some View {
        // At-rest stroke bumped to 22% so the field boundary reads clearly
        // against pure black auth canvases. `vividOutline` (12%) is
        // tuned for dividers and was too faint here.
        let strokeColor: Color = isFocused ? .vividOnSurface : Color.white.opacity(0.22)
        let strokeWidth: CGFloat = isFocused ? 3 : 1.5
        // Slightly elevated fill gives the field a visible silhouette on
        // pure-black backgrounds without washing it into the focus
        // platter when tvOS lights the field up.
        let fillColor: Color = .vividSurfaceElevated

        RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
    }
}

extension View {
    /// Shared centered playback prompt for touch devices.
    ///
    /// `confirmationDialog` can anchor away from the user's thumb on phones,
    /// while a standard alert keeps the decision in the middle of the screen.
    func vividResumePlaybackAlert(
        isPresented: Binding<Bool>,
        stoppedAt timestamp: String,
        onResume: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) -> some View {
        alert("Continue Watching?", isPresented: isPresented) {
            Button("Resume", action: onResume)
            Button("Play from Beginning", action: onRestart)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You stopped at \(timestamp).")
        }
    }
}

// MARK: - Vivid Button Styles

// These styles serve tvOS focus appearance and the pre-Liquid-Glass iOS 18
// fallback. iOS/macOS 26+ continue to use native glass through the routing
// helpers below.

/// Primary action button — filled pill with dark text. At rest the pill is
/// a dimmed white so focus can brighten it to solid white; on tvOS focus
/// also adds a scale + glow so the button is distinguishable even when
/// surrounded by other white-ish surfaces (e.g. focused text fields).
struct VividPrimaryButtonStyle: ButtonStyle {
    var isLoading: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, isLoading: isLoading)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isLoading: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .tint(Color.vividBackground)
                    .scaleEffect(0.8)
            }
            configuration.label
        }
        .font(.vividSubheadline)
        .foregroundColor(Color.vividBackground)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(
            Capsule().fill(
                isLoading ? Color.vividOnSurface.opacity(0.6)
                : isFocused ? Color.vividOnSurface
                : Color.vividOnSurface.opacity(0.72)
            )
        )
        .overlay(
            Capsule().stroke(
                isFocused ? Color.white : Color.clear,
                lineWidth: isFocused ? 4 : 0
            )
        )
        .overlay {
            #if os(tvOS)
            if isFocused {
                Capsule()
                    .stroke(Color.white.opacity(0.36), lineWidth: 7)
                    .padding(-6)
                    .blur(radius: 6)
            }
            #endif
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.055 : 1.0)
        .shadow(
            color: isFocused ? Color.vividOnSurface.opacity(0.48) : .clear,
            radius: isFocused ? 24 : 0,
            y: isFocused ? 8 : 0
        )
        .opacity(configuration.isPressed ? 0.8 : 1.0)
        #if os(tvOS)
        .focusEffectDisabled()
        #endif
        .animation(.easeInOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
        .animation(VividTheme.springAnimation, value: isFocused)
    }
}

/// Secondary action button — outlined pill.
struct VividSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.vividSubheadline)
            .foregroundColor(isFocused ? .vividBackground : .vividOnSurface)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(
                Capsule()
                    .fill(isFocused ? Color.vividOnSurface.opacity(0.96) : Color.clear)
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.white : Color.white.opacity(0.3),
                    lineWidth: isFocused ? 3 : 1.5
                )
            )
            .scaleEffect(isFocused && !reduceMotion ? 1.045 : 1.0)
            .shadow(
                color: isFocused ? Color.vividOnSurface.opacity(0.36) : .clear,
                radius: isFocused ? 18 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
            .animation(VividTheme.springAnimation, value: isFocused)
    }
}

/// Text-only button style for tertiary actions. Focused state fills a
/// soft pill behind the label so the user can distinguish the tertiary action
/// from the primary button above.
struct VividTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration)
    }
}

private struct TextButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.vividBody)
            .foregroundColor(isFocused ? .vividBackground : .vividOnSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    isFocused ? Color.vividOnSurface : Color.clear
                )
            )
            .overlay {
                Capsule().stroke(
                    isFocused ? Color.white.opacity(0.9) : Color.clear,
                    lineWidth: isFocused ? 2 : 0
                )
            }
            .scaleEffect(isFocused ? 1.045 : 1.0)
            .shadow(
                color: isFocused ? Color.vividOnSurface.opacity(0.28) : .clear,
                radius: isFocused ? 14 : 0,
                y: isFocused ? 4 : 0
            )
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
            .animation(VividTheme.springAnimation, value: isFocused)
    }
}

// MARK: - Vivid button style routing (glass on iOS/macOS, Vivid on tvOS)

extension View {
    /// Primary action button: native Liquid Glass on iOS/macOS 26+, the
    /// established Vivid style on iOS 18, and focus-reactive Vivid
    /// chrome on tvOS.
    @ViewBuilder
    func vividPrimaryButton(isLoading: Bool = false) -> some View {
        #if os(tvOS)
        self.buttonStyle(VividPrimaryButtonStyle(isLoading: isLoading))
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            modernVividPrimaryButton(isLoading: isLoading)
        } else {
            self.buttonStyle(VividPrimaryButtonStyle(isLoading: isLoading))
        }
        #else
        modernVividPrimaryButton(isLoading: isLoading)
        #endif
    }

    /// Secondary action button: native glass on iOS/macOS, `VividSecondaryButtonStyle`
    /// on tvOS.
    @ViewBuilder
    func vividSecondaryButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(VividSecondaryButtonStyle())
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(VividSecondaryButtonStyle())
        }
        #else
        self.buttonStyle(.glass)
        #endif
    }

    /// Tertiary / text action button: native glass on iOS/macOS, `VividTextButtonStyle`
    /// on tvOS.
    @ViewBuilder
    func vividTextButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(VividTextButtonStyle())
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(VividTextButtonStyle())
        }
        #else
        self.buttonStyle(.glass)
        #endif
    }

    /// Compact native glass button on iOS 26+, with the corresponding native
    /// bordered control on iOS 18. `buttonBorderShape` and `tint` remain owned
    /// by the caller so the modern modifier order is unchanged.
    @ViewBuilder
    func vividGlassButtonStyle() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.glass)
        #endif
    }

    /// Prominent counterpart to `vividGlassButtonStyle()`.
    @ViewBuilder
    func vividGlassProminentButtonStyle() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.glassProminent)
        #endif
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func modernVividPrimaryButton(isLoading: Bool) -> some View {
        // `.glassProminent` can't take the in-flight state, so surface it the
        // only way a modifier can: disable the button and overlay a spinner.
        self
            .buttonStyle(.glassProminent)
            .tint(.vividAccent)
            .disabled(isLoading)
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
    }
}

// MARK: - Vivid Text Field Style

/// Dark-themed text field with rounded surface background.
struct VividTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        VividTextFieldBody(configuration: configuration)
    }
}

private struct VividTextFieldBody<Label: View>: View {
    let configuration: TextField<Label>
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration
            .font(.vividBody)
            // tvOS renders an unavoidable bright-white focus platter under
            // any focused TextField (`.focusEffectDisabled()` doesn't
            // suppress it for text fields the way it does for Buttons).
            // Rather than fight the platform, flip the text color to dark
            // on focus so the typed value reads black-on-white instead of
            // white-on-white.
            .foregroundColor(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .vividInputChrome(isFocused: isFocused)
            .tint(isFocused ? .vividBackground : .vividOnSurface)
    }

    private var textColor: Color {
        #if os(tvOS)
        isFocused ? .vividBackground : .vividOnSurface
        #else
        .vividOnSurface
        #endif
    }
}

#if os(tvOS)
extension View {
    /// Applies `prefersDefaultFocus` only when a focus namespace is supplied,
    /// so a single element (the first profile tile, the PIN pad's "1", a
    /// rail's first card, the hero Play pill) can claim a scope's initial
    /// focus while callers that don't manage focus pass `nil` and are
    /// untouched. Shared by every tvOS component that takes an optional
    /// `defaultFocusNamespace`.
    @ViewBuilder
    func applyDefaultFocusIfNeeded(_ prefersDefaultFocus: Bool, namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.prefersDefaultFocus(prefersDefaultFocus, in: namespace)
        } else {
            self
        }
    }
}
#endif
