import Foundation

/// Serial Home-cache I/O with at most one replaceable queued save per scope.
/// Saves already running finish normally. Reads and deletions seal queued saves
/// so later writes cannot move ahead of those operations by replacing a closure.
final class HomeMetadataWriter: @unchecked Sendable {
    private final class PendingWrite {
        var operation: () -> Void
        init(_ operation: @escaping () -> Void) { self.operation = operation }
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [String: PendingWrite] = [:]

    init(queue: DispatchQueue = DispatchQueue(label: "vivid.home.metadata", qos: .utility)) {
        self.queue = queue
    }

    func write(scope: String, operation: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let save = pending[scope] {
            save.operation = operation
            return
        }
        let save = PendingWrite(operation)
        pending[scope] = save
        queue.async { [self] in
            lock.lock()
            if pending[scope] === save { pending.removeValue(forKey: scope) }
            let operation = save.operation
            lock.unlock()
            operation()
        }
    }

    /// Submit an ordered operation, such as deleting an account's snapshot.
    /// Sealing stops subsequent writes from being folded into pre-delete work.
    func async(_ operation: @escaping () -> Void) {
        lock.lock()
        pending.removeAll()
        queue.async { operation() }
        lock.unlock()
    }

    /// Read after earlier saves without blocking the caller's actor.
    func read<Value>(_ operation: @escaping () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            async { continuation.resume(returning: operation()) }
        }
    }

    /// Fallback for callers that have not prepared their snapshot yet.
    /// Call from outside the writer queue, just like DispatchQueue.sync.
    func sync<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        pending.removeAll()
        lock.unlock()
        return queue.sync(execute: operation)
    }
}
