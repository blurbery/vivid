import Foundation

// Silo's playback control websocket. Messages are JSON envelopes with a
// `type`; the server sends commands and events, and the app sends hello, ack
// and result envelopes, encoded in their coding keys' declared order.

enum PlaybackRealtimeMessageType: String, Codable {
    case command
    case event
    case hello
    case ack
    case result
}

enum PlaybackRealtimeCommandName: String, Codable, CaseIterable {
    case pause
    case unpause
    case playPause = "play_pause"
    case seek
    case setVolume = "set_volume"
    case stop
    case terminate
    case displayMessage = "display_message"
    case serverRestarting = "server_restarting"
    case serverShuttingDown = "server_shutting_down"
    case playMedia = "play_media"
    case setAudioTrack = "set_audio_track"
    case setSubtitleTrack = "set_subtitle_track"
}

/// The commands the hello says the app handles, in this order.
let supportedApplePlaybackRealtimeCommands: [PlaybackRealtimeCommandName] = [
    .pause,
    .unpause,
    .playPause,
    .seek,
    .stop,
    .terminate,
    .displayMessage,
    .serverRestarting,
    .serverShuttingDown,
]

/// The name of an event envelope. Any name the app doesn't know decodes as
/// ``unknown(_:)`` rather than failing, so a new server event never breaks
/// the envelope; consumers ignore what they don't handle.
enum PlaybackRealtimeEventName: Codable, Equatable {
    case chapterThumbnailReady
    case markersUpdated
    // Known for wire compatibility; the translation events are ignored.
    case subtitleTranslationStarted
    case subtitleTranslationCues
    case subtitleTranslationCompleted
    case subtitleTranslationFailed
    case subtitleReady
    /// A name not listed above, as sent.
    case unknown(String)

    /// The name as sent on the wire.
    var rawValue: String {
        switch self {
        case .chapterThumbnailReady: return "chapter_thumbnail_ready"
        case .markersUpdated: return "markers_updated"
        case .subtitleTranslationStarted: return "subtitle_translation_started"
        case .subtitleTranslationCues: return "subtitle_translation_cues"
        case .subtitleTranslationCompleted: return "subtitle_translation_completed"
        case .subtitleTranslationFailed: return "subtitle_translation_failed"
        case .subtitleReady: return "subtitle_ready"
        case .unknown(let raw): return raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "chapter_thumbnail_ready": self = .chapterThumbnailReady
        case "markers_updated": self = .markersUpdated
        case "subtitle_translation_started": self = .subtitleTranslationStarted
        case "subtitle_translation_cues": self = .subtitleTranslationCues
        case "subtitle_translation_completed": self = .subtitleTranslationCompleted
        case "subtitle_translation_failed": self = .subtitleTranslationFailed
        case "subtitle_ready": self = .subtitleReady
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        self = PlaybackRealtimeEventName(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum PlaybackRealtimeAckStatus: String, Codable {
    case accepted
}

enum PlaybackRealtimeResultStatus: String, Codable {
    case completed
    case rejected
}

/// Why a command was rejected, as its result's `error`.
enum PlaybackRealtimeCommandExecutionError: Error {
    case unsupportedCommand
    case playerNotReady
    case missingSeekPosition
    case commandFailed

    var rejectionReason: String {
        switch self {
        case .unsupportedCommand: return "unsupported_command"
        case .playerNotReady: return "player_not_ready"
        case .missingSeekPosition: return "missing_seek_position"
        case .commandFailed: return "command_failed"
        }
    }
}

/// Any JSON value in a payload. Decoding tries null, then Bool, Double,
/// String, object and array, in that order.
enum PlaybackRealtimeValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PlaybackRealtimeValue])
    case array([PlaybackRealtimeValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: PlaybackRealtimeValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([PlaybackRealtimeValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                PlaybackRealtimeValue.self,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Unsupported realtime JSON payload value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

typealias PlaybackRealtimePayload = [String: PlaybackRealtimeValue]

/// Typed reads from a payload: the first of `keys` holding that type.
extension Dictionary where Key == String, Value == PlaybackRealtimeValue {
    func string(forKeys keys: String...) -> String? {
        firstValue(keys) { value -> String? in
            guard case .string(let string) = value else { return nil }
            return string
        }
    }

    func number(forKeys keys: String...) -> Double? {
        firstValue(keys) { value -> Double? in
            guard case .number(let number) = value else { return nil }
            return number
        }
    }

    /// A number in `Int`'s range, truncated. Anything else is skipped, so a
    /// huge or non-finite value can't trap.
    func int(forKeys keys: String...) -> Int? {
        firstValue(keys) { value -> Int? in
            guard case .number(let number) = value, number.isFinite,
                  number >= -9.223372036854775808e18, number < 9.223372036854775808e18 else { return nil }
            return Int(number)
        }
    }

    private func firstValue<T>(_ keys: [String], _ extract: (PlaybackRealtimeValue) -> T?) -> T? {
        for key in keys {
            if let value = self[key], let extracted = extract(value) { return extracted }
        }
        return nil
    }
}

struct PlaybackRealtimeCommandEnvelope: Decodable, Equatable {
    let type: PlaybackRealtimeMessageType
    let commandId: String
    let sessionId: String
    let name: PlaybackRealtimeCommandName
    let reason: String?
    let issuedBy: PlaybackRealtimeIssuedBy?
    let deadlineMS: Int?
    /// Empty when the envelope has none.
    let payload: PlaybackRealtimePayload

    enum CodingKeys: String, CodingKey {
        case type
        case commandId = "command_id"
        case sessionId = "session_id"
        case name
        case reason
        case issuedBy = "issued_by"
        case deadlineMS = "deadline_ms"
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(PlaybackRealtimeMessageType.self, forKey: .type)
        commandId = try container.decode(String.self, forKey: .commandId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try container.decode(PlaybackRealtimeCommandName.self, forKey: .name)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        issuedBy = try container.decodeIfPresent(PlaybackRealtimeIssuedBy.self, forKey: .issuedBy)
        deadlineMS = try container.decodeIfPresent(Int.self, forKey: .deadlineMS)
        payload = try container.decodeIfPresent(PlaybackRealtimePayload.self, forKey: .payload) ?? [:]
    }
}

struct PlaybackRealtimeIssuedBy: Decodable, Equatable {
    let kind: String
}

struct PlaybackRealtimeEventEnvelope: Decodable, Equatable {
    let type: PlaybackRealtimeMessageType
    let sessionId: String
    let name: PlaybackRealtimeEventName
    /// Empty when the envelope has none.
    let payload: PlaybackRealtimePayload

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case name
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(PlaybackRealtimeMessageType.self, forKey: .type)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try container.decode(PlaybackRealtimeEventName.self, forKey: .name)
        payload = try container.decodeIfPresent(PlaybackRealtimePayload.self, forKey: .payload) ?? [:]
    }
}

enum PlaybackRealtimeInboundMessage: Equatable {
    case command(PlaybackRealtimeCommandEnvelope)
    case event(PlaybackRealtimeEventEnvelope)
}

struct PlaybackRealtimeHelloEnvelope: Encodable {
    let type: PlaybackRealtimeMessageType = .hello
    let sessionId: String
    let client: PlaybackRealtimeClientInfo
    let capabilities: PlaybackRealtimeCapabilities

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case client
        case capabilities
    }
}

struct PlaybackRealtimeClientInfo: Encodable {
    let name: String
    let version: String
}

struct PlaybackRealtimeCapabilities: Encodable {
    let commands: [PlaybackRealtimeCommandName]
}

struct PlaybackRealtimeAckEnvelope: Encodable {
    let type: PlaybackRealtimeMessageType = .ack
    let commandId: String
    let sessionId: String
    let status: PlaybackRealtimeAckStatus = .accepted

    enum CodingKeys: String, CodingKey {
        case type
        case commandId = "command_id"
        case sessionId = "session_id"
        case status
    }
}

struct PlaybackRealtimeResultEnvelope: Encodable {
    let type: PlaybackRealtimeMessageType = .result
    let commandId: String
    let sessionId: String
    let status: PlaybackRealtimeResultStatus
    /// Left out when nil.
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type
        case commandId = "command_id"
        case sessionId = "session_id"
        case status
        case error
    }
}

/// A command or event envelope, or nil for anything else or malformed JSON.
func parsePlaybackRealtimeInboundMessage(_ data: Data) -> PlaybackRealtimeInboundMessage? {
    let decoder = JSONDecoder()
    guard let base = try? decoder.decode(PlaybackRealtimeBaseEnvelope.self, from: data) else { return nil }
    switch base.type {
    case .command:
        return (try? decoder.decode(PlaybackRealtimeCommandEnvelope.self, from: data)).map { .command($0) }
    case .event:
        return (try? decoder.decode(PlaybackRealtimeEventEnvelope.self, from: data)).map { .event($0) }
    default:
        return nil
    }
}

func makePlaybackRealtimeHello(sessionId: String) -> PlaybackRealtimeHelloEnvelope {
    PlaybackRealtimeHelloEnvelope(
        sessionId: sessionId,
        client: PlaybackRealtimeClientInfo(name: applePlaybackRealtimeClientName, version: "1"),
        capabilities: PlaybackRealtimeCapabilities(commands: supportedApplePlaybackRealtimeCommands)
    )
}

func makePlaybackRealtimeAck(sessionId: String, commandId: String) -> PlaybackRealtimeAckEnvelope {
    PlaybackRealtimeAckEnvelope(commandId: commandId, sessionId: sessionId)
}

func makePlaybackRealtimeResult(
    sessionId: String,
    commandId: String,
    status: PlaybackRealtimeResultStatus,
    error: String? = nil
) -> PlaybackRealtimeResultEnvelope {
    PlaybackRealtimeResultEnvelope(commandId: commandId, sessionId: sessionId, status: status, error: error)
}

private struct PlaybackRealtimeBaseEnvelope: Decodable {
    let type: PlaybackRealtimeMessageType
}

// The client names Silo shows for Vivid's realtime sessions.
#if os(tvOS)
private let applePlaybackRealtimeClientName = "vivid-tvos"
#else
private let applePlaybackRealtimeClientName = "vivid-ios"
#endif
