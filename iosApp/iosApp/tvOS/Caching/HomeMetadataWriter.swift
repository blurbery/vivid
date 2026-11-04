import Foundation

/// Runs Home cache file work in order on one serial queue. Each scope keeps
/// at most one queued save: a newer save replaces the queued one's work, and
/// a save already running always finishes. Reads, deletions and `sync` seal
/// the queued saves, so nothing submitted later can be folded into work that
/// runs before them.
final class HomeMetadataWriter: @unchecked Sendable {
    /// A queued save whose work can still be swapped for a newer one.
    private final class QueuedSave {
        var work: () -> Void
        init(_ work: @escaping () -> Void) { self.work = work }
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var queuedSaves: [String: QueuedSave] = [:]

    init(queue: DispatchQueue = DispatchQueue(label: "vivid.home.metadata", qos: .utility)) {
        self.queue = queue
    }

    func write(scope: String, operation: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let queued = queuedSaves[scope] {
            queued.work = operation
            return
        }
        let save = QueuedSave(operation)
        queuedSaves[scope] = save
        queue.async { [self] in
            lock.lock()
            if queuedSaves[scope] === save { queuedSaves.removeValue(forKey: scope) }
            let work = save.work
            lock.unlock()
            work()
        }
    }

    /// Runs an operation after everything submitted so far, such as deleting
    /// an account's snapshot. Saves submitted afterwards queue behind it.
    func async(_ operation: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        queuedSaves.removeAll()
        queue.async { operation() }
    }

    /// Reads after the earlier saves without blocking the caller's actor.
    func read<Value>(_ operation: @escaping () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            async { continuation.resume(returning: operation()) }
        }
    }

    /// Blocking fallback for callers that haven't prepared their snapshot.
    /// Like `DispatchQueue.sync`, never call it from the writer's own queue.
    func sync<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        queuedSaves.removeAll()
        lock.unlock()
        return queue.sync(execute: operation)
    }
}
