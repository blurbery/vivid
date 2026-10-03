#if os(iOS) || os(tvOS)
import Darwin
import Foundation

/// Notes which signal ended the process, and the name and reason of an
/// uncaught Objective-C exception, so the next launch can tell a crash from a
/// system kill. This is the only crash detail tvOS can get, since it has no
/// MetricKit.
///
/// The signal handler only writes four bytes to a file opened in advance,
/// then restores the previous handler and returns, so the faulting
/// instruction runs again and the system's own crash report (and MetricKit)
/// still see the original crash. Stacks are left to Apple's crash reports.
enum AppHealthCrashCapture {
    struct Previous: Equatable {
        var signal: Int32?
        var exceptionName: String?
        var exceptionReason: String?
    }

    static let capturedSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]

    private static var directory: URL {
        AppHealthStore.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("HealthState", isDirectory: true)
    }
    private static var signalURL: URL { directory.appendingPathComponent("last-signal") }
    private static var exceptionURL: URL { directory.appendingPathComponent("last-exception.json") }

    /// What the previous process left behind, then clears it.
    static func collectPrevious() -> Previous? {
        var previous = Previous()
        if let data = try? Data(contentsOf: signalURL), data.count >= 4 {
            let value = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            if capturedSignals.contains(value) { previous.signal = value }
        }
        if let data = try? Data(contentsOf: exceptionURL),
           let fields = try? JSONDecoder().decode([String: String].self, from: data) {
            previous.exceptionName = fields["name"]
            previous.exceptionReason = fields["reason"]
        }
        try? FileManager.default.removeItem(at: signalURL)
        try? FileManager.default.removeItem(at: exceptionURL)
        return previous == Previous() ? nil : previous
    }

    /// Call once, after `collectPrevious()`. Not installed under a debugger or
    /// the test runner, which handle these signals themselves.
    static func install() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(signalURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        crashSignalFD = fd

        #if os(iOS)
        // A stack overflow leaves no stack to run the handler on, so give the
        // main thread a separate one. tvOS has no `sigaltstack`; there a main
        // thread stack overflow reads as an unexpected exit instead.
        let altStackSize = 64 * 1024
        if let stack = malloc(altStackSize) {
            var altStack = stack_t(ss_sp: stack, ss_size: altStackSize, ss_flags: 0)
            sigaltstack(&altStack, nil)
        }
        let flags = SA_SIGINFO | SA_ONSTACK
        #else
        let flags = SA_SIGINFO
        #endif

        let previousActions = UnsafeMutablePointer<sigaction>.allocate(capacity: Int(NSIG))
        previousActions.initialize(repeating: sigaction(), count: Int(NSIG))
        crashPreviousActions = previousActions
        for signal in capturedSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = vividCrashSignalHandler
            action.sa_flags = flags
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, previousActions + Int(signal))
        }

        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(vividUncaughtExceptionHandler)
    }

    /// The process is still running after a clean move to the background, so
    /// any signal recorded so far was handled and did not end it. Clearing it
    /// stops a recovered signal being reported as a crash.
    static func processSurvived() {
        let fd = crashSignalFD
        if fd >= 0 { ftruncate(fd, 0) }
        try? FileManager.default.removeItem(at: exceptionURL)
    }

    /// Normal context, so ordinary Foundation calls are fine here.
    fileprivate static func recordException(_ exception: NSException) {
        let fields = [
            "name": DiagLog.sanitizedText(exception.name.rawValue, maxLength: 128),
            "reason": DiagLog.sanitizedText(exception.reason ?? "", maxLength: 512),
        ]
        if let data = try? JSONEncoder().encode(fields) {
            try? data.write(to: exceptionURL, options: [.atomic])
        }
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGTRAP: return "SIGTRAP"
        default: return "Signal \(signal)"
        }
    }
}

// Read inside the signal handler, so these are plain globals set once before
// the handlers are installed.
nonisolated(unsafe) private var crashSignalFD: Int32 = -1
nonisolated(unsafe) private var crashPreviousActions: UnsafeMutablePointer<sigaction>?
nonisolated(unsafe) private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

/// Async-signal-safe: one `pwrite`, one `sigaction`, no allocation.
private func vividCrashSignalHandler(
    _ signal: Int32,
    _ info: UnsafeMutablePointer<__siginfo>?,
    _ context: UnsafeMutableRawPointer?
) {
    let fd = crashSignalFD
    if fd >= 0 {
        var value = signal
        // Always at the start, so a later signal replaces an earlier one.
        _ = withUnsafeBytes(of: &value) { pwrite(fd, $0.baseAddress, 4, 0) }
    }
    if let previous = crashPreviousActions {
        sigaction(signal, previous + Int(signal), nil)
    } else {
        var reset = sigaction()
        reset.__sigaction_u.__sa_handler = SIG_DFL
        sigaction(signal, &reset, nil)
    }
    // Returning re-runs the faulting instruction under the restored handler,
    // so the crash report keeps the original thread and address. `abort()`
    // raises again itself once its handler returns.
}

private func vividUncaughtExceptionHandler(_ exception: NSException) {
    AppHealthCrashCapture.recordException(exception)
    previousExceptionHandler?(exception)
}
#endif
