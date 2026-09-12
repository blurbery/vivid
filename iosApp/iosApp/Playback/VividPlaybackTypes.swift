// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation
import Combine
import Foundation
import VividKit

enum VividPlaybackEngineIdentity {
    #if os(tvOS)
    static let name = "AetherEngine"
    #else
    static let name = "VividKit"
    #endif
}

enum PlaybackState: Equatable { case idle, loading, playing, paused, seeking, ended, error(String) }
enum PlaybackPhase: Equatable { case idle, loading, playing, paused, seeking, rebuffering, stalled(reconnecting: Bool), ended, error(String) }
enum VideoRoute: String {
    case none, remoteBypass, loopback, sampleBuffer, audio

    var usesNativeVideoSession: Bool { self == .remoteBypass || self == .loopback }

    func isReceiverFetchable(hasCommittedLoad: Bool, hasCustomHeaders: Bool) -> Bool {
        guard hasCommittedLoad else { return false }
        switch self {
        case .loopback: return true
        case .remoteBypass: return !hasCustomHeaders
        case .none, .sampleBuffer, .audio: return false
        }
    }
}
enum VividNativeFrameReadiness {
    static func accepts(item: AnyObject, current: AnyObject?, outgoing: AnyObject?, alreadyPresented: Bool) -> Bool {
        !alreadyPresented && item === current && item !== outgoing
    }
}

/// A native caption renderer needs a new selection only after the item,
/// selected track or presentation destination changes.
struct VividNativeSubtitleHandoff {
    private struct Selection: Equatable {
        let item: ObjectIdentifier
        let track: Int?
        let active: Bool
    }
    private var applied: Selection?

    mutating func needsUpdate(item: AnyObject, track: Int?, active: Bool) -> Bool {
        let next = Selection(item: ObjectIdentifier(item), track: track, active: active)
        guard next != applied else { return false }
        applied = next
        return true
    }

    mutating func reset() { applied = nil }
}

enum VideoFormat { case sdr, hdr10, hdr10Plus, dolbyVision, hlg }
struct PlaybackErrorInfo: Error, Equatable, LocalizedError {
    enum Kind: String {
        case sourceRefused, vodSourceFailed, nativeItemFailed, noPlayableTrackWithinBudget
        case masterPlaylistRejected, softwarePipelineFailed, audioBridgeProducedNoOutput
        case dolbyVisionRequiresHardware, demuxedAudioLiveUnsupported, audioTrackSwitchFailed, sourceRateLimited
    }
    let kind: Kind
    let message: String
    var underlyingDomain: String? = nil
    var underlyingCode: Int? = nil
    var errorDescription: String? { message }

    var transientSourceCode: Int? {
        guard kind == .sourceRefused, underlyingDomain == NSURLErrorDomain,
              let code = underlyingCode, VividTransientRecoveryBudget.recognises(code) else { return nil }
        return code
    }

    static func isHTTPAuthenticationFailure(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        if let typed = error as? VividPlaybackError { return typed == .network(401) }
        if let typed = error as? PlaybackErrorInfo {
            return (typed.kind == .sourceRefused
                && (typed.underlyingDomain == nil || typed.underlyingDomain == NSURLErrorDomain)
                && typed.underlyingCode == 401)
                || (typed.kind == .nativeItemFailed
                    && typed.underlyingDomain == NSURLErrorDomain
                    && typed.underlyingCode == NSURLErrorUserAuthenticationRequired)
        }
        let native = error as NSError
        if native.domain == NSURLErrorDomain && native.code == NSURLErrorUserAuthenticationRequired {
            return true
        }
        guard let underlying = native.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
        return isHTTPAuthenticationFailure(underlying, depth: depth + 1)
    }
}
typealias PlaybackErrorKind = PlaybackErrorInfo.Kind
struct TrackInfo: Identifiable, Equatable {
    let id: Int
    var name: String = ""
    var codec: String = ""
    var language: String? = nil
    var channels: Int = 0
    var bitrate: Int64 = 0
    var isDefault = false
    var isForced = false
    var isHearingImpaired = false
    var isCommentary = false
    var isAtmos = false
    var assHeader: String? = nil
    var isExternal = false
    var isNativelyRenderedSubtitle = false
    init(id: Int, name: String = "", codec: String = "", language: String? = nil, channels: Int = 0,
         bitrate: Int64 = 0, isDefault: Bool = false, isForced: Bool = false,
         isHearingImpaired: Bool = false, isCommentary: Bool = false, isAtmos: Bool = false,
         assHeader: String? = nil, isExternal: Bool = false, isNativelyRenderedSubtitle: Bool = false) {
        self.id=id; self.name=name; self.codec=codec; self.language=language; self.channels=channels
        self.bitrate=bitrate; self.isDefault=isDefault; self.isForced=isForced
        self.isHearingImpaired=isHearingImpaired; self.isCommentary=isCommentary; self.isAtmos=isAtmos
        self.assHeader=assHeader; self.isExternal=isExternal; self.isNativelyRenderedSubtitle=isNativelyRenderedSubtitle
    }
    init(_ track: VividTrack) {
        self.init(id: track.id, name: track.name, codec: track.codec,
                  language: track.language.isEmpty ? nil : track.language, channels: track.channels, bitrate: track.bitrate,
                  isDefault: track.isDefault, isForced: track.isForced)
    }
}
struct ExternalSubtitleTrack: Equatable, Sendable {
    let url: URL
    var name: String? = nil
    var language: String? = nil
    var isForced = false
    var isHearingImpaired = false
    var isDefault = false
    var httpHeaders: [String: String]? = nil
    var formatHint: String? = nil
    var sourceStreamIndex: Int32? = nil
    var nativeTimelineOffsetSeconds: Double = 0
}
struct LoadOptions: Equatable, Sendable {
    var httpHeaders: [String: String] = [:]
    var matchContentEnabled = true
    var panelIsInHDRMode = false
    var audioOnly = false
    var nativeRemoteHLS = false
    var preserveASSMarkup = false
    var prepareNativeSubtitles = true
    var eagerNativeSubtitleReaders = false
    var nativeSubtitlePreferredLanguages: [String] = []
    var preferredAudioLanguages: [String] = []
    var preferredSubtitleLanguages: [String] = []
    var externalSubtitles: [ExternalSubtitleTrack] = []
    var forwardBufferSegments: Int? = nil
    var autoplay = true
    var audioTrackOrdinal: Int? = nil
}
struct MediaChapter: Identifiable { let id: Int; let name: String; let startSeconds: Double }
struct SystemCaptionRequest { let language: String? }
struct StartupProgress { let checkpoint: String }
@MainActor final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
}
struct SubtitleColor: Equatable { let r: UInt8; let g: UInt8; let b: UInt8 }
struct SubtitleTextRun {
    let text: String
    var color: SubtitleColor? = nil
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStruckThrough = false
    var fontName: String? = nil
    var fontSize: Double? = nil
}
struct SubtitleTextPlacement { var alignment: Int? = nil; var position: CGPoint? = nil }
struct SubtitleImage {
    let cgImage: CGImage
    let position: CGRect
    let canvasSize: CGSize
}
struct SubtitleCue: Identifiable {
    enum Body { case text(String), richText([SubtitleTextRun]), image(SubtitleImage) }
    let id: Int
    let startTime: Double
    let endTime: Double
    let body: Body
    var placement: SubtitleTextPlacement? = nil
}
struct LiveTelemetry: Equatable {
    var forwardBufferSeconds: Double? = nil
    var displayCushionSeconds: Double? = nil
    var readerWindowAheadBytes: Int? = nil
    var observedFps: Double? = nil
    var droppedFrameCount: Int? = nil
    var accumulatedFrameDelaySeconds: Double? = nil
    var avSyncGapMs: Double? = nil
    var instantBitrateMbps: Double? = nil
    var averageBitrateMbps: Double? = nil
    var audioBridgeBitrateMbps: Double? = nil
    var networkThroughputMbps: Double? = nil
    var networkTransferredBytes: Int64? = nil
    var cachedBytes: Int64? = nil
    var demuxerBytesFetched: Int64 = 0
    var producerRestartCount: Int = 0
    var rssMb: Int = 0
}
@MainActor final class VividDiagnostics: ObservableObject {
    @Published var liveTelemetry: LiveTelemetry?
}
@MainActor final class SampleBufferPiPSource {
    let layer: AVSampleBufferDisplayLayer
    private weak var engine: VividEngine?
    init(layer: AVSampleBufferDisplayLayer, engine: VividEngine) { self.layer = layer; self.engine = engine }
    var isPaused: Bool { engine?.state != .playing }
    func setPlaying(_ value: Bool) { if value { engine?.play() } else { engine?.pause() } }
    func timeRange() -> CMTimeRange {
        guard let engine, engine.duration > 0 else { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: engine.duration, preferredTimescale: 600))
    }
    func skip(by seconds: Double) {
        guard let engine else { return }
        Task { await engine.seek(to: min(max(0, engine.currentTime + seconds), engine.duration > 0 ? engine.duration : .greatestFiniteMagnitude)) }
    }
}
