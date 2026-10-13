// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation
import Libmpv
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Builds mpv nodes in memory the test owns. Everything is freed when the
/// arena goes, so a test keeps it alive for as long as it converts.
private final class NodeArena {
    private var cleanups: [() -> Void] = []

    deinit { cleanups.forEach { $0() } }

    func int(_ value: Int64) -> mpv_node {
        var node = mpv_node()
        node.format = MPV_FORMAT_INT64
        node.u.int64 = value
        return node
    }

    func double(_ value: Double) -> mpv_node {
        var node = mpv_node()
        node.format = MPV_FORMAT_DOUBLE
        node.u.double_ = value
        return node
    }

    func flag(_ value: Int32) -> mpv_node {
        var node = mpv_node()
        node.format = MPV_FORMAT_FLAG
        node.u.flag = value
        return node
    }

    func node(format: mpv_format) -> mpv_node {
        var node = mpv_node()
        node.format = format
        return node
    }

    func cString(_ bytes: [UInt8]) -> UnsafeMutablePointer<CChar> {
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
        for (index, byte) in bytes.enumerated() { pointer[index] = CChar(bitPattern: byte) }
        pointer[bytes.count] = 0
        cleanups.append { pointer.deallocate() }
        return pointer
    }

    func cString(_ text: String) -> UnsafeMutablePointer<CChar> { cString(Array(text.utf8)) }

    /// A NUL-terminated run of `count` copies of `byte`, without building a Swift array.
    func repeatedCString(_ byte: UInt8, count: Int) -> UnsafeMutablePointer<CChar> {
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: count + 1)
        pointer.initialize(repeating: CChar(bitPattern: byte), count: count)
        pointer[count] = 0
        cleanups.append { pointer.deallocate() }
        return pointer
    }

    func string(_ text: String) -> mpv_node { string(pointer: cString(text)) }

    func string(bytes: [UInt8]) -> mpv_node { string(pointer: cString(bytes)) }

    func string(pointer: UnsafeMutablePointer<CChar>?) -> mpv_node {
        var node = mpv_node()
        node.format = MPV_FORMAT_STRING
        node.u.string = pointer
        return node
    }

    func byteArray(_ bytes: [UInt8]) -> mpv_node {
        let data = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
        cleanups.append { data.deallocate() }
        for (index, byte) in bytes.enumerated() { data.storeBytes(of: byte, toByteOffset: index, as: UInt8.self) }
        return byteArray(size: bytes.count, data: data)
    }

    func zeroedByteArray(count: Int) -> mpv_node {
        let data = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 1)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1))
        cleanups.append { data.deallocate() }
        return byteArray(size: count, data: data)
    }

    func byteArray(size: Int, data: UnsafeMutableRawPointer?) -> mpv_node {
        let array = UnsafeMutablePointer<mpv_byte_array>.allocate(capacity: 1)
        array.initialize(to: mpv_byte_array(data: data, size: size))
        cleanups.append { array.deallocate() }
        var node = mpv_node()
        node.format = MPV_FORMAT_BYTE_ARRAY
        node.u.ba = array
        return node
    }

    func array(_ children: [mpv_node]) -> mpv_node {
        list(format: MPV_FORMAT_NODE_ARRAY, num: Int32(children.count), values: children, keys: nil)
    }

    func map(_ entries: [(key: String?, value: mpv_node)]) -> mpv_node {
        list(format: MPV_FORMAT_NODE_MAP, num: Int32(entries.count), values: entries.map(\.value),
             keys: entries.map { $0.key.map { cString($0) } })
    }

    func map(rawKeys entries: [(key: UnsafeMutablePointer<CChar>?, value: mpv_node)]) -> mpv_node {
        list(format: MPV_FORMAT_NODE_MAP, num: Int32(entries.count), values: entries.map(\.value),
             keys: entries.map(\.key))
    }

    /// A list node with exactly the given storage, including deliberately broken shapes.
    func list(format: mpv_format, num: Int32, values: [mpv_node]?,
              keys: [UnsafeMutablePointer<CChar>?]?) -> mpv_node {
        var valuesPointer: UnsafeMutablePointer<mpv_node>?
        if let values {
            let pointer = UnsafeMutablePointer<mpv_node>.allocate(capacity: max(values.count, 1))
            pointer.initialize(from: values, count: values.count)
            cleanups.append { pointer.deallocate() }
            valuesPointer = pointer
        }
        var keysPointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        if let keys {
            let pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: max(keys.count, 1))
            pointer.initialize(from: keys, count: keys.count)
            cleanups.append { pointer.deallocate() }
            keysPointer = pointer
        }
        let list = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
        list.initialize(to: mpv_node_list(num: num, values: valuesPointer, keys: keysPointer))
        cleanups.append { list.deallocate() }
        var node = mpv_node()
        node.format = format
        node.u.list = list
        return node
    }

    func nullList(format: mpv_format) -> mpv_node {
        var node = mpv_node()
        node.format = format
        node.u.list = nil
        return node
    }

    /// `leaf` wrapped in single-element arrays so that it sits at `depth`
    /// (the root is depth 0).
    func nested(_ leaf: mpv_node, depth: Int) -> mpv_node {
        var node = leaf
        for _ in 0..<depth { node = array([node]) }
        return node
    }
}

/// Section 6.16 of the player bridge specification: node conversion, its
/// budgets and the dimension rule, C string decoding and property values.
final class VividPlayerConversionTests: XCTestCase {
    private let mebibytes16 = 16_777_216

    private func convert(_ node: mpv_node) -> Any? {
        VividPlayerCoreBase().convertNode(node)
    }

    private func unwrap(_ value: Any?, levels: Int) -> Any? {
        var current = value
        for _ in 0..<levels { current = (current as? [Any])?.first }
        return current
    }

    // MARK: Bare instance

    func testBareBaseConvertsAndIsReleasedOnABackgroundThread() {
        let arena = NodeArena()
        let node = arena.map([("id", arena.int(3)), ("title", arena.string("Main"))])
        let finished = expectation(description: "background conversion")
        DispatchQueue.global(qos: .utility).async {
            var result: Any?
            autoreleasepool {
                let base = VividPlayerCoreBase()
                result = base.convertNode(node)
            }
            let map = result as? [String: Any]
            XCTAssertEqual(map?["id"] as? Int64, 3)
            XCTAssertEqual(map?["title"] as? String, "Main")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    // MARK: Scalars

    func testIntegersStayInt64() {
        let arena = NodeArena()
        let value = convert(arena.int(-42))
        XCTAssertTrue(value is Int64)
        XCTAssertFalse(value is Int)
        XCTAssertEqual(value as? Int64, -42)
        XCTAssertEqual(convert(arena.int(.max)) as? Int64, .max)
    }

    func testDoublesPassThroughIncludingNaNAndInfinities() {
        let arena = NodeArena()
        XCTAssertEqual(convert(arena.double(23.976)) as? Double, 23.976)
        XCTAssertEqual((convert(arena.double(.nan)) as? Double)?.isNaN, true)
        XCTAssertEqual(convert(arena.double(.infinity)) as? Double, .infinity)
        XCTAssertEqual(convert(arena.double(-.infinity)) as? Double, -.infinity)
    }

    func testFlagsBecomeBoolWithAnyNonZeroTrue() {
        let arena = NodeArena()
        XCTAssertEqual(convert(arena.flag(0)) as? Bool, false)
        XCTAssertEqual(convert(arena.flag(1)) as? Bool, true)
        XCTAssertEqual(convert(arena.flag(2)) as? Bool, true)
        XCTAssertEqual(convert(arena.flag(-1)) as? Bool, true)
        XCTAssertFalse(convert(arena.flag(1)) is Int64)
    }

    func testStringsDecodeUTF8AndFallBackToLatin1ByteForByte() {
        let arena = NodeArena()
        XCTAssertEqual(convert(arena.string("Ünïcødé ✓")) as? String, "Ünïcødé ✓")
        XCTAssertEqual(convert(arena.string("")) as? String, "")
        // 0xC3 0x28 is not valid UTF-8, nor is a lone 0xFF.
        XCTAssertEqual(convert(arena.string(bytes: [0x41, 0xC3, 0x28, 0xFF])) as? String, "A\u{C3}(\u{FF}")
        XCTAssertEqual(convert(arena.string(bytes: [0xE9, 0x74, 0xE9])) as? String, "\u{E9}t\u{E9}")
    }

    func testByteArraysBecomeData() {
        let arena = NodeArena()
        XCTAssertEqual(convert(arena.byteArray([0, 1, 254, 255])) as? Data, Data([0, 1, 254, 255]))
        XCTAssertEqual(convert(arena.byteArray([])) as? Data, Data())
        // Size 0 is empty data even without storage.
        XCTAssertEqual(convert(arena.byteArray(size: 0, data: nil)) as? Data, Data())
    }

    func testNullPointersAndUnknownFormatsConvertToNil() {
        let arena = NodeArena()
        XCTAssertNil(convert(arena.string(pointer: nil)))
        var nullBytes = mpv_node()
        nullBytes.format = MPV_FORMAT_BYTE_ARRAY
        nullBytes.u.ba = nil
        XCTAssertNil(convert(nullBytes))
        XCTAssertNil(convert(arena.byteArray(size: 3, data: nil)))
        XCTAssertNil(convert(arena.nullList(format: MPV_FORMAT_NODE_ARRAY)))
        XCTAssertNil(convert(arena.nullList(format: MPV_FORMAT_NODE_MAP)))
        XCTAssertNil(convert(arena.node(format: MPV_FORMAT_NONE)))
        XCTAssertNil(convert(arena.node(format: MPV_FORMAT_OSD_STRING)))
        XCTAssertNil(convert(arena.node(format: MPV_FORMAT_NODE)))
    }

    // MARK: Arrays and maps

    func testArraysDropNilChildrenInOrder() {
        let arena = NodeArena()
        let node = arena.array([
            arena.int(1), arena.node(format: MPV_FORMAT_NONE), arena.string("three"),
            arena.string(pointer: nil), arena.flag(1),
        ])
        let items = convert(node) as? [Any]
        XCTAssertEqual(items?.count, 3)
        XCTAssertEqual(items?[0] as? Int64, 1)
        XCTAssertEqual(items?[1] as? String, "three")
        XCTAssertEqual(items?[2] as? Bool, true)
    }

    func testMapsSkipNullKeysAndNilValuesAndKeepTheLastDuplicate() {
        let arena = NodeArena()
        let node = arena.map([
            (nil, arena.int(1)),
            ("missing", arena.node(format: MPV_FORMAT_NONE)),
            ("id", arena.int(1)),
            ("id", arena.int(2)),
            ("lang", arena.string("eng")),
            ("lang", arena.node(format: MPV_FORMAT_NONE)),
        ])
        let map = convert(node) as? [String: Any]
        XCTAssertEqual(map.map { Set($0.keys) }, ["id", "lang"])
        XCTAssertEqual(map?["id"] as? Int64, 2)
        // A later value that converts to nil is left out, so the earlier one stays.
        XCTAssertEqual(map?["lang"] as? String, "eng")
    }

    func testMapKeysDecodeLikeStrings() {
        let arena = NodeArena()
        let node = arena.map(rawKeys: [(arena.cString([0x6B, 0xE9]), arena.int(5))])
        let map = convert(node) as? [String: Any]
        XCTAssertEqual(map?["k\u{E9}"] as? Int64, 5)
    }

    func testTrackListShapeCastsAndKeepsCallerTypes() {
        let arena = NodeArena()
        let track = arena.map([
            ("type", arena.string("audio")), ("id", arena.int(1)), ("ff-index", arena.int(1)),
            ("demux-channel-count", arena.int(6)), ("default", arena.flag(1)), ("forced", arena.flag(0)),
            ("selected", arena.flag(1)), ("external", arena.flag(0)), ("lang", arena.string("eng")),
            ("dolby-vision-profile", arena.int(8)), ("codec", arena.string("eac3")),
        ])
        let tracks = convert(arena.array([track])) as? [[String: Any]]
        let first = tracks?.first
        XCTAssertEqual(first?["type"] as? String, "audio")
        XCTAssertEqual(first?["id"] as? Int64, 1)
        XCTAssertEqual(first?["ff-index"] as? Int64, 1)
        XCTAssertEqual(first?["demux-channel-count"] as? Int64, 6)
        XCTAssertEqual(first?["default"] as? Bool, true)
        XCTAssertEqual(first?["forced"] as? Bool, false)
        XCTAssertEqual(first?["selected"] as? Bool, true)
        XCTAssertEqual(first?["external"] as? Bool, false)
        XCTAssertEqual(first?["dolby-vision-profile"] as? Int64, 8)
        // A single non-map element makes the list-of-maps cast fail.
        XCTAssertNil(convert(arena.array([track, arena.int(1)])) as? [[String: Any]])
    }

    func testBrokenListStorageConvertsToNil() {
        let arena = NodeArena()
        XCTAssertNil(convert(arena.list(format: MPV_FORMAT_NODE_ARRAY, num: -1, values: [], keys: nil)))
        XCTAssertNil(convert(arena.list(format: MPV_FORMAT_NODE_ARRAY, num: 2, values: nil, keys: nil)))
        XCTAssertNil(convert(arena.list(format: MPV_FORMAT_NODE_MAP, num: 1, values: [arena.int(1)], keys: nil)))
        XCTAssertNil(convert(arena.list(format: MPV_FORMAT_NODE_MAP, num: 1, values: nil, keys: [arena.cString("a")])))
        XCTAssertNil(convert(arena.list(format: MPV_FORMAT_NODE_MAP, num: -3, values: [], keys: [])))
        // An empty list needs no storage.
        XCTAssertEqual((convert(arena.list(format: MPV_FORMAT_NODE_ARRAY, num: 0, values: nil, keys: nil)) as? [Any])?.count, 0)
        XCTAssertEqual((convert(arena.list(format: MPV_FORMAT_NODE_MAP, num: 0, values: nil, keys: nil)) as? [String: Any])?.count, 0)
    }

    // MARK: Depth and node budget

    func testDepthThirtyTwoConvertsAndThirtyThreeIsNil() {
        let arena = NodeArena()
        let atLimit = convert(arena.nested(arena.int(7), depth: 32))
        XCTAssertEqual(unwrap(atLimit, levels: 32) as? Int64, 7)

        let beyond = convert(arena.nested(arena.int(7), depth: 33))
        XCTAssertNotNil(beyond)
        // The array at depth 32 survives, without the leaf at depth 33.
        XCTAssertEqual((unwrap(beyond, levels: 32) as? [Any])?.count, 0)
    }

    func testContainerCountMustFitTheNodesLeftAfterItsOwn() {
        let arena = NodeArena()
        let fits = convert(arena.array(Array(repeating: arena.int(1), count: 4_095))) as? [Any]
        XCTAssertEqual(fits?.count, 4_095)
        XCTAssertNil(convert(arena.array(Array(repeating: arena.int(1), count: 4_096))))

        let mapEntries = (0..<4_096).map { (key: String?("k\($0)"), value: arena.int(1)) }
        XCTAssertNil(convert(arena.map(mapEntries)))
    }

    func testNodesReachedAfterTheBudgetIsUsedUpConvertToNil() {
        let arena = NodeArena()
        // Root 1 + first child 1 + 4,092 integers + empty array 1 = 4,095, so the last integer fits.
        let fits = convert(arena.array([
            arena.array(Array(repeating: arena.int(1), count: 4_092)), arena.array([]), arena.int(9),
        ])) as? [Any]
        XCTAssertEqual(fits?.count, 3)
        XCTAssertEqual(fits?.last as? Int64, 9)

        // One more integer uses the last unit before the trailing integer is reached.
        let exhausted = convert(arena.array([
            arena.array(Array(repeating: arena.int(1), count: 4_093)), arena.array([]), arena.int(9),
        ])) as? [Any]
        XCTAssertEqual(exhausted?.count, 2)
        XCTAssertEqual((exhausted?.first as? [Any])?.count, 4_093)
    }

    func testNestedContainerCountIsCheckedAgainstTheSharedBudget() {
        let arena = NodeArena()
        // Root 1, first child 1 + 2,047, second child 1 leaves 2,046 for its entries.
        let fits = convert(arena.array([
            arena.array(Array(repeating: arena.int(1), count: 2_047)),
            arena.array(Array(repeating: arena.int(1), count: 2_046)),
        ])) as? [Any]
        XCTAssertEqual(fits?.count, 2)
        let tooMany = convert(arena.array([
            arena.array(Array(repeating: arena.int(1), count: 2_047)),
            arena.array(Array(repeating: arena.int(1), count: 2_047)),
        ])) as? [Any]
        XCTAssertEqual(tooMany?.count, 1)
    }

    func testEachTopLevelCallHasItsOwnBudget() {
        let arena = NodeArena()
        let base = VividPlayerCoreBase()
        let node = arena.array(Array(repeating: arena.int(1), count: 4_095))
        XCTAssertEqual((base.convertNode(node) as? [Any])?.count, 4_095)
        XCTAssertEqual((base.convertNode(node) as? [Any])?.count, 4_095)

        let text = arena.string(pointer: arena.repeatedCString(0x61, count: mebibytes16))
        XCTAssertEqual((base.convertNode(text) as? String)?.utf8.count, mebibytes16)
        XCTAssertEqual((base.convertNode(text) as? String)?.utf8.count, mebibytes16)
    }

    // MARK: Byte budget

    func testStringsAndBytesMustFitTheBytesLeft() {
        let arena = NodeArena()
        XCTAssertEqual((convert(arena.string(pointer: arena.repeatedCString(0x61, count: mebibytes16))) as? String)?.utf8.count,
                       mebibytes16)
        XCTAssertNil(convert(arena.string(pointer: arena.repeatedCString(0x61, count: mebibytes16 + 1))))
        XCTAssertEqual((convert(arena.zeroedByteArray(count: mebibytes16)) as? Data)?.count, mebibytes16)
        XCTAssertNil(convert(arena.zeroedByteArray(count: mebibytes16 + 1)))

        let half = mebibytes16 / 2
        let shared = convert(arena.array([
            arena.string(pointer: arena.repeatedCString(0x61, count: half)),
            arena.string(pointer: arena.repeatedCString(0x62, count: half + 1)),
            arena.int(3),
        ])) as? [Any]
        XCTAssertEqual(shared?.count, 2)
        XCTAssertEqual(shared?.last as? Int64, 3)
    }

    func testMapKeysUseBytesButNoNodes() {
        let arena = NodeArena()
        let fullKey = convert(arena.map(rawKeys: [(arena.repeatedCString(0x6B, count: mebibytes16), arena.int(1))]))
            as? [String: Any]
        XCTAssertEqual(fullKey?.count, 1)
        let tooLong = convert(arena.map(rawKeys: [(arena.repeatedCString(0x6B, count: mebibytes16 + 1), arena.int(1))]))
            as? [String: Any]
        XCTAssertEqual(tooLong?.count, 0)

        // A key whose value converts to nil still used its bytes: 8 + 1 key bytes leave this exactly.
        let leftAfterKeys = mebibytes16 - 9
        let fits = convert(arena.map([
            ("xxxxxxxx", arena.node(format: MPV_FORMAT_NONE)),
            ("y", arena.string(pointer: arena.repeatedCString(0x7A, count: leftAfterKeys))),
        ])) as? [String: Any]
        XCTAssertEqual((fits?["y"] as? String)?.utf8.count, leftAfterKeys)
        let overflows = convert(arena.map([
            ("xxxxxxxx", arena.node(format: MPV_FORMAT_NONE)),
            ("y", arena.string(pointer: arena.repeatedCString(0x7A, count: leftAfterKeys + 1))),
        ])) as? [String: Any]
        XCTAssertEqual(overflows?.count, 0)

        // Keys use no node units: 4,094 integer entries plus the root and one array fill the budget exactly.
        var entries = (0..<4_094).map { (key: String?("k\($0)"), value: arena.int(1)) }
        entries.append((key: "list", value: arena.array([])))
        XCTAssertEqual((convert(arena.map(entries)) as? [String: Any])?.count, 4_095)
    }

    // MARK: Dimension rule

    func testDimensionCheck() {
        let check = VividPlayerMPVConversion.dimensionsAreAcceptable
        XCTAssertTrue(check(1, 1))
        XCTAssertTrue(check(16_384, 4_096))
        XCTAssertTrue(check(8_192, 8_192))
        XCTAssertFalse(check(8_192, 8_193))
        XCTAssertFalse(check(16_384, 16_384))
        XCTAssertFalse(check(16_385, 1))
        XCTAssertFalse(check(1, 16_385))
        XCTAssertFalse(check(0, 1_080))
        XCTAssertFalse(check(1_920, 0))
        XCTAssertFalse(check(-1_920, 1_080))
        XCTAssertFalse(check(.max, .max))
    }

    private func picture(_ arena: NodeArena, _ dimensions: [(key: String?, value: mpv_node)]) -> mpv_node {
        arena.map(dimensions + [("data", arena.byteArray([1, 2, 3]))])
    }

    func testMapsWithBytesNeedPlausibleDimensions() {
        let arena = NodeArena()
        let accepted = convert(picture(arena, [("w", arena.int(16_384)), ("h", arena.int(4_096))])) as? [String: Any]
        XCTAssertEqual(accepted?["w"] as? Int64, 16_384)
        XCTAssertEqual(accepted?["data"] as? Data, Data([1, 2, 3]))

        XCTAssertNil(convert(picture(arena, [("w", arena.int(16_385)), ("h", arena.int(4_096))])))
        XCTAssertNil(convert(picture(arena, [("w", arena.int(0)), ("h", arena.int(4_096))])))
        XCTAssertNil(convert(picture(arena, [("w", arena.int(1_920))])))
        XCTAssertNil(convert(picture(arena, [("h", arena.int(1_080))])))
        XCTAssertNil(convert(picture(arena, [("w", arena.double(2.5)), ("h", arena.int(4_096))])))
        XCTAssertNil(convert(picture(arena, [("w", arena.int(16_384)), ("h", arena.int(16_384))])))
        XCTAssertNil(convert(picture(arena, [("w", arena.string("1920")), ("h", arena.int(1_080))])))
        XCTAssertNil(convert(picture(arena, [("w", arena.double(.nan)), ("h", arena.int(1_080))])))
        // 2^63 is not representable as Int64; the replacement may reject it but must not trap.
        XCTAssertNil(convert(picture(arena, [("w", arena.double(9_223_372_036_854_775_808)), ("h", arena.int(1))])))

        let integralDoubles = convert(picture(arena, [("w", arena.double(1_920)), ("h", arena.double(1_080))]))
            as? [String: Any]
        XCTAssertEqual(integralDoubles?["w"] as? Double, 1_920)
        XCTAssertNotNil(convert(picture(arena, [("width", arena.int(640)), ("height", arena.int(480))])))
        XCTAssertNil(convert(picture(arena, [("width", arena.int(640)), ("height", arena.int(0))])))
    }

    func testDimensionRuleUsesTheLastOccurrenceOfAKey() {
        let arena = NodeArena()
        XCTAssertNotNil(convert(picture(arena, [("w", arena.int(0)), ("w", arena.int(1_920)), ("h", arena.int(1_080))])))
        XCTAssertNil(convert(picture(arena, [("w", arena.int(1_920)), ("w", arena.int(0)), ("h", arena.int(1_080))])))
    }

    func testDimensionRuleCountsBytesUnderNullKeys() {
        let arena = NodeArena()
        let rejected = arena.map(rawKeys: [
            (nil, arena.byteArray([1])), (arena.cString("w"), arena.int(0)), (arena.cString("h"), arena.int(10)),
        ])
        XCTAssertNil(convert(rejected))
        let accepted = arena.map(rawKeys: [
            (nil, arena.byteArray([1])), (arena.cString("w"), arena.int(10)), (arena.cString("h"), arena.int(10)),
        ])
        XCTAssertEqual((convert(accepted) as? [String: Any]).map { Set($0.keys) }, ["w", "h"])
    }

    func testMapsWithoutBytesOrWithoutDimensionKeysPass() {
        let arena = NodeArena()
        XCTAssertNotNil(convert(arena.map([("w", arena.int(99_999)), ("h", arena.int(0))])))
        XCTAssertNotNil(convert(arena.map([("data", arena.byteArray([9])), ("mime", arena.string("image/png"))])))
    }

    func testRejectedNestedMapIsDroppedFromItsParent() {
        let arena = NodeArena()
        let good = arena.map([("id", arena.int(1))])
        let oversized = picture(arena, [("w", arena.int(20_000)), ("h", arena.int(20_000))])
        let list = convert(arena.array([good, oversized])) as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?["id"] as? Int64, 1)
    }

    // MARK: Property values (section 6.8)

    func testPropertyValuesFollowTheChangeEventFormat() {
        var double = Double.nan
        let nanValue = withUnsafeMutableBytes(of: &double) {
            VividPlayerMPVConversion.propertyValue(format: MPV_FORMAT_DOUBLE, data: $0.baseAddress)
        }
        XCTAssertEqual((nanValue as? Double)?.isNaN, true)

        var int: Int64 = 9
        let intValue = withUnsafeMutableBytes(of: &int) {
            VividPlayerMPVConversion.propertyValue(format: MPV_FORMAT_INT64, data: $0.baseAddress)
        }
        XCTAssertTrue(intValue is Int64)
        XCTAssertEqual(intValue as? Int64, 9)

        var flag: Int32 = 2
        let flagValue = withUnsafeMutableBytes(of: &flag) {
            VividPlayerMPVConversion.propertyValue(format: MPV_FORMAT_FLAG, data: $0.baseAddress)
        }
        XCTAssertEqual(flagValue as? Bool, true)

        let arena = NodeArena()
        var text: UnsafeMutablePointer<CChar>? = arena.cString([0x6E, 0xE9])
        let stringValue = withUnsafeMutableBytes(of: &text) {
            VividPlayerMPVConversion.propertyValue(format: MPV_FORMAT_STRING, data: $0.baseAddress)
        }
        XCTAssertEqual(stringValue as? String, "n\u{E9}")

        var nullText: UnsafeMutablePointer<CChar>?
        let nullStringValue = withUnsafeMutableBytes(of: &nullText) {
            VividPlayerMPVConversion.propertyValue(format: MPV_FORMAT_STRING, data: $0.baseAddress)
        }
        XCTAssertNil(nullStringValue)

        var node = arena.map([("w", arena.int(320)), ("h", arena.int(180)), ("par", arena.double(1))])
        let nodeValue = withUnsafeMutableBytes(of: &node) {
            VividPlayerMPVConversion.propertyValue(format: MPV_FORMAT_NODE, data: $0.baseAddress)
        } as? [String: Any]
        XCTAssertEqual(nodeValue?["w"] as? Int64, 320)
        XCTAssertEqual(nodeValue?["par"] as? Double, 1)

        var unused: Int64 = 1
        for format in [MPV_FORMAT_NONE, MPV_FORMAT_OSD_STRING, MPV_FORMAT_NODE_ARRAY, MPV_FORMAT_BYTE_ARRAY] {
            let value = withUnsafeMutableBytes(of: &unused) {
                VividPlayerMPVConversion.propertyValue(format: format, data: $0.baseAddress)
            }
            XCTAssertNil(value, "format \(format.rawValue)")
        }
        for format in [MPV_FORMAT_DOUBLE, MPV_FORMAT_INT64, MPV_FORMAT_FLAG, MPV_FORMAT_STRING, MPV_FORMAT_NODE] {
            XCTAssertNil(VividPlayerMPVConversion.propertyValue(format: format, data: nil), "format \(format.rawValue)")
        }
    }

    // MARK: C strings and errors

    func testCStringsNeverFailForANonNullPointer() {
        let arena = NodeArena()
        XCTAssertEqual(VividPlayerMPVConversion.string(arena.cString("cplayer")), "cplayer")
        XCTAssertEqual(VividPlayerMPVConversion.string(arena.cString([0x80, 0x81])), "\u{80}\u{81}")
        XCTAssertEqual(VividPlayerMPVConversion.string(arena.cString([])), "")
        let decoded = VividPlayerMPVConversion.string(arena.cString([0x61, 0xFF, 0x62]))
        XCTAssertFalse(decoded.contains("\u{FFFD}"))
        XCTAssertEqual(decoded.unicodeScalars.map(\.value), [0x61, 0xFF, 0x62])
    }

    func testMpvErrorsCarryTheStatusAndMpvsMessage() {
        let status = MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue
        let error = VividPlayerMPVConversion.error(status)
        XCTAssertEqual(error.code, -10)
        XCTAssertEqual(error.localizedDescription, String(cString: mpv_error_string(status)))
        XCTAssertEqual(VividPlayerMPVConversion.errorText(MPV_ERROR_OPTION_NOT_FOUND.rawValue), "option not found")
    }
}
