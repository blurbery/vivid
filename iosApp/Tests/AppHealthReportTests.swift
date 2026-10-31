import XCTest
@testable import Vivid

/// Health reports: what MetricKit and the exit marker produce, how the store
/// keeps, prunes, counts and exports them, and how problems are titled.
final class AppHealthReportTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let app = AppHealthAppInfo(version: "0.14.3", build: "42", os: "iOS 18.1.0", device: "iPhone16,2")
    private static let appleTVApp = AppHealthAppInfo(version: "0.14.3", build: "42", os: "tvOS 26.0.0", device: "AppleTV14,1")
    private static let middleDot = " \u{00B7} "

    private var folder: URL!
    private var now: Date { Self.now }

    override func setUp() {
        super.setUp()
        DiagLog.resetSensitiveHostsForTesting()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppHealthReportTests-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        DiagLog.resetSensitiveHostsForTesting()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeStore(
        reports: Int, bytes: Int, age: TimeInterval, appErrors: Int = 5, in directory: URL? = nil
    ) -> AppHealthStore {
        AppHealthStore(
            directory: directory ?? folder,
            limits: .init(maxReports: reports, maxBytes: bytes, maxAge: age, maxAppErrors: appErrors),
            now: { AppHealthReportTests.now })
    }

    private func callStackJSON() throws -> Data {
        let child: [String: Any] = [
            "binaryUUID": "2B2C3D4E-5F60-4718-9A0B-C1D2E3F40517",
            "binaryName": "libsystem_kernel.dylib",
            "offsetIntoBinaryTextSegment": 42,
            "address": 4_296_000_000,
            "sampleCount": 3,
        ]
        let frame: [String: Any] = [
            "binaryUUID": "1B2C3D4E-5F60-4718-9A0B-C1D2E3F40516",
            "binaryName": "Vivid",
            "offsetIntoBinaryTextSegment": 123_456,
            "address": 4_295_000_000,
            "sampleCount": 3,
            "filePath": "/private/var/mobile/Media/Some.Movie.2019.mkv",
            "subFrames": [child],
        ]
        return try JSONSerialization.data(withJSONObject: [
            "callStackPerThread": true,
            "callStacks": [["threadAttributed": true, "callStackRootFrames": [frame]]],
            "unexpectedTopLevel": "drop me",
        ] as [String: Any])
    }

    private func crashInput() throws -> MetricKitDiagnosticInput {
        MetricKitDiagnosticInput(
            kind: .crash,
            payloadEnd: now,
            appVersion: "0.14.3",
            appBuild: "42",
            osVersion: "iPhone OS 18.1 (22B83)",
            deviceType: "iPhone16,2",
            values: ["signal": .int(11), "exception_type": .int(1), "region_format": .string("AU"), "pid": .int(1_234)],
            text: [
                "termination_reason": "Namespace SIGNAL, Code 11",
                "exception_message": "Request to https://media.example.com/Videos/abc/stream failed, Authorization: Bearer abcdefghijklmnop1234",
                "virtual_memory_region_info": "mapped file /private/var/mobile/Containers/Data/Some.Movie.2019.mkv",
            ],
            callStackTreeJSON: try callStackJSON())
    }

    private func exitMarker(build: String = "42", bootTime: Int = 1_000, debugger: Bool = false, hangMs: Int? = nil) -> AppHealthExitMarker {
        AppHealthExitMarker(
            build: build,
            bootTime: bootTime,
            armedAt: now,
            debuggerAttached: debugger,
            context: AppHealthContextSnapshot(phase: "browsing", playerOpen: true, playMethod: "DirectPlay", memoryWarnings: 2),
            hangInProgressMs: hangMs)
    }

    private func metricKitHang(at date: Date, seed: String, padding: Int = 0) -> AppHealthReport {
        AppHealthReport(
            kind: .hang, source: .metricKit, recordedAt: date, app: Self.app,
            details: ["duration_ms": .int(1_500), "padding": .string(String(repeating: "x", count: padding))],
            fingerprintSeed: seed)
    }

    private func exitReport(at date: Date, phase: String, playerOpen: Bool = false) -> AppHealthReport {
        AppHealthReport(
            kind: .unexpectedExit, source: .exitMarker, recordedAt: date, app: Self.app,
            details: ["likely_cause": .string("unknown")],
            context: ["phase": .string(phase), "player_open": .bool(playerOpen)],
            fingerprintSeed: String(date.timeIntervalSince1970))
    }

    private func report(_ kind: AppHealthReport.Kind, at date: Date, seed: String) -> AppHealthReport {
        AppHealthReport(
            kind: kind, source: kind == .appError ? .app : .exitMarker, recordedAt: date, app: Self.app,
            details: ["tag": .string("HTTP"), "method": .string("GET"), "path": .string("/api/" + seed)],
            fingerprintSeed: seed)
    }

    private func crashReport(signal: Int, foreground: Bool, playerOpen: Bool) -> AppHealthReport {
        AppHealthReport(
            kind: .crash, source: .exitMarker, recordedAt: now, app: Self.appleTVApp,
            details: ["signal": .int(signal), "foreground": .bool(foreground), "pid": .int(321)],
            context: ["phase": .string("browsing"), "player_open": .bool(playerOpen)],
            fingerprintSeed: "\(signal)|\(foreground)|\(playerOpen)")
    }

    private func settingsError(
        at date: Date,
        path: String = "/api/v2/settings/values/{id}",
        method: String = "PUT",
        app: AppHealthAppInfo = AppHealthAppInfo(version: "0.14.3", build: "54", os: "iOS 26.0", device: "iPhone17,1")
    ) -> AppHealthReport {
        AppHealthReport(
            kind: .appError, source: .app, recordedAt: date, app: app,
            details: [
                "category": .string("network"), "tag": .string("HTTP"), "method": .string(method),
                "path": .string(path), "status": .int(422),
            ],
            context: ["phase": .string("launching")],
            fingerprintSeed: "\(date.timeIntervalSince1970)-\(app.device)-\(method) \(path)")
    }

    private func downloadReport(_ failure: DownloadFailureReport, at date: Date) -> AppHealthReport {
        AppHealthReport(
            kind: .downloadFailure, source: .app, recordedAt: date, app: Self.app,
            details: failure.details, fingerprintSeed: String(date.timeIntervalSince1970))
    }

    // MARK: - Summarising MetricKit diagnostics

    func testCallStackKeepsSymbolicationFieldsAndDropsUnknownKeys() throws {
        let report = MetricKitReportSummariser.report(from: try crashInput())
        let text = String(decoding: try AppHealthStore.encoder.encode(report), as: UTF8.self)
        for kept in ["1B2C3D4E-5F60-4718-9A0B-C1D2E3F40516", "123456", "libsystem_kernel.dylib"] {
            XCTAssertTrue(text.contains(kept), kept)
        }
        for dropped in ["filePath", "Some.Movie", "unexpectedTopLevel"] {
            XCTAssertFalse(text.contains(dropped), dropped)
        }
    }

    func testFreeTextIsRedactedAndUnlistedFieldsAreDropped() throws {
        let report = MetricKitReportSummariser.report(from: try crashInput())
        let text = String(decoding: try AppHealthStore.encoder.encode(report), as: UTF8.self)
        XCTAssertEqual(report.details["signal"], .int(11))
        XCTAssertNotNil(report.details["termination_reason"])
        XCTAssertNil(report.details["region_format"])
        XCTAssertNil(report.details["pid"])
        XCTAssertNil(report.details["virtual_memory_region_info"])
        XCTAssertFalse(text.contains("media.example.com"))
        XCTAssertFalse(text.contains("abcdefghijklmnop1234"))
        XCTAssertFalse(text.contains("\"AU\""))
    }

    func testOddBinaryNamesAreReplaced() {
        XCTAssertEqual(MetricKitReportSummariser.binaryNameToken("Vivid"), "Vivid")
        XCTAssertEqual(MetricKitReportSummariser.binaryNameToken("/Users/someone/Vivid"), "[redacted]")
        XCTAssertEqual(MetricKitReportSummariser.binaryNameToken(""), "[redacted]")
    }

    func testSamePayloadProducesSameReportID() throws {
        let input = try crashInput()
        XCTAssertEqual(MetricKitReportSummariser.report(from: input).id, MetricKitReportSummariser.report(from: input).id)
        var later = input
        later.payloadEnd = input.payloadEnd.addingTimeInterval(86_400)
        XCTAssertNotEqual(MetricKitReportSummariser.report(from: later).id, MetricKitReportSummariser.report(from: input).id)
    }

    // MARK: - Exit markers and context tokens

    func testExitMarkerVerdicts() {
        XCTAssertEqual(AppHealthExitMarker.evaluate(nil, currentBuild: "42", currentBootTime: 1_000), .none)
        XCTAssertEqual(AppHealthExitMarker.evaluate(exitMarker(debugger: true), currentBuild: "42", currentBootTime: 1_000),
                       .discarded(reason: "debugger"))
        XCTAssertEqual(AppHealthExitMarker.evaluate(exitMarker(), currentBuild: "43", currentBootTime: 1_000),
                       .discarded(reason: "build_changed"))
        XCTAssertEqual(AppHealthExitMarker.evaluate(exitMarker(), currentBuild: "42", currentBootTime: 1_100),
                       .discarded(reason: "device_restarted"))
        XCTAssertEqual(AppHealthExitMarker.evaluate(exitMarker(), currentBuild: "42", currentBootTime: 1_003),
                       .unexpectedExit(exitMarker()))
    }

    func testExitDuringHangIsLabelledAsHang() {
        let report = exitMarker(hangMs: 4_500).report(detectedAt: Date(), app: Self.appleTVApp)
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

    // MARK: - Storing, limits and export

    func testStoreSkipsDuplicatesAndKeepsNewestFirst() {
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 86_400)
        XCTAssertTrue(store.add(metricKitHang(at: now - 60, seed: "a")))
        XCTAssertFalse(store.add(metricKitHang(at: now - 60, seed: "a")))
        XCTAssertTrue(store.add(metricKitHang(at: now, seed: "b")))
        XCTAssertEqual(store.reports().map(\.recordedAt), [now, now - 60])
    }

    func testStoreEnforcesCountAgeAndSizeLimits() {
        let counted = makeStore(reports: 2, bytes: 1_000_000, age: 3_600)
        counted.add(metricKitHang(at: now - 7_200, seed: "expired"))
        counted.add(metricKitHang(at: now - 30, seed: "older"))
        counted.add(metricKitHang(at: now - 20, seed: "middle"))
        counted.add(metricKitHang(at: now - 10, seed: "newest"))
        XCTAssertEqual(counted.reports().map(\.recordedAt), [now - 10, now - 20])

        let small = makeStore(reports: 10, bytes: 3_000, age: 3_600, in: folder.appendingPathComponent("small", isDirectory: true))
        small.add(metricKitHang(at: now - 20, seed: "big-old", padding: 1_500))
        small.add(metricKitHang(at: now - 10, seed: "big-new", padding: 1_500))
        XCTAssertEqual(small.reports().count, 1)
    }

    func testRemoveAllAndExport() throws {
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 86_400)
        store.add(metricKitHang(at: now, seed: "a"))
        let export = try AppHealthStore.decoder.decode(AppHealthExport.self, from: store.exportData(store.reports()))
        XCTAssertEqual(export.reports.count, 1)
        XCTAssertEqual(export.format, AppHealthReport.formatVersion)
        store.removeAll()
        XCTAssertTrue(store.reports().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Grouping and sent state

    func testSimilarReportsShareAGroupNewestFirst() {
        let groups = AppHealthReportGroup.grouping([
            exitReport(at: now - 300, phase: "launching"),
            exitReport(at: now, phase: "launching"),
            exitReport(at: now - 100, phase: "browsing", playerOpen: true),
        ])
        XCTAssertEqual(groups.map(\.summary), [
            "Closed unexpectedly while opening (cause unknown)",
            "Closed unexpectedly during playback (cause unknown)",
        ])
        XCTAssertEqual(groups.first?.reports.count, 2)
        XCTAssertEqual(groups.first?.latest.recordedAt, now)
    }

    func testUnsentExcludesSentReports() {
        let first = exitReport(at: now, phase: "launching")
        let second = exitReport(at: now - 600, phase: "launching")
        XCTAssertEqual(AppHealthSendState.unsent(in: [first, second], sentIDs: []).count, 2)
        XCTAssertEqual(AppHealthSendState.unsent(in: [first, second], sentIDs: [second.id]).map(\.id), [first.id])
    }

    // MARK: - Pruning by kind, and trail lines

    func testAppErrorsAreDroppedBeforeCrashes() {
        let store = makeStore(reports: 3, bytes: 1_000_000, age: 86_400, appErrors: 5)
        store.add(report(.crash, at: now - 500, seed: "old-crash"))
        store.add(report(.appError, at: now - 10, seed: "error-1"))
        store.add(report(.appError, at: now - 5, seed: "error-2"))
        store.add(report(.hang, at: now, seed: "hang"))
        let kinds = store.reports().map(\.kind)
        XCTAssertTrue(kinds.contains(.crash))
        XCTAssertTrue(kinds.contains(.hang))
        XCTAssertEqual(kinds.filter { $0 == .appError }.count, 1)
    }

    func testAppErrorsHaveTheirOwnCap() {
        let store = makeStore(reports: 20, bytes: 1_000_000, age: 86_400, appErrors: 2)
        for index in 0..<4 {
            store.add(report(.appError, at: now + TimeInterval(index), seed: "error-\(index)"))
        }
        XCTAssertEqual(store.reports().count, 2)
    }

    func testRecentEventLinesAreReadableAndRedacted() throws {
        let rendered = try XCTUnwrap(DiagLog.renderedLine(
            level: .warning, category: .network, tag: "HTTP",
            message: "request failed for https://media.example.com/Videos/abc/Movie.Name.2019.mkv",
            attrs: ["status": .int(500)], timestamp: now, captureSessionID: "-"))
        let readable = try XCTUnwrap(AppHealthTrail.readableLine(fromRendered: rendered))
        XCTAssertTrue(readable.contains("W network/HTTP request failed"))
        XCTAssertTrue(readable.hasSuffix("status=500"))
        XCTAssertFalse(readable.contains("media.example.com"))
        XCTAssertFalse(readable.contains("Movie.Name"))
    }

    // MARK: - Problem titles and filtering

    func testCrashTitlesSayWhatWasHappening() {
        let segv = crashReport(signal: 11, foreground: true, playerOpen: true)
        XCTAssertEqual(segv.groupSummary, "Crashed during playback: invalid memory access")
        XCTAssertEqual(segv.technicalCode, "SIGSEGV")
        XCTAssertEqual(crashReport(signal: 5, foreground: true, playerOpen: false).groupSummary,
                       "Crashed while browsing: internal check failed")
        XCTAssertEqual(crashReport(signal: 5, foreground: false, playerOpen: true).groupSummary,
                       "Crashed during playback: internal check failed")
        XCTAssertEqual(crashReport(signal: 6, foreground: false, playerOpen: false).groupSummary,
                       "Crashed in the background: app stopped itself")
        XCTAssertNotEqual(segv.groupKey, crashReport(signal: 11, foreground: true, playerOpen: false).groupKey)
    }

    func testOnlyAppSideNetworkErrorsAreReported() {
        XCTAssertTrue(AppHealthMonitor.isAppSideNetworkError(["outcome": .string("decode_failed")]))
        XCTAssertTrue(AppHealthMonitor.isAppSideNetworkError(["status": .int(400)]))
        XCTAssertTrue(AppHealthMonitor.isAppSideNetworkError(["status": .int(422)]))
        for status in [401, 403, 404, 408, 429, 500, 502, 503] {
            XCTAssertFalse(AppHealthMonitor.isAppSideNetworkError(["status": .int(status)]), "\(status)")
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
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 86_400)
        let crash = crashReport(signal: 11, foreground: true, playerOpen: true)
        store.add(crash)
        let incoming = MetricKitReportSummariser.report(from: try crashInput())
        XCTAssertFalse(store.merge(metricKitCrash: incoming, pid: 999))
        XCTAssertTrue(store.merge(metricKitCrash: incoming, pid: 321))
        let stored = store.reports()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, crash.id)
        XCTAssertNotNil(stored.first?.callStackTree)
        XCTAssertEqual(stored.first?.context?["player_open"], .bool(true))
        XCTAssertFalse(store.merge(metricKitCrash: incoming, pid: 321))
    }

    func testIssueIDMatchesTheSameProblemAcrossDevicesAndDays() {
        let first = crashReport(signal: 11, foreground: true, playerOpen: true)
        let second = AppHealthReport(
            kind: .crash, source: .exitMarker, recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            app: AppHealthAppInfo(version: "0.15.0", build: "50", os: "iOS 18.2.0", device: "iPhone17,1"),
            details: ["signal": .int(11), "foreground": .bool(true), "pid": .int(777)],
            context: ["phase": .string("browsing"), "player_open": .bool(true), "memory_warnings": .int(2)],
            fingerprintSeed: "other")
        XCTAssertEqual(first.issueID, second.issueID)
        XCTAssertTrue(first.issueID.hasPrefix("VD-"))
        XCTAssertEqual(first.issueID.count, 9)
        XCTAssertNotEqual(first.issueID, crashReport(signal: 11, foreground: true, playerOpen: false).issueID)
        XCTAssertNotEqual(first.issueID, crashReport(signal: 5, foreground: true, playerOpen: true).issueID)
    }

    func testHangDurationDoesNotSplitIssueIDs() {
        func hang(_ milliseconds: Int) -> AppHealthReport {
            AppHealthReport(
                kind: .hang, source: .watchdog, recordedAt: Date(), app: Self.app,
                details: ["duration_ms": .int(milliseconds)],
                context: ["phase": .string("browsing"), "player_open": .bool(true)],
                fingerprintSeed: String(milliseconds))
        }
        XCTAssertEqual(hang(1_200).issueID, hang(4_800).issueID)
    }

    // MARK: - Counting repeats, and issue IDs per request

    func testRepeatsWithinADayAreCountedOnOneReport() {
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 604_800)
        XCTAssertTrue(store.add(settingsError(at: now - 3_600)))
        XCTAssertFalse(store.add(settingsError(at: now - 60)))
        XCTAssertFalse(store.add(settingsError(at: now)))
        let reports = store.reports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.occurrenceCount, 3)
        XCTAssertEqual(reports.first?.recordedAt, now - 3_600)
        XCTAssertEqual(reports.first?.lastOccurredAt, now)
        XCTAssertEqual(AppHealthReportGroup.grouping(reports).first?.occurrenceCount, 3)
    }

    func testRepeatAfterSendingMarksTheReportUnsent() {
        AppHealthSendState.clear()
        defer { AppHealthSendState.clear() }
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 604_800)
        XCTAssertTrue(store.add(settingsError(at: now - 3_600)))
        AppHealthSendState.markSent(store.reports())
        XCTAssertTrue(AppHealthSendState.unsent(in: store.reports()).isEmpty)
        XCTAssertFalse(store.add(settingsError(at: now)))
        XCTAssertEqual(AppHealthSendState.unsent(in: store.reports()).map(\.occurrenceCount), [2])
    }

    func testSameReportAddedTwiceIsNotCountedAsARepeat() {
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 86_400)
        let report = settingsError(at: now)
        XCTAssertTrue(store.add(report))
        XCTAssertFalse(store.add(report))
        XCTAssertEqual(store.reports().map(\.occurrenceCount), [1])
    }

    func testRepeatAfterADayAddsANewReport() {
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 604_800)
        XCTAssertTrue(store.add(settingsError(at: now - AppHealthStore.repeatWindow - 60)))
        XCTAssertTrue(store.add(settingsError(at: now)))
        XCTAssertEqual(store.reports().map(\.occurrenceCount), [1, 1])
    }

    func testDifferentRequestsGetDifferentIssueIDs() {
        let settings = settingsError(at: now)
        let push = settingsError(at: now, path: "/api/v2/devices/push/apple", method: "POST")
        XCTAssertNotEqual(settings.issueID, push.issueID)
        XCTAssertNotEqual(settings.groupKey, push.groupKey)
        XCTAssertEqual(settings.groupSummary, "Server rejected a settings change")
        XCTAssertEqual(push.groupSummary, "Server rejected a request")
        XCTAssertEqual(settings.technicalCode,
                       ["HTTP", "HTTP 422", "PUT /api/v2/settings/values/{id}"].joined(separator: Self.middleDot))
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 86_400)
        XCTAssertTrue(store.add(settings))
        XCTAssertTrue(store.add(push))
    }

    func testSameRequestGetsTheSameIssueIDAcrossDevicesAndLaunches() {
        let first = settingsError(at: Date(timeIntervalSince1970: 1_790_000_000))
        let second = settingsError(
            at: Date(timeIntervalSince1970: 1_800_000_000),
            app: AppHealthAppInfo(version: "0.15.0", build: "60", os: "iOS 26.1", device: "iPad16,3"))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.issueID, second.issueID)
        XCTAssertEqual(first.groupKey, second.groupKey)
    }

    func testDecodeFailuresKeepTheirTitle() {
        let report = AppHealthReport(
            kind: .appError, source: .app, recordedAt: Date(),
            app: AppHealthAppInfo(version: "0.14.3", build: "54", os: "iOS 26.0", device: "iPhone17,1"),
            details: ["tag": .string("Decode"), "path": .string("/api/v2/settings/values"), "outcome": .string("decode_failed")],
            fingerprintSeed: "decode")
        XCTAssertEqual(report.groupSummary, "Couldn't read a server response")
    }

    // MARK: - Rules owned by other areas

    func testPermanentSettingsRejectionsAreDropped() {
        let permanent: [Error] = [
            HTTPError.http(statusCode: 422, body: nil),
            HTTPError.http(statusCode: 400, body: nil),
            SettingsAPIError.invalidValue(message: "bad"),
        ]
        for error in permanent {
            XCTAssertTrue(UICustomizationPreferences.isPermanentRejection(error), "\(error)")
        }
        let temporary: [Error] = [
            HTTPError.http(statusCode: 401, body: nil),
            HTTPError.http(statusCode: 408, body: nil),
            HTTPError.http(statusCode: 409, body: nil),
            HTTPError.http(statusCode: 429, body: nil),
            SettingsAPIError.transport(description: "offline"),
            SettingsAPIError.serverUpgradeRequired,
        ]
        for error in temporary {
            XCTAssertFalse(UICustomizationPreferences.isPermanentRejection(error), "\(error)")
        }
    }

    func testNotificationDeepLinksOnlyFollowVividLinks() {
        let key = NotificationDeepLinkCoordinator.urlUserInfoKey
        XCTAssertEqual(NotificationDeepLinkCoordinator.deepLinkURL(from: [key: "vivid://downloads"]), URL(string: "vivid://downloads"))
        XCTAssertEqual(NotificationDeepLinkCoordinator.deepLinkURL(from: [key: " vivid://downloads\n"]), URL(string: "vivid://downloads"))
        XCTAssertNil(NotificationDeepLinkCoordinator.deepLinkURL(from: [key: "https://example.com/downloads"]))
        XCTAssertNil(NotificationDeepLinkCoordinator.deepLinkURL(from: [key: "silo://item/1"]))
        XCTAssertNil(NotificationDeepLinkCoordinator.deepLinkURL(from: [:]))
    }

    func testExitReportsCarryMemoryUseAndPlaybackLength() {
        var context = AppHealthContextSnapshot()
        context.phase = "browsing"
        context.playerOpen = true
        context.playerOpenedAt = now
        context.memoryWarnings = 2
        context.memoryMB = 1_480
        context.peakMemoryMB = 1_510
        context.memoryAvailableMB = 60
        context.memorySampledAt = now + 860
        let attributes = context.attributes
        XCTAssertEqual(attributes["memory_mb"], .int(1_480))
        XCTAssertEqual(attributes["peak_memory_mb"], .int(1_510))
        XCTAssertEqual(attributes["memory_available_mb"], .int(60))
        XCTAssertEqual(attributes["playing_min"], .int(14))
        context.playerOpen = false
        XCTAssertNil(context.attributes["playing_min"])
        XCTAssertNotNil(AppHealthMemory.footprintMB())
    }

    // MARK: - Downloads

    func testDownloadFailureKeepsOnlyTokensAndNumbers() throws {
        let plain = DownloadFailureReport(
            stage: .transfer, server: "emby", urlErrorCode: -3_003, error: "network", quality: "5mbps", batch: true, retries: 4)
        XCTAssertEqual(plain.details, [
            "stage": .string("transfer"), "server": .string("emby"), "url_error": .int(-3_003), "error": .string("network"),
            "quality": .string("5mbps"), "batch": .bool(true), "retries": .int(4),
        ])
        let report = downloadReport(plain, at: now)
        XCTAssertEqual(report.kind.rawValue, "download_failure")
        XCTAssertEqual(report.groupSummary, "Download stopped before it finished")
        XCTAssertEqual(report.technicalCode, ["transfer", "URLError -3003"].joined(separator: Self.middleDot))

        let refused = try XCTUnwrap(DownloadFailureReport(
            stage: .registration, error: HTTPError.http(statusCode: 500, body: "Secret Title S01E02"),
            server: "silo", quality: "Odd Value/../x", batch: false, retries: 0))
        XCTAssertEqual(refused.status, 500)
        XCTAssertEqual(refused.quality, "other")
        XCTAssertFalse(String(describing: refused.details).contains("Secret"))
        XCTAssertEqual(downloadReport(refused, at: Date()).technicalCode,
                       ["registration", "HTTP 500"].joined(separator: Self.middleDot))

        let unsupported = try XCTUnwrap(DownloadFailureReport(
            stage: .registration, error: EmbyError.unsupportedFeature, server: "emby", quality: "original", batch: false, retries: 0))
        XCTAssertEqual(unsupported.error, "unsupported_feature")
    }

    func testExpectedDownloadOutcomesAreNotFailures() {
        let expected: [Error] = [
            CancellationError(),
            URLError(.cancelled),
            HTTPError.requestIdentityChanged,
            DownloadError.registrationAlreadyInFlight,
            DownloadError.scopeChangedDuringRegistration,
            EmbyDownloads.BatchError.alreadyDownloaded,
            JellyfinDownloads.BatchError.noEpisodes,
        ]
        for error in expected {
            XCTAssertNil(DownloadFailureReport(
                stage: .registration, error: error, server: "emby", quality: nil, batch: true, retries: 0), "\(error)")
        }
    }

    func testDownloadNetworkFailuresOutsideTheAppAreSkipped() {
        func transfer(_ code: URLError.Code) -> DownloadFailureReport {
            DownloadFailureReport(
                stage: .transfer, server: "silo", urlErrorCode: code.rawValue, error: "network",
                quality: "original", batch: false, retries: 4)
        }
        let refused = DownloadFailureReport(
            stage: .transfer, server: "silo", status: 403, error: "http", quality: "original", batch: false, retries: 0)
        var context = AppHealthContextSnapshot()
        for code: URLError.Code in [.notConnectedToInternet, .cannotConnectToHost, .timedOut, .networkConnectionLost, .secureConnectionFailed] {
            XCTAssertFalse(AppHealthMonitor.shouldReportDownloadFailure(transfer(code), context: context), "\(code)")
        }
        XCTAssertTrue(AppHealthMonitor.shouldReportDownloadFailure(transfer(.badServerResponse), context: context))
        XCTAssertTrue(AppHealthMonitor.shouldReportDownloadFailure(transfer(.cannotWriteToFile), context: context))

        context.serverReachable = false
        XCTAssertFalse(AppHealthMonitor.shouldReportDownloadFailure(transfer(.badServerResponse), context: context))
        XCTAssertTrue(AppHealthMonitor.shouldReportDownloadFailure(refused, context: context))

        context.serverReachable = true
        context.deviceOnline = false
        XCTAssertFalse(AppHealthMonitor.shouldReportDownloadFailure(transfer(.badServerResponse), context: context))
        XCTAssertTrue(AppHealthMonitor.shouldReportDownloadFailure(refused, context: context))
    }

    func testOnlyLastingSubtitleFetchFailuresStopTheBackfill() {
        let retryable: [Error] = [
            URLError(.timedOut),
            HTTPError.requestIdentityChanged,
            EmbyError.signInRequired,
            JellyfinError.signInRequired,
            HTTPError.http(statusCode: 401, body: nil),
            HTTPError.http(statusCode: 429, body: nil),
            HTTPError.http(statusCode: 503, body: nil),
        ]
        for error in retryable {
            XCTAssertTrue(DownloadFailureReport.isRetryable(error), "\(error)")
        }
        let lasting: [Error] = [
            HTTPError.http(statusCode: 403, body: nil),
            HTTPError.http(statusCode: 404, body: nil),
            EmbyError.invalidURL,
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "")),
        ]
        for error in lasting {
            XCTAssertFalse(DownloadFailureReport.isRetryable(error), "\(error)")
        }
    }

    func testRepeatedDownloadFailuresAreCountedOnOneReport() {
        let store = makeStore(reports: 10, bytes: 1_000_000, age: 604_800)
        let failure = DownloadFailureReport(
            stage: .preparing, server: "jellyfin", status: 404, error: "http", quality: "original", batch: true, retries: 0)
        XCTAssertTrue(store.add(downloadReport(failure, at: now - 60)))
        XCTAssertFalse(store.add(downloadReport(failure, at: now)))
        XCTAssertEqual(store.reports().map(\.occurrenceCount), [2])
    }

    // MARK: - Sending

    /// Very large retry times still give whole minutes, rounded up, without
    /// overflowing, right up to the largest whole number.
    func testHugeRetryTimeGivesWholeMinutesWithoutOverflow() {
        func message(_ seconds: Int) -> String { DiagnosticsUploader.Failure.rateLimited(retryAfter: seconds).message }
        let earlierInMinute = message(9_223_372_036_854_775_748)
        let laterInMinute = message(9_223_372_036_854_775_749)
        let largest = message(Int.max)
        XCTAssertFalse(laterInMinute.isEmpty)
        XCTAssertFalse(largest.isEmpty)
        XCTAssertEqual(earlierInMinute, laterInMinute)
        XCTAssertNotEqual(laterInMinute, largest)
    }
}
