import Foundation

/// Essential lines feed the debug log and the recent-events trail. Verbose
/// lines are never kept.
enum DiagnosticsVerbosity {
    case essential
    case verbose
}

/// The app's trace calls. A line nobody keeps costs only the call: its
/// message and attributes are never built.
enum DiagTrace {
    static func log(
        _ verbosity: DiagnosticsVerbosity,
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: @autoclosure () -> String,
        attrs: @autoclosure () -> [String: DiagLogAttributeValue] = [:]
    ) {
        let captured = isCaptured(verbosity)
        let kept = isKeptForReports(verbosity)
        guard captured || kept else { return }
        let text = message()
        let attributes = attrs()
        if kept {
            record(level: level, category: category, tag: tag, message: text, attrs: attributes)
        }
        if captured {
            DiagLog.write(level: level, category: category, tag: tag, message: text, attrs: attributes)
        }
    }

    /// The same as `log`, stamped with `timestamp`. True when the line was
    /// written to the debug log.
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
        let captured = isCaptured(verbosity)
        let kept = isKeptForReports(verbosity)
        guard captured || kept else { return false }
        let text = message()
        let attributes = attrs()
        if kept {
            record(level: level, category: category, tag: tag, message: text, attrs: attributes)
        }
        guard captured else { return false }
        return DiagLog.write(
            level: level, category: category, tag: tag, message: text, attrs: attributes, timestamp: timestamp)
    }

    private static func isCaptured(_ verbosity: DiagnosticsVerbosity) -> Bool {
        #if DEBUG
        return verbosity == .essential
        #else
        return false
        #endif
    }

    private static func isKeptForReports(_ verbosity: DiagnosticsVerbosity) -> Bool {
        verbosity == .essential && AppHealthTrail.isEnabled
    }

    private static func record(
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
