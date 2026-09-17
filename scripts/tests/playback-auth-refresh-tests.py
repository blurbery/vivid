#!/usr/bin/env python3
"""Run the production progress-refresh method with an instrumented player boundary."""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--source-ref', help='Run against an unchanged Git revision')
args = parser.parse_args()


def source(path):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=root, text=True)
    return (root / path).read_text()


def declaration(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


view_model = source('iosApp/iosApp/Screens/Player/PlayerViewModel.swift')
method_name = ('updateProtocolV3AuthenticationAfterProgress' if
               'updateProtocolV3AuthenticationAfterProgress' in view_model else
               'attemptProtocolV3AuthenticationReloadAfterProgress')
method = declaration(view_model, 'private func ' + method_name)
policy = source('iosApp/iosApp/Screens/Player/VividLoadSpec.swift')
policy_methods = '\n'.join(declaration(policy, marker) for marker in [
    'static func shouldReload(',
    ('static func shouldUpdateHeadersAfterProgress(' if 'shouldUpdateHeadersAfterProgress' in policy
     else 'static func shouldReloadAfterProgress('),
    'private static func authorizationHeader('
])

swift = r'''
import Foundation
enum PlaybackProgressReportResult { case success, missingSession, transientFailure, deferred }
enum VividAuthenticationRecoveryPolicy {
''' + policy_methods + r'''
}
struct StreamRequest { var headers = ["Authorization": "Bearer new"]; let url = URL(string: "https://example.invalid/media")! }
struct Options { var httpHeaders = ["Authorization": "Bearer old"] }
struct Spec { var planID = "plan"; var sessionID = "session"; var options = Options() }
struct Stream { var headers: [String: String] = [:] }
struct Plan { var nativeApiMajor = 2; var planId = "plan"; var stream = Stream() }
struct Prepared { var plan = Plan(); var serverFeatures: Set<String> = []; var negotiatedAuthorizedMediaOrigins = false }
enum PlaybackProtocolV3 { static let headerAuthenticatedMediaFeature = "header-media" }
struct Logger { func info(_ message: String) {} }
@MainActor final class Controller {
    var activeLoadEpoch: Int? = 1
    var activeSpec: Spec? = Spec()
    var supportsUpdates = false
    var updateCalls = 0
    var position = 123.5
    var paused = false
    var selectedAudio = 2
    var selectedSubtitle = 3
    func updateSourceHeaders(_ headers: [String: String], for epoch: Int,
                             expectedHeaders: [String: String], sourceURL: URL) -> Bool {
        updateCalls += 1
        guard supportsUpdates else { return false }
        activeSpec?.options.httpHeaders = headers
        return true
    }
}
@MainActor final class Bridge {
    var hasSession = true
    func committedProtocolV3Session(planId: String, sessionId: String) async -> Int? { hasSession ? 1 : nil }
}
@MainActor final class Harness {
    static let logger = Logger()
    var protocolV3ReplanTask: Int?
    var activePreparedProtocolV3: Prepared? = Prepared()
    var activePlaybackSessionId: String? = "session"
    var committedProtocolV3LoadEpoch: Int? = 1
    let vividPlaybackController = Controller()
    let sessionBridge = Bridge()
    var request: StreamRequest? = StreamRequest()
    var onResolve: (() -> Void)?
    var reloadCalls = 0
    func makeStreamRequest(session: Int, additionalHeaders: [String: String],
                           requiresHeaderAuthenticatedMedia: Bool, allowsAuthorizedMediaOrigins: Bool,
                           nativeApiMajor: Int) async -> StreamRequest? {
        onResolve?()
        return request
    }
    func beginProtocolV3SameRouteReload(fallbackClassification: String, fallbackMessage: String,
                                       refreshedStreamRequest: StreamRequest? = nil) -> Bool {
        reloadCalls += 1
        vividPlaybackController.activeLoadEpoch = 2
        return true
    }
''' + method + r'''
    func progress(_ result: PlaybackProgressReportResult = .success) async {
        await METHOD(result)
    }
}
@main struct Checks {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
            count += 1
        }
        for paused in [false, true] {
            let h = Harness()
            h.vividPlaybackController.paused = paused
            await h.progress()
            await h.progress()
            check(h.reloadCalls == 0, "Token rotation must not reload a healthy stream")
            check(h.vividPlaybackController.activeLoadEpoch == 1, "Preserve loaded player")
            check(h.vividPlaybackController.position == 123.5, "Preserve playback position")
            check(h.vividPlaybackController.paused == paused, "Preserve play/pause intent")
            check(h.vividPlaybackController.selectedAudio == 2 && h.vividPlaybackController.selectedSubtitle == 3, "Preserve tracks")
            check(h.vividPlaybackController.activeSpec?.options.httpHeaders["Authorization"] == "Bearer old", "Do not claim unsupported headers were installed")
        }
        let capable = Harness()
        capable.vividPlaybackController.supportsUpdates = true
        await capable.progress()
        await capable.progress()
        check(capable.vividPlaybackController.updateCalls == 1, "Update capable readers once")
        check(capable.reloadCalls == 0, "In-place update must not reload")
        for result in [PlaybackProgressReportResult.missingSession, .transientFailure, .deferred] {
            let h = Harness(); await h.progress(result)
            check(h.vividPlaybackController.updateCalls == 0 && h.reloadCalls == 0, "Failed/deferred progress must not touch player")
        }
        for mutation in 0..<7 {
            let h = Harness()
            switch mutation {
            case 0: h.request?.headers = ["Authorization": "Bearer old"]
            case 1: h.request?.headers = [:]
            case 2: h.request = nil
            case 3: h.protocolV3ReplanTask = 1
            case 4: h.sessionBridge.hasSession = false
            case 5: h.activePreparedProtocolV3?.plan.nativeApiMajor = 1
            default: h.activePlaybackSessionId = "different-session"
            }
            await h.progress()
            check(h.vividPlaybackController.updateCalls == 0 && h.reloadCalls == 0, "Ignore unchanged/unavailable/stale context")
        }
        for mutation in 0..<3 {
            let h = Harness()
            h.onResolve = {
                switch mutation {
                case 0: h.activePlaybackSessionId = "replacement-session"
                case 1: h.vividPlaybackController.activeLoadEpoch = 9
                default: h.vividPlaybackController.activeSpec?.options.httpHeaders = ["Authorization": "Bearer newer"]
                }
            }
            await h.progress()
            check(h.vividPlaybackController.updateCalls == 0 && h.reloadCalls == 0, "Reject stale asynchronous completion")
            h.onResolve = nil
        }
        check(VividAuthenticationRecoveryPolicy.shouldReload(failedHeaders: ["Authorization": "Bearer old"], refreshedHeaders: ["authorization": "Bearer new"]), "Actual authentication failure retains changed-token recovery")
        check(!VividAuthenticationRecoveryPolicy.shouldReload(failedHeaders: ["Authorization": "Bearer old"], refreshedHeaders: [:]), "Never recover with missing credentials")
        print("\(count) production auth-refresh checks passed")
    }
}
'''.replace('METHOD(result)', method_name + '(result)')

with tempfile.TemporaryDirectory(prefix='vivid-auth-', dir=root.parent) as temp:
    folder = Path(temp)
    path = folder / 'checks.swift'
    path.write_text(swift)
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'module-cache'),
                    str(path), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=15)
