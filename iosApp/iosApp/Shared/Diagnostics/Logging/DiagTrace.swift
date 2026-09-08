#if os(iOS) || os(tvOS)
import Foundation

/// Verbosity for local development traces.
enum DiagnosticsVerbosity {
    case essential
    case verbose

    var isVerbose: Bool { self == .verbose }
}

/// Redacted development traces written to the local Apple log. No report uploads.
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
        guard shouldCapture(verbosity) else { return }
        switch level {
        case .verbose, .debug: DiagLog.d(category, tag, message(), attrs())
        case .info: DiagLog.i(category, tag, message(), attrs())
        case .warning: DiagLog.w(category, tag, message(), attrs())
        case .error: DiagLog.e(category, tag, message(), attrs())
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
        guard shouldCapture(verbosity),
              let line = DiagLog.renderedLine(
                level: level, category: category, tag: tag,
                message: message(), attrs: attrs(), timestamp: timestamp
              ) else { return false }
        DiagLog.writeLocalLine(line)
        return true
    }
}
#endif
