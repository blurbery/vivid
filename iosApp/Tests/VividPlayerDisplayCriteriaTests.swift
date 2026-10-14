// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation
import CoreMedia
import UIKit
import XCTest
#if os(tvOS)
import AVKit
@testable import VividTV
#else
@testable import Vivid
#endif

private typealias Criteria = VividPlayerDisplayCriteria
private typealias CriteriaRequest = VividPlayerDisplayCriteria.Request

private final class CriteriaRecorder: VividPlayerCoreDelegate {
    var log: [String] = []
    var events: [(name: String, data: [String: Any]?)] = []

    func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
        log.append("property:\(name)")
    }

    func onEvent(name: String, data: [String: Any]?) {
        events.append((name, data))
        log.append("event:\(name)")
    }
}

/// A core whose synchronous mpv reads and platform display write are replaced,
/// so the holds, the early snapshot and the cached apply run without libmpv.
private final class FakeDisplayCore: VividPlayerCoreBase {
    var early = true
    var doubles: [String: Double] = [:]
    var flags: [String: Bool] = [:]
    var maps: [String: [String: Any]] = [:]
    var writeResult = true
    var writes: [CriteriaRequest] = []
    var duringWrite: ((CriteriaRequest) -> Void)?
    weak var log: CriteriaRecorder?

    override var preparesDisplayCriteriaEarly: Bool { early }
    override func fetchNumber(_ name: String) -> Double? { doubles[name] }
    override func fetchFlag(_ name: String) -> Bool? { flags[name] }
    override func fetchMap(_ name: String) -> [String: Any]? { maps[name] }

    override func commitDisplayCriteria(_ request: CriteriaRequest) -> Bool {
        XCTAssertTrue(Thread.isMainThread)
        writes.append(request)
        log?.log.append("write")
        duringWrite?(request)
        return writeResult
    }

    /// The default fixture of section 16.2: 1920 x 1080 with transfer
    /// `bt.1886`, an empty track map, 24 fps container and cadence, no
    /// deinterlacer, and a start-of-file hold in place.
    func useDefaultFixture() {
        maps["video-out-params"] = ["w": Int64(1_920), "h": Int64(1_080), "gamma": "bt.1886"]
        maps["current-tracks/video"] = [:]
        doubles["container-fps"] = 24
        doubles["estimated-vf-fps"] = 24
        flags["deinterlace-active"] = false
        eventQueue.sync { holdDisplayCriteria(startingFile: true) }
    }
}

/// Section 8 of the player bridge specification: frame rate, profile 7,
/// dynamic range, format hints, the holds and both display writes.
@MainActor
final class VividPlayerDisplayCriteriaTests: XCTestCase {
    private func drainMainOnce() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func drainMain() async {
        for _ in 0..<3 { await drainMainOnce() }
    }

    private func makeCore(_ recorder: CriteriaRecorder? = nil) -> FakeDisplayCore {
        let core = FakeDisplayCore()
        core.delegate = recorder
        core.log = recorder
        core.useDefaultFixture()
        return core
    }

    private func prepareEarly(_ core: FakeDisplayCore) {
        core.eventQueue.sync { core.prepareEarlyDisplayCriteria() }
    }

    private func preparedCount(_ recorder: CriteriaRecorder) -> Int {
        recorder.events.filter { $0.name == "display-criteria-prepared" }.count
    }

    /// Whether `work` finishes on another thread within `seconds`. A timed-out
    /// probe is left to finish on its own once the lock it waits for is free.
    private nonisolated func finishes(within seconds: Double, _ work: @escaping () -> Void) -> Bool {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            group.leave()
        }
        return group.wait(timeout: .now() + seconds) == .success
    }

    private func request(profile: Int64 = 0, level: Int64 = 0, compatibility: Int64? = nil, rate: Double = 24,
                         width: Int32 = 1_920, height: Int32 = 1_080, signalPeak: Double = 0,
                         transfer: String? = nil, primaries: String? = nil, matrix: String? = nil) -> CriteriaRequest {
        CriteriaRequest(profile: profile, level: level, compatibility: compatibility, rate: rate, width: width,
                        height: height, signalPeak: signalPeak, transfer: transfer, primaries: primaries,
                        matrix: matrix)
    }

    // MARK: Frame rate (section 8.7)

    func testFieldOutputCadenceRatios() {
        let field = Criteria.isFieldOutput
        XCTAssertTrue(field(25, 50, false))
        XCTAssertFalse(field(25, 25, false))
        XCTAssertTrue(field(20, 34.2, false), "1.71")
        XCTAssertTrue(field(20, 45.8, false), "2.29")
        XCTAssertFalse(field(25, 42.5, false), "exactly 1.7")
        XCTAssertFalse(field(10, 23, false), "exactly 2.3")
        XCTAssertFalse(field(25, 75, false), "3.0")
        XCTAssertFalse(field(0, 50, false))
        XCTAssertFalse(field(25, 0, false))
        XCTAssertTrue(field(25, 25, true), "the deinterlacer alone means field output")
        XCTAssertTrue(field(0, 0, true))
    }

    func testNominalRatesInSpecificationOrder() {
        XCTAssertEqual(Criteria.nominalRates, [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88, 120])
    }

    func testSnapping() {
        let snap = Criteria.snappedRate
        XCTAssertEqual(snap(23.9), 23.976)
        XCTAssertEqual(snap(59.9), 59.94)
        XCTAssertEqual(snap(47.9), 48)
        XCTAssertEqual(snap(23.5), 23.5)
        XCTAssertEqual(snap(45), 45)
        XCTAssertEqual(snap(12.5), 12.5)
        XCTAssertEqual(snap(24), 24)
        XCTAssertEqual(snap(50), 50)
        XCTAssertEqual(snap(23.9761), 23.976)
        XCTAssertEqual(snap(119.9), 119.88)
        XCTAssertEqual(snap(0), 0)
        XCTAssertEqual(snap(-24), 0)
        XCTAssertEqual(snap(.nan), 0)
    }

    func testRequestedRate() {
        let rate = Criteria.requestedRate
        XCTAssertEqual(rate(25, 25, true), 50)
        XCTAssertEqual(rate(30, 60, false), 60)
        XCTAssertEqual(rate(25, 50, false), 50)
        XCTAssertEqual(rate(29.97, 29.97, true), 59.94)
        XCTAssertEqual(rate(23.976, 23.976, false), 23.976)
        XCTAssertEqual(rate(24, 0, false), 24)
        XCTAssertEqual(rate(0, 0, false), 0)
    }

    // MARK: Profile 7 (section 8.8)

    func testProfileSevenIsRequestedAsEightPointOne() {
        let mapped = Criteria.mappingProfile7(request(profile: 7, level: 6))
        XCTAssertEqual(mapped, request(profile: 8, level: 6, compatibility: 1, transfer: "smpte2084",
                                       primaries: "bt2020", matrix: "bt2020nc"))

        let tagged = Criteria.mappingProfile7(request(profile: 7, level: 9, transfer: "pq", primaries: "bt.2020",
                                                      matrix: "bt.2020-ncl"))
        XCTAssertEqual(tagged, request(profile: 8, level: 9, compatibility: 1, transfer: "pq", primaries: "bt.2020",
                                       matrix: "bt.2020-ncl"))

        let partial = Criteria.mappingProfile7(request(profile: 7, transfer: "hlg"))
        XCTAssertEqual(partial.transfer, "hlg")
        XCTAssertEqual(partial.primaries, "bt2020")
        XCTAssertEqual(partial.matrix, "bt2020nc")

        for profile: Int64 in [0, 5, 8] {
            let unchanged = request(profile: profile, level: 6)
            XCTAssertEqual(Criteria.mappingProfile7(unchanged), unchanged)
        }
    }

    func testEarlyRequestReadsTheDecodedOutputParameters() {
        let early = Criteria.earlyRequest(
            outputParams: ["w": Int64(3_840), "h": Int64(2_160), "sig-peak": 10.0, "gamma": "pq",
                           "primaries": "bt.2020", "colormatrix": "bt.2020-ncl"],
            videoTrack: ["dolby-vision-profile": Int64(8), "dolby-vision-level": Int64(6)],
            width: 3_840, height: 2_160, containerFps: 23.976, measuredFps: 23.976, deinterlaced: false)
        XCTAssertEqual(early, request(profile: 8, level: 6, rate: 23.976, width: 3_840, height: 2_160,
                                      signalPeak: 10, transfer: "pq", primaries: "bt.2020", matrix: "bt.2020-ncl"))

        // Wrongly typed track values read as the defaults.
        let wrongTypes = Criteria.earlyRequest(
            outputParams: [:], videoTrack: ["dolby-vision-profile": 8, "dolby-vision-level": "6"],
            width: 1_280, height: 720, containerFps: 25, measuredFps: 50, deinterlaced: false)
        XCTAssertEqual(wrongTypes, request(rate: 50, width: 1_280, height: 720))
    }

    // MARK: Dynamic range (section 8.10)

    func testColourTagNormalisation() {
        XCTAssertEqual(Criteria.normalisedTag("bt.2020-ncl"), "bt2020ncl")
        XCTAssertEqual(Criteria.normalisedTag("arib-std-b67"), "aribstdb67")
        XCTAssertEqual(Criteria.normalisedTag("BT.709"), "bt709")
        XCTAssertEqual(Criteria.normalisedTag(nil), "")
    }

    func testBaseRange() {
        func range(_ transfer: String? = nil, _ primaries: String? = nil, _ matrix: String? = nil,
                   peak: Double = 0, compatibility: Int64? = nil) -> Criteria.DynamicRange {
            Criteria.baseRange(transfer: transfer, primaries: primaries, matrix: matrix, signalPeak: peak,
                               compatibility: compatibility)
        }
        XCTAssertEqual(range("hlg"), .hlg)
        XCTAssertEqual(range("arib-std-b67"), .hlg)
        XCTAssertEqual(range("hlg", "bt.2020", peak: 10), .hlg, "HLG is checked first")
        XCTAssertEqual(range("pq"), .hdr10)
        XCTAssertEqual(range("smpte2084"), .hdr10)
        XCTAssertEqual(range("smpte-st2084"), .hdr10)
        XCTAssertEqual(range("bt.1886", peak: 1.01), .hdr10)
        XCTAssertEqual(range("bt.1886", peak: 1.0), .sdr)
        XCTAssertEqual(range("bt.1886", "bt.2020"), .hdr10, "BT.2020-tagged SDR is requested as HDR10")
        XCTAssertEqual(range("bt.1886", "bt.709", "bt.2020-ncl"), .hdr10)
        XCTAssertEqual(range("bt.1886", "bt.709", "bt.709"), .sdr)
        XCTAssertEqual(range(compatibility: 1), .hdr10)
        XCTAssertEqual(range(compatibility: 6), .hdr10)
        XCTAssertEqual(range(compatibility: 4), .hlg)
        XCTAssertEqual(range(compatibility: 2), .sdr)
        XCTAssertEqual(range("bt.1886", compatibility: 4), .hlg, "compatibility decides when the tags say nothing")
        XCTAssertEqual(range("pq", compatibility: 2), .hdr10)
        XCTAssertEqual(range(), .sdr)
    }

    func testCapabilityFilter() {
        XCTAssertEqual(Criteria.availableRange(.hdr10, hdr10Available: true, hlgAvailable: false), .hdr10)
        XCTAssertEqual(Criteria.availableRange(.hdr10, hdr10Available: false, hlgAvailable: true), .sdr)
        XCTAssertEqual(Criteria.availableRange(.hlg, hdr10Available: true, hlgAvailable: true), .hlg)
        XCTAssertEqual(Criteria.availableRange(.hlg, hdr10Available: true, hlgAvailable: false), .sdr)
        XCTAssertEqual(Criteria.availableRange(.sdr, hdr10Available: false, hlgAvailable: false), .sdr)
        XCTAssertEqual(Criteria.availableRange(.dolbyVision, hdr10Available: false, hlgAvailable: false), .dolbyVision)
    }

    func testRangeNames() {
        XCTAssertEqual(Criteria.DynamicRange.sdr.rawValue, "SDR")
        XCTAssertEqual(Criteria.DynamicRange.hdr10.rawValue, "HDR10")
        XCTAssertEqual(Criteria.DynamicRange.hlg.rawValue, "HLG")
        XCTAssertEqual(Criteria.DynamicRange.dolbyVision.rawValue, "Dolby Vision")
    }

    // MARK: Dolby Vision configuration record (section 8.11)

    private func record(_ bytes: [UInt8]) -> Data {
        Data(bytes + [UInt8](repeating: 0, count: 24 - bytes.count))
    }

    func testConfigurationRecordForProfileEightLevelSix() {
        let configuration = Criteria.dolbyVisionConfiguration(profile: 8, level: 6, compatibility: nil)
        XCTAssertEqual(configuration.atom, "dvvC")
        // 8 << 9 | 6 << 3 | RPU 1, EL 0, BL 1 = 0x1035; compatibility 1 in the top four bits.
        XCTAssertEqual(configuration.record, record([1, 0, 0x10, 0x35, 0x10]))
        XCTAssertEqual(configuration.record.count, 24)
    }

    func testConfigurationRecordForProfileFive() {
        let configuration = Criteria.dolbyVisionConfiguration(profile: 5, level: 6, compatibility: nil)
        XCTAssertEqual(configuration.atom, "dvcC")
        XCTAssertEqual(configuration.record, record([1, 0, 0x0A, 0x35, 0x00]))
    }

    func testConfigurationRecordForProfileSevenAfterMapping() {
        let mapped = Criteria.mappingProfile7(request(profile: 7, level: 6))
        let configuration = Criteria.dolbyVisionConfiguration(profile: mapped.profile, level: mapped.level,
                                                              compatibility: mapped.compatibility)
        XCTAssertEqual(configuration.atom, "dvvC")
        XCTAssertEqual(configuration.record, record([1, 0, 0x10, 0x35, 0x10]))
    }

    func testConfigurationRecordNarrowsThenMasks() {
        let explicit = Criteria.dolbyVisionConfiguration(profile: 8, level: 13, compatibility: 4)
        XCTAssertEqual(explicit.record, record([1, 0, 0x10, 0x6D, 0x40]))
        // 263 narrows to 7 (dvcC); 70 narrows to 70 and masks to 6; 0x21 masks to 1.
        let narrowed = Criteria.dolbyVisionConfiguration(profile: 263, level: 70, compatibility: 0x21)
        XCTAssertEqual(narrowed.atom, "dvcC")
        XCTAssertEqual(narrowed.record, record([1, 0, 0x0E, 0x35, 0x10]))
        // 136 narrows to 136 (dvvC) and masks to 8.
        let wide = Criteria.dolbyVisionConfiguration(profile: 136, level: 1, compatibility: 0)
        XCTAssertEqual(wide.atom, "dvvC")
        XCTAssertEqual(wide.record, record([1, 0, 0x10, 0x0D, 0x00]))
        XCTAssertEqual(Criteria.dolbyVisionConfiguration(profile: 4, level: 1, compatibility: nil).record[4], 0)
    }

    // MARK: Format hints (section 8.11)

    private func extensions(_ hint: CMFormatDescription) -> [String: Any] {
        (CMFormatDescriptionGetExtensions(hint) as? [String: Any]) ?? [:]
    }

    private func assertColour(_ hint: CMFormatDescription, primaries: CFString, transfer: CFString, matrix: CFString,
                              file: StaticString = #filePath, line: UInt = #line) {
        let values = extensions(hint)
        XCTAssertEqual(values[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, primaries as String,
                       file: file, line: line)
        XCTAssertEqual(values[kCMFormatDescriptionExtension_TransferFunction as String] as? String, transfer as String,
                       file: file, line: line)
        XCTAssertEqual(values[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String, matrix as String,
                       file: file, line: line)
    }

    func testFormatHintsForEachRange() throws {
        let base = request(width: 3_840, height: 2_160)
        let sdr = try XCTUnwrap(Criteria.formatHint(for: .sdr, request: base))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(sdr), kCMVideoCodecType_HEVC)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(sdr).width, 3_840)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(sdr).height, 2_160)
        assertColour(sdr, primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                     transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                     matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)

        let hdr10 = try XCTUnwrap(Criteria.formatHint(for: .hdr10, request: base))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(hdr10), kCMVideoCodecType_HEVC)
        assertColour(hdr10, primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                     transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                     matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)

        let hlg = try XCTUnwrap(Criteria.formatHint(for: .hlg, request: base))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(hlg), kCMVideoCodecType_HEVC)
        assertColour(hlg, primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                     transfer: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                     matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
    }

    func testDolbyVisionHintsCarryTheConfigurationAtom() throws {
        let profile8 = try XCTUnwrap(Criteria.formatHint(for: .dolbyVision,
                                                         request: request(profile: 8, level: 6, width: 3_840, height: 2_160)))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(profile8), kCMVideoCodecType_DolbyVisionHEVC)
        XCTAssertEqual(kCMVideoCodecType_DolbyVisionHEVC, 0x6476_6831, "dvh1")
        assertColour(profile8, primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                     transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                     matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
        let atoms = extensions(profile8)[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
            as? [String: Any]
        XCTAssertEqual(atoms.map { Array($0.keys) }, ["dvvC"])
        XCTAssertEqual(atoms?["dvvC"] as? Data, record([1, 0, 0x10, 0x35, 0x10]))

        let profile5 = try XCTUnwrap(Criteria.formatHint(for: .dolbyVision, request: request(profile: 5, level: 6)))
        let atoms5 = extensions(profile5)[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
            as? [String: Any]
        XCTAssertEqual(atoms5.map { Array($0.keys) }, ["dvcC"])
        XCTAssertEqual(atoms5?["dvcC"] as? Data, record([1, 0, 0x0A, 0x35, 0x00]))
    }

    // MARK: Observer effects and caches (sections 6.9 and 8.2)

    func testObserverValuesUpdateCachesOnlyWhenAvailableAndTyped() {
        let criteria = Criteria()
        XCTAssertTrue(criteria.observe(name: "container-fps", value: 25.0).schedulesApply)
        XCTAssertFalse(criteria.observe(name: "container-fps", value: nil).schedulesApply)
        XCTAssertFalse(criteria.observe(name: "container-fps", value: Int64(30)).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "current-tracks/video/dolby-vision-profile", value: Int64(5)).schedulesApply)
        XCTAssertFalse(criteria.observe(name: "current-tracks/video/dolby-vision-profile", value: 5).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "current-tracks/video/dolby-vision-level", value: Int64(6)).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "deinterlace-active", value: false).schedulesApply)
        XCTAssertFalse(criteria.observe(name: "deinterlace-active", value: Int64(1)).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "video-params/gamma", value: "pq").schedulesApply)
        XCTAssertTrue(criteria.observe(name: "video-params/primaries", value: "bt.2020").schedulesApply)
        XCTAssertTrue(criteria.observe(name: "video-params/colormatrix", value: "bt.2020-ncl").schedulesApply)
        XCTAssertFalse(criteria.observe(name: "video-params/gamma", value: nil).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "width", value: 1_280.0).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "height", value: 720.0).schedulesApply)
        // Any non-nil size schedules an apply, but only a Double is stored.
        XCTAssertTrue(criteria.observe(name: "width", value: Int64(5)).schedulesApply)
        XCTAssertFalse(criteria.observe(name: "height", value: nil).schedulesApply)
        XCTAssertFalse(criteria.observe(name: "pause", value: true).schedulesApply)
        XCTAssertFalse(criteria.observe(name: "time-pos", value: 1.0).schedulesApply)

        let peak = criteria.observe(name: "video-params/sig-peak", value: 4.5)
        XCTAssertTrue(peak.schedulesApply)
        XCTAssertEqual(peak.signalPeak, 4.5)
        XCTAssertEqual(criteria.signalPeak, 4.5)
        let missingPeak = criteria.observe(name: "video-params/sig-peak", value: nil)
        XCTAssertFalse(missingPeak.schedulesApply)
        XCTAssertNil(missingPeak.signalPeak)
        XCTAssertEqual(criteria.signalPeak, 4.5)

        // Released, the cached apply sees exactly the stored values.
        criteria.applyRestartSnapshot(.init(measuredFps: 25, containerFps: 25, deinterlaced: false,
                                            videoParams: ["w": Int64(1_920), "h": Int64(1_080)], videoTrack: [:]))
        XCTAssertTrue(criteria.observe(name: "container-fps", value: 50.0).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "width", value: 1_280.0).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "width", value: Int64(5)).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "height", value: 720.0).schedulesApply)
        XCTAssertTrue(criteria.observe(name: "video-params/gamma", value: "pq").schedulesApply)
        XCTAssertTrue(criteria.observe(name: "current-tracks/video/dolby-vision-profile", value: Int64(7)).schedulesApply)
        var written: [CriteriaRequest] = []
        criteria.runCachedApply { written.append($0) }
        XCTAssertEqual(written, [request(profile: 8, compatibility: 1, rate: 50, width: 1_280, height: 720,
                                         transfer: "pq", primaries: "bt2020", matrix: "bt2020nc")])
    }

    func testHoldAndEarlySnapshotFlags() {
        let criteria = Criteria()
        XCTAssertNil(criteria.earlySnapshotEpoch(), "held from creation, but no early snapshot wanted")
        var written = 0
        criteria.runCachedApply { _ in written += 1 }
        XCTAssertEqual(written, 0, "held from creation")

        criteria.holdForSourceTransition(startingFile: true)
        let first = criteria.earlySnapshotEpoch()
        XCTAssertNotNil(first)
        criteria.holdForSourceTransition(startingFile: true)
        let second = criteria.earlySnapshotEpoch()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "every hold advances the epoch")

        criteria.holdForSourceTransition(startingFile: false)
        XCTAssertNil(criteria.earlySnapshotEpoch(), "the end-of-file hold wants no early snapshot")

        criteria.holdForSourceTransition(startingFile: true)
        criteria.finishEarlySnapshot()
        XCTAssertNil(criteria.earlySnapshotEpoch())

        criteria.holdForSourceTransition(startingFile: true)
        criteria.applyRestartSnapshot(.init())
        XCTAssertNil(criteria.earlySnapshotEpoch(), "the restart snapshot clears the wish and the hold")
        criteria.runCachedApply { _ in written += 1 }
        XCTAssertEqual(written, 1)
    }

    func testApplySchedulingMergesUntilTheApplyRuns() {
        let criteria = Criteria()
        XCTAssertTrue(criteria.markApplyScheduled())
        XCTAssertFalse(criteria.markApplyScheduled())
        criteria.runCachedApply { _ in }
        XCTAssertTrue(criteria.markApplyScheduled(), "the apply clears the mark even while held")
    }

    func testDisposalHoldsAndResetsTheCaches() {
        let criteria = Criteria()
        criteria.applyRestartSnapshot(.init(measuredFps: 24, containerFps: 24, deinterlaced: false,
                                            videoParams: ["w": Int64(1_920), "h": Int64(1_080), "sig-peak": 4.0],
                                            videoTrack: ["dolby-vision-profile": Int64(8)]))
        XCTAssertEqual(criteria.signalPeak, 4)
        criteria.resetForDisposal()
        XCTAssertEqual(criteria.signalPeak, 0)
        var written = 0
        criteria.runCachedApply { _ in written += 1 }
        XCTAssertEqual(written, 0)
    }

    // MARK: Restart snapshot (section 8.4)

    func testRestartSnapshotOverwritesEveryInputAndAppliesBeforeTheRestartEvent() async {
        let recorder = CriteriaRecorder()
        let core = makeCore(recorder)
        core.maps["video-params"] = ["w": Int64(3_840), "h": Int64(2_160), "sig-peak": 10.0, "gamma": "pq",
                                     "primaries": "bt.2020", "colormatrix": "bt.2020-ncl"]
        core.maps["current-tracks/video"] = ["dolby-vision-profile": Int64(8), "dolby-vision-level": Int64(6)]
        core.doubles["container-fps"] = 23.976
        core.doubles["estimated-vf-fps"] = 23.976
        core.doubles["time-pos"] = 12.5
        core.eventQueue.sync { core.takeRestartSnapshot() }
        XCTAssertTrue(core.writes.isEmpty, "the apply runs on main")
        await drainMain()

        XCTAssertEqual(core.writes, [request(profile: 8, level: 6, rate: 23.976, width: 3_840, height: 2_160,
                                             signalPeak: 10, transfer: "pq", primaries: "bt.2020",
                                             matrix: "bt.2020-ncl")])
        XCTAssertEqual(recorder.log.filter { $0 == "write" || $0 == "event:playback-restart" },
                       ["write", "event:playback-restart"])
        let restart = recorder.events.first { $0.name == "playback-restart" }
        XCTAssertEqual(restart?.data?.count, 1)
        XCTAssertTrue(restart?.data?["positionSeconds"] is Double)
        XCTAssertEqual(restart?.data?["positionSeconds"] as? Double, 12.5)
        XCTAssertNil(core.displayCriteria.earlySnapshotEpoch(), "the restart cleared the early-snapshot wish")
    }

    func testRestartSnapshotWithNothingReadableReleasesTheHoldWithDefaults() async {
        let recorder = CriteriaRecorder()
        let core = makeCore(recorder)
        core.doubles = [:]
        core.flags = [:]
        core.maps = [:]
        core.eventQueue.sync { core.takeRestartSnapshot() }
        await drainMain()
        XCTAssertEqual(core.writes, [request(rate: 0, width: 0, height: 0)])
        let restart = recorder.events.first { $0.name == "playback-restart" }
        XCTAssertNotNil(restart)
        XCTAssertNil(restart?.data?["positionSeconds"], "omitted, not zero, when time-pos is unreadable")
    }

    func testRestartSnapshotClearsTagsTheStreamNoLongerReports() async {
        let core = makeCore()
        core.maps["video-params"] = ["w": Int64(1_920), "h": Int64(1_080), "gamma": "pq"]
        core.eventQueue.sync { core.takeRestartSnapshot() }
        await drainMain()
        core.maps["video-params"] = ["w": Int64(1_920), "h": Int64(1_080)]
        core.eventQueue.sync { core.takeRestartSnapshot() }
        await drainMain()
        XCTAssertEqual(core.writes.map(\.transfer), ["pq", nil])
    }

    func testCachedApplyMapsProfileSeven() async {
        let core = makeCore()
        core.maps["video-params"] = ["w": Int64(3_840), "h": Int64(2_160)]
        core.maps["current-tracks/video"] = ["dolby-vision-profile": Int64(7), "dolby-vision-level": Int64(6)]
        core.eventQueue.sync { core.takeRestartSnapshot() }
        await drainMain()
        XCTAssertEqual(core.writes, [request(profile: 8, level: 6, compatibility: 1, width: 3_840, height: 2_160,
                                             transfer: "smpte2084", primaries: "bt2020", matrix: "bt2020nc")])
    }

    // MARK: Early snapshot (section 8.5, checklist items 1 to 14)

    func testEarlySnapshotWritesOnceOnMainAtTheDecodedCadence() async {
        let recorder = CriteriaRecorder()
        let core = makeCore(recorder)
        prepareEarly(core)
        XCTAssertTrue(core.writes.isEmpty, "item 1: not written synchronously")
        await drainMain()
        XCTAssertEqual(core.writes.count, 1, "item 2")
        XCTAssertEqual(core.writes.first?.rate, 24)
        XCTAssertEqual(core.writes.first, request(transfer: "bt.1886"))
        XCTAssertEqual(preparedCount(recorder), 1, "item 4")

        // Item 3: still held, so a cached apply writes nothing.
        core.displayCriteria.runCachedApply { _ in XCTFail("held after the early write") }

        // Item 5: no second early write for the same file.
        prepareEarly(core)
        await drainMain()
        XCTAssertEqual(core.writes.count, 1)
        XCTAssertEqual(preparedCount(recorder), 1)
    }

    func testDisplayCriteriaPreparedBypassesOrderedDelivery() async {
        let recorder = CriteriaRecorder()
        let core = makeCore(recorder)
        prepareEarly(core)
        await drainMain()
        XCTAssertEqual(recorder.log.filter { $0 == "write" || $0 == "event:display-criteria-prepared" },
                       ["write", "event:display-criteria-prepared"])
        XCTAssertNil(recorder.events.first { $0.name == "display-criteria-prepared" }?.data)
    }

    private func assertNoEarlyWrite(_ change: (FakeDisplayCore) -> Void, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let recorder = CriteriaRecorder()
        let core = makeCore(recorder)
        change(core)
        prepareEarly(core)
        await drainMain()
        XCTAssertTrue(core.writes.isEmpty, "\(message): no write", file: file, line: line)
        XCTAssertEqual(preparedCount(recorder), 0, message, file: file, line: line)
        XCTAssertNotNil(core.displayCriteria.earlySnapshotEpoch(), "\(message): still wanted", file: file, line: line)
    }

    func testIncompleteEarlySnapshotsWriteNothingAndStayWanted() async {
        await assertNoEarlyWrite({ $0.early = false }, "early snapshot disabled")
        await assertNoEarlyWrite({ $0.maps["video-out-params"] = nil }, "output parameters missing")
        await assertNoEarlyWrite({ $0.maps["video-out-params"]?["w"] = Int64(0) }, "width 0")
        await assertNoEarlyWrite({ $0.maps["video-out-params"]?["w"] = 1_920.0 }, "width not Int64")
        await assertNoEarlyWrite({ $0.maps["video-out-params"]?["h"] = Int64(16_385) }, "height too large")
        await assertNoEarlyWrite({ $0.maps["current-tracks/video"] = nil }, "track map missing")
        await assertNoEarlyWrite({ $0.doubles["container-fps"] = nil }, "container rate missing")
        await assertNoEarlyWrite({ $0.doubles["container-fps"] = .nan }, "container rate NaN")
        await assertNoEarlyWrite({ $0.doubles["container-fps"] = 0 }, "container rate 0")
        await assertNoEarlyWrite({ $0.doubles["estimated-vf-fps"] = nil }, "measured rate missing")
        await assertNoEarlyWrite({ $0.doubles["estimated-vf-fps"] = 0 }, "measured rate 0")
        await assertNoEarlyWrite({ $0.flags["deinterlace-active"] = nil }, "deinterlace flag missing")
    }

    func testEarlySnapshotRejectsNonFiniteRates() async {
        // Section 8.5 step 2: each rate must be finite as well as above 0.
        await assertNoEarlyWrite({ $0.doubles["estimated-vf-fps"] = .infinity }, "measured rate infinite")
        await assertNoEarlyWrite({ $0.doubles["container-fps"] = .infinity }, "container rate infinite")
    }

    func testCompleteSnapshotAfterAnIncompleteOneWritesOnce() async {
        let recorder = CriteriaRecorder()
        let core = makeCore(recorder)
        core.doubles["container-fps"] = nil
        prepareEarly(core)
        await drainMain()
        XCTAssertTrue(core.writes.isEmpty)
        core.doubles["container-fps"] = 24
        prepareEarly(core)
        prepareEarly(core)
        await drainMain()
        XCTAssertEqual(core.writes.count, 1, "item 7")
        XCTAssertEqual(preparedCount(recorder), 1)
    }

    func testEarlyWriteIsDroppedWhenTheSourceMovesOnBeforeMainRuns() async {
        let advanced = makeCore()
        prepareEarly(advanced)
        advanced.eventQueue.sync { advanced.holdDisplayCriteria(startingFile: true) }
        await drainMain()
        XCTAssertTrue(advanced.writes.isEmpty, "item 8: epoch advanced")

        let ended = makeCore()
        prepareEarly(ended)
        ended.eventQueue.sync { ended.holdDisplayCriteria(startingFile: false) }
        await drainMain()
        XCTAssertTrue(ended.writes.isEmpty, "item 8: end of file")

        let released = makeCore()
        prepareEarly(released)
        released.displayCriteria.applyRestartSnapshot(.init())
        await drainMainOnce()
        XCTAssertTrue(released.writes.isEmpty, "item 8: hold released")

        let disposed = makeCore()
        prepareEarly(disposed)
        disposed.beginDisposal()
        await drainMain()
        XCTAssertTrue(disposed.writes.isEmpty, "item 8: terminal")
    }

    func testFieldRatesInTheEarlyWrite() async {
        let doubled = makeCore()
        doubled.doubles["container-fps"] = 25
        doubled.doubles["estimated-vf-fps"] = 50
        prepareEarly(doubled)
        await drainMain()
        XCTAssertEqual(doubled.writes.map(\.rate), [50], "item 9")

        let deinterlaced = makeCore()
        deinterlaced.doubles["container-fps"] = 25
        deinterlaced.doubles["estimated-vf-fps"] = 25
        deinterlaced.flags["deinterlace-active"] = true
        prepareEarly(deinterlaced)
        await drainMain()
        XCTAssertEqual(deinterlaced.writes.map(\.rate), [50], "item 10")
    }

    func testEarlyWriteTagsAndProfileSeven() async {
        let profile7 = makeCore()
        profile7.maps["video-out-params"] = ["w": Int64(3_840), "h": Int64(2_160), "sig-peak": 10.0]
        profile7.maps["current-tracks/video"] = ["dolby-vision-profile": Int64(7), "dolby-vision-level": Int64(6)]
        prepareEarly(profile7)
        await drainMain()
        XCTAssertEqual(profile7.writes.first?.profile, 8, "item 11")
        XCTAssertEqual(profile7.writes.first?.compatibility, 1)
        XCTAssertEqual(profile7.writes.first?.transfer, "smpte2084")
        XCTAssertEqual(profile7.writes.first?.level, 6)
        XCTAssertEqual(profile7.writes.first?.signalPeak, 10)
        XCTAssertEqual(profile7.writes.first?.width, 3_840)

        let pq = makeCore()
        pq.maps["video-out-params"]?["gamma"] = "smpte2084"
        prepareEarly(pq)
        await drainMain()
        XCTAssertEqual(pq.writes.first?.transfer, "smpte2084", "item 12")
        XCTAssertNil(pq.writes.first?.compatibility)
    }

    func testFailedPlatformWriteSendsNoPreparedEvent() async {
        let recorder = CriteriaRecorder()
        let core = makeCore(recorder)
        core.writeResult = false
        prepareEarly(core)
        await drainMain()
        XCTAssertEqual(core.writes.count, 1)
        XCTAssertEqual(preparedCount(recorder), 0, "item 13")
    }

    func testEarlyWriteHoldsTheExclusionButNotTheCacheGuard() async {
        let core = makeCore()
        let criteria = core.displayCriteria
        var cacheGuardFree = false
        var exclusionHeld = false
        var probe: DispatchGroup?
        core.duringWrite = { [unowned self] _ in
            cacheGuardFree = self.finishes(within: 2) { _ = criteria.signalPeak }
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                criteria.holdForSourceTransition(startingFile: false)
                group.leave()
            }
            exclusionHeld = group.wait(timeout: .now() + 0.2) == .timedOut
            probe = group
        }
        prepareEarly(core)
        await drainMain()
        XCTAssertEqual(core.writes.count, 1)
        XCTAssertTrue(cacheGuardFree, "item 14: the cache guard is released during the write")
        XCTAssertTrue(exclusionHeld, "item 14: a source hold waits for the write")
        XCTAssertEqual(probe?.wait(timeout: .now() + 2), .success, "the exclusion is released afterwards")
    }

    // MARK: Cached apply (checklist items 15 to 17)

    func testCachedApplyHoldsTheExclusionWritesOnceAndClearsItsMark() async {
        let core = makeCore()
        let criteria = core.displayCriteria
        var cacheGuardFree = false
        var exclusionHeld = false
        var markCleared = false
        var probe: DispatchGroup?
        core.duringWrite = { [unowned self] _ in
            cacheGuardFree = self.finishes(within: 2) { markCleared = criteria.markApplyScheduled() }
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                criteria.holdForSourceTransition(startingFile: false)
                group.leave()
            }
            exclusionHeld = group.wait(timeout: .now() + 0.2) == .timedOut
            probe = group
        }
        core.eventQueue.sync { core.takeRestartSnapshot() }
        await drainMain()
        XCTAssertEqual(core.writes.count, 1, "item 15: one write")
        XCTAssertTrue(cacheGuardFree, "item 15: the cache guard is released during the write")
        XCTAssertTrue(markCleared, "item 15: the scheduled mark is cleared before the write")
        XCTAssertTrue(exclusionHeld, "item 15: a source hold waits for the write")
        XCTAssertEqual(probe?.wait(timeout: .now() + 2), .success)
    }

    func testSourceHoldsStopAQueuedCachedApply() async {
        for starting in [false, true] {
            let core = makeCore()
            core.early = false
            core.eventQueue.sync {
                core.takeRestartSnapshot()
                core.holdDisplayCriteria(startingFile: starting)
            }
            await drainMain()
            XCTAssertTrue(core.writes.isEmpty, "item 16: \(starting ? "start" : "end")-of-file hold")
        }
    }

    func testHeldApplyReleasesTheExclusion() {
        let criteria = Criteria()
        criteria.holdForSourceTransition(startingFile: false)
        criteria.runCachedApply { _ in XCTFail("held") }
        XCTAssertTrue(finishes(within: 2) { criteria.holdForSourceTransition(startingFile: true) }, "item 17")
        XCTAssertTrue(finishes(within: 2) { criteria.applyRestartSnapshot(.init()) })
    }

    func testDisposalStopsAQueuedCachedApply() async {
        let core = makeCore()
        core.eventQueue.sync { core.takeRestartSnapshot() }
        core.displayCriteria.resetForDisposal()
        await drainMain()
        XCTAssertTrue(core.writes.isEmpty)
    }

    // MARK: Debug-only lock timing (checklist item 18)

    func testDisplayCommitLockEventsFollowTheBuild() async {
        let isTrialBuild = Criteria().holdForSourceTransition(startingFile: true) != nil
        let recorder = CriteriaRecorder()
        let core = FakeDisplayCore()
        core.delegate = recorder
        core.eventQueue.sync {
            core.holdDisplayCriteria(startingFile: false)
            core.holdDisplayCriteria(startingFile: true)
        }
        await drainMain()
        let locks = recorder.events.filter { $0.name == "display-commit-lock" }
        guard isTrialBuild else {
            XCTAssertTrue(locks.isEmpty, "only VIVID_P8_TRIAL builds report lock timing")
            return
        }
        XCTAssertEqual(locks.map { $0.data?["transition"] as? String }, ["end_file", "start_file"])
        for lock in locks {
            XCTAssertEqual(lock.data.map { Set($0.keys) }, ["transition", "wait_ms", "held_ms"])
            XCTAssertGreaterThanOrEqual(lock.data?["wait_ms"] as? Double ?? -1, 0)
            XCTAssertGreaterThanOrEqual(lock.data?["held_ms"] as? Double ?? -1, 0)
        }
    }

    // MARK: Platform write

    func testPlatformWriteNeverWritesWithMatchContentOffOrNoWindow() {
        XCTAssertFalse(Criteria.commit(request(), matchContentEnabled: false, window: nil))
        XCTAssertFalse(Criteria.commit(request(), matchContentEnabled: true, window: nil))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(Criteria.commit(request(), matchContentEnabled: false, window: window))
    }

    #if os(iOS)
    func testPlatformWriteIsNeverAppliedOnIPhoneAndIPad() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(Criteria.commit(request(), matchContentEnabled: true, window: window))
        XCTAssertFalse(Criteria.commit(request(profile: 8, level: 6), matchContentEnabled: true, window: window))
    }

    func testCoreNeverPreparesEarlyOnIPhoneAndIPad() {
        let core = VividPlayerCore()
        core.matchContentEnabled = true
        XCTAssertFalse(core.preparesDisplayCriteriaEarly)
        core.dispose()
    }

    // MARK: EDR (section 8.15)

    func testExtendedDynamicRangeFollowsTheSignalPeak() throws {
        let layer = VividSampleBufferLayer()
        guard #available(iOS 26.0, *) else {
            Criteria.applyExtendedDynamicRange(to: layer, signalPeak: 4)
            XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
            Criteria.applyExtendedDynamicRange(to: layer, signalPeak: 1)
            XCTAssertFalse(layer.wantsExtendedDynamicRangeContent)
            return
        }
        Criteria.applyExtendedDynamicRange(to: layer, signalPeak: 1.01)
        XCTAssertEqual(layer.preferredDynamicRange, .high)
        Criteria.applyExtendedDynamicRange(to: layer, signalPeak: 1.0)
        XCTAssertEqual(layer.preferredDynamicRange, .standard)
        Criteria.applyExtendedDynamicRange(to: layer, signalPeak: 1_000)
        XCTAssertEqual(layer.preferredDynamicRange, .high)
        Criteria.applyExtendedDynamicRange(to: layer, signalPeak: 0)
        XCTAssertEqual(layer.preferredDynamicRange, .standard)
        Criteria.applyExtendedDynamicRange(to: nil, signalPeak: 4)
    }

    func testGeometryUpdatesReassertExtendedDynamicRange() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Checks the iOS 26 dynamic range property.") }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        let core = ContextFreeCore()
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        defer { core.dispose() }
        let layer = try XCTUnwrap(core.sampleBufferDisplayLayer)
        _ = core.displayCriteria.observe(name: "video-params/sig-peak", value: 4.0)
        layer.preferredDynamicRange = .standard
        core.updateFrame()
        XCTAssertEqual(layer.preferredDynamicRange, .high)
        core.applyExtendedDynamicRange(signalPeak: 1)
        XCTAssertEqual(layer.preferredDynamicRange, .standard)
    }
    #endif

    #if os(tvOS)
    func testCoreUsesItsMatchContentFlagForTheEarlySnapshot() {
        let core = VividPlayerCore()
        XCTAssertTrue(core.preparesDisplayCriteriaEarly)
        core.matchContentEnabled = false
        XCTAssertFalse(core.preparesDisplayCriteriaEarly)
        core.dispose(preserveDisplayCriteria: true)
    }

    private func tvWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.isHidden = false
        addTeardownBlock { @MainActor in
            Criteria.clear(in: window)
            window.isHidden = true
        }
        return window
    }

    /// Puts criteria on the window that the bridge did not write, or skips
    /// when this simulator keeps none.
    private func presetCriteria(on window: UIWindow) throws -> AVDisplayCriteria {
        let hint = try XCTUnwrap(Criteria.formatHint(for: .sdr, request: request()))
        let criteria = AVDisplayCriteria(refreshRate: 24, formatDescription: hint)
        window.avDisplayManager.preferredDisplayCriteria = criteria
        try XCTSkipIf(window.avDisplayManager.preferredDisplayCriteria == nil,
                      "This simulator keeps no preferred display criteria.")
        return criteria
    }

    func testMatchContentOffNeverClears() throws {
        let window = tvWindow()
        Criteria.clear(in: window)
        _ = try presetCriteria(on: window)
        XCTAssertFalse(Criteria.commit(request(width: 0, height: 0), matchContentEnabled: false, window: window))
        XCTAssertNotNil(window.avDisplayManager.preferredDisplayCriteria)
    }

    func testUnusableRequestsClear() throws {
        let window = tvWindow()
        for unusable in [request(width: 0, height: 0), request(width: 16_385), request(rate: 0)] {
            Criteria.clear(in: window)
            _ = try presetCriteria(on: window)
            XCTAssertFalse(Criteria.commit(unusable, matchContentEnabled: true, window: window))
            XCTAssertNil(window.avDisplayManager.preferredDisplayCriteria, "\(unusable)")
        }
    }

    func testSystemMatchingOffClears() throws {
        let window = tvWindow()
        try XCTSkipIf(window.avDisplayManager.isDisplayCriteriaMatchingEnabled,
                      "Match Content is on in this simulator.")
        Criteria.clear(in: window)
        _ = try presetCriteria(on: window)
        XCTAssertFalse(Criteria.commit(request(transfer: "bt.1886"), matchContentEnabled: true, window: window))
        XCTAssertNil(window.avDisplayManager.preferredDisplayCriteria)
    }

    /// A display manager stand-in with Match Content switched on, which the
    /// simulator cannot provide.
    private final class StandInDisplayManager {
        var preferred: AVDisplayCriteria?
        var assignments = 0

        var access: Criteria.DisplayManagerAccess {
            Criteria.DisplayManagerAccess(isMatchingEnabled: { true },
                                          preferredCriteria: { self.preferred },
                                          setPreferredCriteria: { self.preferred = $0; self.assignments += 1 })
        }
    }

    func testSharedIdentityAvoidsRepeatWritesAcrossCores() throws {
        let window = tvWindow()
        let manager = StandInDisplayManager()
        Criteria.forgetWrittenIdentityForTesting()
        Criteria.displayManagerForTesting = { _ in manager.access }
        addTeardownBlock { @MainActor in
            Criteria.displayManagerForTesting = nil
            Criteria.forgetWrittenIdentityForTesting()
        }
        let hdr = request(rate: 23.976, width: 3_840, height: 2_160, signalPeak: 10, transfer: "pq")
        XCTAssertTrue(Criteria.commit(hdr, matchContentEnabled: true, window: window))
        let written = try XCTUnwrap(manager.preferred)
        let identity = try XCTUnwrap(Criteria.writtenIdentityForTesting)
        XCTAssertEqual(identity.rate, Float(23.976))
        XCTAssertEqual(identity.width, 3_840)
        XCTAssertNil(identity.compatibility)
        XCTAssertEqual(manager.assignments, 1)

        // A second request for the same identity, as from the next episode's core, writes nothing.
        var again = hdr
        again.rate = Criteria.snappedRate(23.9761)
        XCTAssertTrue(Criteria.commit(again, matchContentEnabled: true, window: window))
        XCTAssertTrue(manager.preferred === written)
        XCTAssertEqual(manager.assignments, 1)

        // An identity match with nothing currently set writes again.
        manager.preferred = nil
        XCTAssertTrue(Criteria.commit(hdr, matchContentEnabled: true, window: window))
        XCTAssertNotNil(manager.preferred)
        XCTAssertEqual(manager.assignments, 2)

        // A different identity writes.
        let current = manager.preferred
        XCTAssertTrue(Criteria.commit(request(rate: 50, transfer: "bt.1886"), matchContentEnabled: true, window: window))
        XCTAssertFalse(manager.preferred === current)
        XCTAssertEqual(Criteria.writtenIdentityForTesting?.rate, 50)

        // Clearing forgets the identity, and clears only when something is set.
        Criteria.clear(in: window)
        XCTAssertNil(manager.preferred)
        XCTAssertNil(Criteria.writtenIdentityForTesting)
        let assignmentsAfterClear = manager.assignments
        Criteria.clear(in: window)
        XCTAssertEqual(manager.assignments, assignmentsAfterClear)
    }

    func testDisposeClearsThroughTheRememberedWindowAfterAFailedInitialize() async throws {
        let window = tvWindow()
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        Criteria.clear(in: window)
        _ = try presetCriteria(on: window)

        let failed = ContextFreeCore()
        failed.startsContext = false
        failed.matchContentEnabled = false
        XCTAssertFalse(failed.initialize(in: window, hostView: host))
        XCTAssertTrue(host.subviews.isEmpty)
        XCTAssertNotNil(window.avDisplayManager.preferredDisplayCriteria)
        let finished = expectation(description: "dispose completion")
        failed.dispose(preserveDisplayCriteria: false) { finished.fulfill() }
        // Synchronous, and not gated by the core's Match Content flag.
        XCTAssertNil(window.avDisplayManager.preferredDisplayCriteria)
        await fulfillment(of: [finished], timeout: 5)
    }

    /// Section 8.16: `VIVID_P8_TRIAL` builds report mode switches posted by
    /// any object, synchronously and with no data, until dispose.
    func testDebugDisplaySwitchEventsAreDeliveredSynchronously() {
        let isTrialBuild = Criteria().holdForSourceTransition(startingFile: true) != nil
        let window = tvWindow()
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        let recorder = CriteriaRecorder()
        let core = ContextFreeCore()
        core.delegate = recorder
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        let switches = { recorder.events.filter { $0.name.hasPrefix("display-switch-") } }

        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchEnd, object: window.avDisplayManager)
        if isTrialBuild {
            XCTAssertEqual(switches().map(\.name), ["display-switch-started", "display-switch-ended"])
            XCTAssertTrue(switches().allSatisfy { $0.data == nil })
        } else {
            XCTAssertTrue(switches().isEmpty, "only VIVID_P8_TRIAL builds observe mode switches")
        }

        let delivered = switches().count
        core.dispose(preserveDisplayCriteria: true)
        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchEnd, object: nil)
        XCTAssertEqual(switches().count, delivered, "observers are removed at dispose")
    }

    func testPreservingDisposeLeavesTheCriteria() throws {
        let window = tvWindow()
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        Criteria.clear(in: window)
        _ = try presetCriteria(on: window)
        let core = ContextFreeCore()
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        core.dispose(preserveDisplayCriteria: true)
        XCTAssertNotNil(window.avDisplayManager.preferredDisplayCriteria)

        let next = ContextFreeCore()
        XCTAssertTrue(next.initialize(in: window, hostView: host))
        next.dispose()
        XCTAssertNil(window.avDisplayManager.preferredDisplayCriteria)
    }
    #endif
}

/// A real core with only its mpv context replaced.
private final class ContextFreeCore: VividPlayerCore {
    var startsContext = true
    override func startContext(wid: Int64) -> Bool { startsContext }
}
