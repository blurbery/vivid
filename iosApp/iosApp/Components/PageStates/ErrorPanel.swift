import SwiftUI

/// A glass panel explaining a failed load, with the actions that make sense
/// for it: sign in again, go back or try again.
struct ErrorView: View {
    let state: ErrorState
    var onRetry: (() -> Void)? = nil

    @Environment(AppRouter.self) private var router

    #if os(tvOS)
    private let stackSpacing: CGFloat = 24
    private let iconSize: CGFloat = 40
    private let badgeSize: CGFloat = 88
    private let headlineSize: CGFloat = 30
    private let messageSize: CGFloat = 22
    private let panelPadding: CGFloat = 36
    private let panelMaxWidth: CGFloat = 640
    private let buttonFontSize: CGFloat = 22
    private let buttonMinHeight: CGFloat = 48
    #else
    private let stackSpacing: CGFloat = 18
    private let iconSize: CGFloat = 30
    private let badgeSize: CGFloat = 68
    private let headlineSize: CGFloat = 22
    private let messageSize: CGFloat = 15
    private let panelPadding: CGFloat = 24
    private let panelMaxWidth: CGFloat = 440
    private let buttonFontSize: CGFloat = 16
    private let buttonMinHeight: CGFloat = 36
    #endif

    init(state: ErrorState, onRetry: (() -> Void)? = nil) {
        self.state = state
        self.onRetry = onRetry
    }

    private struct Action {
        let title: LocalizedStringKey
        let systemImage: String
        let perform: () -> Void
    }

    var body: some View {
        let actions = self.actions
        VStack(spacing: stackSpacing) {
            Image(systemName: state.isAuthFailure ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.circle")
                .font(.system(size: iconSize, weight: .light))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .accessibilityHidden(true)

            Text(headline)
                .font(.system(size: headlineSize, weight: .semibold))
                .foregroundStyle(Color.vividOnSurface)
                .multilineTextAlignment(.center)

            Text(verbatim: state.message)
                .font(.system(size: messageSize))
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let primary = actions.primary {
                VStack(spacing: VividTheme.smallPadding) {
                    button(primary)
                    if let secondary = actions.secondary {
                        button(secondary)
                    }
                }
                .padding(.top, VividTheme.smallPadding)
            }
        }
        .padding(panelPadding)
        .frame(maxWidth: panelMaxWidth)
        .vividGlass(in: RoundedRectangle(cornerRadius: 28), tint: Color.black.opacity(0.16))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: LocalizedStringKey {
        if state.isAuthFailure { return "Session expired" }
        if state.isNotFound { return "Not found" }
        return "Something went wrong"
    }

    private func button(_ action: Action) -> some View {
        Button(action: action.perform) {
            Label(action.title, systemImage: action.systemImage)
                .font(.system(size: buttonFontSize, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: buttonMinHeight)
        }
        .buttonBorderShape(.capsule)
        .vividGlassButtonStyle()
        .tint(.white)
    }

    // MARK: Actions

    private var actions: (primary: Action?, secondary: Action?) {
        let signIn = Action(title: "Sign In Again", systemImage: "person.crop.circle") { router.signOutAndReset() }
        let back = Action(title: "Go Back", systemImage: "chevron.left") { goBack() }
        let retry = onRetry.map { Action(title: "Try Again", systemImage: "arrow.clockwise", perform: $0) }
        let backIsPossible = canGoBack

        if state.isAuthFailure { return (signIn, retry) }
        if state.isNotFound && backIsPossible { return (back, retry) }
        if let retry { return (retry, nil) }
        if backIsPossible { return (back, nil) }
        return (nil, nil)
    }

    /// Inside the iPhone and iPad detail cover, back steps through the
    /// cover's own stack and then closes it; elsewhere it pops the main stack.
    private var canGoBack: Bool {
        #if os(iOS)
        if router.presentedItemDetail != nil { return true }
        #endif
        return !router.path.isEmpty
    }

    private func goBack() {
        #if os(iOS)
        if router.presentedItemDetail != nil {
            if router.itemDetailPath.isEmpty {
                router.dismissItemDetail()
            } else {
                router.goBackInItemDetail()
            }
            return
        }
        #endif
        router.goBack()
    }
}
