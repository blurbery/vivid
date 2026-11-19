import CoreGraphics
import Foundation
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// The keyframe still reader, its byte sources and the tone mapper, against
/// the generated files in `Fixtures/Stills`.
final class KeyframeStillReaderTests: XCTestCase {
    private static let matroska = "stills_h264_bframes.mkv"
    private static let mp4 = "stills_h264_bframes.mp4"
    private static let hevc = "stills_hevc10_pq_opengop.mkv"
    private static let rotated = "stills_h264_rotated.mp4"
    private static let withAudio = "stills_h264_with_audio.mkv"
    private static let oneKeyframe = "stills_h264_one_keyframe.mp4"

    // MARK: - Index and stream facts

    func testTheIndexIsReadInTimeOrder() async throws {
        for name in [Self.matroska, Self.mp4, Self.hevc] {
            let reader = KeyframeStillReader(source: try Self.source(name))
            XCTAssertTrue(reader.index.isEmpty, "nothing is read before it's asked for")
            let info = try await Self.unwrap(await reader.prepare(), name)
            let index = reader.index
            XCTAssertEqual(index.count, 4, name)
            XCTAssertEqual(info.keyframeCount, 4, name)
            XCTAssertTrue(info.hasKeyframeIndex, name)
            XCTAssertEqual(index.map(\.time), index.map(\.time).sorted(), name)
            for (entry, expected) in zip(index, [0.0, 2, 4, 6]) {
                // When the keyframe is shown, on every container: MP4's
                // decode times are a couple of frames earlier.
                XCTAssertEqual(entry.time, expected, accuracy: 0.001, name)
                XCTAssertGreaterThan(entry.bytePosition, 0, name)
            }
            // Only Matroska's last keyframe can't be read.
            XCTAssertEqual(index.map(\.isReadable), [true, true, true, name == Self.mp4], name)
            XCTAssertEqual(index.map(\.bytePosition), index.map(\.bytePosition).sorted(), name)
            XCTAssertEqual(info.codedWidth, 320, name)
            XCTAssertEqual(info.codedHeight, 180, name)
            XCTAssertEqual(info.rotationDegrees, 0, name)
            XCTAssertEqual(try XCTUnwrap(info.duration), 8, accuracy: 0.2, name)
            XCTAssertEqual(info.startTime, 0, accuracy: 0.01, name)
            XCTAssertNil(info.dolbyVisionProfile, name)
            XCTAssertTrue(info.canProduceStills, name)
            XCTAssertGreaterThan(info.bytesReadToOpen, 0, name)
            XCTAssertEqual(reader.info, info, name)
            await reader.shutdown()
        }
    }

    func testStreamFactsAreReported() async throws {
        let plain = KeyframeStillReader(source: try Self.source(Self.mp4))
        let h264 = try await Self.unwrap(await plain.prepare())
        XCTAssertEqual(h264.codecName, "h264")
        XCTAssertEqual(h264.bitDepth, 8)
        XCTAssertNotEqual(h264.transfer, .pq)
        XCTAssertNotNil(plain.index.first?.size, "MP4 records each sample's size")
        await plain.shutdown()

        let hdr = KeyframeStillReader(source: try Self.source(Self.hevc))
        let hevc = try await Self.unwrap(await hdr.prepare())
        XCTAssertEqual(hevc.codecName, "hevc")
        XCTAssertEqual(hevc.bitDepth, 10)
        XCTAssertEqual(hevc.transfer, .pq)
        XCTAssertEqual(hevc.primaries, .bt2020)
        XCTAssertEqual(hevc.matrix, .bt2020)
        XCTAssertEqual(hevc.range, .limited)
        XCTAssertNil(hdr.index.first?.size, "Matroska's cues don't record sizes")
        await hdr.shutdown()
    }

    func testDolbyVisionWithoutACompatibleBasePictureIsGatedOff() {
        func info(profile: Int?, compatibility: Int) -> KeyframeStillInfo {
            KeyframeStillInfo(duration: 60, startTime: 0, codedWidth: 3840, codedHeight: 2160, sampleAspectNumerator: 1,
                              sampleAspectDenominator: 1, rotationDegrees: 0, codecName: "hevc", bitDepth: 10, transfer: .pq,
                              primaries: .bt2020, matrix: .bt2020, range: .limited, dolbyVisionProfile: profile,
                              dolbyVisionCompatibility: compatibility, hasKeyframeIndex: true, keyframeCount: 30, bytesReadToOpen: 0)
        }
        XCTAssertTrue(info(profile: nil, compatibility: 0).canProduceStills)
        XCTAssertFalse(info(profile: 5, compatibility: 0).canProduceStills)
        XCTAssertTrue(info(profile: 8, compatibility: 1).canProduceStills, "HDR10 base")
        XCTAssertTrue(info(profile: 8, compatibility: 4).canProduceStills, "HLG base")
        XCTAssertTrue(info(profile: 7, compatibility: 6).canProduceStills)
        XCTAssertFalse(info(profile: 10, compatibility: 0).canProduceStills)
    }

    // MARK: - Stills

    func testAStillIsTheKeyframeAtOrBeforeTheTime() async throws {
        let cases: [(time: Double, keyframe: Double, patch: Patch)] = [
            (0, 0, .red), (1.9, 0, .red), (2, 2, .green), (3.5, 2, .green),
            (4.01, 4, .blue), (5.99, 4, .blue), (6.5, 6, .white), (7.9, 6, .white), (500, 6, .white),
        ]
        for name in [Self.matroska, Self.mp4, Self.hevc] {
            let reader = KeyframeStillReader(source: try Self.source(name))
            for (time, keyframe, patch) in cases {
                if name != Self.mp4, keyframe == 6 {
                    // Matroska's last keyframe: refused, and said to be.
                    let result = await reader.result(at: time, maxWidth: 320)
                    XCTAssertEqual(result.name, "lastCue", "\(name) at \(time)")
                    continue
                }
                let still = try await Self.unwrap(await reader.still(at: time, maxWidth: 320), "\(name) at \(time)")
                XCTAssertEqual(still.time, keyframe, accuracy: 0.05, "\(name) at \(time)")
                XCTAssertLessThanOrEqual(still.time, max(time, 0) + 0.001, "\(name) at \(time)")
                XCTAssertEqual(still.indexPosition, Int(keyframe / 2), "\(name) at \(time)")
                XCTAssertEqual(still.image.width, 320)
                XCTAssertEqual(still.image.height, 180)
                let pixel = try Self.pixel(of: still.image, x: 32, y: 32)
                XCTAssertTrue(patch.matches(pixel, isToneMapped: name == Self.hevc), "\(name) at \(time): \(pixel)")
            }
            await reader.shutdown()
        }
    }

    /// The index gives the time each keyframe is shown, so asking for a
    /// still at an entry's own time gives that keyframe. MP4 lists decode
    /// times, which with B-frames are a couple of frames early: asked for
    /// at one of those, the keyframe before would come back.
    func testAStillAtAnIndexTimeIsThatKeyframe() async throws {
        for name in [Self.matroska, Self.mp4, Self.hevc, Self.rotated, Self.withAudio] {
            let reader = KeyframeStillReader(source: try Self.source(name))
            XCTAssertNil(reader.indexPosition(at: 1), "nothing is known before the file is open")
            _ = try await Self.unwrap(await reader.prepare(), name)
            let index = reader.index
            XCTAssertGreaterThanOrEqual(index.count, 2, name)
            for (position, entry) in index.enumerated() {
                XCTAssertEqual(reader.indexPosition(at: entry.time), position, name)
                XCTAssertEqual(reader.indexPosition(at: entry.time + 0.4), position, name)
                let result = await reader.result(at: entry.time, maxWidth: 160)
                guard entry.isReadable else {
                    XCTAssertEqual(result.name, "lastCue", "\(name) entry \(position)")
                    continue
                }
                let still = try Self.unwrap(result.still, "\(name) entry \(position): \(result.name)")
                XCTAssertEqual(still.time, entry.time, accuracy: 0.001, "\(name) entry \(position)")
                XCTAssertEqual(still.indexPosition, position, "\(name) entry \(position)")
                XCTAssertEqual(still.packetsDecoded, 1, "\(name) entry \(position)")
            }
            XCTAssertNil(reader.indexPosition(at: .nan), name)
            XCTAssertEqual(reader.indexPosition(at: -5), 0, "\(name): before the start counts as the start")
            XCTAssertEqual(reader.indexPosition(at: 1_000_000), index.count - 1, name)
            await reader.shutdown()
        }
    }

    func testStillsAreScaledDownButNeverUp() async throws {
        let reader = KeyframeStillReader(source: try Self.source(Self.matroska))
        let small = try await Self.unwrap(await reader.still(at: 2, maxWidth: 160))
        XCTAssertEqual(small.image.width, 160)
        XCTAssertEqual(small.image.height, 90)
        XCTAssertTrue(Patch.green.matches(try Self.pixel(of: small.image, x: 16, y: 16), isToneMapped: false))
        let large = try await Self.unwrap(await reader.still(at: 2, maxWidth: 4000))
        XCTAssertEqual(large.image.width, 320)
        XCTAssertEqual(large.image.height, 180)
        let absurd = try await Self.unwrap(await reader.still(at: 2, maxWidth: .max))
        XCTAssertEqual(absurd.image.width, 320)
        let none = await reader.result(at: 2, maxWidth: 0)
        XCTAssertEqual(none.name, "notPossible")
        let never = await reader.result(at: .nan, maxWidth: 320)
        XCTAssertEqual(never.name, "notPossible")
        await reader.shutdown()
    }

    /// With B-frames a decoder normally holds a keyframe back until later
    /// frames arrive. One packet in and one picture out, for little more
    /// than the keyframe's own bytes, shows the drain works.
    func testEachStillReadsAndDecodesOnlyItsKeyframe() async throws {
        for name in [Self.matroska, Self.mp4, Self.hevc] {
            let source = try Self.source(name)
            let reader = KeyframeStillReader(source: source)
            _ = try await Self.unwrap(await reader.prepare(), name)
            let index = reader.index
            // The last keyframe is left to the test below: Matroska's is
            // never read.
            for (position, time) in [(1, 2.5), (2, 4.5), (1, 3.9)] {
                let groupBytes = Int(index[position + 1].bytePosition - index[position].bytePosition)
                let before = source.counts()
                let still = try await Self.unwrap(await reader.still(at: time, maxWidth: 320), name)
                let after = source.counts()

                XCTAssertEqual(still.packetsDecoded, 1, name)
                XCTAssertEqual(still.time, Double(position * 2), accuracy: 0.05, name)
                XCTAssertEqual(after.bytes - before.bytes, still.bytesRead, name)
                XCTAssertGreaterThanOrEqual(still.bytesRead, still.keyframeBytes, name)
                XCTAssertLessThan(still.bytesRead, still.keyframeBytes + 20 * 1024, name)
                XCTAssertLessThan(still.bytesRead, groupBytes / 2, name)
                if let listed = index[position].size { XCTAssertEqual(listed, still.keyframeBytes, name) }
                print("STILL-MEASURE \(name) at \(time): keyframe \(still.keyframeBytes) B, read \(still.bytesRead) B in \(still.readCount) reads, "
                    + "group of pictures \(groupBytes) B, \(Int(still.elapsed * 1_000_000)) us")
            }
            await reader.shutdown()
        }
    }

    /// Asked for the last keyframe in a Matroska index, the demuxer reads on
    /// to the end of the file in case the index missed keyframes. That is
    /// refused before anything is read, and the index says so beforehand.
    func testTheLastMatroskaKeyframeIsRefusedWithoutReading() async throws {
        for name in [Self.matroska, Self.hevc, Self.withAudio] {
            let source = try Self.source(name)
            let reader = KeyframeStillReader(source: source)
            let info = try await Self.unwrap(await reader.prepare(), name)
            let last = try XCTUnwrap(reader.index.last, name)
            XCTAssertFalse(last.isReadable, name)
            XCTAssertTrue(reader.index.dropLast().allSatisfy(\.isReadable), name)
            let before = source.counts()
            for time in [last.time, last.time + 0.5, try XCTUnwrap(info.duration), 10_000] {
                let result = await reader.result(at: time, maxWidth: 320)
                XCTAssertEqual(result.name, "lastCue", "\(name) at \(time)")
            }
            XCTAssertEqual(source.counts().reads, before.reads, "\(name): refused without a read")
            // The keyframe before it is as cheap as any other.
            let position = reader.index.count - 2
            let earlier = try await Self.unwrap(await reader.still(at: last.time - 0.01, maxWidth: 320), name)
            XCTAssertEqual(earlier.indexPosition, position, name)
            XCTAssertEqual(earlier.time, reader.index[position].time, accuracy: 0.001, name)
            await reader.shutdown()
        }

        // MP4 lists every sample, so its last keyframe costs no more than
        // any other.
        let other = KeyframeStillReader(source: try Self.source(Self.mp4), stillByteLimit: 20_000)
        _ = try await Self.unwrap(await other.still(at: 0.5, maxWidth: 320))
        XCTAssertEqual(other.index.last?.isReadable, true)
        let final = try await Self.unwrap(await other.still(at: 6.5, maxWidth: 320))
        XCTAssertEqual(final.time, 6, accuracy: 0.05)
        XCTAssertLessThan(final.bytesRead, final.keyframeBytes + 20 * 1024)
        await other.shutdown()
    }

    /// Where the index gives a keyframe's size, one over the limit is
    /// turned down before a byte of it is fetched.
    func testAKeyframeOverTheByteLimitIsRefusedWithoutReading() async throws {
        let source = try Self.source(Self.mp4)
        let reader = KeyframeStillReader(source: source, stillByteLimit: 3000)
        _ = try await Self.unwrap(await reader.prepare())
        let sizes = reader.index.compactMap(\.size)
        XCTAssertEqual(sizes.count, 4)
        XCTAssertLessThan(sizes[0], 3000)
        XCTAssertGreaterThan(sizes[1], 3000)
        let before = source.counts()
        let refused = await reader.result(at: 2.5, maxWidth: 320)
        XCTAssertEqual(refused.name, "overLimit")
        XCTAssertEqual(source.counts().reads, before.reads, "nothing was read")
        let small = try await Self.unwrap(await reader.still(at: 0.5, maxWidth: 320), "the limit doesn't break the reader")
        XCTAssertEqual(small.time, 0, accuracy: 0.05)
        XCTAssertEqual(small.bytesRead, small.keyframeBytes, "exactly the keyframe")
        await reader.shutdown()

        // Matroska's index has no sizes, so the limit is met while reading.
        let whole = try Self.bytes(Self.matroska)
        let limited = KeyframeStillReader(source: MemorySource(whole), stillByteLimit: 1000)
        let cut = await limited.result(at: 2.5, maxWidth: 320)
        XCTAssertEqual(cut.name, "overLimit")
        await limited.shutdown()
    }

    func testAPictureOverThePixelLimitIsRefused() async throws {
        // The fixtures are 320 by 180: 57 600 pixels.
        for name in [Self.matroska, Self.mp4, Self.hevc] {
            let small = KeyframeStillReader(source: try Self.source(name), picturePixelLimit: 57_599)
            let info = await small.prepare()
            XCTAssertNil(info, name)
            let result = await small.result(at: 2.5, maxWidth: 320)
            XCTAssertEqual(result.name, "overLimit", name)
            await small.shutdown()

            let exact = KeyframeStillReader(source: try Self.source(name), picturePixelLimit: 57_600)
            let still = await exact.still(at: 2.5, maxWidth: 320)
            XCTAssertNotNil(still, name)
            await exact.shutdown()
        }
    }

    func testAFileThatCostsTooMuchToOpenIsRefusedOnce() async throws {
        for name in [Self.matroska, Self.mp4] {
            let source = try Self.source(name)
            let reader = KeyframeStillReader(source: source, openByteLimit: 1000)
            let info = await reader.prepare()
            XCTAssertNil(info, name)
            XCTAssertLessThanOrEqual(source.counts().bytes, 1000, name)
            let attempts = source.attempts()
            let result = await reader.result(at: 2.5, maxWidth: 320)
            XCTAssertEqual(result.name, "overLimit", name)
            XCTAssertEqual(source.attempts(), attempts, "\(name): not opened again for every still")
            await reader.shutdown()
        }
        // The default is ample for these.
        let reader = KeyframeStillReader(source: try Self.source(Self.matroska))
        let info = try await Self.unwrap(await reader.prepare())
        XCTAssertLessThan(info.bytesReadToOpen, 64 * 1024)
        await reader.shutdown()
    }

    func testRepeatedStillsReuseTheOpenFile() async throws {
        let source = try Self.source(Self.matroska)
        let reader = KeyframeStillReader(source: source)
        let info = try await Self.unwrap(await reader.prepare())
        let opened = source.counts()
        XCTAssertEqual(opened.bytes, info.bytesReadToOpen)
        var total = 0
        for time in [4.2, 0.5, 4.4, 2.2, 0.1] {
            let still = try await Self.unwrap(await reader.still(at: time, maxWidth: 160))
            XCTAssertEqual(still.packetsDecoded, 1)
            total += still.bytesRead
        }
        let finished = source.counts()
        XCTAssertEqual(finished.bytes - opened.bytes, total, "nothing but the stills' own reads")
        XCTAssertEqual(source.readsOfTheFileStart(), opened.startReads, "the header is read once")
        await reader.shutdown()
    }

    func testClosingTheDecoderKeepsTheFileUsable() async throws {
        for name in [Self.matroska, Self.hevc] {
            let source = try Self.source(name)
            let reader = KeyframeStillReader(source: source)
            reader.closeDecoder()
            let first = try await Self.unwrap(await reader.still(at: 2.5, maxWidth: 320), name)
            let startReads = source.readsOfTheFileStart()
            reader.closeDecoder()
            reader.closeDecoder()
            let second = try await Self.unwrap(await reader.still(at: 2.5, maxWidth: 320), name)
            XCTAssertEqual(second.time, first.time, name)
            XCTAssertEqual(second.packetsDecoded, 1, name)
            XCTAssertEqual(try Self.pixel(of: second.image, x: 200, y: 100), try Self.pixel(of: first.image, x: 200, y: 100), name)
            XCTAssertEqual(source.readsOfTheFileStart(), startReads, "\(name): the file wasn't opened again")
            reader.closeDecoder()
            let third = try await Self.unwrap(await reader.still(at: 4.5, maxWidth: 320), name)
            XCTAssertEqual(third.time, 4, accuracy: 0.05, name)
            await reader.shutdown()
        }
    }

    func testAStillComesBackTurnedAsTheFileAsks() async throws {
        let reader = KeyframeStillReader(source: try Self.source(Self.rotated))
        let info = try await Self.unwrap(await reader.prepare())
        XCTAssertEqual(info.codedWidth, 160)
        XCTAssertEqual(info.codedHeight, 90)
        // The file asks for a quarter turn anticlockwise, which is three
        // clockwise.
        XCTAssertEqual(info.rotationDegrees, 270)
        XCTAssertTrue(info.hasKeyframeIndex, "two keyframes in two seconds still cover the file")
        let still = try await Self.unwrap(await reader.still(at: 0, maxWidth: 160))
        XCTAssertEqual(still.image.width, 90)
        XCTAssertEqual(still.image.height, 160)
        // The red square starts in the top left corner. Turned anticlockwise
        // it ends up in the bottom left.
        XCTAssertTrue(Patch.red.matches(try Self.pixel(of: still.image, x: 20, y: 140), isToneMapped: false))
        XCTAssertFalse(Patch.red.matches(try Self.pixel(of: still.image, x: 20, y: 20), isToneMapped: false))
        await reader.shutdown()
    }

    // MARK: - Cancelling, replacing and shutting down

    func testCancellingMidReadReturnsAtOnceAndTheNextStillWorks() async throws {
        let source = try Self.source(Self.matroska)
        let reader = KeyframeStillReader(source: source)
        _ = try await Self.unwrap(await reader.prepare())

        // A held read only ends when it is cancelled, so getting an
        // answer at all shows the cancel reached it.
        source.holdNextRead()
        async let held = reader.result(at: 4.5, maxWidth: 320)
        await source.waitUntilHeld()
        reader.cancelCurrent()
        let cancelled = await held
        XCTAssertEqual(cancelled.name, "cancelled")

        let next = try await Self.unwrap(await reader.still(at: 4.5, maxWidth: 320))
        XCTAssertEqual(next.time, 4, accuracy: 0.05)
        XCTAssertTrue(Patch.blue.matches(try Self.pixel(of: next.image, x: 32, y: 32), isToneMapped: false))
        // With nothing running, a cancel does nothing to the next still.
        reader.cancelCurrent()
        let later = await reader.still(at: 0.5, maxWidth: 320)
        XCTAssertNotNil(later)
        await reader.shutdown()
    }

    func testCancellingWhileOpeningLeavesTheFileOpenable() async throws {
        let source = try Self.source(Self.mp4)
        let reader = KeyframeStillReader(source: source)
        source.holdNextRead()
        async let held = reader.prepare()
        await source.waitUntilHeld()
        reader.cancelCurrent()
        let cancelled = await held
        XCTAssertNil(cancelled)
        XCTAssertNil(reader.info)
        let still = try await Self.unwrap(await reader.still(at: 2.5, maxWidth: 320))
        XCTAssertEqual(still.time, 2, accuracy: 0.05)
        await reader.shutdown()
    }

    func testANewerRequestReplacesTheOneWaiting() async throws {
        let source = try Self.source(Self.matroska)
        let reader = KeyframeStillReader(source: source)
        _ = try await Self.unwrap(await reader.prepare())
        XCTAssertFalse(reader.hasWaitingRequest)

        source.holdNextRead()
        async let running = reader.result(at: 0.5, maxWidth: 320)
        await source.waitUntilHeld()
        XCTAssertFalse(reader.hasWaitingRequest, "the one running isn't waiting")
        let replaced = Task { await reader.result(at: 2.5, maxWidth: 320) }
        // That one must have taken the waiting place before the next asks
        // for it. The reader says when it has.
        while !reader.hasWaitingRequest { await Task.yield() }
        let newest = Task { await reader.result(at: 4.5, maxWidth: 320, urgent: true) }
        let dropped = await replaced.value
        XCTAssertEqual(dropped.name, "superseded", "the older waiting request gives way")
        XCTAssertTrue(reader.hasWaitingRequest)
        reader.cancelCurrent()
        let aborted = await running
        XCTAssertEqual(aborted.name, "cancelled")
        let shown = try Self.unwrap((await newest.value).still)
        XCTAssertEqual(shown.time, 4, accuracy: 0.05)
        XCTAssertFalse(reader.hasWaitingRequest)
        await reader.shutdown()
    }

    func testCancelStopsTheRunningStillAndTheOneWaitingAndLeavesTheReaderUsable() async throws {
        let source = try Self.source(Self.matroska)
        let reader = KeyframeStillReader(source: source)
        _ = try await Self.unwrap(await reader.prepare())

        source.holdNextRead()
        async let running = reader.result(at: 0.5, maxWidth: 320)
        await source.waitUntilHeld()
        let waiting = Task { await reader.result(at: 2.5, maxWidth: 320, urgent: true) }
        while !reader.hasWaitingRequest { await Task.yield() }
        // One call, which returns without waiting for the reader's thread:
        // the read that was held only ends because the cancel reached it.
        reader.cancel()
        XCTAssertFalse(reader.hasWaitingRequest, "the waiting one is dropped in the call itself")
        let dropped = await waiting.value
        XCTAssertEqual(dropped.name, "cancelled")
        let aborted = await running
        XCTAssertEqual(aborted.name, "cancelled")

        // The reader was not shut down: the next still works.
        let next = try await Self.unwrap(await reader.still(at: 4.5, maxWidth: 320))
        XCTAssertEqual(next.time, 4, accuracy: 0.05)
        // With nothing running, a cancel does nothing to the next still.
        reader.cancel()
        let later = await reader.still(at: 0.5, maxWidth: 320)
        XCTAssertNotNil(later)
        await reader.shutdown()
    }

    func testShutdownStopsARunningStillAndRefusesNewOnes() async throws {
        let source = try Self.source(Self.matroska)
        let reader = KeyframeStillReader(source: source)
        _ = try await Self.unwrap(await reader.prepare())
        source.holdNextRead()
        async let running = reader.result(at: 4.5, maxWidth: 320)
        await source.waitUntilHeld()
        await reader.shutdown()
        let stopped = await running
        XCTAssertEqual(stopped.name, "cancelled")
        let after = await reader.result(at: 1, maxWidth: 320)
        XCTAssertEqual(after.name, "cancelled")
        let prepared = await reader.prepare()
        XCTAssertNil(prepared)
        await reader.shutdown()

        let unused = KeyframeStillReader(source: try Self.source(Self.matroska))
        await unused.shutdown()
        let nothing = await unused.still(at: 1, maxWidth: 320)
        XCTAssertNil(nothing)
    }

    // MARK: - Bad input

    func testFilesThatAreNotMediaFailCleanly() async throws {
        var noise = Data(count: 96 * 1024)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for position in noise.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            noise[position] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let whole = try Self.bytes(Self.matroska)
        let inputs: [(String, Data)] = [
            ("empty", Data()),
            ("noise", noise),
            ("a few header bytes", whole.prefix(40)),
            ("text", Data(String(repeating: "not a film ", count: 500).utf8)),
        ]
        for (label, data) in inputs {
            let source = MemorySource(data)
            let reader = KeyframeStillReader(source: source)
            let info = await reader.prepare()
            XCTAssertNil(info, label)
            let attempts = source.attempts()
            let result = await reader.result(at: 1, maxWidth: 320)
            XCTAssertEqual(result.name, "notPossible", label)
            XCTAssertEqual(source.attempts(), attempts, "\(label): a file that was refused isn't read again")
            XCTAssertTrue(reader.index.isEmpty, label)
            await reader.shutdown()
        }
    }

    /// Only Matroska and MP4 are read. Anything else is turned away on its
    /// first few bytes, before any demuxer is given it: other containers,
    /// and the text formats that would have a demuxer go and open other
    /// files or addresses.
    func testOtherContainersAndPlaylistsAreRefusedOnTheirFirstBytes() async throws {
        func padded(_ start: [UInt8]) -> Data {
            Data(start) + Data(repeating: 0, count: 64 * 1024)
        }
        let transportPacket: [UInt8] = [0x47, 0x40, 0x00, 0x10] + [UInt8](repeating: 0xFF, count: 184)
        let inputs: [(String, Data)] = [
            ("AVI", padded(Array("RIFF".utf8) + [0x00, 0x10, 0x00, 0x00] + Array("AVI LIST".utf8))),
            ("MPEG-TS", Data((0..<300).flatMap { _ in transportPacket })),
            ("an HLS playlist", Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://media.example.invalid/a.m3u8\n".utf8)),
            ("a list of files to join", Data("ffconcat version 1.0\nfile 'other.mkv'\n".utf8)),
            ("Ogg", padded(Array("OggS".utf8))),
            ("FLV", padded(Array("FLV".utf8) + [0x01, 0x05, 0x00, 0x00, 0x00, 0x09])),
        ]
        for (label, data) in inputs {
            let source = MemorySource(data)
            let reader = KeyframeStillReader(source: source)
            let info = await reader.prepare()
            XCTAssertNil(info, label)
            XCTAssertLessThanOrEqual(source.counts().bytes, 12, "\(label): told apart on its first bytes")
            let result = await reader.result(at: 1, maxWidth: 320)
            XCTAssertEqual(result.name, "notPossible", label)
            await reader.shutdown()
        }
    }

    /// A file with sound opens for its picture alone. No decoder is made
    /// for the sound (FLAC here, which isn't one of the video decoders the
    /// reader keeps to) and none of its packets are wanted: the open reads
    /// the header, the first video packet and the index, and stops.
    func testAFileWithSoundOpensForItsPictureOnly() async throws {
        let source = try Self.source(Self.withAudio)
        let reader = KeyframeStillReader(source: source)
        let info = try await Self.unwrap(await reader.prepare())
        XCTAssertEqual(info.codecName, "h264")
        XCTAssertEqual(info.codedWidth, 160)
        XCTAssertEqual(info.codedHeight, 90)
        XCTAssertEqual(info.bitDepth, 8)
        XCTAssertEqual(info.keyframeCount, 4)
        XCTAssertTrue(info.hasKeyframeIndex)
        XCTAssertEqual(info.startTime, 0, accuracy: 0.01)
        XCTAssertLessThan(info.bytesReadToOpen, 16 * 1024, "nothing like the megabyte a search through the streams reads")
        XCTAssertEqual(reader.index.map(\.time), [0, 1, 2, 3])
        let red = try await Self.unwrap(await reader.still(at: 1.5, maxWidth: 160))
        XCTAssertEqual(red.time, 1, accuracy: 0.001)
        XCTAssertEqual(red.packetsDecoded, 1)
        XCTAssertTrue(Patch.red.matches(try Self.pixel(of: red.image, x: 16, y: 16), isToneMapped: false))
        let green = try await Self.unwrap(await reader.still(at: 2.5, maxWidth: 160))
        XCTAssertEqual(green.time, 2, accuracy: 0.001)
        XCTAssertTrue(Patch.green.matches(try Self.pixel(of: green.image, x: 16, y: 16), isToneMapped: false))
        await reader.shutdown()
    }

    /// One keyframe is the whole index of a short clip, and a still comes
    /// from it. A couple of keyframes picked up along the way in a longer
    /// file are not an index.
    func testALoneKeyframeIsAnIndexForAShortClip() async throws {
        let reader = KeyframeStillReader(source: try Self.source(Self.oneKeyframe))
        let info = try await Self.unwrap(await reader.prepare())
        XCTAssertEqual(info.keyframeCount, 1)
        XCTAssertEqual(try XCTUnwrap(info.duration), 1, accuracy: 0.1)
        XCTAssertTrue(info.hasKeyframeIndex)
        XCTAssertEqual(reader.index.map(\.isReadable), [true])
        let still = try await Self.unwrap(await reader.still(at: 0.7, maxWidth: 160))
        XCTAssertEqual(still.time, 0, accuracy: 0.001)
        XCTAssertEqual(still.indexPosition, 0)
        XCTAssertTrue(Patch.blue.matches(try Self.pixel(of: still.image, x: 16, y: 16), isToneMapped: false))
        await reader.shutdown()

        // The Matroska fixture without its cues, which sit at the end. What
        // is known of its keyframes stops well short of its eight seconds.
        let whole = try Self.bytes(Self.matroska)
        let cut = KeyframeStillReader(source: MemorySource(whole.prefix(whole.count - 200)))
        let partial = try await Self.unwrap(await cut.prepare())
        XCTAssertLessThan(partial.keyframeCount, 4)
        XCTAssertFalse(partial.hasKeyframeIndex)
        await cut.shutdown()
    }

    /// A decoder patches over damage and hands back a picture anyway. A
    /// patched-up picture is not a preview of anything, so it is refused.
    func testADamagedKeyframeIsRefusedNotShown() async throws {
        var bytes = try Self.bytes(Self.mp4)
        let clean = KeyframeStillReader(source: MemorySource(bytes))
        _ = try await Self.unwrap(await clean.prepare())
        let entry = clean.index[1]
        await clean.shutdown()
        let start = Int(entry.bytePosition)
        let size = try XCTUnwrap(entry.size)
        for position in stride(from: start + 200, to: start + size - 200, by: 7) {
            bytes[position] ^= 0x5A
        }
        let reader = KeyframeStillReader(source: MemorySource(bytes))
        let damaged = await reader.result(at: entry.time + 0.5, maxWidth: 320)
        XCTAssertEqual(damaged.name, "notPossible")
        let whole = try await Self.unwrap(await reader.still(at: 4.5, maxWidth: 320), "the keyframes around it are untouched")
        XCTAssertEqual(whole.time, 4, accuracy: 0.05)
        XCTAssertTrue(Patch.blue.matches(try Self.pixel(of: whole.image, x: 32, y: 32), isToneMapped: false))
        await reader.shutdown()
    }

    func testASourceThatFailsOrLiesFailsCleanly() async throws {
        let failing = MemorySource(try Self.bytes(Self.matroska))
        failing.failEveryRead()
        let reader = KeyframeStillReader(source: failing)
        let result = await reader.result(at: 1, maxWidth: 320)
        XCTAssertEqual(result.name, "transientFailure", "the source failed, not the file")
        await reader.shutdown()

        let lying = MemorySource(try Self.bytes(Self.matroska))
        lying.claimTooManyBytes()
        let second = KeyframeStillReader(source: lying)
        let refused = await second.still(at: 1, maxWidth: 320)
        XCTAssertNil(refused, "a read that claims more than the buffer holds is refused")
        await second.shutdown()
    }

    /// A read that fails while the file is being opened says nothing about
    /// the file. It is tried again, but not for every still: after five
    /// seconds, and after thirty once it has failed three times running.
    func testAFailedOpenIsRetriedAfterAWait() async throws {
        let source = try Self.source(Self.mp4)
        let clock = Box<TimeInterval>(1000)
        let reader = KeyframeStillReader(source: source, uptime: { clock.get() })

        func expectFailure(tries: Bool, _ message: String, line: UInt = #line) async {
            let before = source.attempts()
            let result = await reader.result(at: 2.5, maxWidth: 320)
            XCTAssertEqual(result.name, "transientFailure", message, line: line)
            if tries {
                XCTAssertGreaterThan(source.attempts(), before, message, line: line)
            } else {
                XCTAssertEqual(source.attempts(), before, message, line: line)
            }
        }

        source.failEveryRead()
        await expectFailure(tries: true, "the first open is tried")
        await expectFailure(tries: false, "not again straight away")
        let waiting = await reader.prepare()
        XCTAssertNil(waiting)
        clock.set(1004.9)
        await expectFailure(tries: false, "not before five seconds")
        clock.set(1005.1)
        await expectFailure(tries: true, "again after five seconds")
        clock.set(1010.3)
        await expectFailure(tries: true, "and a third time")
        clock.set(1016)
        await expectFailure(tries: false, "three in a row: the wait is longer now")
        clock.set(1039)
        await expectFailure(tries: false, "still inside thirty seconds")
        clock.set(1041)
        await expectFailure(tries: true, "after thirty seconds")

        // The server comes back.
        source.stopFailing()
        await expectFailure(tries: false, "the wait still runs")
        clock.set(1072)
        let still = try await Self.unwrap(await reader.still(at: 2.5, maxWidth: 320))
        XCTAssertEqual(still.time, 2, accuracy: 0.05)
        XCTAssertNotNil(reader.info)

        // A read that fails once the file is open fails that still only.
        source.failEveryRead()
        let failed = await reader.result(at: 4.5, maxWidth: 320)
        XCTAssertEqual(failed.name, "transientFailure")
        source.stopFailing()
        let next = try await Self.unwrap(await reader.still(at: 4.5, maxWidth: 320), "no wait after a failed still")
        XCTAssertEqual(next.time, 4, accuracy: 0.05)
        await reader.shutdown()
    }

    func testASourceThatTurnedItselfOffIsNotRetried() async throws {
        let source = try Self.source(Self.mp4)
        let clock = Box<TimeInterval>(50)
        let reader = KeyframeStillReader(source: source, uptime: { clock.get() })
        source.failEveryRead()
        source.turnOffForGood()
        let first = await reader.result(at: 2.5, maxWidth: 320)
        XCTAssertEqual(first.name, "notPossible")
        let attempts = source.attempts()
        clock.set(5000)
        source.stopFailing()
        let later = await reader.result(at: 2.5, maxWidth: 320)
        XCTAssertEqual(later.name, "notPossible")
        XCTAssertEqual(source.attempts(), attempts, "never asked again")
        await reader.shutdown()
    }

    // MARK: - File source

    func testTheFileSourceReadsAFileOnDisk() async throws {
        let url = try Self.fixtureURL(Self.mp4)
        let expected = try Data(contentsOf: url)
        let source = try XCTUnwrap(FileStillByteSource(url: url))
        XCTAssertEqual(source.size, Int64(expected.count))
        var buffer = [UInt8](repeating: 0, count: 1000)
        let count = try buffer.withUnsafeMutableBytes { try source.read(into: $0, offset: 5000) }
        XCTAssertEqual(count, 1000)
        XCTAssertEqual(Data(buffer), expected.subdata(in: 5000..<6000))
        let tail = try buffer.withUnsafeMutableBytes { try source.read(into: $0, offset: Int64(expected.count) - 10) }
        XCTAssertEqual(tail, 10)
        let end = try buffer.withUnsafeMutableBytes { try source.read(into: $0, offset: Int64(expected.count)) }
        XCTAssertEqual(end, 0)
        XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try source.read(into: $0, offset: -1) })
        source.cancel()
        XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try source.read(into: $0, offset: 0) }) {
            XCTAssertEqual($0 as? StillByteSourceError, .cancelled)
        }
        source.resume()
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try source.read(into: $0, offset: 0) }, 1000)

        XCTAssertNil(FileStillByteSource(url: url.deletingLastPathComponent().appendingPathComponent("missing.mkv")))
        XCTAssertNil(FileStillByteSource(url: url.deletingLastPathComponent()), "a folder isn't a file")
        XCTAssertNil(FileStillByteSource(url: URL(string: "https://media.example.invalid/a.mkv")!))

        let reader = KeyframeStillReader(source: source)
        let still = try await Self.unwrap(await reader.still(at: 4.5, maxWidth: 320))
        XCTAssertEqual(still.time, 4, accuracy: 0.05)
        await reader.shutdown()
    }

    // MARK: - HTTP source

    func testRequestsCarryARangeAndFreshHeaders() throws {
        let file = Self.pattern(count: 1_000_000)
        RangeStub.serve(file)
        let tokens = Counter()
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession()) {
            ["Authorization": "Bearer token-\(tokens.next())"]
        }
        XCTAssertNil(source.size)
        XCTAssertEqual(try Self.read(source, count: 1000, offset: 0), file.subdata(in: 0..<1000))
        XCTAssertEqual(source.size, 1_000_000, "the length comes from Content-Range")
        XCTAssertEqual(try Self.read(source, count: 1000, offset: 600_000), file.subdata(in: 600_000..<601_000))

        let requests = RangeStub.requests()
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Range") }, ["bytes=0-262143", "bytes=600000-862143"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer token-1", "Bearer token-2"])
        XCTAssertEqual(source.counters, .init(requests: 2, bytes: 2 * 262_144))

        // The last block is cut to the end of the file.
        XCTAssertEqual(try Self.read(source, count: 1000, offset: 999_500), file.subdata(in: 999_500..<1_000_000))
        XCTAssertEqual(RangeStub.requests().last?.value(forHTTPHeaderField: "Range"), "bytes=999500-999999")
        XCTAssertEqual(try Self.read(source, count: 1000, offset: 1_000_000), Data(), "the end of the file")
        XCTAssertEqual(try Self.read(source, count: 1000, offset: 5_000_000), Data())
        XCTAssertEqual(source.counters.requests, 3)
    }

    func testBlocksAlreadyFetchedAreNotAskedForAgain() throws {
        let file = Self.pattern(count: 3_000_000)
        RangeStub.serve(file)
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        for offset in stride(from: 100_000, to: 360_000, by: 8192) {
            XCTAssertEqual(try Self.read(source, count: 8192, offset: Int64(offset)), file.subdata(in: offset..<(offset + 8192)))
        }
        XCTAssertEqual(source.counters.requests, 1, "many small reads, one request")
        XCTAssertEqual(try Self.read(source, count: 8192, offset: 100_000 + 262_144 - 100).count, 100, "a short read up to the block's end")
        XCTAssertEqual(source.counters.requests, 1)
        XCTAssertEqual(try Self.read(source, count: 8192, offset: 100_000 + 262_144).count, 8192)
        XCTAssertEqual(source.counters.requests, 2)
        // Going back to an earlier block costs nothing.
        XCTAssertEqual(try Self.read(source, count: 500, offset: 150_000), file.subdata(in: 150_000..<150_500))
        XCTAssertEqual(source.counters.requests, 2)

        // Only a handful of blocks are kept.
        for block in 0..<8 {
            _ = try Self.read(source, count: 100, offset: Int64(1_000_000 + block * 262_144))
        }
        let before = source.counters.requests
        _ = try Self.read(source, count: 100, offset: 150_000)
        XCTAssertEqual(source.counters.requests, before + 1, "the oldest block was let go")
    }

    func testTheBlockSizeFollowsTheLargestKeyframe() throws {
        RangeStub.serve(Self.pattern(count: 4_000_000))
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        XCTAssertEqual(source.blockBytes, 256 * 1024)
        source.noteKeyframeSize(4000)
        XCTAssertEqual(source.blockBytes, 256 * 1024, "never below the floor")
        source.noteKeyframeSize(200_000)
        XCTAssertEqual(source.blockBytes, 8 * 64 * 1024, "twice 200 000 plus 64 KiB, rounded up to 64 KiB")
        source.noteKeyframeSize(1000)
        XCTAssertEqual(source.blockBytes, 8 * 64 * 1024, "the largest one counts")
        _ = try Self.read(source, count: 100, offset: 1000)
        XCTAssertEqual(RangeStub.requests().last?.value(forHTTPHeaderField: "Range"), "bytes=1000-525287")
        source.noteKeyframeSize(50_000_000)
        XCTAssertEqual(source.blockBytes, 1024 * 1024, "never above the ceiling")
        source.noteKeyframeSize(.max)
        XCTAssertEqual(source.blockBytes, 1024 * 1024)
        source.noteKeyframeSize(-5)
        XCTAssertEqual(source.blockBytes, 1024 * 1024)
    }

    func testAReplyThatIgnoresTheRangeTurnsTheSourceOff() throws {
        let file = Self.pattern(count: 500_000)
        RangeStub.configure { _ in .reply(status: 200, headers: [:], body: file) }
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        XCTAssertFalse(source.isPermanentlyUnusable)
        XCTAssertThrowsError(try Self.read(source, count: 100, offset: 0)) {
            XCTAssertEqual($0 as? StillByteSourceError, .disabled)
        }
        XCTAssertTrue(source.isPermanentlyUnusable)
        XCTAssertThrowsError(try Self.read(source, count: 100, offset: 0))
        XCTAssertEqual(RangeStub.requests().count, 1, "once off, it stops asking")
        XCTAssertEqual(source.counters.bytes, 0)
    }

    func testARangeReplyThatIsNotTheRangeAskedForTurnsTheSourceOff() throws {
        let file = Self.pattern(count: 2_000_000)
        let replies: [(String, RangeStub.Reply)] = [
            ("no Content-Range", .reply(status: 206, headers: [:], body: file.prefix(1000))),
            ("another range", .reply(status: 206, headers: ["Content-Range": "bytes 50-1049/2000000"], body: file.subdata(in: 50..<1050))),
            ("more than asked", .reply(status: 206, headers: ["Content-Range": "bytes 0-1999999/2000000"], body: file)),
            ("a longer body than it says", .reply(status: 206, headers: ["Content-Range": "bytes 0-999/2000000"], body: file)),
            ("a negative length", .reply(status: 206, headers: ["Content-Range": "bytes 0-999/-5"], body: file.prefix(1000))),
            ("a total before the range", .reply(status: 206, headers: ["Content-Range": "bytes 0-999/500"], body: file.prefix(1000))),
            ("nonsense", .reply(status: 206, headers: ["Content-Range": "bytes lots"], body: file.prefix(1000))),
        ]
        for (label, reply) in replies {
            RangeStub.configure { _ in reply }
            let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
            XCTAssertThrowsError(try Self.read(source, count: 100, offset: 0), label) {
                XCTAssertEqual($0 as? StillByteSourceError, .disabled, label)
            }
            XCTAssertTrue(source.isPermanentlyUnusable, label)
        }

        RangeStub.serve(file)
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try source.read(into: $0, offset: -1) }) {
            XCTAssertEqual($0 as? StillByteSourceError, .invalidRequest)
        }
        XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try source.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<0]), offset: 0) })
        XCTAssertFalse(source.isPermanentlyUnusable, "a bad request from the app isn't the server's fault")
        XCTAssertEqual(RangeStub.requests().count, 0)
    }

    /// A server that says no, is busy or breaks off has failed one read.
    /// The next may work: a token is refreshed, the server recovers.
    func testOtherRepliesFailOneReadAndLeaveTheSourceUsable() throws {
        let file = Self.pattern(count: 600_000)
        let replies: [(String, RangeStub.Reply)] = [
            ("unauthorised", .reply(status: 401, headers: [:], body: Data("no".utf8))),
            ("forbidden", .reply(status: 403, headers: [:], body: Data())),
            ("not found", .reply(status: 404, headers: [:], body: Data("no".utf8))),
            ("too many requests", .reply(status: 429, headers: ["Retry-After": "1"], body: Data())),
            ("server error", .reply(status: 500, headers: [:], body: Data("oops".utf8))),
            ("bad gateway", .reply(status: 502, headers: [:], body: Data())),
            ("unavailable", .reply(status: 503, headers: [:], body: Data())),
            ("no content", .reply(status: 204, headers: [:], body: Data())),
            ("a range reply cut short", .reply(status: 206, headers: ["Content-Range": "bytes 0-262143/600000"], body: file.prefix(5000))),
            ("a range that isn't there, short of the end", .reply(status: 416, headers: ["Content-Range": "bytes */600000"], body: Data())),
            ("a dropped connection", .failure(URLError(.networkConnectionLost))),
            ("a timeout", .failure(URLError(.timedOut))),
        ]
        for (label, reply) in replies {
            let calls = Counter()
            RangeStub.configure { request in
                calls.next() == 1 ? reply : RangeStub.rangeReply(for: request, from: file, total: file.count)
            }
            let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
            XCTAssertThrowsError(try Self.read(source, count: 100, offset: 0), label) {
                XCTAssertEqual($0 as? StillByteSourceError, .failed, label)
            }
            XCTAssertFalse(source.isPermanentlyUnusable, label)
            XCTAssertEqual(try Self.read(source, count: 100, offset: 0), file.prefix(100), "\(label): the next read works")
            XCTAssertEqual(RangeStub.requests().count, 2, label)
        }
    }

    /// Some servers answer `bytes first-last/*`, without the file's length.
    /// The end of the file is then found by asking past it, which is an
    /// ordinary end of file and nothing to turn the source off over.
    func testAServerThatDoesNotGiveTheLengthIsReadToTheEnd() throws {
        let file = Self.pattern(count: 300_000)
        for sendsTotalWhenPastEnd in [false, true] {
            RangeStub.configure { request in
                guard case let .reply(status, headers, body) = RangeStub.rangeReply(for: request, from: file, total: file.count) else {
                    return .failure(URLError(.badServerResponse))
                }
                if status == 416 {
                    return .reply(status: 416, headers: sendsTotalWhenPastEnd ? headers : [:], body: body)
                }
                let range = headers["Content-Range"].map { String($0.prefix { $0 != "/" }) + "/*" }
                return .reply(status: status, headers: ["Content-Range": range ?? ""], body: body)
            }
            let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
            XCTAssertEqual(try Self.read(source, count: 1000, offset: 0), file.prefix(1000))
            XCTAssertNil(source.size, "the server never said")
            // The second block is short: the file ends inside it.
            XCTAssertEqual(try Self.read(source, count: 1000, offset: 299_500), file.suffix(500))
            XCTAssertEqual(try Self.read(source, count: 1000, offset: 300_000), Data(), "the end of the file")
            XCTAssertFalse(source.isPermanentlyUnusable)
            let asked = RangeStub.requests().count
            XCTAssertEqual(try Self.read(source, count: 1000, offset: 300_000), Data())
            XCTAssertEqual(try Self.read(source, count: 1000, offset: 900_000), Data())
            XCTAssertEqual(RangeStub.requests().count, asked, "the end is remembered")
            XCTAssertEqual(source.size, sendsTotalWhenPastEnd ? 300_000 : nil)
            XCTAssertEqual(try Self.read(source, count: 1000, offset: 100), file.subdata(in: 100..<1100), "and the file still reads")
        }
    }

    /// The reader over such a server: Matroska keeps its cues at the end of
    /// the file, and finds them without being told how long the file is.
    func testStillsComeFromAServerThatDoesNotGiveTheLength() async throws {
        let file = try Self.bytes(Self.matroska)
        RangeStub.configure { request in
            guard case let .reply(status, headers, body) = RangeStub.rangeReply(for: request, from: file, total: file.count),
                  status == 206, let range = headers["Content-Range"]
            else { return .reply(status: 416, headers: [:], body: Data()) }
            return .reply(status: 206, headers: ["Content-Range": String(range.prefix { $0 != "/" }) + "/*"], body: body)
        }
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        let reader = KeyframeStillReader(source: source)
        let info = try await Self.unwrap(await reader.prepare())
        XCTAssertEqual(info.keyframeCount, 4)
        let still = try await Self.unwrap(await reader.still(at: 2.5, maxWidth: 320))
        XCTAssertEqual(still.time, 2, accuracy: 0.05)
        XCTAssertFalse(source.isPermanentlyUnusable)
        await reader.shutdown()
    }

    /// The reader over a server that fails and then recovers: the failure
    /// is not held against the file.
    func testAServerErrorWhileOpeningIsNotHeldAgainstTheFile() async throws {
        let file = try Self.bytes(Self.mp4)
        let isDown = Box(true)
        RangeStub.configure { request in
            isDown.get() ? .reply(status: 503, headers: [:], body: Data()) : RangeStub.rangeReply(for: request, from: file, total: file.count)
        }
        let clock = Box<TimeInterval>(10)
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        let reader = KeyframeStillReader(source: source, uptime: { clock.get() })
        let down = await reader.result(at: 2.5, maxWidth: 320)
        XCTAssertEqual(down.name, "transientFailure")
        XCTAssertFalse(source.isPermanentlyUnusable)
        isDown.set(false)
        clock.set(20)
        let still = try await Self.unwrap(await reader.still(at: 2.5, maxWidth: 320))
        XCTAssertEqual(still.time, 2, accuracy: 0.05)
        await reader.shutdown()

        // A server that sends the whole file is another matter.
        RangeStub.configure { _ in .reply(status: 200, headers: [:], body: file) }
        let whole = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        let second = KeyframeStillReader(source: whole, uptime: { clock.get() })
        let refused = await second.result(at: 2.5, maxWidth: 320)
        XCTAssertEqual(refused.name, "notPossible")
        XCTAssertTrue(whole.isPermanentlyUnusable)
        clock.set(500)
        let again = await second.result(at: 2.5, maxWidth: 320)
        XCTAssertEqual(again.name, "notPossible")
        XCTAssertEqual(RangeStub.requests().count, 1, "asked once, never again")
        await second.shutdown()
    }

    func testAFileThatChangesLengthTurnsTheSourceOff() throws {
        let file = Self.pattern(count: 1_000_000)
        let calls = Counter()
        RangeStub.configure { request in
            let total = calls.next() == 1 ? 1_000_000 : 900_000
            return RangeStub.rangeReply(for: request, from: file, total: total)
        }
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        XCTAssertEqual(try Self.read(source, count: 100, offset: 0).count, 100)
        XCTAssertThrowsError(try Self.read(source, count: 100, offset: 500_000)) {
            XCTAssertEqual($0 as? StillByteSourceError, .disabled)
        }
    }

    func testRedirectsAreNotFollowedWhenHeadersAreAttached() throws {
        let file = Self.pattern(count: 300_000)
        let elsewhere = URL(string: "https://other.example.invalid/film.mkv")!
        RangeStub.configure { request in
            request.url == elsewhere ? RangeStub.rangeReply(for: request, from: file, total: file.count) : .redirect(elsewhere)
        }
        let signedIn = HTTPStillByteSource(url: Self.address, session: Self.stubSession()) { ["X-Emby-Token": "secret"] }
        XCTAssertThrowsError(try Self.read(signedIn, count: 100, offset: 0)) {
            XCTAssertEqual($0 as? StillByteSourceError, .failed)
        }
        XCTAssertEqual(RangeStub.requests().map(\.url), [Self.address], "the credentials went nowhere else")
        XCTAssertFalse(signedIn.isPermanentlyUnusable, "a redirect that isn't followed fails that read only")

        RangeStub.configure { request in
            request.url == elsewhere ? RangeStub.rangeReply(for: request, from: file, total: file.count) : .redirect(elsewhere)
        }
        let anonymous = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        XCTAssertEqual(try Self.read(anonymous, count: 100, offset: 0), file.prefix(100))
        XCTAssertEqual(RangeStub.requests().map(\.url), [Self.address, elsewhere])

        // HTTPS down to plain HTTP on a public host is refused either way.
        let plain = URL(string: "http://other.example.invalid/film.mkv")!
        RangeStub.configure { request in
            request.url == plain ? RangeStub.rangeReply(for: request, from: file, total: file.count) : .redirect(plain)
        }
        let downgraded = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        XCTAssertThrowsError(try Self.read(downgraded, count: 100, offset: 0))
        XCTAssertEqual(RangeStub.requests().map(\.url), [Self.address])
    }

    func testCancellingFailsTheReadInFlightAtOnce() throws {
        let file = Self.pattern(count: 300_000)
        let release = DispatchSemaphore(value: 0)
        let arrived = DispatchSemaphore(value: 0)
        let calls = Counter()
        RangeStub.configure { request in
            if calls.next() == 1 {
                arrived.signal()
                _ = release.wait(timeout: .now() + 20)
            }
            return RangeStub.rangeReply(for: request, from: file, total: file.count)
        }
        defer { release.signal() }
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession())
        let finished = expectation(description: "the read returns")
        let outcome = Box<Result<Data, Error>?>(nil)
        Thread.detachNewThread {
            outcome.set(Result { try Self.read(source, count: 100, offset: 0) })
            finished.fulfill()
        }
        // The request has reached the server, which is sitting on it. Only
        // the cancel can end the read before the server lets go.
        XCTAssertEqual(arrived.wait(timeout: .now() + 15), .success)
        source.cancel()
        wait(for: [finished], timeout: 15)
        guard case let .failure(error)? = outcome.get() else { return XCTFail("the read should have failed") }
        XCTAssertEqual(error as? StillByteSourceError, .cancelled)
        XCTAssertFalse(source.isPermanentlyUnusable)

        XCTAssertThrowsError(try Self.read(source, count: 100, offset: 0), "still cancelled") {
            XCTAssertEqual($0 as? StillByteSourceError, .cancelled)
        }
        source.resume()
        XCTAssertEqual(try Self.read(source, count: 100, offset: 0), file.prefix(100))
    }

    func testStillsOverHTTPCostFewRequests() async throws {
        let file = try Self.bytes(Self.hevc)
        RangeStub.serve(file)
        let source = HTTPStillByteSource(url: Self.address, session: Self.stubSession()) { ["Authorization": "Bearer t"] }
        let reader = KeyframeStillReader(source: source)
        let info = try await Self.unwrap(await reader.prepare())
        XCTAssertEqual(info.keyframeCount, 4)
        let still = try await Self.unwrap(await reader.still(at: 4.5, maxWidth: 320, urgent: true))
        XCTAssertEqual(still.time, 4, accuracy: 0.05)
        XCTAssertTrue(Patch.blue.matches(try Self.pixel(of: still.image, x: 32, y: 32), isToneMapped: true))
        let requests = RangeStub.requests()
        XCTAssertFalse(requests.isEmpty)
        XCTAssertLessThanOrEqual(requests.count, 4, "the whole file is under one block")
        for request in requests {
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Range"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        }
        XCTAssertLessThanOrEqual(source.counters.bytes, file.count)
        print("STILL-MEASURE http \(Self.hevc): \(requests.count) requests, \(source.counters.bytes) B for open and one still")
        await reader.shutdown()
    }

    // MARK: - Tone mapping

    /// PQ and HLG code values whose light is known from the standards:
    /// PQ 0.5081 is 100 nits, 0.5807 is 203 and 0.7518 is 1000. HLG 0.75
    /// is 203 nits on a 1000 nit display and 0.5 is about 51.
    func testKnownGreysMapToTheExpectedLevels() throws {
        let cases: [(StillToneMapper.Transfer, Double, Int)] = [
            (.pq, 0, 0), (.pq, 0.5081, 188), (.pq, 0.5807, 216), (.pq, 0.7518, 255), (.pq, 1, 255),
            (.hlg, 0, 0), (.hlg, 0.5, 157), (.hlg, 0.75, 216), (.hlg, 1, 255),
        ]
        for (transfer, signal, expected) in cases {
            let code = UInt16((signal * 65535).rounded())
            let mapped = try Self.map([code, code, code, 65535], transfer: transfer, primaries: .bt2020)
            XCTAssertEqual(Int(mapped[0]), expected, accuracy: 2, "\(transfer) \(signal)")
            XCTAssertEqual(Int(mapped[1]), expected, accuracy: 2, "\(transfer) \(signal)")
            XCTAssertEqual(Int(mapped[2]), expected, accuracy: 2, "\(transfer) \(signal)")
            XCTAssertEqual(mapped[3], 255)
        }
    }

    func testTheTablesAgreeWithTheMathsWorkedInFull() throws {
        for transfer in [StillToneMapper.Transfer.pq, .hlg] {
            for primaries in [StillToneMapper.Primaries.bt2020, .p3, .bt709] {
                var seed: UInt64 = 42
                for _ in 0..<400 {
                    var pixel: [UInt16] = []
                    for _ in 0..<3 {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        pixel.append(UInt16(truncatingIfNeeded: seed >> 40))
                    }
                    pixel.append(65535)
                    let mapped = try Self.map(pixel, transfer: transfer, primaries: primaries)
                    let expected = Self.reference(pixel, transfer: transfer, primaries: primaries)
                    for channel in 0..<3 {
                        XCTAssertEqual(Int(mapped[channel]), expected[channel], accuracy: 2, "\(transfer) \(primaries) \(pixel)")
                    }
                }
            }
        }
    }

    func testSaturatedColoursKeepTheirHue() throws {
        let hundredNits = UInt16((0.5081 * 65535).rounded())
        let red = try Self.map([hundredNits, 0, 0, 65535], transfer: .pq, primaries: .bt2020)
        XCTAssertEqual(Int(red[0]), 208, accuracy: 3)
        XCTAssertEqual(red[1], 0)
        XCTAssertEqual(red[2], 0)
        let green = try Self.map([0, hundredNits, 0, 65535], transfer: .pq, primaries: .bt2020)
        XCTAssertGreaterThan(green[1], 180)
        XCTAssertEqual(green[0], 0)
        XCTAssertEqual(green[2], 0)
    }

    func testSDRPassesThroughUntouched() throws {
        for level in 0...255 {
            let wide = UInt16(level * 257)
            let mapped = try Self.map([wide, UInt16((255 - level) * 257), wide, 0], transfer: .sdr, primaries: .bt2020)
            XCTAssertEqual(mapped, [UInt8(level), UInt8(255 - level), UInt8(level), 255])
        }
    }

    func testTheMapperRefusesABufferThatIsTooSmall() {
        let pixels = [UInt16](repeating: 1000, count: 4 * 4 * 2)
        pixels.withUnsafeBytes { bytes in
            XCTAssertNotNil(StillToneMapper.map(rgba16: bytes, width: 4, height: 2, bytesPerRow: 32, transfer: .pq, primaries: .bt2020))
            XCTAssertNil(StillToneMapper.map(rgba16: bytes, width: 4, height: 3, bytesPerRow: 32, transfer: .pq, primaries: .bt2020))
            XCTAssertNil(StillToneMapper.map(rgba16: bytes, width: 4, height: 2, bytesPerRow: 24, transfer: .pq, primaries: .bt2020))
            XCTAssertNil(StillToneMapper.map(rgba16: bytes, width: 0, height: 2, bytesPerRow: 32, transfer: .pq, primaries: .bt2020))
            XCTAssertNil(StillToneMapper.map(rgba16: bytes, width: 100_000, height: 100_000, bytesPerRow: 800_000, transfer: .pq, primaries: .bt2020))
        }
    }

    /// Prints how long a preview takes to map. Nothing is asserted about
    /// the time: a debug build in a busy simulator can take any amount.
    func testAPreviewSizedPictureMaps() {
        let width = 320, height = 180
        let pixels = (0..<(width * height * 4)).map { UInt16(truncatingIfNeeded: $0 &* 2_654_435_761) }
        // Warm the tables, which are built on first use.
        _ = pixels.withUnsafeBytes { StillToneMapper.map(rgba16: $0, width: 8, height: 8, bytesPerRow: 64, transfer: .hlg, primaries: .bt2020) }
        for transfer in [StillToneMapper.Transfer.pq, .hlg] {
            let started = ProcessInfo.processInfo.systemUptime
            let mapped = pixels.withUnsafeBytes {
                StillToneMapper.map(rgba16: $0, width: width, height: height, bytesPerRow: width * 8, transfer: transfer, primaries: .bt2020)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            XCTAssertEqual(mapped?.count, width * height * 4)
            print("STILL-MEASURE tone map \(transfer) 320x180: \(Int(elapsed * 1_000_000)) us")
        }
    }

    // MARK: - Helpers

    private static let address = URL(string: "https://media.example.invalid/Videos/1/stream.mkv")!

    private static func unwrap<Value>(_ value: Value?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> Value {
        try XCTUnwrap(value, message, file: file, line: line)
    }

    private static func fixtureURL(_ name: String) throws -> URL {
        let parts = name.split(separator: ".").map(String.init)
        return try XCTUnwrap(Bundle(for: KeyframeStillReaderTests.self).url(forResource: parts[0], withExtension: parts[1]), name)
    }

    private static func bytes(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private static func source(_ name: String) throws -> MemorySource {
        MemorySource(try bytes(name))
    }

    /// Bytes that differ everywhere, so a read from the wrong place shows.
    private static func pattern(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for position in 0..<count {
                bytes[position] = UInt8(truncatingIfNeeded: (position &* 31) ^ (position >> 8) ^ (position >> 16))
            }
        }
        return data
    }

    private static func read(_ source: StillByteSource, count: Int, offset: Int64) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let copied = try buffer.withUnsafeMutableBytes { try source.read(into: $0, offset: offset) }
        return Data(buffer.prefix(copied))
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeStub.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// The red, green and blue of one pixel, counting from the top left.
    private static func pixel(of image: CGImage, x: Int, y: Int) throws -> [Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let width = image.width, height = image.height
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let start = (y * width + x) * 4
        return [Int(bytes[start]), Int(bytes[start + 1]), Int(bytes[start + 2])]
    }

    private static func map(_ pixel: [UInt16], transfer: StillToneMapper.Transfer, primaries: StillToneMapper.Primaries) throws -> [UInt8] {
        try XCTUnwrap(pixel.withUnsafeBytes {
            StillToneMapper.map(rgba16: $0, width: 1, height: 1, bytesPerRow: 8, transfer: transfer, primaries: primaries)
        })
    }

    /// The mapper's maths with no tables, in double precision.
    private static func reference(_ pixel: [UInt16], transfer: StillToneMapper.Transfer, primaries: StillToneMapper.Primaries) -> [Int] {
        let signal = pixel.prefix(3).map { Double($0) / 65535 }
        var light: [Double]
        if transfer == .pq {
            light = signal.map { value in
                let power = pow(value, 4096.0 / (2523.0 * 128.0))
                let top = max(power - 3424.0 / 4096.0, 0)
                let bottom = 2413.0 / 4096.0 * 32.0 - 2392.0 / 4096.0 * 32.0 * power
                return 10000 * pow(top / bottom, 16384.0 / 2610.0) / 100
            }
        } else {
            let scene = signal.map { $0 <= 0.5 ? $0 * $0 / 3 : (exp(($0 - 0.55991073) / 0.17883277) + 0.28466892) / 12 }
            let luminance = 0.2627 * scene[0] + 0.6780 * scene[1] + 0.0593 * scene[2]
            light = scene.map { 1000 * pow(luminance, 0.2) * $0 / 100 }
        }
        let matrix: [Double] = switch primaries {
        case .bt709: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        case .bt2020: [1.6605, -0.5876, -0.0728, -0.1246, 1.1329, -0.0083, -0.0182, -0.1006, 1.1187]
        case .p3: [1.2249, -0.2247, 0, -0.0420, 1.0419, 0, -0.0197, -0.0786, 1.0979]
        }
        return (0..<3).map { row in
            let linear = max(matrix[row * 3] * light[0] + matrix[row * 3 + 1] * light[1] + matrix[row * 3 + 2] * light[2], 0)
            let rolled = min(linear * (1 + linear / 100) / (1 + linear), 1)
            let encoded = rolled <= 0.0031308 ? rolled * 12.92 : 1.055 * pow(rolled, 1 / 2.4) - 0.055
            return Int((encoded * 255).rounded())
        }
    }
}

private extension KeyframeStillResult {
    /// The case's name, for comparing and for failure messages.
    var name: String {
        switch self {
        case .still: "still"
        case .superseded: "superseded"
        case .cancelled: "cancelled"
        case .transientFailure: "transientFailure"
        case .notPossible: "notPossible"
        case .lastCue: "lastCue"
        case .overLimit: "overLimit"
        }
    }
}

/// The colour of the square in the fixtures' top left corner, which changes
/// with every keyframe.
private enum Patch {
    case red, green, blue, white

    /// Tone-mapped stills come from a file whose test pattern was only
    /// labelled as PQ, so their colours are checked by which channels lead.
    func matches(_ pixel: [Int], isToneMapped: Bool) -> Bool {
        let (red, green, blue) = (pixel[0], pixel[1], pixel[2])
        let margin = isToneMapped ? 40 : 120
        switch self {
        case .red: return red > green + margin && red > blue + margin
        case .green: return green > red + margin && green > blue + margin
        case .blue: return blue > red + margin && blue > green + margin
        case .white: return min(red, green, blue) > 150 && max(red, green, blue) - min(red, green, blue) < 40
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ new: Value) {
        lock.withLock { value = new }
    }

    func get() -> Value {
        lock.withLock { value }
    }
}

/// A file held in memory that counts what is read from it and can hold a
/// read until it is cancelled.
private final class MemorySource: StillByteSource, @unchecked Sendable {
    private let data: Data
    private let state = NSCondition()
    private var bytesRead = 0
    private var readCount = 0
    private var startReads = 0
    private var isCancelled = false
    private var holdsNextRead = false
    private var isHolding = false
    private var failsEveryRead = false
    private var claimsTooMuch = false
    private var isOffForGood = false
    private var attemptCount = 0
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ data: Data) {
        self.data = Data(data)
    }

    var size: Int64? { Int64(data.count) }

    func counts() -> (bytes: Int, reads: Int, startReads: Int) {
        state.withLock { (bytesRead, readCount, startReads) }
    }

    func readsOfTheFileStart() -> Int {
        state.withLock { startReads }
    }

    /// The next read waits until `cancel()` and then fails.
    func holdNextRead() {
        state.withLock { holdsNextRead = true }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            state.lock()
            if isHolding {
                state.unlock()
                continuation.resume()
            } else {
                heldWaiters.append(continuation)
                state.unlock()
            }
        }
    }

    func failEveryRead() {
        state.withLock { failsEveryRead = true }
    }

    func stopFailing() {
        state.withLock { failsEveryRead = false }
    }

    /// Reads asked for, whether or not they gave any bytes.
    func attempts() -> Int {
        state.withLock { attemptCount }
    }

    func turnOffForGood() {
        state.withLock { isOffForGood = true }
    }

    var isPermanentlyUnusable: Bool {
        state.withLock { isOffForGood }
    }

    func claimTooManyBytes() {
        state.withLock { claimsTooMuch = true }
    }

    func cancel() {
        state.withLock {
            isCancelled = true
            state.broadcast()
        }
    }

    func resume() {
        state.withLock { isCancelled = false }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, offset: Int64) throws -> Int {
        state.lock()
        defer { state.unlock() }
        attemptCount += 1
        if isCancelled { throw StillByteSourceError.cancelled }
        if failsEveryRead { throw StillByteSourceError.failed }
        if holdsNextRead {
            holdsNextRead = false
            isHolding = true
            let waiters = heldWaiters
            heldWaiters = []
            waiters.forEach { $0.resume() }
            let limit = Date().addingTimeInterval(20)
            while !isCancelled, state.wait(until: limit) {}
            isHolding = false
            throw StillByteSourceError.cancelled
        }
        guard offset >= 0, let base = buffer.baseAddress else { throw StillByteSourceError.invalidRequest }
        if claimsTooMuch { return buffer.count + 1 }
        guard offset < Int64(data.count) else { return 0 }
        let start = Int(offset)
        let count = min(buffer.count, data.count - start)
        data.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), from: start..<(start + count))
        bytesRead += count
        readCount += 1
        if offset == 0 { startReads += 1 }
        return count
    }
}

/// Answers range requests from a file held in memory. Each request is
/// answered on its own thread, so one a test holds back can't hold up the
/// others.
private final class RangeStub: URLProtocol {
    enum Reply {
        case reply(status: Int, headers: [String: String], body: Data)
        case redirect(URL)
        /// The connection fails before any reply.
        case failure(URLError)
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var recorded: [URLRequest] = []

    static func configure(_ body: @escaping (URLRequest) -> Reply) {
        lock.withLock {
            handler = body
            recorded = []
        }
    }

    /// Serves `file` the way a server that honours byte ranges does.
    static func serve(_ file: Data) {
        configure { rangeReply(for: $0, from: file, total: file.count) }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recorded }
    }

    static func rangeReply(for request: URLRequest, from file: Data, total: Int) -> Reply {
        guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") else {
            return .reply(status: 200, headers: [:], body: file)
        }
        let ends = header.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        guard ends.count == 2, ends[0] < file.count, ends[0] <= ends[1] else {
            return .reply(status: 416, headers: ["Content-Range": "bytes */\(total)"], body: Data())
        }
        let last = min(ends[1], file.count - 1)
        return .reply(status: 206, headers: ["Content-Range": "bytes \(ends[0])-\(last)/\(total)"],
                      body: file.subdata(in: ends[0]..<(last + 1)))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.lock.withLock { () -> ((URLRequest) -> Reply)? in
            Self.recorded.append(request)
            return Self.handler
        }
        guard let body, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Thread.detachNewThread { [self] in
            switch body(request) {
            case let .reply(status, headers, data):
                var fields = headers
                fields["Content-Length"] = String(data.count)
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case let .redirect(target):
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target.absoluteString])!
                var next = request
                next.url = target
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            case let .failure(error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
