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

/// Volume Boost and Enhanced Dialogue through Lucid itself: the shipped mpv
/// and FFmpeg decode a generated tone file with the adapter's exact options
/// and write it to mpv's PCM file output, whose channel levels are measured.
/// The tones are -21.07 dBFS RMS (a 1/8 amplitude sine).
final class LucidAudioEnhancementTests: XCTestCase {
    private static let toneLevel = -21.07
    private static let tolerance = 0.3

    func testUnchangedWhenBothAreOff() throws {
        let result = try Self.render(channels: 2, mask: 0x3, frequency: 1_000, enhancement: .off)
        XCTAssertFalse(result.usedFilter)
        Self.assertLevels(result.levels, [Self.toneLevel, Self.toneLevel])
    }

    func testVolumeBoostDoublesTheLevelAtTwoHundredPercent() throws {
        let result = try Self.render(channels: 2, mask: 0x3, frequency: 1_000,
                                     enhancement: VividAudioEnhancement(boostPercent: 200))
        Self.assertLevels(result.levels, [Self.toneLevel + 6.02, Self.toneLevel + 6.02])
    }

    func testEnhancedDialogueKeepsTheCentreAndLowersTheRestOfFivePointOne() throws {
        // 5.1(side): FL FR FC LFE SL SR, with Volume Boost at 150% on top.
        let result = try Self.render(channels: 6, mask: 0x60F, frequency: 1_000,
                                     enhancement: VividAudioEnhancement(boostPercent: 150, enhancedDialogue: true))
        XCTAssertTrue(result.usedFilter)
        let others = Self.toneLevel + 3.52 - 6
        Self.assertLevels(result.levels, [others, others, Self.toneLevel + 3.52, others, others, others])
    }

    func testEnhancedDialogueFavoursTheSpeechBandWithoutACentre() throws {
        let dialogue = VividAudioEnhancement(enhancedDialogue: true)
        for (frequency, gain) in [(3_000.0, 0.0), (1_000, -2), (60, -8)] {
            let result = try Self.render(channels: 2, mask: 0x3, frequency: frequency, enhancement: dialogue)
            XCTAssertTrue(result.usedFilter)
            Self.assertLevels(result.levels, [Self.toneLevel + gain, Self.toneLevel + gain], "\(frequency) Hz")
        }
    }

    // MARK: - Harness

    private struct Rendered {
        var levels: [Double]
        var usedFilter: Bool
    }

    private static func assertLevels(_ levels: [Double], _ expected: [Double], _ context: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(levels.count, expected.count, context, file: file, line: line)
        for (index, (level, target)) in zip(levels, expected).enumerated() {
            XCTAssertEqual(level, target, accuracy: tolerance, "channel \(index) \(context)", file: file, line: line)
        }
    }

    /// Plays a generated tone through Lucid and returns each output channel's RMS level in dBFS.
    private static func render(channels: Int, mask: UInt32, frequency: Double,
                               enhancement: VividAudioEnhancement) throws -> Rendered {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LucidAudioEnhancementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("tone.wav")
        let output = folder.appendingPathComponent("out.wav")
        try toneWAV(channels: channels, mask: mask, frequency: frequency).write(to: input)

        let handle = try XCTUnwrap(mpv_create())
        var options = [
            "config": "no", "terminal": "no", "vid": "no", "vo": "null",
            "ao": "pcm", "ao-pcm-file": output.path, "ao-pcm-waveheader": "yes",
            "audio-format": "float", "audio-channels": channels == 6 ? "5.1(side)" : "stereo",
            "audio-spdif": VividMPVAudio.spdifCodecs(rate: 1, enhancement: enhancement),
        ]
        for (name, value) in VividMPVAudio.enhancementOptions(enhancement) { options[name] = value }
        for (name, value) in options {
            XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, name, value), 0, "option \(name)")
        }
        XCTAssertGreaterThanOrEqual(mpv_request_log_messages(handle, "v"), 0)
        XCTAssertGreaterThanOrEqual(mpv_initialize(handle), 0)
        XCTAssertGreaterThanOrEqual(mpv_command_string(handle, "loadfile \"\(input.path)\""), 0)

        var problems: [String] = []
        var usedFilter = false
        var ended: mpv_end_file_reason?
        let deadline = Date().addingTimeInterval(30)
        while ended == nil, Date() < deadline {
            guard let event = mpv_wait_event(handle, 1)?.pointee else { continue }
            switch event.event_id {
            case MPV_EVENT_LOG_MESSAGE:
                guard let message = event.data?.load(as: mpv_event_log_message.self) else { break }
                let prefix = message.prefix.map { String(cString: $0) } ?? ""
                let level = message.level.map { String(cString: $0) } ?? ""
                let text = message.text.map { String(cString: $0) } ?? ""
                if level == "error" || level == "fatal" || text.contains("Disabling filter") {
                    problems.append("[\(prefix)] \(text)")
                }
                if prefix == "af", text.contains("lavfi") { usedFilter = true }
            case MPV_EVENT_END_FILE:
                ended = event.data?.load(as: mpv_event_end_file.self).reason
            default:
                break
            }
        }
        // Destroying the handle closes the file and writes its final header.
        mpv_terminate_destroy(handle)
        XCTAssertEqual(ended, MPV_END_FILE_REASON_EOF)
        XCTAssertEqual(problems, [])
        return Rendered(levels: try rmsLevels(of: Data(contentsOf: output)), usedFilter: usedFilter)
    }

    /// A 1.5 s, 48 kHz, 32-bit float tone with the same sine on every channel.
    private static func toneWAV(channels: Int, mask: UInt32, frequency: Double) -> Data {
        let rate = 48_000, frames = rate * 3 / 2
        var samples = Data(capacity: frames * channels * 4)
        for frame in 0..<frames {
            let value = Float32(0.125 * sin(2 * .pi * frequency * Double(frame) / Double(rate)))
            for _ in 0..<channels { withUnsafeBytes(of: value.bitPattern.littleEndian) { samples.append(contentsOf: $0) } }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(4 + 8 + 40 + 8 + samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(40))
        append(UInt16(0xFFFE)); append(UInt16(channels)); append(UInt32(rate))
        append(UInt32(rate * channels * 4)); append(UInt16(channels * 4)); append(UInt16(32))
        append(UInt16(22)); append(UInt16(32)); append(mask)
        // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
        data.append(contentsOf: [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        data.append(samples)
        return data
    }

    /// Each channel's RMS level in dBFS, skipping the first and last 0.2 s.
    private static func rmsLevels(of wav: Data) throws -> [Double] {
        func read<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
            wav.subdata(in: offset..<offset + MemoryLayout<T>.size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }.littleEndian
        }
        var offset = 12, channels = 0, bits = 0, rate = 0
        var samples: Data?
        while offset + 8 <= wav.count {
            let id = String(decoding: wav.subdata(in: offset..<offset + 4), as: UTF8.self)
            var size = Int(read(UInt32.self, at: offset + 4))
            let body = offset + 8
            if id == "fmt " {
                channels = Int(read(UInt16.self, at: body + 2))
                rate = Int(read(UInt32.self, at: body + 4))
                bits = Int(read(UInt16.self, at: body + 14))
            } else if id == "data" {
                if size == 0 || body + size > wav.count { size = wav.count - body }
                samples = wav.subdata(in: body..<body + size)
                break
            }
            offset = body + size + (size & 1)
        }
        let pcm = try XCTUnwrap(samples, "no data chunk")
        XCTAssertEqual(bits, 32, "expected 32-bit float output")
        let frames = pcm.count / (4 * max(channels, 1))
        let skip = rate / 5
        XCTAssertGreaterThan(frames, skip * 3, "output too short")
        var sums = [Double](repeating: 0, count: channels)
        pcm.withUnsafeBytes { raw in
            for frame in skip..<(frames - skip) {
                for channel in 0..<channels {
                    let bits = raw.loadUnaligned(fromByteOffset: (frame * channels + channel) * 4, as: UInt32.self)
                    let value = Double(Float32(bitPattern: UInt32(littleEndian: bits)))
                    sums[channel] += value * value
                }
            }
        }
        let counted = Double(frames - 2 * skip)
        return sums.map { 10 * log10(max($0 / counted, 1e-20)) }
    }
}
