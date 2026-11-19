import AVFoundation
import Foundation
import Observation
import os
import ShazamKit
import VividAudioClipC
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Song identification: the clip reader over the shipped FFmpeg, the steps
/// and mixes asked of a catalogue, and the player's model. Matching runs
/// against custom catalogues made from the generated files in
/// `Fixtures/SongClips`, so nothing here reaches Shazam.
final class SongIdentificationTests: XCTestCase {
    private static let centre51 = "songclip_ac3_51_centre.mkv"
    private static let stereo = "songclip_aac_stereo.mp4"
    private static let twoTracks = "songclip_flac_two_tracks.mkv"
    private static let gap = "songclip_flac_gap.mkv"
    private static let layoutChange = "songclip_ac3_layout_change.mkv"
    private static let melody = "songclip_melody.mkv"
    private static let melodyReference = "songclip_melody_reference.m4a"
    private static let otherReference = "songclip_other_reference.m4a"

    // MARK: - Clips

    func testTheMusicMixLeavesOutTheCentreChannel() async throws {
        let reader = try Self.reader(Self.centre51)
        let clip = try await reader.clip(from: 1, duration: 2)
        XCTAssertEqual(clip.mix.count, 96000)
        XCTAssertEqual(clip.startSeconds, 1, accuracy: 0.001)
        let music = try XCTUnwrap(clip.music, "5.1 has a centre channel, so there is a music mix")
        XCTAssertEqual(music.count, clip.mix.count)
        // The fronts carry 440 Hz and the centre 1 kHz.
        XCTAssertGreaterThan(Self.level(clip.mix, at: 1000), 0.005)
        XCTAssertLessThan(Self.level(music, at: 1000), 0.0005)
        XCTAssertGreaterThan(Self.level(clip.mix, at: 440), 0.005)
        XCTAssertGreaterThan(Self.level(music, at: 440), 0.005)
    }

    func testStereoIsConvertedTo48kHzWithoutAMusicMix() async throws {
        let reader = try Self.reader(Self.stereo)
        let clip = try await reader.clip(from: 1, duration: 2)
        XCTAssertNil(clip.music, "no centre channel, so no second mix")
        XCTAssertEqual(clip.mix.count, 96000, "44.1 kHz comes back at 48 kHz")
        // AAC's start-up delay is taken care of: the clip starts on time.
        XCTAssertEqual(clip.startSeconds, 1, accuracy: 0.001)
        XCTAssertGreaterThan(Self.level(clip.mix, at: 440), 0.005)
    }

    func testAClipThatStartsWhereTheLastEndedCarriesOn() async throws {
        let reader = try Self.reader(Self.centre51)
        let first = try await reader.clip(from: 1, duration: 2)
        let afterFirst = reader.bytesRead
        let second = try await reader.clip(from: first.startSeconds + first.duration, duration: 1.5)
        XCTAssertEqual(second.startSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(second.mix.count, 72000)
        // Carrying on reads only what follows; a seek would go back to the
        // keyframe before the time and read the second's bytes again.
        XCTAssertLessThan(reader.bytesRead - afterFirst, afterFirst)
    }

    func testAClipEndsAtAGapInTheTrack() async throws {
        // Sound from 0 to 2 seconds, then from 7 to 9.
        let reader = try Self.reader(Self.gap)
        let before = try await reader.clip(from: 1, duration: 3)
        XCTAssertEqual(before.startSeconds, 1, accuracy: 0.001)
        XCTAssertLessThan(before.duration, 1.1, "nothing from after the gap is joined on")
        XCTAssertTrue(before.endedAtBoundary, "short because of the gap, not the end of the file")
        let after = try await reader.clip(from: 7, duration: 1)
        XCTAssertEqual(after.startSeconds, 7, accuracy: 0.01)
        XCTAssertFalse(after.endedAtBoundary)
    }

    func testAClipEndsAtAChannelLayoutChange() async throws {
        // 3.0 with a 1 kHz centre for two seconds, then 2.1 with a 60 Hz
        // low-frequency channel: the same three channels, laid out apart.
        let reader = try Self.reader(Self.layoutChange)
        let before = try await reader.clip(from: 0.5, duration: 3)
        XCTAssertTrue(before.endedAtBoundary, "short because the layout changed, not the end of the file")
        XCTAssertLessThan(before.startSeconds + before.duration, 2.1, "nothing after the change is mixed with 3.0's weights")
        let music = try XCTUnwrap(before.music, "3.0 has a centre channel")
        XCTAssertGreaterThan(Self.level(before.mix, at: 1000), 0.005)
        XCTAssertLessThan(Self.level(music, at: 1000), 0.0005, "the music mix leaves the centre out")

        // The next read carries on in 2.1, mixed with 2.1's own weights.
        let after = try await reader.clip(from: before.startSeconds + before.duration, duration: 1.5)
        XCTAssertEqual(after.startSeconds, before.startSeconds + before.duration, accuracy: 0.05)
        XCTAssertNil(after.music, "2.1 has no centre channel")
        XCTAssertGreaterThan(Self.level(after.mix, at: 440), 0.005)
        XCTAssertLessThan(Self.level(after.mix, at: 60), 0.0005, "the low-frequency channel isn't mixed in")
        XCTAssertLessThan(Self.level(after.mix, at: 1000), 0.0005)
    }

    func testTheTrackAskedForIsTheOneRead() async throws {
        // Stream 1 is 440 Hz from one second in, stream 2 is 1 kHz from the
        // start.
        let late = try await Self.reader(Self.twoTracks, stream: 1).clip(from: 0, duration: 1)
        XCTAssertEqual(late.startSeconds, 1, accuracy: 0.001, "the clip starts where the track's sound does")
        XCTAssertGreaterThan(Self.level(late.mix, at: 440), 0.005)
        XCTAssertLessThan(Self.level(late.mix, at: 1000), 0.0005)

        let early = try await Self.reader(Self.twoTracks, stream: 2).clip(from: 0, duration: 1)
        XCTAssertEqual(early.startSeconds, 0, accuracy: 0.001)
        XCTAssertGreaterThan(Self.level(early.mix, at: 1000), 0.005)
        XCTAssertLessThan(Self.level(early.mix, at: 440), 0.0005)

        // Without a track, the file's default sound.
        let fallback = try await Self.reader(Self.twoTracks, stream: nil).clip(from: 2, duration: 1)
        XCTAssertGreaterThan(Self.level(fallback.mix, at: 440), 0.005)
    }

    func testANumberThatIsntASoundStreamGetsTheDefaultSound() async throws {
        // Stream 0 is the picture, and 9 isn't in the file. Both read the
        // default sound, the 440 Hz track from one second in.
        for stream in [0, 9] {
            let clip = try await Self.reader(Self.twoTracks, stream: stream).clip(from: 2, duration: 1)
            XCTAssertGreaterThan(Self.level(clip.mix, at: 440), 0.005, "stream \(stream)")
            XCTAssertLessThan(Self.level(clip.mix, at: 1000), 0.0005, "stream \(stream)")
        }
    }

    func testThereIsNoSoundPastTheEnd() async throws {
        await Self.assertThrows(.noSound) { try await Self.reader(Self.stereo).clip(from: 60, duration: 1) }
    }

    func testAFileThatIsntMediaIsUnreadable() async throws {
        let (reader, path) = try Self.notMediaReader()
        defer { try? FileManager.default.removeItem(at: path) }
        await Self.assertThrows(.unreadable) { try await reader.clip(from: 0, duration: 1) }
    }

    func testCancelStopsReading() async throws {
        let reader = try Self.reader(Self.melody)
        reader.cancel()
        await Self.assertThrows(.cancelled) { try await reader.clip(from: 0, duration: 6) }
    }

    func testAClipStopsAtItsByteLimit() throws {
        let data = try Data(contentsOf: Self.fixtureURL(Self.melody))
        let box = DataBox(data)
        var callbacks = VividAudioClipCallbacks(context: Unmanaged.passUnretained(box).toOpaque(), read: { context, buffer, size, offset in
            let box = Unmanaged<DataBox>.fromOpaque(context!).takeUnretainedValue()
            guard offset < box.data.count else { return 0 }
            let count = min(Int(size), box.data.count - Int(offset))
            box.data.copyBytes(to: buffer!, from: Int(offset)..<Int(offset) + count)
            return Int32(count)
        }, size: { context in
            Int64(Unmanaged<DataBox>.fromOpaque(context!).takeUnretainedValue().data.count)
        }, aborted: nil)
        var handle: OpaquePointer?
        XCTAssertEqual(Int(vivid_audio_clip_open(&callbacks, 0, -1, &handle)), VIVID_AUDIO_CLIP_OK)
        defer { vivid_audio_clip_close(handle) }
        var samples = VividAudioClipSamples()
        XCTAssertEqual(Int(vivid_audio_clip_read(handle, 5, 10, 1024, &samples)), VIVID_AUDIO_CLIP_ERROR_OVER_BYTE_LIMIT)
        XCTAssertNil(samples.mix)
        // The handle still works after a refusal.
        XCTAssertEqual(Int(vivid_audio_clip_read(handle, 5, 1, 0, &samples)), VIVID_AUDIO_CLIP_OK)
        XCTAssertEqual(samples.count, 48000)
        vivid_audio_clip_samples_free(&samples)
    }

    // MARK: - Identification

    func testTheClipIsLengthenedWhenTheFirstStepFindsNothing() async throws {
        let catalog = RecordingCatalog(try await Self.catalog(Self.melodyReference, title: "Test melody"))
        let outcome = await SongIdentifier(catalog: catalog).identify(reader: try Self.reader(Self.melody), at: 9)
        guard case let .found(match) = outcome else { return XCTFail("expected a match, got \(outcome)") }
        XCTAssertEqual(match.title, "Test melody")
        XCTAssertEqual(match.artist, "Vivid")
        // The first step, five to eleven seconds, holds only the other tune;
        // the second reaches the catalogue's.
        let durations = await catalog.durations
        XCTAssertEqual(durations.count, 2)
        XCTAssertEqual(durations.first ?? 0, 6, accuracy: 0.1)
        XCTAssertEqual(durations.last ?? 0, 12, accuracy: 0.1)
    }

    func testAnUnknownSongIsNotFound() async throws {
        let catalog = RecordingCatalog(try await Self.catalog(Self.otherReference, title: "Another melody"))
        let outcome = await SongIdentifier(catalog: catalog).identify(reader: try Self.reader(Self.melody), at: 9)
        XCTAssertEqual(outcome, .notFound)
        let durations = await catalog.durations
        XCTAssertEqual(durations.count, 2, "both steps were tried")
    }

    func testSoundWithACentreChannelIsTriedInBothMixes() async throws {
        let catalog = StubCatalog(answers: [.noMatch, .noMatch, .noMatch, .noMatch])
        let outcome = await SongIdentifier(catalog: catalog).identify(reader: try Self.reader(Self.centre51), at: 2)
        XCTAssertEqual(outcome, .notFound)
        // The file is six seconds long, so there's nothing for a second step
        // to read. The first step asks twice: without the centre channel,
        // then with it.
        let asked = await catalog.asked
        XCTAssertEqual(asked.count, 2)
        // Signatures are deterministic, so the same six seconds read again
        // tell which mix was asked about when.
        let clip = try await Self.reader(Self.centre51).clip(from: 0, duration: 6)
        let music = try XCTUnwrap(SongIdentifier.signature(of: try XCTUnwrap(clip.music))).dataRepresentation
        let full = try XCTUnwrap(SongIdentifier.signature(of: clip.mix)).dataRepresentation
        XCTAssertNotEqual(music, full)
        let signatures = await catalog.signatures
        XCTAssertEqual(signatures, [music, full], "the mix without the centre first, then the full mix")
    }

    func testShazamBeingUnreachableIsReportedAsSuch() async throws {
        let failed = StubCatalog(answers: [.failed(code: SHError.Code.matchAttemptFailed.rawValue)])
        let outcome = await SongIdentifier(catalog: failed).identify(reader: try Self.reader(Self.melody), at: 9)
        XCTAssertEqual(outcome, .failed(.shazamUnavailable))
        let asked = await failed.asked
        XCTAssertEqual(asked.count, 1, "a lost connection isn't asked again")
    }

    func testTheFirstStepCanMatchOnItsOwn() async throws {
        let catalog = RecordingCatalog(try await Self.catalog(Self.melodyReference, title: "Test melody"))
        // Four seconds before 16 is 12, inside the catalogue's tune.
        let outcome = await SongIdentifier(catalog: catalog).identify(reader: try Self.reader(Self.melody), at: 16)
        guard case .found = outcome else { return XCTFail("expected a match, got \(outcome)") }
        let durations = await catalog.durations
        XCTAssertEqual(durations.count, 1, "nothing more is read after a match")
    }

    func testThePlayerCanStopLaterSteps() async throws {
        let catalog = RecordingCatalog(try await Self.catalog(Self.melodyReference, title: "Test melody"))
        let outcome = await SongIdentifier(catalog: catalog)
            .identify(reader: try Self.reader(Self.melody), at: 9, mayReadMore: { false })
        XCTAssertEqual(outcome, .notFound, "the first step's answer stands")
        let durations = await catalog.durations
        XCTAssertEqual(durations.count, 1)
    }

    func testASliverAtTheEndIsntAskedAbout() async throws {
        // Asked at 17.5 seconds into the twenty-second file: the first step
        // reads 13.5 to 19.5, and the second finds only about half a second
        // before the end.
        let catalog = StubCatalog(answers: [])
        let outcome = await SongIdentifier(catalog: catalog).identify(reader: try Self.reader(Self.melody), at: 17.5)
        XCTAssertEqual(outcome, .notFound)
        let asked = await catalog.asked
        XCTAssertEqual(asked.count, 1, "stereo asks once a step, and the sliver isn't asked about")
    }

    func testALaterReadFailingIsntReportedAsNoSong() async throws {
        // The first step can't match at 9 seconds. The connection then
        // drops before the second, so the longer clip is never asked about.
        let file = try XCTUnwrap(FileStillByteSource(url: try Self.fixtureURL(Self.melody)))
        let source = BreakableSource(file)
        let reader = SongClipReader(source: source, streamIndex: nil)
        let catalog = RecordingCatalog(try await Self.catalog(Self.melodyReference, title: "Test melody"))
        let outcome = await SongIdentifier(catalog: catalog).identify(reader: reader, at: 9, mayReadMore: {
            source.breakNow()
            return true
        })
        XCTAssertEqual(outcome, .failed(.unreachable))
        let durations = await catalog.durations
        XCTAssertEqual(durations.count, 1)
    }

    func testIdentificationCarriesOnPastAGap() async throws {
        // From 0: the first step stops at the gap two seconds in, and later
        // steps carry on from seven seconds, as a fresh run.
        let catalog = StubCatalog(answers: [])
        let outcome = await SongIdentifier(catalog: catalog).identify(reader: try Self.reader(Self.gap), at: 4)
        XCTAssertEqual(outcome, .notFound)
        let asked = await catalog.asked
        XCTAssertEqual(asked.count, 2, "the sound on each side of the gap is asked about")
        for duration in asked {
            XCTAssertLessThan(duration, 2.5, "the two sides are never joined into one signature")
        }
    }

    func testAnUnreadableFileIsReportedBeforeShazamIsAsked() async throws {
        let catalog = StubCatalog(answers: [])
        let (reader, path) = try Self.notMediaReader()
        defer { try? FileManager.default.removeItem(at: path) }
        let outcome = await SongIdentifier(catalog: catalog).identify(reader: reader, at: 1)
        XCTAssertEqual(outcome, .failed(.unreadable))
        let asked = await catalog.asked
        XCTAssertTrue(asked.isEmpty)
    }

    // MARK: - Model

    @MainActor
    func testPressingWhileUnavailableSaysWhy() {
        let model = SongIdentificationModel(openReader: { _ in XCTFail("nothing should be read"); return nil })
        model.availability = { .unavailable(.busy) }
        model.identify()
        XCTAssertEqual(model.phase, .refused(.busy), "pressing says why instead of doing nothing")
        XCTAssertEqual(model.unavailability, .busy)
    }

    @MainActor
    func testTheModelFindsAndSavesASong() async throws {
        let reference = try await Self.catalog(Self.melodyReference, title: "Test melody")
        let url = try Self.fixtureURL(Self.melody)
        let saved = SavedItems()
        let model = SongIdentificationModel(identifier: { SongIdentifier(catalog: CustomSongCatalog(catalog: reference)) },
                                            addToLibrary: { item in await saved.add(item.value.title) })
        XCTAssertFalse(model.canSaveToShazam)
        model.availability = { .ready(.init(sourceURL: url, headers: [:], streamIndex: nil, transportSeconds: 9)) }
        model.identify()
        XCTAssertEqual(model.phase, .listening)
        try await Self.waitUntil("a match") { model.phase != .listening }
        guard case let .found(match) = model.phase else { return XCTFail("expected a match, got \(model.phase)") }
        XCTAssertEqual(match.title, "Test melody")
        XCTAssertTrue(model.canSaveToShazam)

        model.saveToShazam()
        XCTAssertEqual(model.saveState, .saving)
        try await Self.waitUntil("the save") { model.saveState != .saving }
        XCTAssertEqual(model.saveState, .saved)
        let titles = await saved.titles
        XCTAssertEqual(titles, ["Test melody"])

        model.reset()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.saveState, .idle)
    }

    @MainActor
    func testThePanelRedrawsWhenPlaybackStarts() {
        let model = SongIdentificationModel()
        var changed = false
        withObservationTracking { _ = model.blockingReason } onChange: { changed = true }
        model.loadDidStart()
        XCTAssertTrue(changed, "the player's own start marker isn't observed, so the model's revision has to be")
    }

    @MainActor
    func testASeekStopsTheSecondStep() async throws {
        let reference = try await Self.catalog(Self.melodyReference, title: "Test melody")
        let url = try Self.fixtureURL(Self.melody)
        let model = SongIdentificationModel(identifier: { SongIdentifier(catalog: CustomSongCatalog(catalog: reference)) })
        // At 9 seconds the first step can't match and the second would. By
        // the second step the viewer has jumped to a minute in.
        var asked = 0
        model.availability = {
            asked += 1
            return .ready(.init(sourceURL: url, headers: [:], streamIndex: nil, transportSeconds: asked == 1 ? 9 : 60))
        }
        model.identify()
        try await Self.waitUntil("an answer") { model.phase != .listening }
        XCTAssertEqual(model.phase, .notFound, "sound from before the seek isn't read on")
    }

    @MainActor
    func testASongWithoutAShazamIDCantBeSaved() async throws {
        let reference = try await Self.catalog(Self.melodyReference, title: "Test melody", shazamID: nil)
        let url = try Self.fixtureURL(Self.melody)
        let model = SongIdentificationModel(identifier: { SongIdentifier(catalog: CustomSongCatalog(catalog: reference)) },
                                            addToLibrary: { _ in XCTFail("nothing should be saved") })
        model.availability = { .ready(.init(sourceURL: url, headers: [:], streamIndex: nil, transportSeconds: 16)) }
        model.identify()
        try await Self.waitUntil("a match") { model.phase != .listening }
        guard case .found = model.phase else { return XCTFail("expected a match, got \(model.phase)") }
        XCTAssertFalse(model.canSaveToShazam)
        model.saveToShazam()
        XCTAssertEqual(model.saveState, .idle)
    }

    @MainActor
    func testAnAttemptThatTakesTooLongGivesUp() async throws {
        let url = try Self.fixtureURL(Self.melody)
        let model = SongIdentificationModel(identifier: { SongIdentifier(catalog: StubCatalog(answers: [], delay: true)) },
                                            timeLimit: .milliseconds(200))
        model.availability = { .ready(.init(sourceURL: url, headers: [:], streamIndex: nil, transportSeconds: 9)) }
        model.identify()
        try await Self.waitUntil("the time limit") { model.phase != .listening }
        XCTAssertEqual(model.phase, .failed(.timedOut))
    }

    @MainActor
    func testACancelledAttemptsLateMatchNeverLands() async throws {
        let url = try Self.fixtureURL(Self.melody)
        let gate = GateCatalog()
        let model = SongIdentificationModel(identifier: { SongIdentifier(catalog: gate) })
        model.availability = { .ready(.init(sourceURL: url, headers: [:], streamIndex: nil, transportSeconds: 9)) }

        // The first attempt is cancelled while Shazam has its question.
        model.identify()
        try await Self.waitUntilAsync("the first question") { await gate.waiting == 1 }
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
        // A second attempt starts and asks too.
        model.identify()
        try await Self.waitUntilAsync("the second question") { await gate.waiting == 2 }

        // The first attempt's match arrives late: it lands nowhere.
        await gate.answerOldest(title: "Stale")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.phase, .listening, "the newer attempt is still listening")

        await gate.answerOldest(title: "Fresh")
        try await Self.waitUntil("the second answer") { model.phase != .listening }
        guard case let .found(match) = model.phase else { return XCTFail("expected a match, got \(model.phase)") }
        XCTAssertEqual(match.title, "Fresh")
    }

    // MARK: - Helpers

    private static func fixtureURL(_ name: String) throws -> URL {
        let parts = name.split(separator: ".").map(String.init)
        return try XCTUnwrap(Bundle(for: SongIdentificationTests.self).url(forResource: parts[0], withExtension: parts[1]), name)
    }

    private static func reader(_ name: String, stream: Int? = nil) throws -> SongClipReader {
        let source = try XCTUnwrap(FileStillByteSource(url: try fixtureURL(name)), name)
        return SongClipReader(source: source, streamIndex: stream)
    }

    /// A catalogue of one song. The Shazam library only takes songs with a
    /// Shazam ID, so the song has a made-up one unless told otherwise.
    private static func catalog(_ reference: String, title: String, shazamID: String? = "1234567") async throws -> SHCustomCatalog {
        let signature = try await SHSignatureGenerator.signature(from: AVURLAsset(url: try fixtureURL(reference)))
        var properties: [SHMediaItemProperty: Any] = [.title: title, .artist: "Vivid"]
        if let shazamID { properties[.shazamID] = shazamID }
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(signature, representing: [SHMediaItem(properties: properties)])
        return catalog
    }

    /// A reader of a file that isn't media at all, and the file to remove.
    private static func notMediaReader() throws -> (SongClipReader, URL) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("songclip-not-media-\(UUID().uuidString).mkv")
        try Data(repeating: 0x5A, count: 64 * 1024).write(to: path)
        let source = try XCTUnwrap(FileStillByteSource(url: path))
        return (SongClipReader(source: source, streamIndex: nil), path)
    }

    /// How strong `frequency` is in 48 kHz samples (Goertzel).
    private static func level(_ samples: [Float], at frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / SongClip.sampleRate)
        var previous = 0.0, beforePrevious = 0.0
        for sample in samples {
            let value = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = value
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return sqrt(max(power, 0)) / Double(max(samples.count, 1))
    }

    private static func assertThrows(_ expected: SongClipError, file: StaticString = #filePath, line: UInt = #line,
                                     _ body: () async throws -> SongClip) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SongClipError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    @MainActor
    private static func waitUntilAsync(_ label: String, timeout: TimeInterval = 20, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("\(label): timed out")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private static func waitUntil(_ label: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("\(label): timed out")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// A file whose reads start failing, as a dropped connection's do, once
/// told to.
private final class BreakableSource: StillByteSource, @unchecked Sendable {
    private let file: FileStillByteSource
    private let broken = OSAllocatedUnfairLock(initialState: false)

    init(_ file: FileStillByteSource) {
        self.file = file
    }

    func breakNow() {
        broken.withLock { $0 = true }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, offset: Int64) throws -> Int {
        if broken.withLock({ $0 }) { throw StillByteSourceError.failed }
        return try file.read(into: buffer, offset: offset)
    }

    var size: Int64? { file.size }
    func cancel() { file.cancel() }
    func resume() { file.resume() }
}

private final class DataBox {
    let data: Data
    init(_ data: Data) { self.data = data }
}

private actor SavedItems {
    private(set) var titles: [String?] = []
    func add(_ title: String?) { titles.append(title) }
}

/// A real catalogue that also notes how long each question was.
private struct RecordingCatalog: SongCatalog {
    private let inner: CustomSongCatalog
    private let log = DurationLog()

    init(_ catalog: SHCustomCatalog) {
        inner = CustomSongCatalog(catalog: catalog)
    }

    var minimumQueryDuration: Double { inner.minimumQueryDuration }
    var maximumQueryDuration: Double { inner.maximumQueryDuration }
    var durations: [Double] { get async { await log.durations } }

    func match(_ signature: SHSignature) async -> SongCatalogAnswer {
        await log.add(signature.duration)
        return await inner.match(signature)
    }
}

private actor DurationLog {
    private(set) var durations: [Double] = []
    func add(_ duration: Double) { durations.append(duration) }
}

/// Holds every question until the test answers it, oldest first.
private actor GateCatalog: SongCatalog {
    nonisolated let minimumQueryDuration = 1.0
    nonisolated let maximumQueryDuration = 12.0
    private var held: [CheckedContinuation<SongCatalogAnswer, Never>] = []
    private(set) var waiting = 0

    func match(_ signature: SHSignature) async -> SongCatalogAnswer {
        await withCheckedContinuation { continuation in
            held.append(continuation)
            waiting += 1
        }
    }

    func answerOldest(title: String) {
        guard !held.isEmpty else { return }
        let item = SHMediaItem(properties: [.title: title])
        held.removeFirst().resume(returning: .match(SongMatch(title: title, artist: nil, artworkURL: nil, appleMusicURL: nil,
                                                              shazamID: nil, item: SongMediaItem(value: item))))
    }
}

/// Answers from a list, noting each question.
private actor StubCatalog: SongCatalog {
    nonisolated let minimumQueryDuration = 1.0
    nonisolated let maximumQueryDuration = 12.0
    private var answers: [SongCatalogAnswer]
    private let delay: Bool
    private(set) var asked: [Double] = []
    private(set) var signatures: [Data] = []

    init(answers: [SongCatalogAnswer], delay: Bool = false) {
        self.answers = answers
        self.delay = delay
    }

    func match(_ signature: SHSignature) async -> SongCatalogAnswer {
        asked.append(signature.duration)
        signatures.append(signature.dataRepresentation)
        if delay { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        return answers.isEmpty ? .noMatch : answers.removeFirst()
    }
}
