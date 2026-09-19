#!/usr/bin/env python3
"""Exercise production EOF/error handlers with instrumented playback boundaries."""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--source-ref')
args = parser.parse_args()

def source(path):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=root, text=True)
    return (root / path).read_text()

def declaration(text, marker):
    start = text.find(marker)
    if start < 0: raise SystemExit(f"Missing declaration: {marker}")
    brace = text.find('{', start)
    if brace < 0: raise SystemExit(f"Missing opening brace: {marker}")
    depth, end = 1, brace + 1
    while depth:
        if end >= len(text): raise SystemExit(f"Unclosed declaration: {marker}")
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end].replace(', privacy: .public', '')

vm = source('iosApp/iosApp/Screens/Player/PlayerViewModel.swift')
policy = source('iosApp/iosApp/Screens/Player/PlayerNextUpCompletionPolicy.swift')
policy += '\n' + declaration(source('iosApp/iosApp/Screens/Player/PlayerSettings.swift'), 'enum PlaybackCompletionPolicy')
names = ['handleEndOfFile', 'handlePlaybackError', 'performCreditsSkip', 'updateNextUpPresentation', 'shouldShowNextUpBeforeEnd', 'handleVividFailure', 'attemptProtocolV3Recovery', 'updateNextUpCountdownForActivePlayback', 'updatePlaybackCompletion']
for name in ['suppressNextUpForPlaybackFailure', 'shouldTreatPlaybackErrorAsNaturalEnd', 'recoverPendingUnexpectedEnd']:
    if 'private func ' + name in vm:
        names.append(name)
methods = '\n'.join(declaration(vm, 'private func ' + name) for name in names)
if 'private func suppressNextUpForPlaybackFailure' not in vm:
    methods += '\nprivate func suppressNextUpForPlaybackFailure() { cancelNextUpCountdown(); showNextUpScreen = false }\nprivate func recoverPendingUnexpectedEnd() {}'
engine = source('iosApp/iosApp/Playback/MPV/VividMPVPlayer.swift')
engine_methods = '\n'.join(declaration(engine, 'private func ' + name) for name in
    ['handleEndFile', 'cancelEndConfirmation', 'observeEndOfFile', 'fail']) if 'private func observeEndOfFile' in engine else ''
if engine_methods:
    delay = 'try await Task.sleep(for: .milliseconds(250))'
    if engine_methods.count(delay) != 1:
        raise SystemExit('Expected exactly one EOF confirmation delay; update the controlled-clock adapter')
    engine_methods = engine_methods.replace(delay, 'try await self?.delay.wait()')
engine_harness = r'''
@MainActor final class ConfirmationDelay {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async throws {
        try Task.checkCancellation()
        entered = true
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }
    func advance() { continuation?.resume(); continuation = nil }
}
enum EngineState: Equatable { case playing, ended, error(String) }
struct Core { func setProperty(_ name: String, value: String) {} }
struct Trace { func event(_ name: String, fields: String) {} }
@MainActor final class EndHarness {
    let delay = ConfirmationDelay()
    var generation: UInt64 = 1, seekGeneration: UInt64 = 0
    var endConfirmationTask: Task<Void, Never>?
    var errorInfo: PlaybackErrorInfo?
    var isSessionReady = true, hasFirstFrameReadyForDisplay = true, isSeeking = false, isBuffering = false
    var state = EngineState.playing { didSet { if state == .ended { ends += 1 } } }
    var playbackPhase = EngineState.playing
    var core: Core?, trace: Trace?
    var ends = 0
''' + engine_methods + r'''
    func eof(_ value: Bool = true) { observeEndOfFile(value) }
    func endFile(_ reason: Int, error: Int? = nil) {
        var data: [String: Any] = ["reason": reason]
        if let error { data["error"] = error }
        handleEndFile(data)
    }
}
''' if engine_methods else ''
controller = source('iosApp/iosApp/Screens/Player/VividPlaybackController.swift')
seek_method = declaration(controller, 'func seek(toSourceTime')
seek_harness = r'''
enum SeekResult { case requiresReplan(sourceSeconds: Double), completed(sourceSeconds: Double) }
enum SeekDisposition { case local(Double), replan(Double) }
struct Timeline {
    var local = true
    func seekDisposition(forSourceTime time: Double) -> SeekDisposition { local ? .local(time) : .replan(time) }
    func sourcePosition(forPlayerTime time: Double) -> Double { time }
}
struct SeekSpec { var timeline = Timeline() }
@MainActor final class SeekEngine {
    struct Clock { var currentTime = 0.0 }
    var clock = Clock()
    func seek(to seconds: Double) async { clock.currentTime = seconds }
}
@MainActor final class SeekHarness {
    var activeSpec: SeekSpec? = SeekSpec()
    var didPublishEnd = true
    var generation = 1
    let engine = SeekEngine()
''' + seek_method + '\n}\n'
swift = r'''
import Foundation
enum PlaybackErrorKind: String { case audioTrackSwitchFailed, sourceRefused, vodSourceFailed, nativeItemFailed, noPlayableTrackWithinBudget, masterPlaylistRejected, softwarePipelineFailed, audioBridgeProducedNoOutput, dolbyVisionRequiresHardware, demuxedAudioLiveUnsupported, sourceRateLimited }
struct PlaybackErrorInfo { var kind: PlaybackErrorKind; var message: String; var transientSourceCode: Int? = nil }
enum MediaLogRedactor { static func sanitize(_ s: String) -> String { s } }
struct Logger { func info(_ s: String) {}; func warning(_ s: String) {}; func error(_ s: String) {} }
struct Settings { var playbackSpeed = 1.0; var nextUpPromptSeconds = 30; var autoPlayNextEpisode = true }
struct NowPlaying { func update(title: String, duration: Double, position: Double, isPlaying: Bool, playbackRate: Double) {} }
struct Engine { var isSeeking = false; var activeAudioTrackIndex: Int? }
struct Options { var nativeRemoteHLS = false }
struct Spec { var options = Options() }
@MainActor final class Controller { var engine = Engine(); var activeSpec: Spec? = Spec(); var pauses = 0; func pause() { pauses += 1 } }
enum ReportResult { case success }
@MainActor final class Bridge {
    var positions: [Double] = []
    func reportProgress(position: Double, isPaused: Bool, eligible: Bool, completedContentId: String?) async -> ReportResult { positions.append(position); return .success }
}
struct TimeRange { var start: Double; var end: Double }
struct WatchDetail { var type = "episode"; var contentId = "episode" }
struct Version { var credits: TimeRange? }
@MainActor final class Harness {
    static let logger = Logger()
    static let nearEndPlaybackErrorThresholdSeconds = 8.0
    var currentTime = 1200.0, duration = 3600.0
    var activeVividLoadEpoch: Int? = 1, startedVividLoadEpoch: Int? = 1
    var nextUpPromptDismissed = false
    let canShowNextUpScreen = true
    var hasReachedEndOfFile = false, nextUpAutoplayCancelled = false
    var showNextUpScreen = true, nextUpScreenVideoEnded = false
    var isLoading = false, isBuffering = false, isLoadingSubtitles = false, isPlaying = true, showControls = false
    var bufferingProgress: Double?
    var error: String?
    var isDisposed = false
    var pendingUnexpectedEndEpoch: Int?
    var isScrubbing = false, isQualitySwitching = false
    var seekTargetTime: Double?
    var protocolV3ReplanTask: Task<Void, Never>?
    var lastVividAudioTrackSwitchFailure: PlaybackErrorInfo?, selectedAudioId: Int64?
    var freshLoadOwnsFailureHandling = false, isVividLoadEstablished = true
    var authenticationReloadGeneration: Int?, streamLoadGeneration = 1
    var replanAccepted = true
    func protocolV3FailureClassification(_ message: String) -> String { "playback_error" }
    func attemptProtocolV3Replan(position: Double, classification: String, message: String) -> Bool {
        recoveries += 1; return replanAccepted
    }
    func attemptProtocolV3AuthenticationReload(after failure: PlaybackErrorInfo) -> Bool { false }
    func beginProtocolV3SameRouteReload(fallbackClassification: String, fallbackMessage: String, transientFailureCode: Int) -> Bool { false }
    var hideControlsTask: Task<Void, Never>?, progressTask: Task<Void, Never>?, naturalEndProgressTask: Task<Void, Never>?
    var activePreparedProtocolV3: Int? = 1, committedProtocolV3LoadEpoch: Int? = 1
    var offlinePlaybackContext: Int?
    var completedPlaybackContentId: String? { didSet { if completedPlaybackContentId != nil { completions += 1 } } }
    var currentWatchDetail: WatchDetail? = WatchDetail()
    var currentSelectedVersion: Version?
    var creditsRange: TimeRange?
    var refreshHomeAfterPlaybackWrite: (() -> Void)?
    var offlineWrites = 0
    let vividPlaybackController = Controller(), nowPlaying = NowPlaying(), sessionBridge = Bridge(), settings = Settings()
    let title = "episode", progressIsEligible = true
    var recoveries = 0, errors = 0, completions = 0, watchedWrites = 0, postrolls = 0, countdown = 5, seeks = 0
    static let nextUpHUDCountdownThresholdSeconds = 30.0
    var isNextUpTransitioning = false
    var nextUpEpisode: Int? = 2
    enum PresentationSource { case hud, automatic }
    var nextUpPresentationSource = PresentationSource.automatic
    var nextUpCountdownSeconds: Int? { didSet { countdown = nextUpCountdownSeconds ?? 0 } }
    var nextUpCountdownTotalSeconds = 5
    var nextEpisodes = 0
    func playNextEpisodeNow() { nextEpisodes += 1 }
    func cancelNextUpCountdown() { countdown = 0 }
    func isPlaybackSessionMissingMessage(_ s: String) -> Bool { false }
    func isExpiredPlaybackSessionSource(_ f: PlaybackErrorInfo?) -> Bool { false }
    func attemptStaleSessionRenewal(reason: String, observedPosition: Double) -> Bool { false }
    func finalizeTerminalPlaybackError(_ message: String) { suppressNextUpForPlaybackFailure(); errors += 1; error = message }
    func recordCurrentPlaybackMutation(markedCompleted: Bool) { watchedWrites += 1 }
    func recordOfflineProgress(context: Int, position: Double, markCompleted: Bool) { offlineWrites += 1 }
    enum Presentation { case automatic }
    func beginNextUpPostroll(videoEnded: Bool, source: Presentation = .automatic) { postrolls += 1; showNextUpScreen = true; if !nextUpAutoplayCancelled { countdown = 5 } }
    func showNotice(title: String, message: String, tone: Tone, duration: Double) {}
    enum Tone { case warning, info }
    func seekTo(seconds: Double, revealingControls: Bool) { seeks += 1; currentTime = seconds }
''' + methods + r'''
    func tick() { updateNextUpPresentation(for: currentTime) }
    func countdownTick() { updateNextUpCountdownForActivePlayback(at: currentTime) }
    func end() { handleEndOfFile() }
    func fail() { handlePlaybackError("Connection interrupted") }
    func settleLoad() { freshLoadOwnsFailureHandling = false; protocolV3ReplanTask = nil; committedProtocolV3LoadEpoch = 1; recoverPendingUnexpectedEnd() }
    func typedFail() { handleVividFailure(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "Failure")) }
    func skipCredits(to time: Double) { performCreditsSkip(to: time) }
}
''' + engine_harness + seek_harness + r'''
@main struct Checks {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: " + message); exit(1) }; count += 1
        }
        for (position, duration) in [(1200.0, 3600.0), (3546, 3600), (7190, 7200), (0, 3600), (100, 0), (100, Double.nan), (Double.nan, 3600), (Double.infinity, 3600), (100, Double.infinity)] {
            for silo in [true, false] {
                let h = Harness(); h.currentTime = position; h.duration = duration
                if !silo { h.activePreparedProtocolV3 = nil; h.committedProtocolV3LoadEpoch = nil }
                h.end()
                check(!h.hasReachedEndOfFile, "Unexpected EOF must not latch completion")
                check(h.postrolls == 0 && !h.showNextUpScreen && h.countdown == 0, "Unexpected EOF must not show or count down Next Up")
                check(h.completions == 0 && h.watchedWrites == 0, "Unexpected EOF must not write watched completion")
                check(silo ? h.recoveries == 1 : h.errors == 1, "Recover current Silo item or retain existing provider error path")
                check(position.isNaN ? h.currentTime.isNaN : h.currentTime == position, "Preserve resume position")
                check(h.vividPlaybackController.pauses == 0, "Do not replace playback intent before recovery")
            }
        }
        for position in [3592.0, 3599, 3600, 3601] {
            let h = Harness(); h.currentTime = position; h.showNextUpScreen = false
            h.end(); h.end()
            check(h.postrolls == 1 && h.completions == 1 && h.watchedWrites == 1, "Natural EOF completes exactly once")
            check(h.currentTime == 3600 && h.countdown == 5, "Keep natural-end countdown and terminal position")
        }
        for position in [1200.0, 3546, 3599, 3600] {
            let h = Harness(); h.currentTime = position; h.fail()
            check(h.recoveries == 1 && !h.hasReachedEndOfFile && h.postrolls == 0 && h.watchedWrites == 0, "An error is not successful completion, even near EOF")
            check(h.countdown == 0 && !h.showNextUpScreen, "Error cancels already-visible Next Up")
        }
        for buffering in [true, false] {
            let h = Harness(); h.currentTime = 3590; h.showNextUpScreen = false; h.countdown = 0
            h.isBuffering = buffering; h.isLoading = !buffering; h.tick()
            check(h.postrolls == 0 && h.countdown == 0, "Buffering or recovery must not present or advance Next Up")
        }
        for mode in 0..<8 {
            let h = Harness(); h.currentTime = 3599.9; h.countdown = 0
            switch mode {
            case 0: h.isPlaying = false
            case 1: h.isScrubbing = true
            case 2: h.seekTargetTime = 3600
            case 3: h.vividPlaybackController.engine.isSeeking = true
            case 4: h.isQualitySwitching = true
            case 5: h.error = "Failed"
            case 6: h.protocolV3ReplanTask = Task {}
            default: h.startedVividLoadEpoch = 0
            }
            h.tick()
            check(h.countdown == 0 && h.postrolls == 0 && h.nextEpisodes == 0, "Unsettled, paused or failed playback must not advance visible Next Up")
        }
        for mode in 0..<7 {
            let h = Harness(); h.currentTime = 3599.9
            switch mode {
            case 0: h.isPlaying = false
            case 1: h.isScrubbing = true
            case 2: h.seekTargetTime = 3600
            case 3: h.vividPlaybackController.engine.isSeeking = true
            case 4: h.isQualitySwitching = true
            case 5: h.error = "Failed"
            default: h.protocolV3ReplanTask = Task {}
            }
            h.countdownTick()
            check(h.nextEpisodes == 0, "Direct countdown calls cannot bypass transport guards")
        }
        let advancing = Harness(); advancing.currentTime = 3599.9; advancing.countdownTick()
        check(advancing.nextEpisodes == 1, "Healthy end-of-playback countdown still advances")
        for ownedLoad in [true, false] {
            let h = Harness()
            h.freshLoadOwnsFailureHandling = ownedLoad
            if !ownedLoad { h.committedProtocolV3LoadEpoch = nil }
            h.end()
            check(h.recoveries == 0 && h.errors == 0 && h.postrolls == 0, "Provisional and fresh loads retain sole failure ownership")
            h.settleLoad(); h.settleLoad()
            check(h.recoveries == 1 && h.pendingUnexpectedEndEpoch == nil, "Deferred premature EOF recovers exactly once after the owning load settles")
        }
        let replacedLoad = Harness(); replacedLoad.freshLoadOwnsFailureHandling = true
        replacedLoad.end(); replacedLoad.activeVividLoadEpoch = 2; replacedLoad.settleLoad()
        check(replacedLoad.recoveries == 0 && replacedLoad.pendingUnexpectedEndEpoch == nil, "A deferred EOF cannot recover a replacement episode")
        for typed in [true, false] {
            let rejected = Harness(); rejected.replanAccepted = false
            if typed { rejected.typedFail() } else { rejected.fail() }
            check(rejected.errors == 1 && rejected.countdown == 0, "Rejected recovery exposes Retry without Next Up")
            let busy = Harness(); busy.protocolV3ReplanTask = Task {}
            if typed { busy.typedFail() } else { busy.fail() }
            check(busy.recoveries == 0 && busy.errors == 0 && busy.countdown == 0, "An active recovery remains the sole owner")
        }
        let failed = Harness(); failed.activePreparedProtocolV3 = nil; failed.currentTime = 3599
        failed.fail(); failed.tick()
        check(failed.postrolls == 0 && failed.countdown == 0, "Late clocks cannot reopen Next Up after terminal failure")
        for paused in [true, false] {
            let h = Harness(); h.isPlaying = !paused; h.offlinePlaybackContext = 1
            h.activePreparedProtocolV3 = nil; h.end()
            check(h.errors == 1 && h.watchedWrites == 0 && h.postrolls == 0, "Offline truncation uses Retry, never completion")
        }
        let healthy = Harness(); healthy.currentTime = 3590; healthy.showNextUpScreen = false; healthy.tick()
        check(healthy.postrolls == 1, "Keep normal near-end presentation during healthy playback")
        let recovered = Harness(); recovered.end()
        recovered.currentTime = 3600; recovered.end()
        check(recovered.postrolls == 1 && recovered.countdown == 5, "Recovery must not disable later genuine autoplay")
        let cancelled = Harness(); cancelled.nextUpAutoplayCancelled = true; cancelled.end()
        cancelled.currentTime = 3600; cancelled.end()
        check(cancelled.countdown == 0, "Recovery must preserve the user's cancelled autoplay")
        for offline in [true, false] {
            for previouslyCompleted in [true, false] {
                let h = Harness(); h.currentTime = 3600
                if offline { h.offlinePlaybackContext = 1 }
                if previouslyCompleted { h.completedPlaybackContentId = "episode" }
                h.end(); h.end()
                await h.naturalEndProgressTask?.value
                check(offline ? h.offlineWrites == 1 : h.sessionBridge.positions == [3600], "EOF writes the final position once, including already-watched items")
                check(h.watchedWrites == (previouslyCompleted ? 0 : 1), "Watched mutation is emitted once, only on completion transition")
            }
        }
        let credits = Harness(); credits.skipCredits(to: 3600)
        check(credits.postrolls == 1 && credits.completions == 1, "Intentional end-of-credits skip still completes")
        let midCredits = Harness(); midCredits.skipCredits(to: 3500)
        check(midCredits.seeks == 1 && midCredits.postrolls == 0, "Credits before a post-credit scene still seek")
        let natural = EndHarness(); natural.eof(); natural.endFile(0)
        let eofThenError = EndHarness(); eofThenError.eof(); eofThenError.endFile(4, error: -13)
        let errorThenEOF = EndHarness(); errorThenEOF.endFile(4, error: -13); errorThenEOF.eof()
        let cleared = EndHarness(); cleared.eof(); cleared.eof(false)
        let replaced = EndHarness(); replaced.eof(); replaced.generation += 1
        let sought = EndHarness(); sought.eof(); sought.seekGeneration += 1
        let unopened = EndHarness(); unopened.isSessionReady = false; unopened.eof()
        let noPicture = EndHarness(); noPicture.hasFirstFrameReadyForDisplay = false; noPicture.eof()
        let stopped = EndHarness(); stopped.eof(); stopped.endFile(2)
        let delayedError = EndHarness(); delayedError.eof()
        let pending = [natural, replaced, sought, unopened, noPicture, delayedError]
        while pending.contains(where: { !$0.delay.entered }) { await Task.yield() }
        let confirmations = pending.compactMap { $0.endConfirmationTask }
        delayedError.endFile(4, error: -13)
        for h in pending { h.delay.advance() }
        for task in confirmations { await task.value }
        check(natural.ends == 1, "Natural EOF and duplicate end-file complete once")
        check(eofThenError.ends == 0 && eofThenError.errorInfo != nil, "EOF followed by error must fail without completing")
        check(errorThenEOF.ends == 0 && errorThenEOF.errorInfo != nil, "EOF cannot override a known error")
        check(delayedError.ends == 0 && delayedError.errorInfo != nil, "A queued error wins within the EOF confirmation window")
        check(cleared.ends == 0, "A withdrawn EOF cannot complete")
        check(replaced.ends == 0 && sought.ends == 0, "Stale load and seek generations cannot complete")
        check(unopened.ends == 0 && unopened.errorInfo != nil, "EOF before file-loaded is a load failure")
        check(noPicture.ends == 0 && noPicture.errorInfo != nil, "EOF before playback-restart is a startup failure")
        check(stopped.ends == 0, "Stop is not completion")
        let rewind = SeekHarness(); _ = await rewind.seek(toSourceTime: 3590)
        check(!rewind.didPublishEnd && rewind.engine.clock.currentTime == 3590, "A local rewind re-arms genuine EOF")
        let remoteSeek = SeekHarness(); remoteSeek.activeSpec?.timeline.local = false
        _ = await remoteSeek.seek(toSourceTime: 3590)
        check(remoteSeek.didPublishEnd, "Replan seeks leave the outgoing epoch untouched")
        print("\(count) production end/recovery checks passed")
    }
}
'''
if not engine_methods:
    start = swift.index('        let natural = EndHarness()')
    end = swift.index('        let rewind = SeekHarness()', start)
    swift = swift[:start] + swift[end:]
with tempfile.TemporaryDirectory(prefix='vivid-end-', dir=root.parent) as folder:
    folder = Path(folder)
    path = folder / 'checks.swift'
    path.write_text(policy + '\n' + swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder/'cache'), str(path), '-o', str(folder/'checks')], check=True, timeout=90)
    subprocess.run([str(folder/'checks')], check=True, timeout=15)

# Verify the production early snapshot without a device or changing HDMI state.
base = source('iosApp/iosApp/Playback/MPV/MpvPlayerCoreBase.swift')
if 'private func prepareInitialDisplayCriteria' not in base:
    raise SystemExit('Missing required early-display implementation')
early = declaration(base, 'private func prepareInitialDisplayCriteria')
early += '\n' + declaration(base, 'private func holdDisplayCriteriaForSource')
cadence = declaration(base, 'static func presentsFields')
rates_start = base.index('private static let nominalRefreshRates:')
rates_end = base.index(']', base.index('= [', rates_start)) + 1
nominal = base[rates_start:rates_end] + '\n' + declaration(base, 'static func nominalRefreshRate')
early_swift = r'''
import Foundation
final class ControlledQueue {
var jobs: [() -> Void] = []
func async(execute: @escaping () -> Void) { jobs.append(execute) }
func drain() { let pending = jobs; jobs = []; pending.forEach { $0() } }
}
enum DispatchQueue { static let main = ControlledQueue() }
final class Delegate {
var events = 0
func onEvent(name: String, data: [String: Any]?) { precondition(name == "display-criteria-prepared"); events += 1 }
}
final class Early {
var preparesDisplayCriteriaEarly = true
let cacheLock = NSLock()
let displayCriteriaCommitLock = NSLock()
var cachedEstimatedFps = 0.0
var commitHeldDuringWrite = false, cacheReleasedDuringWrite = false
var initialDisplayCriteriaPending = true, displayCriteriaHeld = true, isLifecycleActive = true
var displayCriteriaEpoch: UInt64 = 1
var delegate: Delegate? = Delegate()
var params: [String: Any]? = ["w": Int64(1920), "h": Int64(1080), "gamma": "bt.1886"]
var track: [String: Any]? = [:]
var fps: Double? = 24, presented: Double? = 24, deinterlaced: Bool? = false
var applications = 0, resultingFPS = 0.0, resultingProfile: Int64 = 0
var resultingCompatibility: Int64?, resultingGamma: String?
var applies = true
func readMapProperty(_ name: String) -> [String: Any]? { name == "video-out-params" ? params : track }
func readDoubleProperty(_ name: String) -> Double? { name == "container-fps" ? fps : presented }
func readFlagProperty(_ name: String) -> Bool? { deinterlaced }
func validateSideDataDimensions(width: Int64, height: Int64) -> Bool { width > 0 && height > 0 && width <= 16384 && height <= 16384 }
func updateDisplayCriteria(doviProfile: Int64, doviLevel: Int64, doviCompatibilityId: Int64?, fps: Double,
    width: Int32, height: Int32, sigPeak: Double, gamma: String?, primaries: String?, colorMatrix: String?) -> Bool {
    let available = displayCriteriaCommitLock.try()
    commitHeldDuringWrite = !available
    if available { displayCriteriaCommitLock.unlock() }
    cacheReleasedDuringWrite = cacheLock.try()
    if cacheReleasedDuringWrite { cacheLock.unlock() }
    applications += 1; resultingFPS = fps; resultingProfile = doviProfile
    resultingCompatibility = doviCompatibilityId; resultingGamma = gamma
    return applies
}
__EARLY__
__CADENCE__
__NOMINAL__
func prepare() { prepareInitialDisplayCriteria() }
}
@main struct Checks {
static func main() {
    var count = 0
    func check(_ yes: @autoclosure () -> Bool, _ message: String) { precondition(yes(), message); count += 1 }
    let ready = Early(); ready.prepare()
    check(ready.applications == 0, "HDMI writes must dispatch to main")
    DispatchQueue.main.drain()
    check(ready.applications == 1 && ready.resultingFPS == 24, "Decoded cadence starts matching before playback restart")
    check(ready.displayCriteriaHeld, "Partial observers remain held until authoritative restart")
    check(ready.delegate!.events == 1, "Successful early matching emits a timing milestone")
    ready.prepare(); DispatchQueue.main.drain()
    check(ready.applications == 1, "Repeated reconfiguration cannot repeat initial matching")
    for mutate in [
        { (x: Early) in x.preparesDisplayCriteriaEarly = false },
        { (x: Early) in x.params = nil },
        { (x: Early) in x.params?["w"] = Int64(0) },
        { (x: Early) in x.track = nil },
        { (x: Early) in x.fps = nil },
        { (x: Early) in x.fps = .nan },
        { (x: Early) in x.presented = 0 },
        { (x: Early) in x.presented = .infinity },
        { (x: Early) in x.deinterlaced = nil }
    ] {
        let x = Early(); mutate(x); x.prepare(); DispatchQueue.main.drain()
        check(x.applications == 0 && x.initialDisplayCriteriaPending, "Incomplete or disabled snapshot leaves original matching fallback")
    }
    let retry = Early(); retry.params = nil; retry.prepare(); retry.params = ready.params; retry.prepare(); DispatchQueue.main.drain()
    check(retry.applications == 1, "Later valid output can retry an incomplete snapshot")
    for mutate in [
        { (x: Early) in x.displayCriteriaEpoch += 1 },
        { (x: Early) in x.displayCriteriaHeld = false },
        { (x: Early) in x.isLifecycleActive = false }
    ] {
        let x = Early(); x.prepare(); mutate(x); DispatchQueue.main.drain()
        check(x.applications == 0, "Ended, replaced or already-reconciled snapshot cannot change HDMI")
    }
    let interlaced = Early(); interlaced.fps = 25; interlaced.presented = 50; interlaced.prepare(); DispatchQueue.main.drain()
    check(interlaced.resultingFPS == 50, "Measured field output retains doubled refresh")
    let filtered = Early(); filtered.fps = 25; filtered.presented = 25; filtered.deinterlaced = true; filtered.prepare(); DispatchQueue.main.drain()
    check(filtered.resultingFPS == 50, "Explicit deinterlacing retains doubled refresh")
    let dv = Early(); dv.track = ["dolby-vision-profile": Int64(7)]; dv.params?.removeValue(forKey: "gamma"); dv.prepare(); DispatchQueue.main.drain()
    check(dv.resultingProfile == 8 && dv.resultingCompatibility == 1 && dv.resultingGamma == "smpte2084", "DV7 conversion keeps existing output criteria")
    let hdr = Early(); hdr.params?["gamma"] = "smpte2084"; hdr.prepare(); DispatchQueue.main.drain()
    check(hdr.resultingGamma == "smpte2084", "HDR output metadata survives snapshot")
    let rejected = Early(); rejected.applies = false; rejected.prepare(); DispatchQueue.main.drain()
    check(rejected.delegate!.events == 0, "Rejected criteria cannot claim success")
    let locking = Early(); locking.prepare(); DispatchQueue.main.drain()
    check(locking.commitHeldDuringWrite, "Source transitions cannot interleave with the platform write")
    check(locking.cacheReleasedDuringWrite, "Platform write does not hold the cache lock")
    print("\(count) production early-display checks passed")
}
}
'''.replace('__EARLY__', early).replace('__CADENCE__', cadence).replace('__NOMINAL__', nominal)
with tempfile.TemporaryDirectory(prefix='vivid-early-display-', dir=root.parent) as folder:
    folder = Path(folder)
    path = folder / 'checks.swift'
    path.write_text(early_swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder/'cache'), str(path), '-o', str(folder/'checks')], check=True, timeout=90)
    subprocess.run([str(folder/'checks')], check=True, timeout=15)
