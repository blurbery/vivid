#!/usr/bin/env python3
"""Run complete production bridge entrypoints against instrumented server boundaries."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift').read_text()

def method(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace(', privacy: .public', '')

state = source[source.index('    private var embyPlayback:'):source.index('    func reportNativePlaybackStarted(')]
methods = '\n'.join(method(marker) for marker in [
    '    func startSession(', '    func stopSession(', '    func reportProgress(',
    '    private func adoptSession('])

swift = r'''
import Foundation
actor Gate {
    var entered = false
    var released: Bool
    var entries: [CheckedContinuation<Void, Never>] = []
    var exits: [CheckedContinuation<Void, Never>] = []
    init(released: Bool = false) { self.released = released }
    func wait() async {
        entered = true; entries.forEach { $0.resume() }; entries.removeAll()
        if !released { await withCheckedContinuation { exits.append($0) } }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entries.append($0) } } }
    func release() { released = true; exits.forEach { $0.resume() }; exits.removeAll() }
}
enum Failure: Error { case expected }
struct Logger { func info(_ text: String) {}; func warning(_ text: String) {}; func error(_ text: String) {} }
enum MediaLogRedactor { static func sanitize(_ error: Error) -> String { "error" } }
enum MediaServerProvider { case jellyfin, emby, silo; static var active: Self { .jellyfin } }
struct AudioTrack { var language: String? = nil }
struct FileVersion {
    let fileId = 1
    let audioTracks: [AudioTrack]? = nil
    let resolution: String? = nil
    let codecVideo: String? = nil
    let bitrate: Int? = nil
}
struct UserData { let lastResolution: String? = nil; let positionSeconds: Double? = nil; let lastFileId: Int? = nil }
struct WatchDetail {
    let contentId: String
    var versions: [FileVersion] { [FileVersion()] }
    let type = "movie"
    let userData: UserData? = nil
    let effectiveSubtitleLanguage: String? = nil
    let effectiveSubtitleMode: String? = nil
    let effectiveShowForcedSubtitles: Bool? = nil
    let effectiveSubtitleTrackSignature: SubtitleTrackSignature? = nil
}
struct SubtitleTrackSignature {}
enum SubtitleMode: String { case off }
struct InitialProtocolV3SubtitlePreferences {
    let preferredLanguage: String? = nil
    let additionalPreferredLanguages: [String] = []
    let mode: SubtitleMode? = nil
    let showForced = false, forcedOnly = false, preferAccessibilityTracks = false, disableWhenNoLanguageMatch = false
    let trackSignature: SubtitleTrackSignature? = nil
}
struct SubtitleIntent { let ffmpegStreamIndex: Int? = nil; let combinedIndex: Int? = nil }
struct PlayerSettings {
    static let shared = Self()
    let fallbackMode: PlaybackFallbackMode? = nil
    let preferredQuality: String? = nil
    let maxBitrateKbps: Int? = nil
    let audioLanguage: String? = nil
}
enum PlaybackFallbackMode: String { case auto; static func matching(_ s: String?) -> Self? { nil } }
enum ApplePlaybackQuality { static func protocolV3QualityId(_ s: String?) -> String { "auto" } }
enum AppleQualityAxes { static func resolvedBitrateCap(qualityOverride: String?, fallbackBitrateKbps: Int?) -> Int? { nil } }
enum VividInitialAudioPreference {
    static func selectedOrdinal(manual: Int?, tracks: [AudioTrack], preferredLanguage: String?) -> Int? { manual }
}
actor TokenStore { static let shared = TokenStore(); func getProfileId() -> String? { "profile" } }
struct PlaybackV3TerminalFailure: Error { let reason: String; let message: String; let retryable: Bool }
enum APIError: Error { case httpError(statusCode: Int) }
struct PlaybackSessionResponse { let sessionId: String; var playMethod: String { "DirectPlay" } }
struct PreparedPlayback { let session: PlaybackSessionResponse }
enum PlaybackProgressReportResult { case success, deferred, transientFailure, missingSession }
struct ProgressReport { let position: Double; let isPaused: Bool }
struct VividAPI {
    static let shared = Self()
    func get(_ path: String) async throws -> WatchDetail { throw Failure.expected }
    func postVoid(_ path: String, body: ProgressReport) async throws { throw Failure.expected }
    func delete(_ path: String) async throws { throw Failure.expected }
}
@MainActor final class Probe {
    static var all: [String: Probe] = [:]
    let preparing = Gate(released: true)
    var prepareGate: Gate?
    var retirementGate: Gate?
    var progressGate: Gate?
    var validationGate: Gate?
    var validationGateCall = 1
    var validationFailureCall: Int?
    var validationCalls = 0
    var cleanupCount = 0
    var cleanupWasCancelled = false
    var retirementCount = 0
    var progressPositions: [Double] = []
    var progressAfterStop = false
    var stopPosition: Double?
    var completionCount = 0
    var failStop = false
    init(_ id: String) { Self.all[id] = self }
}
struct Connection {
    let probe: Probe
    @MainActor func validate() async throws {
        probe.validationCalls += 1
        if probe.validationCalls == probe.validationGateCall, let gate = probe.validationGate { await gate.wait() }
        if probe.validationCalls == probe.validationFailureCall { throw Failure.expected }
        try Task.checkCancellation()
    }
}
@MainActor final class JellyfinPlayback {
    struct Metadata { let detail: WatchDetail; let connection: Connection }
    let playSessionID: String
    let probe: Probe
    var stopped = false
    init(_ id: String, probe: Probe) { playSessionID = id; self.probe = probe }
    static func loadMetadata(contentID: String) async throws -> Metadata {
        Metadata(detail: WatchDetail(contentId: contentID), connection: Connection(probe: Probe.all[contentID]!))
    }
    static func prepare(metadata: Metadata, detail: WatchDetail, version: FileVersion, start: Double,
                        audioOrdinal: Int?, subtitleIndex: Int?, bitrateKbps: Int?, quality: String?) async throws -> (PreparedPlayback, JellyfinPlayback) {
        await metadata.connection.probe.preparing.wait()
        if let gate = metadata.connection.probe.prepareGate { await gate.wait() }
        try Task.checkCancellation()
        return (PreparedPlayback(session: PlaybackSessionResponse(sessionId: detail.contentId)), JellyfinPlayback(detail.contentId, probe: metadata.connection.probe))
    }
    func retireForReplacement() async throws {
        probe.retirementCount += 1
        if let gate = probe.retirementGate { await gate.wait() }
        stopped = true
    }
    func stopWithoutProgress() async throws {
        probe.cleanupCount += 1
        probe.cleanupWasCancelled = Task.isCancelled
        stopped = true
    }
    func report(position: Double, isPaused: Bool, stopping: Bool = false) async throws {
        if stopping { probe.stopPosition = position; stopped = true; if probe.failStop { throw Failure.expected }; return }
        if let gate = probe.progressGate { await gate.wait() }
        if stopped { probe.progressAfterStop = true }
        probe.progressPositions.append(position)
    }
    func ping() async throws {}
}
typealias EmbyPlayback = JellyfinPlayback
actor Bridge {
    var progressWriteTail: Task<PlaybackProgressReportResult, Never>?
    let logger = Logger()
    var sessionId: String?
    var currentSession: PlaybackSessionResponse?
    var activeProtocolV3: String?
    struct Pending { let priorSessionId: String? }
    var pendingProtocolV3Transition: Pending?
    var protocolV3FirstFramePlanIds = Set<String>()
    var consecutiveProgressFailures = 0
    var emittedOrphanedSessionWarning = false
    PRODUCTION_STATE
    PRODUCTION_METHODS
    func snapshot() -> String? { sessionId }
    func awaitTransition() async { while !jellyfinTransitionInProgress { await Task.yield() } }
    func awaitWaiters(_ count: Int) async { while jellyfinTransitionWaiters.count < count { await Task.yield() } }
    func normalizedQualityPreference(_ quality: String?) -> String? { quality }
    static func selectVersion(from versions: [FileVersion], lastFileId: Int?, preferredQuality: String?) -> FileVersion { versions[0] }
    static func initialProtocolV3SubtitleIntent(version: FileVersion, explicitFFmpegIndex: Int?, explicitCombinedIndex: Int?, preferredLanguage: String?, additionalPreferredLanguages: [String], mode: SubtitleMode?, showForced: Bool, forcedOnly: Bool, preferAccessibilityTracks: Bool, disableWhenNoLanguageMatch: Bool, trackSignature: SubtitleTrackSignature?, currentAudioLanguage: String?) -> SubtitleIntent { SubtitleIntent() }
    func resolvedStartPosition(startFromBeginning: Bool, explicitResumePosition: Double?, storedResumePosition: Double?, watchDetail: WatchDetail, selectedVersion: FileVersion, allowNearEndResume: Bool) -> Double? { explicitResumePosition }
    func requestedQualityPreference(preferredQuality: String?, selectedVersion: FileVersion, hasManualSelection: Bool) -> String? { preferredQuality }
    func startProtocolV3(watchDetail: WatchDetail, selectedVersion: FileVersion, profileId: String, qualityPreference: String?, bandwidthCapKbps: Int?, startPosition: Double?, audioTrackIndex: Int?, subtitleTrackIndex: Int?, subtitleCombinedIndex: Int?) async throws -> PreparedPlayback { throw Failure.expected }
    func stopStaleSession(_ id: String) {}
    func emitProtocolV3Event(active: String, sessionId: String, event: String, classification: String?, fallbackReason: String?, diagnostics: [String: String]) async {}
    static func isPlaybackSessionMissing(_ error: Error) -> Bool { false }
    func writeSiloProgress(sessionId: String, position: Double, isPaused: Bool) async -> PlaybackProgressReportResult { .transientFailure }
    func writeCompletion(after result: PlaybackProgressReportResult, contentId: String?, playback: EmbyPlayback?) async -> PlaybackProgressReportResult { result }
    func writeJellyfinCompletion(after result: PlaybackProgressReportResult, contentId: String?, playback: JellyfinPlayback?) async -> PlaybackProgressReportResult {
        if contentId != nil, let playback { await MainActor.run { playback.probe.completionCount += 1 } }
        return result
    }
}
@main struct Run {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        // Execute complete production start/stop/report entrypoints. Only
        // external settings, media metadata and server boundaries are stubbed.
        for window in ["prepare", "progress", "retirement", "validation"] {
            let bridge = Bridge(), old = Probe("old"), first = Probe("first"), latest = Probe("latest")
            _ = try await bridge.startSession(contentId: "old", startFromBeginning: false)
            let gate = Gate()
            var progress: Task<PlaybackProgressReportResult, Never>?
            switch window {
            case "prepare": first.prepareGate = gate
            case "progress":
                old.progressGate = gate
                progress = Task { await bridge.reportProgress(position: 42, isPaused: false, eligible: true) }
                await gate.waitUntilEntered()
            case "retirement": old.retirementGate = gate
            default: first.validationGate = gate
            }
            let firstTask = Task { try await bridge.startSession(contentId: "first", startFromBeginning: false) }
            if window == "progress" { await bridge.awaitTransition() } else { await gate.waitUntilEntered() }
            let latestTask = Task { try await bridge.startSession(contentId: "latest", startFromBeginning: false) }
            await latest.preparing.waitUntilEntered()
            if window != "prepare" { await bridge.awaitWaiters(1) }
            await gate.release()
            _ = try await latestTask.value
            do { _ = try await firstTask.value; preconditionFailure("Stale start committed at \(window)") }
            catch is CancellationError { checks += 1 }
            _ = await progress?.value
            let current = await bridge.snapshot()
            check(current == "latest", "Old start replaced newer session")
            check(first.cleanupCount == 0, "Stale candidate stopped current server playback")
            check(latest.cleanupCount == 0, "Current session was reclaimed")
            check(!old.progressAfterStop, "Progress ran after retirement")
            check(old.retirementCount == 1, "Old playback retired more than once")
        }
        // A progress sample arriving during replacement must neither race the
        // old stop nor be applied to the new stream after the barrier opens.
        do {
            let bridge = Bridge(), old = Probe("old"), new = Probe("new"), gate = Gate()
            _ = try await bridge.startSession(contentId: "old", startFromBeginning: false)
            old.progressGate = gate
            let firstProgress = Task { await bridge.reportProgress(position: 40, isPaused: false, eligible: true) }
            await gate.waitUntilEntered()
            let replacement = Task { try await bridge.startSession(contentId: "new", startFromBeginning: false) }
            await bridge.awaitTransition()
            let lateProgress = Task { await bridge.reportProgress(position: 41, isPaused: false, eligible: true, completedContentId: "old") }
            await bridge.awaitWaiters(1)
            await gate.release()
            _ = try await replacement.value
            _ = await firstProgress.value
            let lateResult = await lateProgress.value
            check(lateResult == .deferred, "Old sample was not deferred")
            check(old.progressPositions == [40], "Late progress reached retired playback")
            check(new.progressPositions.isEmpty, "Old position reached new playback")
            check(!old.progressAfterStop, "Retirement raced progress")
            check(old.completionCount == 1 && new.completionCount == 0, "Replacement lost or redirected terminal completion")
        }
        // Failure before retirement preserves the previous session; failure
        // after retirement finalises it instead of retaining a dead reference.
        for validationCall in [1, 2] {
            let bridge = Bridge(), old = Probe("old"), new = Probe("new")
            _ = try await bridge.startSession(contentId: "old", startFromBeginning: false)
            new.validationFailureCall = validationCall
            do { _ = try await bridge.startSession(contentId: "new", startFromBeginning: false); preconditionFailure("Validation failure ignored") }
            catch Failure.expected { checks += 1 }
            let current = await bridge.snapshot()
            check(current == (validationCall == 1 ? "old" : nil), "Retired session retained or live session lost")
            check(old.retirementCount == (validationCall == 1 ? 0 : 1), "Wrong retirement ordering")
            check(new.cleanupCount == 0, "Rejected candidate stopped current server playback")
            let progress = await bridge.reportProgress(position: 50, isPaused: false, eligible: true)
            check(progress == (validationCall == 1 ? .success : .transientFailure), "Bridge retained stopped playback")
        }
        // Call production stop while preparation is suspended and no session
        // exists. This fails if stop's invalidation moves behind its nil guard.
        do {
            let bridge = Bridge(), candidate = Probe("candidate"), gate = Gate()
            candidate.prepareGate = gate
            let task = Task { try await bridge.startSession(contentId: "candidate", startFromBeginning: false) }
            await gate.waitUntilEntered()
            _ = await bridge.stopSession(position: 0, isPaused: true, eligible: false)
            await gate.release()
            do { _ = try await task.value; preconditionFailure("Stop failed to invalidate pending start") }
            catch is CancellationError { checks += 1 }
            let current = await bridge.snapshot()
            check(current == nil, "Pending start survived stop")
            check(candidate.cleanupCount == 0, "Unadopted candidate sent a server stop")
        }
        // Cancellation after retirement safely leaves no current session;
        // no candidate stop is sent and the barrier always opens again.
        do {
            let bridge = Bridge(), old = Probe("old"), candidate = Probe("candidate"), gate = Gate()
            _ = try await bridge.startSession(contentId: "old", startFromBeginning: false)
            old.retirementGate = gate
            let task = Task { try await bridge.startSession(contentId: "candidate", startFromBeginning: false) }
            await gate.waitUntilEntered(); task.cancel(); await gate.release()
            do { _ = try await task.value; preconditionFailure("Cancelled replacement committed") }
            catch is CancellationError { checks += 1 }
            let current = await bridge.snapshot()
            check(current == nil, "Cancelled replacement retained stopped playback")
            check(candidate.cleanupCount == 0, "Unadopted candidate sent a server stop")
            _ = Probe("recovery")
            _ = try await bridge.startSession(contentId: "recovery", startFromBeginning: false)
            let recovered = await bridge.snapshot()
            check(recovered == "recovery", "Transition barrier was not released")
        }
        // Stop during retirement invalidates the candidate and cannot leave a
        // stopped reference. A later start can proceed after stop completes.
        do {
            let bridge = Bridge(), old = Probe("old"), candidate = Probe("candidate"), gate = Gate()
            _ = try await bridge.startSession(contentId: "old", startFromBeginning: false)
            old.retirementGate = gate
            let task = Task { try await bridge.startSession(contentId: "candidate", startFromBeginning: false) }
            await gate.waitUntilEntered()
            let stop = Task { await bridge.stopSession(position: 50, isPaused: true, eligible: true) }
            await bridge.awaitWaiters(1)
            await gate.release()
            do { _ = try await task.value; preconditionFailure("Start survived concurrent stop") }
            catch is CancellationError { checks += 1 }
            _ = await stop.value
            let current = await bridge.snapshot()
            check(current == nil && old.retirementCount == 1, "Stop raced replacement retirement")
            check(candidate.cleanupCount == 0, "Unused negotiation issued a server stop")
        }
        // Cancellation of pure negotiation preserves the current playback.
        do {
            let bridge = Bridge(), old = Probe("old"), candidate = Probe("candidate"), gate = Gate()
            _ = try await bridge.startSession(contentId: "old", startFromBeginning: false)
            candidate.prepareGate = gate
            let task = Task { try await bridge.startSession(contentId: "candidate", startFromBeginning: false) }
            await gate.waitUntilEntered(); task.cancel(); await gate.release()
            do { _ = try await task.value; preconditionFailure("Cancelled negotiation succeeded") }
            catch is CancellationError { checks += 1 }
            let current = await bridge.snapshot()
            check(current == "old" && old.retirementCount == 0, "Negotiation cancelled active playback")
            check(candidate.cleanupCount == 0, "Cancelled negotiation issued a server stop")
        }
        // Terminal watched state still runs if the stop report fails.
        do {
            let bridge = Bridge(), old = Probe("old")
            _ = try await bridge.startSession(contentId: "old", startFromBeginning: false)
            old.failStop = true
            let result = await bridge.stopSession(position: 100, isPaused: true, eligible: true, completedContentId: "old")
            check(result == .transientFailure, "Stop failure disappeared")
            check(old.completionCount == 1, "Failed stop skipped completion")
        }
        print("\(checks) Jellyfin lifecycle checks passed")
    }
}
'''

swift = swift.replace('PRODUCTION_STATE', state).replace('PRODUCTION_METHODS', methods)
with tempfile.TemporaryDirectory(prefix='vivid-jellyfin-replacement-', dir=root.parent) as folder:
    folder = Path(folder)
    (folder / 'checks.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', str(folder / 'checks.swift'), '-o', str(folder / 'checks')], check=True, timeout=60)
    subprocess.run([str(folder / 'checks')], check=True, timeout=20)
