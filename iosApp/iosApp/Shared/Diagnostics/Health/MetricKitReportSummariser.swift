#if os(iOS) || os(tvOS)
import Foundation

/// One MetricKit diagnostic, copied out of the `MX*` objects. The subscriber
/// fills this in on iOS; tests build it directly, since MetricKit payloads
/// cannot be constructed outside the system.
struct MetricKitDiagnosticInput {
    var kind: AppHealthReport.Kind
    var payloadEnd: Date
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var deviceType: String
    /// Used only to match a report the crash capture already made.
    var pid: Int32?
    /// Numeric and boolean facts (signal, exception codes, durations).
    var values: [String: DiagnosticsJSONValue] = [:]
    /// Free text from the system, such as a termination reason or an
    /// Objective-C exception message. Always redacted before it is kept.
    var text: [String: String] = [:]
    /// `MXCallStackTree.jsonRepresentation()`.
    var callStackTreeJSON: Data?
}

/// Turns MetricKit diagnostics into health reports. Only allow-listed fields
/// survive: region format, process IDs, memory region dumps and any other
/// field MetricKit adds later are dropped.
///
/// Free text goes through the diagnostics redactor. Call stacks do not,
/// because the redactor removes UUIDs and the binary UUIDs are what make a
/// stack symbolicatable. Stack fields are numbers, UUIDs and binary names
/// only, and anything else in them is dropped.
enum MetricKitReportSummariser {
    static let allowedValueKeys: Set<String> = [
        "signal", "exception_type", "exception_code",
        "duration_ms", "cpu_time_ms", "sampled_time_ms", "writes_bytes",
        "low_power_mode", "testflight", "architecture",
    ]
    static let allowedTextKeys: Set<String> = [
        "termination_reason", "exception_name", "exception_class",
        "exception_kind", "exception_message",
    ]

    static let maxStacks = 8
    static let maxDepth = 256
    static let maxFrames = 3_000

    static func report(from input: MetricKitDiagnosticInput) -> AppHealthReport {
        var details: [String: DiagnosticsJSONValue] = [:]
        for (key, value) in input.values where allowedValueKeys.contains(key) {
            switch value {
            case .string(let text):
                details[key] = .string(DiagLog.sanitizedText(text, maxLength: 64))
            case .int, .double, .bool:
                details[key] = value
            default:
                continue
            }
        }
        for (key, text) in input.text where allowedTextKeys.contains(key) {
            details[key] = .string(DiagLog.sanitizedText(text, maxLength: 512))
        }
        let tree = input.callStackTreeJSON.flatMap(allowListedCallStackTree)
        let app = AppHealthAppInfo(
            version: DiagLog.sanitizedText(input.appVersion, maxLength: 32),
            build: DiagLog.sanitizedText(input.appBuild, maxLength: 32),
            os: DiagLog.sanitizedText(input.osVersion, maxLength: 64),
            device: DiagLog.sanitizedText(input.deviceType, maxLength: 32)
        )
        let canonicalDetails = (try? AppHealthStore.encoder.encode(details)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let canonicalTree = (try? AppHealthStore.encoder.encode(tree)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return AppHealthReport(
            kind: input.kind,
            source: .metricKit,
            recordedAt: input.payloadEnd,
            app: app,
            details: details,
            callStackTree: tree,
            fingerprintSeed: "\(input.payloadEnd.timeIntervalSince1970)|\(app.build)|\(canonicalDetails)|\(canonicalTree)"
        )
    }

    // MARK: - Call stacks

    static func allowListedCallStackTree(_ data: Data) -> DiagnosticsJSONValue? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return nil }
        var frameBudget = maxFrames
        var keptStacks: [DiagnosticsJSONValue] = []
        for stack in stacks.prefix(maxStacks) {
            var keptStack: [String: DiagnosticsJSONValue] = [:]
            if let attributed = boolValue(stack["threadAttributed"]) {
                keptStack["threadAttributed"] = .bool(attributed)
            }
            let roots = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            keptStack["callStackRootFrames"] = .array(frames(roots, depth: 0, budget: &frameBudget))
            keptStacks.append(.object(keptStack))
        }
        var kept: [String: DiagnosticsJSONValue] = ["callStacks": .array(keptStacks)]
        if let perThread = boolValue(root["callStackPerThread"]) {
            kept["callStackPerThread"] = .bool(perThread)
        }
        return .object(kept)
    }

    private static func frames(_ frames: [[String: Any]], depth: Int, budget: inout Int) -> [DiagnosticsJSONValue] {
        guard depth < maxDepth else { return [] }
        var kept: [DiagnosticsJSONValue] = []
        for frame in frames {
            guard budget > 0 else { break }
            budget -= 1
            var keptFrame: [String: DiagnosticsJSONValue] = [:]
            if let uuid = frame["binaryUUID"] as? String, isUUID(uuid) {
                keptFrame["binaryUUID"] = .string(uuid.uppercased())
            }
            if let name = frame["binaryName"] as? String {
                keptFrame["binaryName"] = .string(binaryNameToken(name))
            }
            for key in ["offsetIntoBinaryTextSegment", "address", "sampleCount"] {
                if let number = intValue(frame[key]) { keptFrame[key] = .int(number) }
            }
            if let subFrames = frame["subFrames"] as? [[String: Any]], !subFrames.isEmpty {
                keptFrame["subFrames"] = .array(self.frames(subFrames, depth: depth + 1, budget: &budget))
            }
            kept.append(.object(keptFrame))
        }
        return kept
    }

    private static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// Binary names are image names like `Vivid` or `libsystem_kernel.dylib`.
    /// Anything with characters outside that shape is replaced.
    static func binaryNameToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+- "))
        guard !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else { return "[redacted]" }
        return value
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        // Addresses can exceed Int64 on paper; drop rather than wrap.
        let unsigned = number.uint64Value
        guard unsigned <= UInt64(Int.max) else { return nil }
        return Int(unsigned)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
#endif
