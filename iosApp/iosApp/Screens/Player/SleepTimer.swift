import Foundation
import SwiftUI

/// Observable sleep timer. When `start(minutes:)` is called, it schedules a
/// task that pauses playback after the requested interval. The timer is
/// purely session-scoped — nothing persists; the user sets it once per
/// movie/episode. All callers are expected to be on the main thread (the
/// player sheet and VM are both view-layer).
///
/// Exposes `remainingSeconds` for the settings sheet to tick down a countdown.
@Observable
final class SleepTimer {
    private(set) var isActive: Bool = false
    private(set) var remainingSeconds: Int = 0

    private var task: Task<Void, Never>?
    private var onFire: (() -> Void)?

    /// Install the callback that performs the pause action. Called once from
    /// the ViewModel; the timer itself stays backend-agnostic.
    func configure(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    /// Start or replace the timer. `minutes <= 0` cancels instead.
    func start(minutes: Int) {
        cancel()
        guard minutes > 0 else { return }
        isActive = true
        remainingSeconds = minutes * 60

        task = Task { [weak self] in
            while let self, self.isActive, self.remainingSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if self.remainingSeconds > 0 { self.remainingSeconds -= 1 }
            }
            guard let self, self.isActive else { return }
            self.onFire?()
            self.isActive = false
            self.remainingSeconds = 0
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isActive = false
        remainingSeconds = 0
    }
}
