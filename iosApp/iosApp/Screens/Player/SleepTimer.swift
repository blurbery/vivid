import Foundation
import SwiftUI

/// The player's sleep timer. Once started it counts down a second at a time
/// and then runs the callback (which pauses playback). It lasts for the
/// session only; nothing is saved. Used on the main thread by the player and
/// its settings sheet, which shows `remainingSeconds`.
@Observable
final class SleepTimer {
    private(set) var isActive: Bool = false
    private(set) var remainingSeconds: Int = 0

    private var task: Task<Void, Never>?
    private var onFire: (() -> Void)?

    /// Installs the action to run when the timer ends. Set once by the
    /// player, so the timer itself stays independent of playback.
    func configure(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    /// Starts or replaces the timer. `minutes <= 0` just cancels it.
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
