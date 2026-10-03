#if os(iOS) || os(tvOS)
import Foundation

/// Verbosity for local development traces.
enum DiagnosticsVerbosity {
    case essential
    case verbose

    var isVerbose: Bool { self == .verbose }
}

/// Redacted development traces written to the local Apple log in debug
/// builds. Essential lines also feed the on-device health reports. No uploads.
enum DiagTrace {
    static func shouldCapture(_ verbosity: DiagnosticsVerbosity) -> Bool {
        #if DEBUG
        return !verbosity.isVerbose
        #else
        return false
        #endif
    }

    static func log(
        _ verbosity: DiagnosticsVerbosity,
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: @autoclosure () -> String,
        attrs: @autoclosure () -> [String: DiagLogAttributeValue] = [:]
    ) {
        let captures = shouldCapture(verbosity)
        let keepsForReports = !verbosity.isVerbose && AppHealthTrail.isEnabled
        guard captures || keepsForReports else { return }
        let message = message()
        let attrs = attrs()
        if keepsForReports {
            recordForReports(level: level, category: category, tag: tag, message: message, attrs: attrs)
        }
        guard captures else { return }
        switch level {
        case .verbose, .debug: DiagLog.d(category, tag, message, attrs)
        case .info: DiagLog.i(category, tag, message, attrs)
        case .warning: DiagLog.w(category, tag, message, attrs)
        case .error: DiagLog.e(category, tag, message, attrs)
        }
    }

    @discardableResult
    static func breadcrumb(
        _ verbosity: DiagnosticsVerbosity,
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: @autoclosure () -> String,
        attrs: @autoclosure () -> [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date()
    ) -> Bool {
        let captures = shouldCapture(verbosity)
        let keepsForReports = !verbosity.isVerbose && AppHealthTrail.isEnabled
        guard captures || keepsForReports else { return false }
        let message = message()
        let attrs = attrs()
        if keepsForReports {
            recordForReports(level: level, category: category, tag: tag, message: message, attrs: attrs)
        }
        guard captures,
              let line = DiagLog.renderedLine(
                level: level, category: category, tag: tag,
                message: message, attrs: attrs, timestamp: timestamp
              ) else { return false }
        DiagLog.writeLocalLine(line)
        return true
    }

    /// Essential lines also feed the recent-events log in every build, and
    /// errors become app error reports. Neither is uploaded.
    private static func recordForReports(
        level: DiagnosticsLogLevel,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue]
    ) {
        AppHealthTrail.record(level: level, category: category, tag: tag, message: message, attrs: attrs)
        if level == .error {
            AppHealthMonitor.errorLogged(category: category, tag: tag, attrs: attrs)
        }
    }
}
#endif
