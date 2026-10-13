// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
import AVFoundation
import CoreMedia
import UIKit
#if os(tvOS)
import AVKit
#endif

/// Match Content on Apple TV and EDR on iPhone and iPad for one core.
///
/// It keeps the stream properties mpv reports and a hold that stops display
/// writes between files: a start or end of file engages it, the playback
/// restart snapshot releases it, and observer changes in between merge into
/// single writes on main. The source-transition lock keeps those holds from
/// interleaving with a write in progress. It is always taken before the cache
/// lock, and the platform write runs with it held and the cache lock released.
final class VividPlayerDisplayCriteria {
    /// What one platform write asks the display for.
    struct Request: Equatable {
        var profile: Int64
        var level: Int64
        var compatibility: Int64?
        var rate: Double
        var width: Int32
        var height: Int32
        var signalPeak: Double
        var transfer: String?
        var primaries: String?
        var matrix: String?
    }

    /// The synchronous reads taken at playback restart.
    struct Readings {
        var measuredFps: Double?
        var containerFps: Double?
        var deinterlaced: Bool?
        var videoParams: [String: Any]?
        var videoTrack: [String: Any]?
    }

    /// What an observed property change asks the core to do next.
    struct ObservationEffect {
        var schedulesApply = false
        /// An EDR update to queue on main, ahead of the apply.
        var signalPeak: Double?
    }

    struct TransitionTiming {
        let waitMs: Double
        let heldMs: Double
    }

    enum DynamicRange: String {
        case sdr = "SDR"
        case hdr10 = "HDR10"
        case hlg = "HLG"
        case dolbyVision = "Dolby Vision"
    }

    private struct Inputs {
        var width = 0.0
        var height = 0.0
        var signalPeak = 0.0
        var profile: Int64 = 0
        var level: Int64 = 0
        var containerFps = 0.0
        var measuredFps = 0.0
        var deinterlaced = false
        var transfer: String?
        var primaries: String?
        var matrix: String?
    }

    private struct State {
        var inputs = Inputs()
        var held = true
        var epoch: UInt64 = 0
        var earlySnapshotWanted = false
        var applyScheduled = false
    }

    private let transitionLock = NSLock()
    private let cacheLock = NSLock()
    private var state = State()

    var signalPeak: Double {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return state.inputs.signalPeak
    }

    // MARK: Event queue

    /// Stores an available value. An unavailable or wrongly typed one says
    /// nothing reliable about the stream about to be shown, so it is ignored.
    func observe(name: String, value: Any?) -> ObservationEffect {
        var effect = ObservationEffect()
        cacheLock.lock(); defer { cacheLock.unlock() }
        switch name {
        case "container-fps":
            guard let fps = value as? Double else { break }
            state.inputs.containerFps = fps
            effect.schedulesApply = true
        case "current-tracks/video/dolby-vision-level":
            guard let level = value as? Int64 else { break }
            state.inputs.level = level
            effect.schedulesApply = true
        case "current-tracks/video/dolby-vision-profile":
            guard let profile = value as? Int64 else { break }
            state.inputs.profile = profile
            effect.schedulesApply = true
        case "deinterlace-active":
            guard let deinterlaced = value as? Bool else { break }
            state.inputs.deinterlaced = deinterlaced
            effect.schedulesApply = true
        case "width", "height":
            if let size = value as? Double {
                if name == "width" { state.inputs.width = size } else { state.inputs.height = size }
            }
            effect.schedulesApply = value != nil
        case "video-params/colormatrix":
            guard let matrix = value as? String else { break }
            state.inputs.matrix = matrix
            effect.schedulesApply = true
        case "video-params/gamma":
            guard let transfer = value as? String else { break }
            state.inputs.transfer = transfer
            effect.schedulesApply = true
        case "video-params/primaries":
            guard let primaries = value as? String else { break }
            state.inputs.primaries = primaries
            effect.schedulesApply = true
        case "video-params/sig-peak":
            guard let peak = value as? Double else { break }
            state.inputs.signalPeak = peak
            effect.signalPeak = peak
            effect.schedulesApply = true
        default:
            break
        }
        return effect
    }

    /// Holds display writes across a start or end of file. Only a start
    /// resets the measured cadence and wants an early snapshot. Returns the
    /// lock timing in `VIVID_P8_TRIAL` builds.
    @discardableResult
    func holdForSourceTransition(startingFile: Bool) -> TransitionTiming? {
        #if VIVID_P8_TRIAL
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        #endif
        transitionLock.lock()
        #if VIVID_P8_TRIAL
        let acquiredAt = DispatchTime.now().uptimeNanoseconds
        #endif
        cacheLock.lock()
        if startingFile { state.inputs.measuredFps = 0 }
        state.epoch &+= 1
        state.earlySnapshotWanted = startingFile
        state.held = true
        cacheLock.unlock()
        transitionLock.unlock()
        #if VIVID_P8_TRIAL
        let releasedAt = DispatchTime.now().uptimeNanoseconds
        return TransitionTiming(waitMs: Double(acquiredAt - requestedAt) / 1_000_000,
                                heldMs: Double(releasedAt - acquiredAt) / 1_000_000)
        #else
        return nil
        #endif
    }

    /// Replaces every input with what the stream reports now, defaults where
    /// it reports nothing, and releases the hold even if every read failed.
    func applyRestartSnapshot(_ readings: Readings) {
        let params = readings.videoParams
        let track = readings.videoTrack
        transitionLock.lock()
        cacheLock.lock()
        state.inputs = Inputs(
            width: Double(params?["w"] as? Int64 ?? 0),
            height: Double(params?["h"] as? Int64 ?? 0),
            signalPeak: params?["sig-peak"] as? Double ?? 0,
            profile: track?["dolby-vision-profile"] as? Int64 ?? 0,
            level: track?["dolby-vision-level"] as? Int64 ?? 0,
            containerFps: readings.containerFps ?? 0,
            measuredFps: readings.measuredFps ?? 0,
            deinterlaced: readings.deinterlaced ?? false,
            transfer: params?["gamma"] as? String,
            primaries: params?["primaries"] as? String,
            matrix: params?["colormatrix"] as? String)
        state.held = false
        state.earlySnapshotWanted = false
        cacheLock.unlock()
        transitionLock.unlock()
    }

    /// The epoch to write against when this file still wants an early write.
    func earlySnapshotEpoch() -> UInt64? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return state.earlySnapshotWanted && state.held ? state.epoch : nil
    }

    /// At most one early write per file, however often video reconfigures.
    func finishEarlySnapshot() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        state.earlySnapshotWanted = false
    }

    /// Whether the caller should queue a cached apply; false while one is queued.
    func markApplyScheduled() -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard !state.applyScheduled else { return false }
        state.applyScheduled = true
        return true
    }

    /// Disposal holds and resets the inputs under the cache lock only.
    func resetForDisposal() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        state.held = true
        state.inputs.profile = 0
        state.inputs.level = 0
        state.inputs.containerFps = 0
        state.inputs.signalPeak = 0
        state.inputs.measuredFps = 0
        state.inputs.deinterlaced = false
        state.inputs.transfer = nil
        state.inputs.primaries = nil
        state.inputs.matrix = nil
    }

    // MARK: Main thread

    /// The early write, unless a source transition or the restart snapshot
    /// happened since the snapshot was taken. `applied` runs inside the lock.
    func commitEarly(_ request: Request, epoch: UInt64, write: (Request) -> Bool, applied: () -> Void) {
        transitionLock.lock(); defer { transitionLock.unlock() }
        cacheLock.lock()
        let current = state.epoch == epoch && state.held
        cacheLock.unlock()
        guard current else { return }
        if write(request) { applied() }
    }

    /// One merged write from the cached inputs. Nothing is written while held.
    func runCachedApply(write: (Request) -> Void) {
        transitionLock.lock(); defer { transitionLock.unlock() }
        cacheLock.lock()
        // Changes that arrive during the write schedule a fresh pass.
        state.applyScheduled = false
        guard !state.held else {
            cacheLock.unlock()
            return
        }
        let inputs = state.inputs
        cacheLock.unlock()
        write(Self.request(from: inputs))
    }

    // MARK: Derivation

    static let nominalRates: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88, 120]

    /// Interlaced video decoded to fields presents at twice the container rate.
    static func isFieldOutput(containerFps: Double, measuredFps: Double, deinterlaced: Bool) -> Bool {
        if deinterlaced { return true }
        guard containerFps > 0, measuredFps > 0 else { return false }
        let ratio = measuredFps / containerFps
        return ratio > 1.7 && ratio < 2.3
    }

    static func requestedRate(containerFps: Double, measuredFps: Double, deinterlaced: Bool) -> Double {
        let fields = isFieldOutput(containerFps: containerFps, measuredFps: measuredFps, deinterlaced: deinterlaced)
        return snappedRate(fields ? containerFps * 2 : containerFps)
    }

    /// TVs offer modes only at nominal rates, so a rate within 1% of one asks for it.
    static func snappedRate(_ rate: Double) -> Double {
        guard rate > 0 else { return 0 }
        var nearest = nominalRates[0]
        for nominal in nominalRates.dropFirst() where abs(rate - nominal) < abs(rate - nearest) {
            nearest = nominal
        }
        return abs(rate - nearest) / nearest < 0.01 ? nearest : rate
    }

    /// The pinned decoder outputs profile 8.1 for profile 7, so ask for that,
    /// with PQ and BT.2020 tags where the stream has none.
    static func mappingProfile7(_ request: Request) -> Request {
        guard request.profile == 7 else { return request }
        var mapped = request
        mapped.profile = 8
        mapped.compatibility = 1
        mapped.transfer = request.transfer ?? "smpte2084"
        mapped.primaries = request.primaries ?? "bt2020"
        mapped.matrix = request.matrix ?? "bt2020nc"
        return mapped
    }

    /// The early write's request, from the decoded output parameters rather
    /// than the source's `video-params`.
    static func earlyRequest(outputParams: [String: Any], videoTrack: [String: Any], width: Int64, height: Int64,
                             containerFps: Double, measuredFps: Double, deinterlaced: Bool) -> Request {
        mappingProfile7(Request(
            profile: videoTrack["dolby-vision-profile"] as? Int64 ?? 0,
            level: videoTrack["dolby-vision-level"] as? Int64 ?? 0,
            compatibility: nil,
            rate: requestedRate(containerFps: containerFps, measuredFps: measuredFps, deinterlaced: deinterlaced),
            width: Int32(width), height: Int32(height),
            signalPeak: outputParams["sig-peak"] as? Double ?? 0,
            transfer: outputParams["gamma"] as? String,
            primaries: outputParams["primaries"] as? String,
            matrix: outputParams["colormatrix"] as? String))
    }

    private static func request(from inputs: Inputs) -> Request {
        mappingProfile7(Request(
            profile: inputs.profile, level: inputs.level, compatibility: nil,
            rate: requestedRate(containerFps: inputs.containerFps, measuredFps: inputs.measuredFps,
                                deinterlaced: inputs.deinterlaced),
            width: Int32(inputs.width), height: Int32(inputs.height),
            signalPeak: inputs.signalPeak,
            transfer: inputs.transfer, primaries: inputs.primaries, matrix: inputs.matrix))
    }

    /// Lowercase letters and digits only: `bt.2020-ncl` reads as `bt2020ncl`.
    static func normalisedTag(_ tag: String?) -> String {
        String((tag ?? "").lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The range the colour tags describe. Compatibility only decides when
    /// the tags say nothing.
    static func baseRange(transfer: String?, primaries: String?, matrix: String?,
                          signalPeak: Double, compatibility: Int64?) -> DynamicRange {
        let transfer = normalisedTag(transfer)
        if transfer.contains("hlg") || transfer.contains("arib") { return .hlg }
        if transfer.contains("pq") || transfer.contains("smpte2084") || transfer.contains("st2084")
            || signalPeak > 1.0
            || normalisedTag(primaries).contains("bt2020") || normalisedTag(matrix).contains("bt2020") {
            return .hdr10
        }
        switch compatibility {
        case 1?, 6?: return .hdr10
        case 4?: return .hlg
        default: return .sdr
        }
    }

    /// HDR10 and HLG fall back to SDR where the display lacks them.
    static func availableRange(_ range: DynamicRange, hdr10Available: Bool, hlgAvailable: Bool) -> DynamicRange {
        switch range {
        case .hdr10: return hdr10Available ? .hdr10 : .sdr
        case .hlg: return hlgAvailable ? .hlg : .sdr
        case .sdr, .dolbyVision: return range
        }
    }

    /// A `DOVIDecoderConfigurationRecord` (ETSI TS 103 572) and the sample
    /// description atom that carries it.
    static func dolbyVisionConfiguration(profile: Int64, level: Int64,
                                         compatibility: Int64?) -> (atom: String, record: Data) {
        let profile = UInt8(truncatingIfNeeded: profile)
        let level = UInt8(truncatingIfNeeded: level)
        let compatibility = UInt8(truncatingIfNeeded: compatibility ?? (profile == 8 ? 1 : 0))
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = 1
        bytes[1] = 0
        // Profile (7 bits), level (6), RPU present, no enhancement layer, base layer present.
        let fields = UInt16(profile & 0x7F) << 9 | UInt16(level & 0x3F) << 3 | 0b101
        bytes[2] = UInt8(fields >> 8)
        bytes[3] = UInt8(fields & 0xFF)
        bytes[4] = (compatibility & 0x0F) << 4
        return (profile > 7 ? "dvvC" : "dvcC", Data(bytes))
    }

    /// The format hint for a range. Every non-Dolby-Vision request is
    /// described as HEVC and every Dolby Vision one as `dvh1`.
    static func formatHint(for range: DynamicRange, request: Request) -> CMFormatDescription? {
        var codec = kCMVideoCodecType_HEVC
        var extensions: [String: Any]
        switch range {
        case .sdr:
            extensions = colourExtensions(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                                          transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                                          matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        case .hdr10:
            extensions = colourExtensions(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                                          transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                                          matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
        case .hlg:
            extensions = colourExtensions(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                                          transfer: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                                          matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
        case .dolbyVision:
            codec = kCMVideoCodecType_DolbyVisionHEVC
            extensions = colourExtensions(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                                          transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                                          matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
            let configuration = dolbyVisionConfiguration(profile: request.profile, level: request.level,
                                                         compatibility: request.compatibility)
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] =
                [configuration.atom: configuration.record]
        }
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codec, width: request.width, height: request.height,
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    private static func colourExtensions(primaries: CFString, transfer: CFString, matrix: CFString) -> [String: Any] {
        [kCMFormatDescriptionExtension_ColorPrimaries as String: primaries,
         kCMFormatDescriptionExtension_TransferFunction as String: transfer,
         kCMFormatDescriptionExtension_YCbCrMatrix as String: matrix]
    }

    // MARK: Platform write (main thread)

    private struct Identity: Equatable {
        let range: DynamicRange
        let rate: Float
        let width: Int32
        let height: Int32
        let profile: Int64
        let level: Int64
        let compatibility: Int64?
    }

    #if os(tvOS)
    /// The criteria this bridge last wrote, shared by every core so a new
    /// episode recognises the mode already on the HDMI link. Main thread only.
    nonisolated(unsafe) private static var writtenIdentity: Identity?
    #endif

    /// Asks the TV for the mode that suits `request`. Returns whether suitable
    /// criteria are in effect afterwards; always false on iPhone and iPad.
    static func commit(_ request: Request, matchContentEnabled: Bool, window: UIWindow?) -> Bool {
        guard matchContentEnabled else { return false }
        #if os(tvOS)
        guard let window else { return false }
        let manager = window.avDisplayManager
        let rate: Float = request.rate > 0 ? Float(request.rate) : 0
        let describesStream = rate > 0 || request.profile > 0 || request.signalPeak > 0
            || request.transfer != nil || request.primaries != nil || request.matrix != nil
        guard VividPlayerMPVConversion.dimensionsAreAcceptable(Int64(request.width), Int64(request.height)),
              describesStream, manager.isDisplayCriteriaMatchingEnabled,
              let format = requestedFormat(request) else {
            clear(manager)
            return false
        }
        let identity = Identity(range: format.range, rate: rate, width: request.width, height: request.height,
                                profile: request.profile, level: request.level,
                                compatibility: request.compatibility)
        if identity == writtenIdentity, manager.preferredDisplayCriteria != nil { return true }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: format.hint)
        writtenIdentity = identity
        return true
        #else
        return false
        #endif
    }

    #if os(tvOS)
    /// Clears the criteria (whoever set them) through `window`'s display
    /// manager. Nothing happens without a window.
    static func clear(in window: UIWindow?) {
        guard let window else { return }
        clear(window.avDisplayManager)
    }

    /// Only acts when something is set, so repeated failures never write.
    private static func clear(_ manager: AVDisplayManager) {
        guard writtenIdentity != nil || manager.preferredDisplayCriteria != nil else { return }
        manager.preferredDisplayCriteria = nil
        writtenIdentity = nil
    }

    /// Dolby Vision is requested without a capability check. A hint that
    /// cannot be built falls back to the range the tags describe, unfiltered.
    private static func requestedFormat(_ request: Request) -> (range: DynamicRange, hint: CMFormatDescription)? {
        let base = baseRange(transfer: request.transfer, primaries: request.primaries, matrix: request.matrix,
                             signalPeak: request.signalPeak, compatibility: request.compatibility)
        let range: DynamicRange
        if request.profile > 0 {
            range = .dolbyVision
        } else {
            let modes = AVPlayer.availableHDRModes
            range = availableRange(base, hdr10Available: modes.contains(.hdr10), hlgAvailable: modes.contains(.hlg))
        }
        if let hint = formatHint(for: range, request: request) { return (range, hint) }
        guard request.profile > 0, let hint = formatHint(for: base, request: request) else { return nil }
        return (base, hint)
    }
    #endif

    #if os(iOS)
    /// EDR when the signal peak is above SDR reference white.
    static func applyExtendedDynamicRange(to layer: CALayer?, signalPeak: Double) {
        guard let layer else { return }
        let wanted = signalPeak > 1.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if #available(iOS 26.0, *) {
            layer.preferredDynamicRange = wanted ? .high : .standard
        } else {
            layer.wantsExtendedDynamicRangeContent = wanted
        }
        CATransaction.commit()
    }
    #endif
}
#endif
