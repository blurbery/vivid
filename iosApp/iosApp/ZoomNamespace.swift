import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Zoom transition namespace

/// Carries the `@Namespace.ID` used by the iOS 26 poster → detail zoom
/// transition. Published by `MainTabView` so card components (the
/// `.matchedTransitionSource` sources) and the central
/// `navigationDestination` (the `.navigationTransition(.zoom)` destination)
/// can share one namespace without routing it through `Route`/`router.path`.
/// `nil` when unset (e.g. tvOS / macOS) so callers fall back to a plain push.
struct ZoomNamespaceEnvironmentKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceEnvironmentKey.self] }
        set { self[ZoomNamespaceEnvironmentKey.self] = newValue }
    }
}
