#if os(tvOS)
import SwiftUI
import UIKit

extension TVMainTabView {
    /// Notices when the focus engine holds nothing at all, so the remote
    /// seems dead, and nudges it once per outage check.
    struct FocusWatchdog: ViewModifier {
        let isActive: Bool
        let onRepair: () -> Void

        @State private var tracker = OutageTracker()

        func body(content: Content) -> some View {
            content.task(id: isActive) {
                tracker.endOutage()
                guard isActive else { return }
                defer { tracker.endOutage() }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { break }
                    tracker.check(onRepair: onRepair)
                }
            }
        }

        /// The key window of a foreground-active scene.
        static func activeKeyWindow() -> UIWindow? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
        }

        /// Asks the focus engine to pick a focused item again, at once.
        static func reResolveFocus() {
            guard let window = activeKeyWindow() else { return }
            window.setNeedsFocusUpdate()
            window.updateFocusIfNeeded()
        }
    }

    @MainActor
    final class OutageTracker {
        private var misses = 0
        private var repairs = 0
        private var repairPending = false
        /// Never reset, so repairs stay at least five seconds apart.
        private var lastRepair: ContinuousClock.Instant?

        func endOutage() {
            misses = 0
            repairs = 0
            repairPending = false
        }

        func check(onRepair: () -> Void) {
            let window = FocusWatchdog.activeKeyWindow()
            if let window, let item = UIFocusSystem.focusSystem(for: window)?.focusedItem {
                if misses >= 2 { recordRecovery(focusedType: String(describing: type(of: item))) }
                endOutage()
                return
            }

            misses += 1
            let now = ContinuousClock.now
            guard misses >= 2, repairs < 3 else { return }
            if let lastRepair, now - lastRepair < .seconds(5) { return }
            repairs += 1
            lastRepair = now
            repairPending = true
            DiagTrace.breadcrumb(
                .essential, level: .warning, category: .focus, tag: "FocusRepair",
                message: "no focused item after \(misses) checks; repair attempt \(repairs)",
                attrs: ["target": .string("focusSystem"), "action": .string("repair")]
            )
            onRepair()
        }

        /// Type names only, never an item's contents.
        private func recordRecovery(focusedType: String) {
            let message = repairPending
                ? "focus restored after \(misses) checks"
                : "focus recovered unaided after \(misses) checks"
            DiagTrace.breadcrumb(
                .essential, category: .focus, tag: "FocusRepair",
                message: message,
                attrs: [
                    "target": .string(focusedType),
                    "action": .string(repairPending ? "restoredAfterRepair" : "recoveredUnaided"),
                ]
            )
        }
    }
}
#endif
