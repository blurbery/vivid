import Foundation

/// The level letter written into every diagnostics line.
enum DiagnosticsLogLevel: String, Codable, Equatable {
    case debug = "D"
    case info = "I"
    case warning = "W"
    case error = "E"
}

/// The area of the app a diagnostics line comes from. Each category accepts
/// only its registered attributes.
enum DiagnosticsLogCategory: String, Codable, Equatable, Hashable {
    case playback
    case focus
    case network
    case lifecycle
    case crash
}

/// An attribute value passed with a diagnostics line. Values are redacted
/// when the line is rendered.
enum DiagLogAttributeValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case url(URL)
    case error(any Error)
}

/// A JSON value kept in health reports and diagnostics lines.
enum DiagnosticsJSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([DiagnosticsJSONValue])
    case object([String: DiagnosticsJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DiagnosticsJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: DiagnosticsJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One rendered diagnostics line. The short keys are the wire format.
struct DiagnosticsLogLine: Codable, Equatable {
    let ts: String
    let run: String
    let lvl: DiagnosticsLogLevel
    let cat: DiagnosticsLogCategory
    let tag: String
    let msg: String
    let attrs: [String: DiagnosticsJSONValue]?
}
