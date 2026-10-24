#if os(tvOS)
import SwiftUI
import UIKit

/// One button of a `tvSystemAlert`, in the order UIKit shows them.
struct TVSystemAlertButton {
    let title: LocalizedStringResource
    let style: UIAlertAction.Style
    let action: () -> Void

    static func `default`(_ title: LocalizedStringResource, action: @escaping () -> Void = {}) -> Self {
        Self(title: title, style: .default, action: action)
    }

    static func cancel(_ title: LocalizedStringResource, action: @escaping () -> Void = {}) -> Self {
        Self(title: title, style: .cancel, action: action)
    }

    static func destructive(_ title: LocalizedStringResource, action: @escaping () -> Void) -> Self {
        Self(title: title, style: .destructive, action: action)
    }
}

extension View {
    /// The system alert, presented by UIKit instead of SwiftUI's `.alert`.
    /// In Vivid's Settings on tvOS 27, SwiftUI's alert left the focused
    /// button's label white on its white platter, and neither the alert's
    /// UIKit tint nor its colour scheme changed that. A `UIAlertController`
    /// presented directly looks the same and turns the focused label dark.
    func tvSystemAlert(
        _ title: LocalizedStringResource,
        isPresented: Binding<Bool>,
        message: LocalizedStringResource? = nil,
        buttons: [TVSystemAlertButton]
    ) -> some View {
        background {
            TVSystemAlertPresenter(title: title, message: message, buttons: buttons, isPresented: isPresented)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// An empty controller in the view's background that presents the alert
/// while `isPresented` is true and dismisses it when it turns false or the
/// view goes away.
private struct TVSystemAlertPresenter: UIViewControllerRepresentable {
    let title: LocalizedStringResource
    let message: LocalizedStringResource?
    let buttons: [TVSystemAlertButton]
    @Binding var isPresented: Bool

    final class Coordinator {
        var alert: UIAlertController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        if isPresented, coordinator.alert == nil {
            let alert = UIAlertController(
                title: String(localized: title),
                message: message.map { String(localized: $0) },
                preferredStyle: .alert
            )
            let isPresented = $isPresented
            for button in buttons {
                alert.addAction(UIAlertAction(title: String(localized: button.title), style: button.style) { _ in
                    coordinator.alert = nil
                    isPresented.wrappedValue = false
                    button.action()
                })
            }
            coordinator.alert = alert
            // Present after the current SwiftUI update has finished.
            DispatchQueue.main.async {
                Self.present(alert, from: anchor, coordinator: coordinator, isPresented: isPresented, attempts: 4)
            }
        } else if !isPresented, let alert = coordinator.alert {
            coordinator.alert = nil
            alert.presentingViewController?.dismiss(animated: true)
        }
    }

    /// UIKit drops a presentation it can't start, for example while the
    /// Language menu is still closing, so try again shortly and give up
    /// cleanly rather than leave `isPresented` stuck on.
    private static func present(_ alert: UIAlertController, from anchor: UIViewController,
                                coordinator: Coordinator, isPresented: Binding<Bool>, attempts: Int) {
        guard coordinator.alert === alert else { return }
        if anchor.viewIfLoaded?.window != nil {
            var presenter = anchor
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(alert, animated: true)
            if alert.presentingViewController != nil { return }
        }
        guard attempts > 1 else {
            coordinator.alert = nil
            isPresented.wrappedValue = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            present(alert, from: anchor, coordinator: coordinator, isPresented: isPresented, attempts: attempts - 1)
        }
    }

    static func dismantleUIViewController(_ anchor: UIViewController, coordinator: Coordinator) {
        coordinator.alert?.presentingViewController?.dismiss(animated: true)
        coordinator.alert = nil
    }
}
#endif
