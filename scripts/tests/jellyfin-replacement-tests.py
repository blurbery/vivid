#!/usr/bin/env python3
"""Exercise the production replacement window with deterministic suspension gates."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift').read_text()
start = source.index('            do {\n                try validateJellyfinStart(jellyfinAttempt)')
end = source.index('            return prepared', start)
replacement = source[start:end].replace(', privacy: .public', '')
start = source.index('    private func validateJellyfinStart(')
end = source.index('\n    }', start) + len('\n    }')
validation = source[start:end]
assert 'let jellyfinAttempt = UUID()\n        jellyfinStartAttempt = jellyfinAttempt' in source
assert 'jellyfinStartAttempt = UUID()\n        guard let sid = sessionId' in source

swift = r'''
import Foundation
actor Gate {
    var entered = false
    var released = false
    var entryWaiters: [CheckedContinuation<Void, Never>] = []
    var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
}
struct Logger { func warning(_ message: String) {} }
enum MediaLogRedactor { static func sanitize(_ error: Error) -> String { "error" } }
struct Connection {
    let gate: Gate?
    func validate() async throws { if let gate { await gate.wait() } }
}
struct Metadata { let connection: Connection }
struct Prepared { let session: String }
@MainActor final class Playback {
    var playSessionID: String
    let retirementGate: Gate?
    var retired = false
    var cleanupCount = 0
    var cleanupWasCancelled = false
    init(_ id: String, gate: Gate? = nil) { playSessionID = id; retirementGate = gate }
    func retireForReplacement() async throws {
        guard !retired else { return }
        retired = true
        if let retirementGate { await retirementGate.wait() }
    }
    func stopWithoutProgress() async throws {
        cleanupCount += 1
        cleanupWasCancelled = Task.isCancelled
    }
}
actor Bridge {
    var jellyfinStartAttempt = UUID()
    var jellyfinPlayback: Playback?
    var progressWriteTail: Task<Void, Never>?
    var adopted: String?
    let logger = Logger()
    init(previous: Playback? = nil) { jellyfinPlayback = previous }
    func begin() -> UUID { jellyfinStartAttempt = UUID(); return jellyfinStartAttempt }
    func stop() { jellyfinStartAttempt = UUID() }
    func setProgress(_ task: Task<Void, Never>?) { progressWriteTail = task }
    func adoptSession(_ session: String) { adopted = session }
    VALIDATION
    func commit(_ playback: Playback, attempt jellyfinAttempt: UUID, connection: Connection) async throws {
        let prepared = Prepared(session: await playback.playSessionID)
        let jellyfinMetadata = Metadata(connection: connection)
        REPLACEMENT
    }
}
@main struct Run {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        // Hold the older attempt at each suspension window while the newer
        // attempt commits. Continuations, rather than sleeps, control ordering.
        for window in ["progress", "retirement", "validation"] {
            let gate = Gate()
            let previous = window == "retirement" ? Playback("previous", gate: gate) : nil
            let bridge = Bridge(previous: previous)
            if window == "progress" { await bridge.setProgress(Task { await gate.wait() }) }
            let older = Playback("older"), newer = Playback("newer")
            let first = await bridge.begin()
            let oldTask = Task {
                try await bridge.commit(older, attempt: first,
                    connection: Connection(gate: window == "validation" ? gate : nil))
            }
            await gate.waitUntilEntered()
            await bridge.setProgress(nil)
            let second = await bridge.begin()
            try await bridge.commit(newer, attempt: second, connection: Connection(gate: nil))
            await gate.release()
            do { try await oldTask.value; preconditionFailure("Stale attempt committed") }
            catch is CancellationError { checks += 1 }
            let adopted = await bridge.adopted
            check(adopted == "newer", "Older start overwrote newer session at \(window)")
            check(older.cleanupCount == 1, "Stale candidate was not cleaned up")
            check(newer.cleanupCount == 0, "Current candidate was cleaned up")
        }
        for cancel in [true, false] {
            let gate = Gate(), bridge = Bridge(), candidate = Playback("candidate")
            let attempt = await bridge.begin()
            let task = Task {
                try await bridge.commit(candidate, attempt: attempt, connection: Connection(gate: gate))
            }
            await gate.waitUntilEntered()
            if cancel { task.cancel() } else { await bridge.stop() }
            await gate.release()
            do { try await task.value; preconditionFailure("Cancelled/stopped start committed") }
            catch is CancellationError { checks += 1 }
            let adopted = await bridge.adopted
            check(adopted == nil, "Stopped start adopted a session")
            check(candidate.cleanupCount == 1, "Abandoned candidate was not cleaned up")
            check(!candidate.cleanupWasCancelled, "Cleanup inherited cancellation")
        }
        // A stale result returned by preparation must not touch the old session.
        let previous = Playback("previous"), candidate = Playback("stale")
        let bridge = Bridge(previous: previous)
        let stale = await bridge.begin()
        _ = await bridge.begin()
        do {
            try await bridge.commit(candidate, attempt: stale, connection: Connection(gate: nil))
            preconditionFailure("Stale preparation committed")
        } catch is CancellationError { checks += 1 }
        check(!previous.retired, "Stale preparation retired current playback")
        check(candidate.cleanupCount == 1, "Stale preparation leaked its candidate")
        print("\(checks) Jellyfin replacement checks passed")
    }
}
'''.replace('VALIDATION', validation).replace('REPLACEMENT', replacement)

with tempfile.TemporaryDirectory(prefix='vivid-jellyfin-replacement-', dir=root.parent) as folder:
    folder = Path(folder)
    (folder / 'checks.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', str(folder / 'checks.swift'), '-o', str(folder / 'checks')], check=True, timeout=60)
    subprocess.run([str(folder / 'checks')], check=True, timeout=20)
