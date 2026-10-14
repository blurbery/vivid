// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
import UIKit
#if os(tvOS) && VIVID_P8_TRIAL
import AVKit
#endif

/// The app lifecycle notifications a core reacts to. Each handler runs
/// synchronously on the posting thread, so the core reads its Picture in
/// Picture state at that moment. Observation lasts until `stop()`.
final class VividPlayerLifecycleObserver {
    private var observers: [NSObjectProtocol] = []

    /// On iOS the core follows the scene of the window it was initialised in,
    /// read now; if that window has no scene yet, it follows every scene. On
    /// tvOS it follows the application. `didActivate` is iOS only and
    /// `displaySwitch` is used only by tvOS `VIVID_P8_TRIAL` builds.
    init(window: UIWindow,
         didEnterBackground: @escaping () -> Void,
         willEnterForeground: @escaping () -> Void,
         didActivate: @escaping () -> Void,
         displaySwitch: @escaping (_ started: Bool) -> Void) {
        #if os(tvOS) && VIVID_P8_TRIAL
        observe(.AVDisplayManagerModeSwitchStart, object: nil) { displaySwitch(true) }
        observe(.AVDisplayManagerModeSwitchEnd, object: nil) { displaySwitch(false) }
        #endif
        #if os(iOS)
        let scene = window.windowScene
        observe(UIScene.didEnterBackgroundNotification, object: scene, didEnterBackground)
        observe(UIScene.willEnterForegroundNotification, object: scene, willEnterForeground)
        observe(UIScene.didActivateNotification, object: scene, didActivate)
        #else
        observe(UIApplication.didEnterBackgroundNotification, object: nil, didEnterBackground)
        observe(UIApplication.willEnterForegroundNotification, object: nil, willEnterForeground)
        #endif
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func observe(_ name: Notification.Name, object: AnyObject?, _ handler: @escaping () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { _ in
            handler()
        })
    }
}
#endif
