// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
import Foundation
import Libmpv

/// Turns what libmpv hands over into the Swift values Vivid reads. Stateless,
/// so it runs on any thread, including on a bare core in a detached task.
enum VividPlayerMPVConversion {
    static let maximumNodeDepth = 32
    static let nodeBudget = 4_096
    static let byteBudget = 16_777_216
    static let maximumDimension: Int64 = 16_384
    static let maximumPixelCount: Int64 = 67_108_864

    // MARK: Strings

    /// mpv strings are usually UTF-8 but can carry legacy bytes. Anything that
    /// is not valid UTF-8 reads as one character per byte, never as nil.
    static func string(_ pointer: UnsafePointer<CChar>) -> String {
        decode(UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
    }

    private static func decode(_ bytes: UnsafeRawBufferPointer) -> String {
        if let text = String(validating: bytes, as: UTF8.self) { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
        return String(scalars)
    }

    static func errorText(_ status: CInt) -> String {
        guard let text = mpv_error_string(status) else { return "unknown error" }
        return string(text)
    }

    static func error(_ status: CInt) -> NSError {
        NSError(domain: "VividPlayerCore.mpv", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: errorText(status)])
    }

    // MARK: Property changes

    /// A property change's value, typed by the format mpv delivered it in.
    static func propertyValue(format: mpv_format, data: UnsafeMutableRawPointer?) -> Any? {
        guard let data else { return nil }
        switch format {
        case MPV_FORMAT_DOUBLE: return data.load(as: Double.self)
        case MPV_FORMAT_INT64: return data.load(as: Int64.self)
        case MPV_FORMAT_FLAG: return data.load(as: CInt.self) != 0
        case MPV_FORMAT_STRING:
            guard let pointer = data.load(as: UnsafePointer<CChar>?.self) else { return nil }
            return string(pointer)
        case MPV_FORMAT_NODE: return value(of: data.load(as: mpv_node.self))
        default: return nil
        }
    }

    // MARK: Nodes

    private struct Budget {
        var nodes = nodeBudget
        var bytes = byteBudget
    }

    /// Integers stay `Int64`, flags `Bool` and fractions `Double`, because
    /// callers read them with exact casts. Each call has its own budget.
    static func value(of node: mpv_node) -> Any? {
        var budget = Budget()
        return convert(node, depth: 0, budget: &budget)
    }

    private static func convert(_ node: mpv_node, depth: Int, budget: inout Budget) -> Any? {
        guard depth <= maximumNodeDepth, budget.nodes > 0 else { return nil }
        budget.nodes -= 1
        switch node.format {
        case MPV_FORMAT_INT64:
            return node.u.int64
        case MPV_FORMAT_DOUBLE:
            return node.u.double_
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0
        case MPV_FORMAT_STRING:
            guard let pointer = node.u.string else { return nil }
            return string(pointer, budget: &budget)
        case MPV_FORMAT_BYTE_ARRAY:
            guard let array = node.u.ba?.pointee, array.size <= budget.bytes else { return nil }
            guard array.size > 0 else { return Data() }
            guard let bytes = array.data else { return nil }
            budget.bytes -= array.size
            return Data(bytes: bytes, count: array.size)
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee,
                  let count = entryCount(of: list, isMap: false, budget: budget) else { return nil }
            var items: [Any] = []
            for index in 0..<count {
                if let item = convert(list.values[index], depth: depth + 1, budget: &budget) {
                    items.append(item)
                }
            }
            return items
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee,
                  let count = entryCount(of: list, isMap: true, budget: budget),
                  sideDataSizeIsAcceptable(list, count: count) else { return nil }
            var map: [String: Any] = [:]
            for index in 0..<count {
                guard let keyPointer = list.keys[index],
                      let key = string(keyPointer, budget: &budget) else { continue }
                if let value = convert(list.values[index], depth: depth + 1, budget: &budget) {
                    map[key] = value
                }
            }
            return map
        default:
            return nil
        }
    }

    /// Reads no further than the bytes left allow, plus the terminator.
    private static func string(_ pointer: UnsafePointer<CChar>, budget: inout Budget) -> String? {
        let length = strnlen(pointer, budget.bytes + 1)
        guard length <= budget.bytes else { return nil }
        budget.bytes -= length
        return decode(UnsafeRawBufferPointer(start: pointer, count: length))
    }

    private static func entryCount(of list: mpv_node_list, isMap: Bool, budget: Budget) -> Int? {
        let count = Int(list.num)
        guard count >= 0, count <= budget.nodes else { return nil }
        guard count > 0 else { return 0 }
        guard list.values != nil, !isMap || list.keys != nil else { return nil }
        return count
    }

    // MARK: Dimensions

    /// Whether a picture size is plausible: both sides 1 to 16,384 and at
    /// most 64 Mi pixels.
    static func dimensionsAreAcceptable(_ width: Int64, _ height: Int64) -> Bool {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= maximumPixelCount
    }

    /// Rejects a map that carries bytes (an embedded image, say) with a
    /// missing or implausible size, before anything is allocated for it.
    private static func sideDataSizeIsAcceptable(_ list: mpv_node_list, count: Int) -> Bool {
        var carriesBytes = false
        var width: mpv_node?
        var height: mpv_node?
        for index in 0..<count {
            let value = list.values[index]
            if value.format == MPV_FORMAT_BYTE_ARRAY { carriesBytes = true }
            guard let key = list.keys[index] else { continue }
            if strcmp(key, "width") == 0 || strcmp(key, "w") == 0 {
                width = value
            } else if strcmp(key, "height") == 0 || strcmp(key, "h") == 0 {
                height = value
            }
        }
        guard carriesBytes, width != nil || height != nil else { return true }
        guard let width = width.flatMap(integerDimension),
              let height = height.flatMap(integerDimension) else { return false }
        return dimensionsAreAcceptable(width, height)
    }

    private static func integerDimension(_ node: mpv_node) -> Int64? {
        switch node.format {
        case MPV_FORMAT_INT64: return node.u.int64
        case MPV_FORMAT_DOUBLE: return Int64(exactly: node.u.double_)
        default: return nil
        }
    }
}
#endif
