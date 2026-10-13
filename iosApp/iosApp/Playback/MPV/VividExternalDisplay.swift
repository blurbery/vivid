// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS)
import UIKit

/// Shows Lucid's video on an external screen when iOS gives Vivid an
/// external-display scene. One per process, main thread only. It looks for
/// such a scene only when a core attaches, once per load.
final class VividExternalDisplay {
    static let shared = VividExternalDisplay()

    private weak var activeCore: VividPlayerCore?
    private var scene: UIWindowScene?
    private var window: UIWindow?
    private var rootController: UIViewController?

    private init() {}

    /// Only the role counts, never the screen: an iPad window dragged to an
    /// extended display is an application scene.
    static func isExternalDisplayRole(_ role: UISceneSession.Role) -> Bool {
        role.rawValue == "UIWindowSceneSessionRoleExternalDisplay"
            || role.rawValue == "UIWindowSceneSessionRoleExternalDisplayNonInteractive"
    }

    /// Where video goes on the external screen, while a scene is adopted.
    var externalRootView: UIView? { scene == nil ? nil : rootController?.view }

    /// Makes `core` the one whose video may go external, replacing any other.
    func attach(_ core: VividPlayerCore) {
        activeCore = core
        if scene == nil, let external = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { Self.isExternalDisplayRole($0.session.role) }) {
            adopt(external)
        }
        activeCore?.externalDisplayDidChange()
    }

    func detach(_ core: VividPlayerCore) {
        if activeCore === core { activeCore = nil }
    }

    private func adopt(_ scene: UIWindowScene) {
        self.scene = scene
        if let window, window.windowScene !== scene {
            window.isHidden = true
            self.window = nil
            rootController = nil
        }
        if window == nil {
            let controller = UIViewController()
            controller.view.backgroundColor = .black
            controller.view.frame = scene.coordinateSpace.bounds
            let window = UIWindow(windowScene: scene)
            window.backgroundColor = .black
            window.rootViewController = controller
            window.isHidden = false
            self.window = window
            rootController = controller
        }
        activeCore?.externalDisplayDidChange()
    }
}
#endif
