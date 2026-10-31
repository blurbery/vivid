import Foundation

/// The attributes each category may carry. Anything else is dropped from the
/// line, and stops a debug build so the caller gets fixed.
enum DiagnosticsAttributeRegistry {
    enum Kind {
        case text
        case integer

        func accepts(_ value: DiagLogAttributeValue) -> Bool {
            switch (self, value) {
            case (.text, .string), (.text, .url), (.text, .error), (.integer, .int): true
            default: false
            }
        }
    }

    static let keys: [DiagnosticsLogCategory: [String: Kind]] = [
        .playback: [
            "play_method": .text,
            "position_ms": .integer,
            "reason": .text,
            "session_id": .text,
            "sink": .text,
        ],
        .focus: [
            "action": .text,
            "target": .text,
        ],
        .network: [
            "attempt": .integer,
            "duration_ms": .integer,
            "error_code": .text,
            "method": .text,
            "outcome": .text,
            "path": .text,
            "status": .integer,
        ],
        .lifecycle: [
            "duration_ms": .integer,
            "launch_type": .text,
            "outcome": .text,
            "phase": .text,
            "reason": .text,
            "state": .text,
        ],
        .crash: [
            "source": .text,
        ],
    ]

    /// The value when it is registered for the category with the right kind.
    static func accepted(
        _ value: DiagLogAttributeValue,
        key: String,
        category: DiagnosticsLogCategory
    ) -> DiagLogAttributeValue? {
        guard let kind = keys[category]?[key] else {
            assertionFailure("Unregistered diagnostics attribute \(category.rawValue).\(key)")
            return nil
        }
        guard kind.accepts(value) else {
            assertionFailure("Diagnostics attribute \(category.rawValue).\(key) has wrong value type")
            return nil
        }
        return value
    }
}

extension DiagnosticsLogLine {
    /// Compact JSON with sorted keys and unescaped slashes.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    var isComplete: Bool {
        !ts.isEmpty && !run.isEmpty && !tag.isEmpty && !msg.isEmpty
    }
}
