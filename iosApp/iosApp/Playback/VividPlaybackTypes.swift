// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation
import Combine
import Foundation


/// Vivid-owned branding; upstream package and licence identities remain intact.
enum LucidCore {
    static let name = "Lucid"
    static let path = "Lucid/mpv"
}

enum VividPlaybackEngineIdentity {
    static let name = LucidCore.name
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
        /// The shared audio session refused activation. It says nothing about
        /// the stream, so recovery must never step down to another route.
        case audioSessionUnavailable
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

/// Vivid's own playback failure messages in the app's language.
///
/// Failure messages stay English while recovery handles them: their words
/// pick the replan classification and the diagnostics failure token, and
/// they are sent to the server and logged. The failure panel and notices
/// translate them here as they are shown. Any other message, the server's
/// own or a system error's description, shows as it is.
enum PlaybackFailureText {
    static func localized(_ message: String) -> String {
        if let exact = exact(message) { return exact }
        for template in templates {
            if let value = template.value(in: message) { return template.localized(value) }
        }
        return message
    }

    // Keep each case's English identical to the message it translates.
    private static func exact(_ message: String) -> String? {
        switch message {
        case "The playback surface is unavailable.":
            return String(localized: "The playback surface is unavailable.")
        case "Audio output isn't available right now. Try again in a moment.":
            return String(localized: "Audio output isn't available right now. Try again in a moment.")
        case "Lucid could not initialise.":
            return String(localized: "Lucid could not initialise.", comment: "Lucid is the name of Vivid's playback engine")
        case "Lucid did not open the source within 60 seconds.":
            return String(localized: "Lucid did not open the source within 60 seconds.", comment: "Lucid is the name of Vivid's playback engine")
        case "The media stream ended before playback started.":
            return String(localized: "The media stream ended before playback started.")
        case "Lucid could not change playback speed.":
            return String(localized: "Lucid could not change playback speed.", comment: "Lucid is the name of Vivid's playback engine")
        case "The Lucid seek did not complete.":
            return String(localized: "The Lucid seek did not complete.", comment: "Lucid is the name of Vivid's playback engine")
        case "Lucid is not available for this request.":
            return String(localized: "Lucid is not available for this request.", comment: "Lucid is the name of Vivid's playback engine")
        case "Lucid closed before the request finished.":
            return String(localized: "Lucid closed before the request finished.", comment: "Lucid is the name of Vivid's playback engine")
        case "Playback could not be set up with the selected audio track.":
            return String(localized: "Playback could not be set up with the selected audio track.")
        case "Playback did not resume after reconnecting the media source.":
            return String(localized: "Playback did not resume after reconnecting the media source.")
        case "Playback did not resume after renewing authentication.":
            return String(localized: "Playback did not resume after renewing authentication.")
        case "The server could not be reached while renewing playback.":
            return String(localized: "The server could not be reached while renewing playback.")
        case "The media stream ended before playback completion could be confirmed.":
            return String(localized: "The media stream ended before playback completion could be confirmed.")
        case "The server didn't respond in time.":
            return String(localized: "The server didn't respond in time.")
        case "The selected embedded subtitle is unavailable in the opened media.":
            return String(localized: "The selected embedded subtitle is unavailable in the opened media.")
        case "The Apple audio output route changed.":
            return String(localized: "The Apple audio output route changed.")
        case "Reanchor the active stream at the requested source position.":
            return String(localized: "Reanchor the active stream at the requested source position.")
        case "Your Silo server hasn't been updated to support the latest version of this app. Please update your server, or use an earlier compatible version of Vivid until the server has been updated.":
            return String(localized: "Your Silo server hasn't been updated to support the latest version of this app. Please update your server, or use an earlier compatible version of Vivid until the server has been updated.")
        case "Select a profile before starting playback.":
            return String(localized: "Select a profile before starting playback.")
        case "The server returned an incompatible protocol V3 playback plan.":
            return String(localized: "The server returned an incompatible protocol V3 playback plan.")
        case "This server did not honor authenticated media transport for the playback plan.":
            return String(localized: "This server did not honor authenticated media transport for the playback plan.")
        case "The server selected a media version that is not present in the item response.":
            return String(localized: "The server selected a media version that is not present in the item response.")
        case "Playback recovery exhausted the protocol V3 route ladder.":
            return String(localized: "Playback recovery exhausted the protocol V3 route ladder.")
        case "The server returned an incompatible protocol V3 replacement plan.":
            return String(localized: "The server returned an incompatible protocol V3 replacement plan.")
        case "The server did not preserve authenticated media transport during replanning.":
            return String(localized: "The server did not preserve authenticated media transport during replanning.")
        case "The server returned a protocol V3 plan that already failed on this output route.":
            return String(localized: "The server returned a protocol V3 plan that already failed on this output route.")
        case "The replacement plan selected an unavailable media version.":
            return String(localized: "The replacement plan selected an unavailable media version.")
        case "The server changed the route or playback intent during a V3 seek re-anchor.":
            return String(localized: "The server changed the route or playback intent during a V3 seek re-anchor.")
        case "The server could not produce a playable Apple route.":
            return String(localized: "The server could not produce a playable Apple route.")
        default:
            return nil
        }
    }

    /// An English message with one inserted value, such as an error code.
    private struct Template: Sendable {
        let prefix: String
        let suffix: String
        let localized: @Sendable (String) -> String

        func value(in message: String) -> String? {
            guard message.count > prefix.count + suffix.count,
                  message.hasPrefix(prefix), message.hasSuffix(suffix) else { return nil }
            return String(message.dropFirst(prefix.count).dropLast(suffix.count))
        }
    }

    private static let templates: [Template] = [
        Template(prefix: "Lucid playback failed (", suffix: ").") {
            String(localized: "Lucid playback failed (\($0)).", comment: "Lucid is the name of Vivid's playback engine; the value is an error code")
        },
        Template(prefix: "The server returned HTTP ", suffix: " while renewing playback.") {
            String(localized: "The server returned HTTP \($0) while renewing playback.", comment: "The value is an HTTP status code")
        },
        Template(prefix: "The server selected an unsupported V3 delivery: ", suffix: ".") {
            String(localized: "The server selected an unsupported V3 delivery: \($0).", comment: "The value is a technical identifier")
        },
        Template(prefix: "The V3 playback transport is invalid: ", suffix: ".") {
            String(localized: "The V3 playback transport is invalid: \($0).", comment: "The value is a technical detail in English")
        },
        Template(prefix: "The V3 plan requires an unsupported client transformation: ", suffix: ".") {
            String(localized: "The V3 plan requires an unsupported client transformation: \($0).", comment: "The value is a technical identifier")
        },
        Template(prefix: "The V3 client transformation cannot be executed as planned: ", suffix: ".") {
            String(localized: "The V3 client transformation cannot be executed as planned: \($0).", comment: "The value is a technical detail in English")
        },
        Template(prefix: "The embedded subtitle selection is invalid: ", suffix: ".") {
            String(localized: "The embedded subtitle selection is invalid: \($0).", comment: "The value is a technical detail in English")
        },
        Template(prefix: "The V3 plan requires an unsupported runtime correction: ", suffix: ".") {
            String(localized: "The V3 plan requires an unsupported runtime correction: \($0).", comment: "The value is a technical identifier")
        },
        Template(prefix: "User selected audio track ", suffix: ".") {
            String(localized: "User selected audio track \($0).", comment: "The value is the audio track's name or number")
        },
        Template(prefix: "User selected playback quality ", suffix: ".") {
            String(localized: "User selected playback quality \($0).", comment: "The value is a quality identifier such as 1080p")
        },
    ]
}

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
    var sourceStreamIndex: Int? = nil
    init(id: Int, name: String = "", codec: String = "", language: String? = nil, channels: Int = 0,
         bitrate: Int64 = 0, isDefault: Bool = false, isForced: Bool = false,
         isHearingImpaired: Bool = false, isCommentary: Bool = false, isAtmos: Bool = false,
         assHeader: String? = nil, isExternal: Bool = false, isNativelyRenderedSubtitle: Bool = false, sourceStreamIndex: Int? = nil) {
        self.id=id; self.name=name; self.codec=codec; self.language=language; self.channels=channels
        self.bitrate=bitrate; self.isDefault=isDefault; self.isForced=isForced
        self.isHearingImpaired=isHearingImpaired; self.isCommentary=isCommentary; self.isAtmos=isAtmos
        self.assHeader=assHeader; self.isExternal=isExternal; self.isNativelyRenderedSubtitle=isNativelyRenderedSubtitle
        self.sourceStreamIndex = sourceStreamIndex
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
    /// The source is one ranged HTTPS file that Vivid may read for Lucid, so
    /// refreshed credentials reach the live stream.
    var managedHTTPReader = false
}
/// Volume Boost and Enhanced Dialogue, as one load applies them.
struct VividAudioEnhancement: Equatable, Sendable {
    /// The boost levels Settings offers, as a percentage of the standard level.
    static let boostLevels = [125, 150, 175, 200]
    static let defaultBoostLevel = 150
    static let off = VividAudioEnhancement()

    /// Output level as a percentage of the standard level; 100 is no boost.
    var boostPercent = 100
    /// Lowers everything except dialogue, so voices stand out.
    var enhancedDialogue = false

    /// Both work on decoded audio, so either one turns passthrough off.
    var isActive: Bool { boostPercent > 100 || enhancedDialogue }

    /// The boost as a signal gain: 200% doubles the level, which is +6.02 dB.
    var boostDecibels: Double {
        boostPercent > 100 ? 20 * log10(Double(boostPercent) / 100) : 0
    }

    /// The offered level nearest to a stored one, so a value written by
    /// another build still reads back as one of the choices.
    static func boostLevel(_ percent: Int) -> Int {
        // Bounded first, so a corrupt stored value cannot overflow the distance.
        let percent = min(max(percent, 0), 1_000)
        return boostLevels.min { abs($0 - percent) < abs($1 - percent) } ?? defaultBoostLevel
    }
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

    /// Every attribute but the text matches.
    func sameStyle(as other: SubtitleTextRun) -> Bool {
        color == other.color && isBold == other.isBold && isItalic == other.isItalic
            && isUnderlined == other.isUnderlined && isStruckThrough == other.isStruckThrough
            && fontName == other.fontName && fontSize == other.fontSize
    }
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
