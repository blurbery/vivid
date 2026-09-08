import SwiftUI

/// Error screen with status-aware copy and recovery buttons.
///
/// `onGoBack` and `onSignOut` fall back to the ambient `AppRouter`, so call
/// sites normally only supply `onRetry`. `onGoBack` auto-hides at the root
/// of the navigation stack. Pass an explicit closure to override either.
struct ErrorView: View {
    let state: ErrorState
    var onRetry: (() -> Void)? = nil
    var onGoBack: (() -> Void)? = nil
    var onSignOut: (() -> Void)? = nil

    @Environment(AppRouter.self) private var router

    private var isTV: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: isTV ? 24 : 18) {
            Image(systemName: state.isAuthFailure ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.circle")
                .font(.system(size: isTV ? 40 : 30, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: isTV ? 88 : 68, height: isTV ? 88 : 68)
                .background(.white.opacity(0.06), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .accessibilityHidden(true)

            Text(headline)
                .font(.system(size: isTV ? 30 : 22, weight: .semibold))
                .foregroundColor(.vividOnSurface)
                .multilineTextAlignment(.center)

            Text(state.message)
                .font(.system(size: isTV ? 22 : 15))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: VividTheme.smallPadding) {
                if let primary = primaryAction {
                    recoveryButton(primary)
                }
                if let secondary = secondaryAction {
                    recoveryButton(secondary)
                }
            }
            .padding(.top, VividTheme.smallPadding)
        }
        .padding(isTV ? 36 : 24)
        .frame(maxWidth: isTV ? 640 : 440)
        .vividGlass(in: RoundedRectangle(cornerRadius: 28), tint: .black.opacity(0.16))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recoveryButton(_ action: Action) -> some View {
        Button(action: action.run) {
            Label(action.title, systemImage: action.title == "Try Again" ? "arrow.clockwise" : (action.title == "Go Back" ? "chevron.left" : "person.crop.circle"))
                .font(.system(size: isTV ? 22 : 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: isTV ? 48 : 36)
        }
        .buttonBorderShape(.capsule)
        .vividGlassButtonStyle()
        .tint(.white)
    }

    private var headline: String {
        if state.isAuthFailure { return "Session expired" }
        if state.isNotFound { return "Not found" }
        return "Something went wrong"
    }

    // MARK: - Action selection

    private struct Action {
        let title: String
        let run: () -> Void
    }

    private var resolvedOnGoBack: (() -> Void)? {
        if let onGoBack { return onGoBack }
        return router.path.isEmpty ? nil : { router.goBack() }
    }

    private var resolvedOnSignOut: () -> Void {
        onSignOut ?? { router.signOutAndReset() }
    }

    private var primaryAction: Action? {
        if state.isAuthFailure {
            return Action(title: "Sign In Again", run: resolvedOnSignOut)
        }
        if state.isNotFound, let goBack = resolvedOnGoBack {
            return Action(title: "Go Back", run: goBack)
        }
        if let onRetry {
            return Action(title: "Try Again", run: onRetry)
        }
        if let goBack = resolvedOnGoBack {
            return Action(title: "Go Back", run: goBack)
        }
        return nil
    }

    private var secondaryAction: Action? {
        if state.isAuthFailure {
            return onRetry.map { Action(title: "Try Again", run: $0) }
        }
        if state.isNotFound, resolvedOnGoBack != nil {
            if let onRetry { return Action(title: "Try Again", run: onRetry) }
            return nil
        }
        return nil
    }
}
