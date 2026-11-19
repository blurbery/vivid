import AVFoundation
import Foundation
import os
import ShazamKit

/// A song Shazam recognised.
struct SongMatch: Equatable, Sendable {
    let title: String
    let artist: String?
    let artworkURL: URL?
    let appleMusicURL: URL?
    let shazamID: String?
    /// The matched item itself, kept for adding to the Shazam library.
    let item: SongMediaItem

    static func == (lhs: SongMatch, rhs: SongMatch) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.artworkURL == rhs.artworkURL
            && lhs.appleMusicURL == rhs.appleMusicURL && lhs.shazamID == rhs.shazamID
    }
}

/// ShazamKit's media item, which is immutable once made.
struct SongMediaItem: @unchecked Sendable {
    let value: SHMediaItem
}

/// What became of an attempt to identify the song playing.
enum SongIdentificationOutcome: Equatable, Sendable {
    case found(SongMatch)
    /// The sound was read and Shazam answered, but knows no song in it.
    case notFound
    case failed(SongIdentificationFailure)
}

enum SongIdentificationFailure: Equatable, Sendable {
    case cancelled
    /// The file's bytes couldn't be fetched just now.
    case unreachable
    /// The file's sound can't be read for identification: its container,
    /// codec or layout isn't one Vivid reads, or reading it would cost too
    /// much.
    case unreadable
    /// There is no sound at this point in the file, or too little before
    /// it ends.
    case noSound
    /// Shazam couldn't be asked: no connection, or the service refused.
    case shazamUnavailable
    /// The whole attempt took longer than the player allows.
    case timedOut
}

/// What a catalogue said about one signature.
enum SongCatalogAnswer: Sendable {
    case match(SongMatch)
    case noMatch
    /// The catalogue couldn't be asked. Carries ShazamKit's error code, or
    /// -1 for an error from elsewhere.
    case failed(code: Int)
}

/// Something signatures can be matched against: Shazam's own catalogue in
/// the app, a custom one in tests.
protocol SongCatalog: Sendable {
    var minimumQueryDuration: Double { get }
    var maximumQueryDuration: Double { get }
    func match(_ signature: SHSignature) async -> SongCatalogAnswer
}

/// Shazam's catalogue of recorded music.
struct ShazamSongCatalog: SongCatalog {
    let minimumQueryDuration: Double
    let maximumQueryDuration: Double

    init() {
        let catalog = SHSession().catalog
        // ShazamKit says what it takes. The fallbacks are its documented
        // values, should it ever say nothing.
        minimumQueryDuration = catalog.minimumQuerySignatureDuration > 0 ? catalog.minimumQuerySignatureDuration : 1
        maximumQueryDuration = catalog.maximumQuerySignatureDuration > 0 ? catalog.maximumQuerySignatureDuration : 12
    }

    func match(_ signature: SHSignature) async -> SongCatalogAnswer {
        // A session per question: nothing is shared between attempts.
        await SongCatalogAnswer(SHSession().result(from: signature))
    }
}

/// A catalogue made from reference signatures, for tests that must not
/// reach Shazam.
struct CustomSongCatalog: SongCatalog, @unchecked Sendable {
    let catalog: SHCustomCatalog

    var minimumQueryDuration: Double { catalog.minimumQuerySignatureDuration }
    var maximumQueryDuration: Double { catalog.maximumQuerySignatureDuration }

    func match(_ signature: SHSignature) async -> SongCatalogAnswer {
        await SongCatalogAnswer(SHSession(catalog: catalog).result(from: signature))
    }
}

extension SongCatalogAnswer {
    init(_ result: SHSession.Result) {
        switch result {
        case let .match(match):
            guard let item = match.mediaItems.first,
                  let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else {
                self = .noMatch
                return
            }
            let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .match(SongMatch(title: title, artist: artist?.isEmpty == false ? artist : nil,
                                    artworkURL: item.artworkURL, appleMusicURL: item.appleMusicURL,
                                    shazamID: item.shazamID, item: SongMediaItem(value: item)))
        case .noMatch:
            self = .noMatch
        case let .error(error, _):
            let code = (error as NSError).domain == SHErrorDomain ? (error as NSError).code : -1
            self = .failed(code: code)
        }
    }
}

/// Identifies the song playing at a point in a file: reads the sound
/// around it, makes Shazam signatures and asks the catalogue.
///
/// The sound is read in steps, so a song that is easy to recognise costs
/// one short read: first from a little before the point to a little after
/// it, then on from there until the catalogue's longest query. At each
/// step the mix without the centre channel, where a film's dialogue sits,
/// is tried first, then the full mix.
struct SongIdentifier: Sendable {
    /// How far before the playhead the clip starts. Someone asking what a
    /// song is has usually been hearing it for a few seconds.
    static let leadSeconds = 4.0
    /// The first step's length, and how much each later step adds.
    static let stepSeconds = 6.0
    /// No more than this is ever read, whatever the catalogue would take.
    static let longestClipSeconds = 12.0
    /// A later step that adds less than this, because the file ends, isn't
    /// worth asking about again.
    static let shortestUsefulStepSeconds = 1.0

    private static let logger = Logger(subsystem: "com.blurbery.vivid", category: "SongID")

    let catalog: SongCatalog

    init(catalog: SongCatalog = ShazamSongCatalog()) {
        self.catalog = catalog
    }

    /// Identifies the song at `transportSeconds` on the player's clock.
    /// Cancelling the task stops the read at once. `mayReadMore` is asked
    /// before each step after the first, so the player can stop the reads
    /// when it needs the connection itself: identification then ends with
    /// what it has.
    func identify(reader: SongClipReader, at transportSeconds: Double,
                  mayReadMore: @escaping @Sendable () async -> Bool = { true }) async -> SongIdentificationOutcome {
        await withTaskCancellationHandler {
            await run(reader: reader, at: transportSeconds, mayReadMore: mayReadMore)
        } onCancel: {
            reader.cancel()
        }
    }

    private func run(reader: SongClipReader, at transportSeconds: Double,
                     mayReadMore: @Sendable () async -> Bool) async -> SongIdentificationOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        let longest = min(Self.longestClipSeconds, max(catalog.maximumQueryDuration, catalog.minimumQueryDuration))
        var mix: [Float] = []
        var music: [Float]? = []
        var next = max(transportSeconds - Self.leadSeconds, 0)
        /// True once a question has been put to the catalogue, and once it
        /// has answered one, match or not.
        var asked = false
        var answered = false
        var lastFailureCode: Int?
        var steps = 0

        while Double(mix.count) / SongClip.sampleRate < longest - 0.01 {
            if Task.isCancelled { return finish(.failed(.cancelled), reader: reader, steps: steps, started: started) }
            if steps > 0, await !mayReadMore() { break }
            let have = Double(mix.count) / SongClip.sampleRate
            let wanted = min(Self.stepSeconds, longest - have)
            let clip: SongClip
            do {
                clip = try await reader.clip(from: next, duration: wanted)
            } catch let error as SongClipError {
                // Running out of file after the first step leaves the answer
                // to the sound already asked about. Any other failure means
                // the longer clip was never asked about, so "no song found"
                // would be wrong advice: report the failure, whichever step.
                if !mix.isEmpty, error == .noSound { break }
                return finish(.failed(Self.failure(for: error)), reader: reader, steps: steps, started: started)
            } catch {
                return finish(.failed(.unreadable), reader: reader, steps: steps, started: started)
            }
            steps += 1
            mix += clip.mix
            if let part = clip.music, music != nil {
                music! += part
            } else {
                music = nil
            }
            next = clip.startSeconds + clip.duration
            let total = Double(mix.count) / SongClip.sampleRate
            let reachedEnd = clip.duration < wanted - 0.01
            // A sliver from the end of the file adds nothing worth a second
            // question.
            let addsEnough = steps == 1 || clip.duration >= Self.shortestUsefulStepSeconds

            if addsEnough, total >= catalog.minimumQueryDuration {
                for samples in [music, mix].compactMap({ $0 }) {
                    if Task.isCancelled { return finish(.failed(.cancelled), reader: reader, steps: steps, started: started) }
                    guard let signature = Self.signature(of: samples) else { continue }
                    asked = true
                    switch await catalog.match(signature) {
                    case let .match(found):
                        return finish(.found(found), reader: reader, steps: steps, started: started)
                    case .noMatch:
                        answered = true
                    case let .failed(code):
                        lastFailureCode = code
                        // Shazam can't be reached: the other mix won't do
                        // better.
                        if Self.isConnectionFailure(code) {
                            return finish(.failed(.shazamUnavailable), reader: reader, steps: steps, started: started,
                                          code: code)
                        }
                    }
                }
            }
            if reachedEnd { break }
        }
        if Task.isCancelled { return finish(.failed(.cancelled), reader: reader, steps: steps, started: started) }
        // Nothing to ask about: no sound, or too little before the file ends.
        if mix.isEmpty || !asked { return finish(.failed(.noSound), reader: reader, steps: steps, started: started) }
        // Every question failed: Shazam never actually said no.
        if !answered, let lastFailureCode {
            return finish(.failed(.shazamUnavailable), reader: reader, steps: steps, started: started, code: lastFailureCode)
        }
        return finish(.notFound, reader: reader, steps: steps, started: started)
    }

    /// A Shazam signature of mono 48 kHz samples, or nil when ShazamKit
    /// won't make one.
    static func signature(of samples: [Float]) -> SHSignature? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: SongClip.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let generator = SHSignatureGenerator()
        do {
            try generator.append(buffer, at: nil)
        } catch {
            return nil
        }
        return generator.signature()
    }

    static func failure(for error: SongClipError) -> SongIdentificationFailure {
        switch error {
        case .cancelled: return .cancelled
        case .unreachable: return .unreachable
        case .tooCostly, .unreadable: return .unreadable
        case .noSound: return .noSound
        }
    }

    /// ShazamKit's "the match attempt failed" covers no connection and a
    /// refused request alike.
    static func isConnectionFailure(_ code: Int) -> Bool {
        code == SHError.Code.matchAttemptFailed.rawValue
    }

    /// Numbers only: no title, address or file name goes in the log.
    private func finish(_ outcome: SongIdentificationOutcome, reader: SongClipReader, steps: Int, started: TimeInterval,
                        code: Int? = nil) -> SongIdentificationOutcome {
        let name: String
        switch outcome {
        case .found: name = "found"
        case .notFound: name = "not-found"
        case let .failed(failure): name = "failed-\(failure)"
        }
        let milliseconds = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        Self.logger.info("""
        song-id \(name, privacy: .public) steps=\(steps, privacy: .public) \
        bytes=\(reader.bytesRead, privacy: .public) ms=\(milliseconds, privacy: .public) \
        code=\(code.map(String.init) ?? "-", privacy: .public)
        """)
        return outcome
    }
}
