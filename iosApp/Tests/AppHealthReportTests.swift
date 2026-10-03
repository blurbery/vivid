import XCTest
@testable import Vivid

/// Health reports can be shared off the device, so redaction and the
/// allow-list are the high-risk part. All inputs here are synthetic.
final class AppHealthReportTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        DiagLog.resetSensitiveHostsForTesting()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppHealthReportTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        DiagLog.resetSensitiveHostsForTesting()
        super.tearDown()
    }

    // MARK: - MetricKit summaries

    private static let binaryUUID = "1B2C3D4E-5F60-4718-9A0B-C1D2E3F40516"

    private func callStackJSON(extraFrameKey: Bool = true) -> Data {
        var frame: [String: Any] = [
            "binaryUUID": Self.binaryUUID,
            "binaryName": "Vivid",
            "offsetIntoBinaryTextSegment": 123_456,
            "address": 4_295_000_000,
            "sampleCount": 3,
            "subFrames": [[
                "binaryUUID": "2B2C3D4E-5F60-4718-9A0B-C1D2E3F40517",
                "binaryName": "libsystem_kernel.dylib",
                "offsetIntoBinaryTextSegment": 42,
                "address": 4_296_000_000,
                "sampleCount": 3,
            ]],
        ]
        if extraFrameKey { frame["filePath"] = "/private/var/mobile/Media/Some.Movie.2019.mkv" }
        let tree: [String: Any] = [
            "callStackPerThread": true,
            "callStacks": [["threadAttributed": true, "callStackRootFrames": [frame]]],
            "unexpectedTopLevel": "drop me",
        ]
        return try! JSONSerialization.data(withJSONObject: tree)
    }

    private func crashInput() -> MetricKitDiagnosticInput {
        MetricKitDiagnosticInput(
            kind: .crash,
            payloadEnd: Date(timeIntervalSince1970: 1_790_000_000),
            appVersion: "0.14.3",
            appBuild: "42",
            osVersion: "iPhone OS 18.1 (22B83)",
            deviceType: "iPhone16,2",
            values: [
                "signal": .int(11),
                "exception_type": .int(1),
                "region_format": .string("AU"),
                "pid": .int(1234),
            ],
            text: [
                "termination_reason": "Namespace SIGNAL, Code 11",
                "exception_message": "Request to https://media.example.com/Videos/abc/stream failed, Authorization: Bearer abcdefghijklmnop1234",
                "virtual_memory_region_info": "mapped file /private/var/mobile/Containers/Data/Some.Movie.2019.mkv",
            ],
            callStackTreeJSON: callStackJSON()
        )
    }

    func testCallStackKeepsSymbolicationFieldsAndDropsUnknownKeys() throws {
        let report = MetricKitReportSummariser.report(from: crashInput())
        let encoded = String(decoding: try AppHealthStore.encoder.encode(report), as: UTF8.self)

        XCTAssertTrue(encoded.contains(Self.binaryUUID), "binary UUIDs are needed to symbolicate")
        XCTAssertTrue(encoded.contains("123456"))
        XCTAssertTrue(encoded.contains("libsystem_kernel.dylib"))
        XCTAssertFalse(encoded.contains("filePath"))
        XCTAssertFalse(encoded.contains("Some.Movie"))
        XCTAssertFalse(encoded.contains("unexpectedTopLevel"))
    }

    func testFreeTextIsRedactedAndUnlistedFieldsAreDropped() throws {
        let report = MetricKitReportSummariser.report(from: crashInput())
        let encoded = String(decoding: try AppHealthStore.encoder.encode(report), as: UTF8.self)

        XCTAssertEqual(report.details["signal"], .int(11))
        XCTAssertNotNil(report.details["termination_reason"])
        XCTAssertNil(report.details["region_format"])
        XCTAssertNil(report.details["pid"])
        XCTAssertNil(report.details["virtual_memory_region_info"])
        XCTAssertFalse(encoded.contains("media.example.com"))
        XCTAssertFalse(encoded.contains("abcdefghijklmnop1234"))
        XCTAssertFalse(encoded.contains("\"AU\""))
    }

    func testOddBinaryNamesAreReplaced() {
        XCTAssertEqual(MetricKitReportSummariser.binaryNameToken("Vivid"), "Vivid")
        XCTAssertEqual(MetricKitReportSummariser.binaryNameToken("/Users/someone/Vivid"), "[redacted]")
        XCTAssertEqual(MetricKitReportSummariser.binaryNameToken(""), "[redacted]")
    }

    func testSamePayloadProducesSameReportID() {
        let first = MetricKitReportSummariser.report(from: crashInput())
        let second = MetricKitReportSummariser.report(from: crashInput())
        XCTAssertEqual(first.id, second.id)

        var other = crashInput()
        other.payloadEnd = other.payloadEnd.addingTimeInterval(86_400)
        XCTAssertNotEqual(MetricKitReportSummariser.report(from: other).id, first.id)
    }

    // MARK: - Exit marker

    private func marker(
        build: String = "42",
        bootTime: Int = 1_000,
        debugger: Bool = false,
        hang: Int? = nil
    ) -> AppHealthExitMarker {
        AppHealthExitMarker(
            build: build,
            bootTime: bootTime,
            armedAt: Date(timeIntervalSince1970: 1_790_000_000),
            debuggerAttached: debugger,
            context: AppHealthContextSnapshot(phase: "browsing", playerOpen: true, playMethod: "DirectPlay", memoryWarnings: 2),
            hangInProgressMs: hang
        )
    }

    func testExitMarkerVerdicts() {
        XCTAssertEqual(AppHealthExitMarker.evaluate(nil, currentBuild: "42", currentBootTime: 1_000), .none)
        XCTAssertEqual(
            AppHealthExitMarker.evaluate(marker(debugger: true), currentBuild: "42", currentBootTime: 1_000),
            .discarded(reason: "debugger")
        )
        XCTAssertEqual(
            AppHealthExitMarker.evaluate(marker(), currentBuild: "43", currentBootTime: 1_000),
            .discarded(reason: "build_changed")
        )
        XCTAssertEqual(
            AppHealthExitMarker.evaluate(marker(), currentBuild: "42", currentBootTime: 1_100),
            .discarded(reason: "device_restarted")
        )
        // Small clock corrections are not a restart.
        XCTAssertEqual(
            AppHealthExitMarker.evaluate(marker(), currentBuild: "42", currentBootTime: 1_003),
            .unexpectedExit(marker())
        )
    }

    func testExitDuringHangIsLabelledAsHang() {
        let app = AppHealthAppInfo(version: "0.14.3", build: "42", os: "tvOS 26.0.0", device: "AppleTV14,1")
        let report = marker(hang: 4_500).report(detectedAt: Date(), app: app)
        XCTAssertEqual(report.kind, .unexpectedExit)
        XCTAssertEqual(report.details["likely_cause"], .string("hang"))
        XCTAssertEqual(report.details["hang_in_progress_ms"], .int(4_500))
        XCTAssertEqual(report.context?["player_open"], .bool(true))
        XCTAssertEqual(report.context?["play_method"], .string("DirectPlay"))
    }

    func testPlayMethodTokenRejectsAnythingButShortWords() {
        XCTAssertEqual(AppHealthContextSnapshot.playMethodToken("DirectPlay"), "DirectPlay")
        XCTAssertEqual(AppHealthContextSnapshot.playMethodToken("remux_hls"), "remux_hls")
        XCTAssertNil(AppHealthContextSnapshot.playMethodToken("https://media.example.com/x"))
        XCTAssertNil(AppHealthContextSnapshot.playMethodToken(String(repeating: "a", count: 40)))
        XCTAssertNil(AppHealthContextSnapshot.playMethodToken(nil))
    }

    // MARK: - Store

    /// MetricKit hangs are kept one per report, so these exercise the limits
    /// without repeat counting.
    private func hangReport(at date: Date, seed: String, padding: Int = 0) -> AppHealthReport {
        AppHealthReport(
            kind: .hang,
            source: .metricKit,
            recordedAt: date,
            app: AppHealthAppInfo(version: "0.14.3", build: "42", os: "iOS 18.1.0", device: "iPhone16,2"),
            details: ["duration_ms": .int(1_500), "padding": .string(String(repeating: "x", count: padding))],
            fingerprintSeed: seed
        )
    }

    func testStoreSkipsDuplicatesAndKeepsNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(directory: directory, limits: .init(maxReports: 10, maxBytes: 1_000_000, maxAge: 86_400), now: { now })
        XCTAssertTrue(store.add(hangReport(at: now.addingTimeInterval(-60), seed: "a")))
        XCTAssertFalse(store.add(hangReport(at: now.addingTimeInterval(-60), seed: "a")))
        XCTAssertTrue(store.add(hangReport(at: now, seed: "b")))
        XCTAssertEqual(store.reports().map(\.recordedAt), [now, now.addingTimeInterval(-60)])
    }

    func testStoreEnforcesCountAgeAndSizeLimits() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(directory: directory, limits: .init(maxReports: 2, maxBytes: 1_000_000, maxAge: 3_600), now: { now })
        store.add(hangReport(at: now.addingTimeInterval(-7_200), seed: "expired"))
        store.add(hangReport(at: now.addingTimeInterval(-30), seed: "older"))
        store.add(hangReport(at: now.addingTimeInterval(-20), seed: "middle"))
        store.add(hangReport(at: now.addingTimeInterval(-10), seed: "newest"))
        XCTAssertEqual(store.reports().map(\.recordedAt), [now.addingTimeInterval(-10), now.addingTimeInterval(-20)])

        let small = AppHealthStore(
            directory: directory.appendingPathComponent("small"),
            limits: .init(maxReports: 10, maxBytes: 3_000, maxAge: 3_600),
            now: { now }
        )
        small.add(hangReport(at: now.addingTimeInterval(-20), seed: "big-old", padding: 1_500))
        small.add(hangReport(at: now.addingTimeInterval(-10), seed: "big-new", padding: 1_500))
        XCTAssertEqual(small.reports().count, 1, "the older report is dropped to stay under the byte limit")
    }

    func testRemoveAllAndExport() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(directory: directory, limits: .init(maxReports: 10, maxBytes: 1_000_000, maxAge: 86_400), now: { now })
        store.add(hangReport(at: now, seed: "a"))
        let export = try AppHealthStore.decoder.decode(AppHealthExport.self, from: store.exportData(store.reports()))
        XCTAssertEqual(export.reports.count, 1)
        XCTAssertEqual(export.format, AppHealthReport.formatVersion)

        store.removeAll()
        XCTAssertTrue(store.reports().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Grouping

    private func exitReport(at date: Date, phase: String, playerOpen: Bool = false) -> AppHealthReport {
        AppHealthReport(
            kind: .unexpectedExit,
            source: .exitMarker,
            recordedAt: date,
            app: AppHealthAppInfo(version: "0.14.3", build: "42", os: "iOS 18.1.0", device: "iPhone16,2"),
            details: ["likely_cause": .string("unknown")],
            context: ["phase": .string(phase), "player_open": .bool(playerOpen)],
            fingerprintSeed: "\(date.timeIntervalSince1970)"
        )
    }

    func testSimilarReportsShareAGroupNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let groups = AppHealthReportGroup.grouping([
            exitReport(at: now.addingTimeInterval(-300), phase: "launching"),
            exitReport(at: now, phase: "launching"),
            exitReport(at: now.addingTimeInterval(-100), phase: "browsing", playerOpen: true),
        ])
        XCTAssertEqual(groups.map(\.summary), ["Closed unexpectedly while opening (cause unknown)", "Closed unexpectedly during playback (cause unknown)"])
        XCTAssertEqual(groups[0].reports.count, 2)
        XCTAssertEqual(groups[0].latest.recordedAt, now)
    }

    func testUnsentExcludesSentReports() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = exitReport(at: now, phase: "launching")
        let second = exitReport(at: now.addingTimeInterval(-600), phase: "launching")
        XCTAssertEqual(AppHealthSendState.unsent(in: [first, second], sentIDs: []).count, 2)
        XCTAssertEqual(AppHealthSendState.unsent(in: [first, second], sentIDs: [second.id]).map(\.id), [first.id])
    }

    // MARK: - Retention and recent events

    private func report(_ kind: AppHealthReport.Kind, at date: Date, seed: String) -> AppHealthReport {
        AppHealthReport(
            kind: kind,
            source: kind == .appError ? .app : .exitMarker,
            recordedAt: date,
            app: AppHealthAppInfo(version: "0.14.3", build: "42", os: "iOS 18.1.0", device: "iPhone16,2"),
            // A distinct request per seed, so app errors are not counted as
            // repeats of one another.
            details: ["tag": .string("HTTP"), "method": .string("GET"), "path": .string("/api/\(seed)")],
            fingerprintSeed: seed
        )
    }

    func testAppErrorsAreDroppedBeforeCrashes() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(
            directory: directory,
            limits: .init(maxReports: 3, maxBytes: 1_000_000, maxAge: 86_400, maxAppErrors: 5),
            now: { now }
        )
        store.add(report(.crash, at: now.addingTimeInterval(-500), seed: "old-crash"))
        store.add(report(.appError, at: now.addingTimeInterval(-10), seed: "error-1"))
        store.add(report(.appError, at: now.addingTimeInterval(-5), seed: "error-2"))
        store.add(report(.hang, at: now, seed: "hang"))
        let kinds = store.reports().map(\.kind)
        XCTAssertTrue(kinds.contains(.crash), "the oldest crash outlives newer app errors")
        XCTAssertTrue(kinds.contains(.hang))
        XCTAssertEqual(kinds.filter { $0 == .appError }.count, 1)
    }

    func testAppErrorsHaveTheirOwnCap() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(
            directory: directory,
            limits: .init(maxReports: 20, maxBytes: 1_000_000, maxAge: 86_400, maxAppErrors: 2),
            now: { now }
        )
        for index in 0..<4 {
            store.add(report(.appError, at: now.addingTimeInterval(Double(index)), seed: "error-\(index)"))
        }
        XCTAssertEqual(store.reports().count, 2)
    }

    func testRecentEventLinesAreReadableAndRedacted() throws {
        let rendered = try XCTUnwrap(DiagLog.renderedLine(
            level: .warning, category: .network, tag: "HTTP",
            message: "request failed for https://media.example.com/Videos/abc/Movie.Name.2019.mkv",
            attrs: ["status": .int(500)],
            timestamp: Date(timeIntervalSince1970: 1_790_000_000), captureSessionID: "-"
        ))
        let line = try XCTUnwrap(AppHealthTrail.readableLine(rendered))
        XCTAssertTrue(line.contains("W network/HTTP request failed"))
        XCTAssertTrue(line.hasSuffix("status=500"))
        XCTAssertFalse(line.contains("media.example.com"))
        XCTAssertFalse(line.contains("Movie.Name"))
    }

    // MARK: - Titles and false positives

    private func crash(signal: Int, foreground: Bool, playerOpen: Bool) -> AppHealthReport {
        AppHealthReport(
            kind: .crash,
            source: .exitMarker,
            recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
            app: AppHealthAppInfo(version: "0.14.3", build: "42", os: "tvOS 26.0.0", device: "AppleTV14,1"),
            details: ["signal": .int(signal), "foreground": .bool(foreground), "pid": .int(321)],
            context: ["phase": .string("browsing"), "player_open": .bool(playerOpen)],
            fingerprintSeed: "\(signal)|\(foreground)|\(playerOpen)"
        )
    }

    func testCrashTitlesSayWhatWasHappening() {
        let playback = crash(signal: 11, foreground: true, playerOpen: true)
        XCTAssertEqual(playback.groupSummary, "Crashed during playback: invalid memory access")
        XCTAssertEqual(playback.technicalCode, "SIGSEGV")
        XCTAssertEqual(crash(signal: 5, foreground: true, playerOpen: false).groupSummary,
                       "Crashed while browsing: internal check failed")
        XCTAssertEqual(crash(signal: 5, foreground: false, playerOpen: true).groupSummary,
                       "Crashed during playback: internal check failed")
        XCTAssertEqual(crash(signal: 6, foreground: false, playerOpen: false).groupSummary,
                       "Crashed in the background: app stopped itself")
        XCTAssertNotEqual(playback.groupKey, crash(signal: 11, foreground: true, playerOpen: false).groupKey)
    }

    func testOnlyAppSideNetworkErrorsAreReported() {
        XCTAssertTrue(AppHealthMonitor.isAppSideNetworkError(["outcome": .string("decode_failed")]))
        XCTAssertTrue(AppHealthMonitor.isAppSideNetworkError(["status": .int(400)]))
        XCTAssertTrue(AppHealthMonitor.isAppSideNetworkError(["status": .int(422)]))
        for status in [401, 403, 404, 408, 429, 500, 502, 503] {
            XCTAssertFalse(AppHealthMonitor.isAppSideNetworkError(["status": .int(status)]), "status \(status)")
        }
        XCTAssertFalse(AppHealthMonitor.isAppSideNetworkError([
            "outcome": .string("transport_error"), "error_code": .string("timed_out"),
        ]))
    }

    func testPlaybackFailuresOutsideTheAppAreSkipped() {
        var context = AppHealthContextSnapshot(phase: "browsing", playerOpen: true)
        XCTAssertTrue(AppHealthMonitor.shouldReportPlaybackFailure(reason: "decode", context: context))
        XCTAssertTrue(AppHealthMonitor.shouldReportPlaybackFailure(reason: "network", context: context))
        XCTAssertFalse(AppHealthMonitor.shouldReportPlaybackFailure(reason: "cancelled", context: context))
        context.serverReachable = false
        XCTAssertFalse(AppHealthMonitor.shouldReportPlaybackFailure(reason: "network", context: context))
        XCTAssertFalse(AppHealthMonitor.shouldReportPlaybackFailure(reason: "timeout", context: context))
        XCTAssertTrue(AppHealthMonitor.shouldReportPlaybackFailure(reason: "decode", context: context))
        context.serverReachable = true
        context.deviceOnline = false
        XCTAssertFalse(AppHealthMonitor.shouldReportPlaybackFailure(reason: "network", context: context))
    }

    func testMetricKitCrashMergesIntoTheSameProcessReport() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(directory: directory, limits: .init(maxReports: 10, maxBytes: 1_000_000, maxAge: 86_400), now: { now })
        let existing = crash(signal: 11, foreground: true, playerOpen: true)
        store.add(existing)
        let metricKit = MetricKitReportSummariser.report(from: crashInput())
        XCTAssertFalse(store.merge(metricKitCrash: metricKit, pid: 999))
        XCTAssertTrue(store.merge(metricKitCrash: metricKit, pid: 321))
        let reports = store.reports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].id, existing.id)
        XCTAssertNotNil(reports[0].callStackTree)
        XCTAssertEqual(reports[0].context?["player_open"], .bool(true))
        XCTAssertFalse(store.merge(metricKitCrash: metricKit, pid: 321), "a report only takes one stack")
    }

    func testIssueIDMatchesTheSameProblemAcrossDevicesAndDays() {
        let first = crash(signal: 11, foreground: true, playerOpen: true)
        let laterOnAnotherDevice = AppHealthReport(
            kind: .crash,
            source: .exitMarker,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            app: AppHealthAppInfo(version: "0.15.0", build: "50", os: "iOS 18.2.0", device: "iPhone17,1"),
            details: ["signal": .int(11), "foreground": .bool(true), "pid": .int(777)],
            context: ["phase": .string("browsing"), "player_open": .bool(true), "memory_warnings": .int(2)],
            fingerprintSeed: "other"
        )
        XCTAssertEqual(first.issueID, laterOnAnotherDevice.issueID)
        XCTAssertTrue(first.issueID.hasPrefix("VD-"))
        XCTAssertEqual(first.issueID.count, 9)
        XCTAssertNotEqual(first.issueID, crash(signal: 11, foreground: true, playerOpen: false).issueID)
        XCTAssertNotEqual(first.issueID, crash(signal: 5, foreground: true, playerOpen: true).issueID)
    }

    func testHangDurationDoesNotSplitIssueIDs() {
        func hang(_ ms: Int) -> AppHealthReport {
            AppHealthReport(
                kind: .hang, source: .watchdog, recordedAt: Date(),
                app: AppHealthAppInfo(version: "0.14.3", build: "42", os: "iOS 18.1.0", device: "iPhone16,2"),
                details: ["duration_ms": .int(ms)],
                context: ["phase": .string("browsing"), "player_open": .bool(true)],
                fingerprintSeed: "\(ms)"
            )
        }
        XCTAssertEqual(hang(1_200).issueID, hang(4_800).issueID)
    }

    // MARK: - Repeats and request-specific issue IDs

    private func settingsError(
        at date: Date,
        path: String = "/api/v2/settings/values/{id}",
        method: String = "PUT",
        app: AppHealthAppInfo = AppHealthAppInfo(version: "0.14.3", build: "54", os: "iOS 26.0", device: "iPhone17,1")
    ) -> AppHealthReport {
        AppHealthReport(
            kind: .appError,
            source: .app,
            recordedAt: date,
            app: app,
            details: [
                "category": .string("network"), "tag": .string("HTTP"),
                "method": .string(method), "path": .string(path), "status": .int(422),
            ],
            context: ["phase": .string("launching")],
            fingerprintSeed: "\(date.timeIntervalSince1970)-\(app.device)-\(method) \(path)"
        )
    }

    func testRepeatsWithinADayAreCountedOnOneReport() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(directory: directory, limits: .init(maxReports: 10, maxBytes: 1_000_000, maxAge: 7 * 86_400), now: { now })
        XCTAssertTrue(store.add(settingsError(at: now.addingTimeInterval(-3_600))))
        XCTAssertFalse(store.add(settingsError(at: now.addingTimeInterval(-60))), "a repeat does not add a report")
        XCTAssertFalse(store.add(settingsError(at: now)))
        let reports = store.reports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].occurrenceCount, 3)
        XCTAssertEqual(reports[0].recordedAt, now.addingTimeInterval(-3_600))
        XCTAssertEqual(reports[0].lastOccurredAt, now)
        XCTAssertEqual(AppHealthReportGroup.grouping(reports)[0].occurrenceCount, 3)
    }

    func testSameReportAddedTwiceIsNotCountedAsARepeat() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(directory: directory, limits: .init(maxReports: 10, maxBytes: 1_000_000, maxAge: 86_400), now: { now })
        let report = settingsError(at: now)
        XCTAssertTrue(store.add(report))
        XCTAssertFalse(store.add(report))
        XCTAssertEqual(store.reports().map(\.occurrenceCount), [1])
    }

    func testRepeatAfterADayAddsANewReport() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = AppHealthStore(directory: directory, limits: .init(maxReports: 10, maxBytes: 1_000_000, maxAge: 7 * 86_400), now: { now })
        XCTAssertTrue(store.add(settingsError(at: now.addingTimeInterval(-AppHealthStore.repeatWindow - 60))))
        XCTAssertTrue(store.add(settingsError(at: now)))
        XCTAssertEqual(store.reports().map(\.occurrenceCount), [1, 1])
    }

    func testDifferentRequestsGetDifferentIssueIDs() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let settings = settingsError(at: now)
        let push = settingsError(at: now, path: "/api/v2/devices/push/apple", method: "POST")
        XCTAssertNotEqual(settings.issueID, push.issueID)
        XCTAssertNotEqual(settings.groupKey, push.groupKey)
        XCTAssertEqual(settings.groupSummary, "Server rejected a settings change")
        XCTAssertEqual(push.groupSummary, "Server rejected a request")
        XCTAssertEqual(settings.technicalCode, "HTTP · HTTP 422 · PUT /api/v2/settings/values/{id}")

        let store = AppHealthStore(directory: directory, limits: .init(maxReports: 10, maxBytes: 1_000_000, maxAge: 86_400), now: { now })
        XCTAssertTrue(store.add(settings))
        XCTAssertTrue(store.add(push), "a different request is its own report")
    }

    func testSameRequestGetsTheSameIssueIDAcrossDevicesAndLaunches() {
        let first = settingsError(at: Date(timeIntervalSince1970: 1_790_000_000))
        let later = settingsError(
            at: Date(timeIntervalSince1970: 1_800_000_000),
            app: AppHealthAppInfo(version: "0.15.0", build: "60", os: "iOS 26.1", device: "iPad16,3")
        )
        XCTAssertNotEqual(first.id, later.id)
        XCTAssertEqual(first.issueID, later.issueID)
        XCTAssertEqual(first.groupKey, later.groupKey)
    }

    func testDecodeFailuresKeepTheirTitle() {
        let report = AppHealthReport(
            kind: .appError, source: .app, recordedAt: Date(),
            app: AppHealthAppInfo(version: "0.14.3", build: "54", os: "iOS 26.0", device: "iPhone17,1"),
            details: ["tag": .string("Decode"), "path": .string("/api/v2/settings/values"), "outcome": .string("decode_failed")],
            fingerprintSeed: "decode"
        )
        XCTAssertEqual(report.groupSummary, "Couldn't read a server response")
    }

    // MARK: - Settings writes the server refuses

    func testPermanentSettingsRejectionsAreDropped() {
        let permanent: [Error] = [
            HTTPError.http(statusCode: 422, body: nil),
            HTTPError.http(statusCode: 400, body: nil),
            SettingsAPIError.invalidValue(message: "bad"),
        ]
        for error in permanent {
            XCTAssertTrue(UICustomizationPreferences.isPermanentRejection(error), "\(error)")
        }
        let retryable: [Error] = [
            HTTPError.http(statusCode: 401, body: nil),
            HTTPError.http(statusCode: 408, body: nil),
            HTTPError.http(statusCode: 409, body: nil),
            HTTPError.http(statusCode: 429, body: nil),
            SettingsAPIError.transport(description: "offline"),
            SettingsAPIError.serverUpgradeRequired,
        ]
        for error in retryable {
            XCTAssertFalse(UICustomizationPreferences.isPermanentRejection(error), "\(error)")
        }
    }

    // MARK: - Notification deep links

    func testNotificationDeepLinksOnlyFollowVividLinks() {
        let key = NotificationDeepLinkCoordinator.urlUserInfoKey
        XCTAssertEqual(NotificationDeepLinkCoordinator.deepLinkURL(from: [key: "vivid://downloads"]), URL(string: "vivid://downloads"))
        XCTAssertEqual(NotificationDeepLinkCoordinator.deepLinkURL(from: [key: " vivid://downloads\n"]), URL(string: "vivid://downloads"))
        XCTAssertNil(NotificationDeepLinkCoordinator.deepLinkURL(from: [key: "https://example.com/downloads"]))
        XCTAssertNil(NotificationDeepLinkCoordinator.deepLinkURL(from: [key: "silo://item/1"]))
        XCTAssertNil(NotificationDeepLinkCoordinator.deepLinkURL(from: [:]))
    }
}
