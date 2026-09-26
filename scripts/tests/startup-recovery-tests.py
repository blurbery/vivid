#!/usr/bin/env python3
"""Run extracted Vivid startup code in an isolated iOS Simulator app.

Requires an already-booted simulator. Uses fake credentials and account updates;
never launches, uninstalls or reads the installed Vivid app.
--source-ref <pre-fix-revision> with --expect-stall verifies the original failure.
"""
import argparse
import atexit
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device')
parser.add_argument('--platform', choices=['ios', 'tvos'], default='ios')
parser.add_argument('--compile-only', action='store_true')
parser.add_argument('--source-ref')
parser.add_argument('--capture-loading', type=Path)
parser.add_argument('--expect-stall', action='store_true')
args = parser.parse_args()
if not args.compile_only and not args.device:
    parser.error('--device is required unless --compile-only is used')
repo = Path(__file__).resolve().parents[2]
root = repo / 'iosApp/iosApp'
temporary = tempfile.TemporaryDirectory(prefix='vivid-startup-test-')
atexit.register(temporary.cleanup)
out = Path(temporary.name)

def read(relative):
    if args.source_ref:
        return subprocess.check_output(
            ['git', 'show', f'{args.source_ref}:iosApp/iosApp/{relative}'],
            cwd=repo, text=True, timeout=15)
    return (root / relative).read_text()

source=read('ContentView.swift')
def between(start,end):
 return source[source.index(start):source.index(end,source.index(start))]
check=between('    private func checkInitialState() async {','    private func finishInitialStartupIfReady()')
finish=between('    private func finishInitialStartupIfReady()', '    #if DEBUG\n    /// Dumps')
launch=between('    @ViewBuilder\n    private var launchContent:', '    @ViewBuilder\n    private var authContent:')
stable_task = '\n        .task(id: initialStateAttempt)' in source
if stable_task:
 task=between('        .task(id: initialStateAttempt)', '        #if os(iOS) || os(tvOS)\n        .sheet')
else:
 task=between('            .task(id: initialStateAttempt)', '\n\n        case .needsServerSetup')
retry=read('Shared/SharedStorage.swift').split('struct KeychainReadFailure:')[1].split('/// Minimal Keychain')[0]
splash=read('tvOS/Components/VividStartupView.swift').replace('VividLoadingDots()', 'VividLoadingDots().onAppear { trace("dots visible") }.onDisappear { trace("dots hidden") }')
dots=read('Screens/Player/PlayerBufferingCapsule.swift').split('struct VividLoadingDots: View {')[1].split('struct VividLoadingProgressStyle')[0]
preamble=r'''
import SwiftUI
import UIKit
import Security
@MainActor func trace(_ text: String) {
 let path=URL.documentsDirectory.appending(path:"result.txt")
 let previous=(try? String(contentsOf:path,encoding:.utf8)) ?? ""
 try! (previous+text+"\n").write(to:path,atomically:true,encoding:.utf8)
}
@Observable @MainActor final class AppRouter {
 enum AuthState: String { case loading, needsServerSetup, needsLogin, needsProfile, authenticated
 var diagnosticsState: String { rawValue } }
 var authState: AuthState = .loading
 var path=NavigationPath()
}
@Observable @MainActor final class ServerRegistry {
 static let shared=ServerRegistry()
 var activeServerId: String?="emby:test"
 var entries=["emby:test"]
 func retryInitialRegistryReadIfNeeded() throws {}
}
@Observable @MainActor final class TVSavedAccountStore {
 static let shared=TVSavedAccountStore()
 var accounts=["saved-user"]
 var contentRevision=0
 func prepareColdLaunch() {}
 func restoreLocalSessionForLaunch() async throws {}
}
@MainActor final class VividCloudAccountSync {
 static let shared=VividCloudAccountSync()
 func synchronize(router: AppRouter) async {}
}
actor TokenStore {
 static let shared=TokenStore()
 var count=0
 func hasAccessTokenForActiveServer(serverId: String) async throws -> Bool {
  if CommandLine.arguments.contains("--slow") { try await Task.sleep(for:.seconds(4)); return true }
  if CommandLine.arguments.contains("--unavailable") { throw KeychainReadFailure(status: errSecNotAvailable) }
  if CommandLine.arguments.contains("--missing-token") { return false }
  count += 1
  if count == 1 { throw KeychainReadFailure(status: errSecNotAvailable) }
  return true
 }
}
@MainActor final class AuthService {
 static let shared=AuthService()
 var hasServer=true
 func resolveActiveProfileForSession() async -> Bool { !CommandLine.arguments.contains("--profile") }
}
enum Route: Hashable { case serverSetup }
enum HTTPError: Error { case requestIdentityChanged }
struct TVAppBackdrop: View { var body: some View { Color.black.ignoresSafeArea() } }
@MainActor enum StartupContentPrefetcher {
 static func prefetchForInitialRoute(_ state: AppRouter.AuthState) {}
}
@MainActor enum LaunchTimeline {
 static func recordInitialStateCheckStarted() { trace("startup task entered") }
 static func recordInitialStateResolved(state: String) { trace("resolved "+state) }
 static func recordFirstContent(state: String) { trace("first content "+state) }
 static func recordSplashFinished() { trace("splash finished") }
}
struct Harness: View {
 @State private var router=AppRouter()
 @State private var didCompleteProviderSetup=true
 @State private var didStartInitialStateCheck=false
 @State private var initialStateAttempt=0
 @State private var showsCredentialReadError=false
 @State private var didFinishStartupSplash=false
 @State private var showsStartupOverlay=true
 @State private var pendingInitialAuthState: AppRouter.AuthState?
 @Environment(\.accessibilityReduceMotion) private var reduceStartupMotion
 var body: some View {
  launchContent
   .id(ServerRegistry.shared.activeServerId)
   .id(TVSavedAccountStore.shared.contentRevision)
__STARTUP_TASK__
   .onChange(of: showsStartupOverlay) { _, value in trace("overlay \(value) route=\(router.authState.rawValue)") }
   .onChange(of: didStartInitialStateCheck) { _, value in trace("started flag \(value)") }
   .onChange(of: showsCredentialReadError) { _, value in trace("credential alert \(value)") }
   .task {
    // Survives the subtree re-key, like ContentView's own State.
    Task { @MainActor in
     try? await Task.sleep(for:.seconds(2))
     trace("FINAL route=\(router.authState.rawValue) overlay=\(showsStartupOverlay) started=\(didStartInitialStateCheck) pending=\(pendingInitialAuthState?.rawValue ?? "nil")")
     try? await Task.sleep(for:.seconds(8))
     trace("AFTER 10s route=\(router.authState.rawValue) overlay=\(showsStartupOverlay) started=\(didStartInitialStateCheck)")
    }
   }
 }
 @ViewBuilder var authContent: some View {
  if router.authState == .loading {
   Color.black.ignoresSafeArea()
'''
end=r'''
  } else { Text("HOME").foregroundStyle(.green) }
 }
}
@main struct ReproApp: App {
 init() {
  try? FileManager.default.removeItem(at:URL.documentsDirectory.appending(path:"result.txt"))
  let interrupted=CommandLine.arguments.contains("--interrupt")
  trace("MODE \(interrupted ? "interrupt" : "control")")
  if interrupted || CommandLine.arguments.contains("--server-change") {
   Task { @MainActor in
    try? await Task.sleep(for:.milliseconds(150))
    trace("injected account revision change")
    if CommandLine.arguments.contains("--server-change") {
     ServerRegistry.shared.activeServerId = "emby:other"
    } else { TVSavedAccountStore.shared.contentRevision += 1 }
   }
  }
 }
 var body: some Scene { WindowGroup { Harness() } }
}
'''
if 'guard await StartupContentPrefetcher.prefetchForInitialRoute' in check:
    preamble = preamble.replace(
        'static func prefetchForInitialRoute(_ state: AppRouter.AuthState) {}',
        'static func prefetchForInitialRoute(_ state: AppRouter.AuthState) async -> Bool { true }')

# Use the original task modifier, launch gate, launch resolution and retry helper.
text=preamble.replace("__STARTUP_TASK__",task if stable_task else "")+("" if stable_task else task)+end.split('@main')[0].replace('\n}\n','\n'+launch+check+finish+'\n}\n',1)+'@main'+end.split('@main')[1]+ '\nstruct KeychainReadFailure:'+retry+'\n'+splash+'\nstruct VividLoadingDots: View {'+dots+'\n'+read('tvOS/Components/VividLogoView.swift')
(out/'Repro.swift').write_text(text)
app=out/'StartupRepro.app';app.mkdir(exist_ok=True)
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.codex.vivid-startup-repro','CFBundleName':'StartupRepro','CFBundleExecutable':'StartupRepro','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False}}))


bundle = 'com.codex.vivid-startup-repro'
def sim(*arguments, check=True):
    result = subprocess.run(['xcrun', 'simctl', *arguments], check=check,
                            capture_output=True, text=True, timeout=30)
    return result.stdout.strip()

sdk_name = 'appletvsimulator' if args.platform == 'tvos' else 'iphonesimulator'
assets = out / 'Assets.xcassets'
assets.mkdir()
for mark in ['VividMarkSilver', 'VividMarkLeft', 'VividMarkRight']:
    shutil.copytree(root / 'Assets.xcassets' / (mark + '.imageset'), assets / (mark + '.imageset'))
subprocess.run(['xcrun', 'actool', str(assets), '--compile', str(app),
                '--platform', sdk_name, '--minimum-deployment-target', '18.0',
                '--target-device', 'tv' if args.platform == 'tvos' else 'iphone', '--output-partial-info-plist', str(out / 'assets.plist')],
               check=True, stdout=subprocess.DEVNULL, timeout=60)
sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', '--sdk', sdk_name, 'swiftc',
                '-module-cache-path', str(out / 'ModuleCache'),
                '-target', f'arm64-apple-{args.platform}18.0-simulator', '-sdk', sdk,
                '-parse-as-library', str(out / 'Repro.swift'), '-o', str(app / 'StartupRepro')],
               check=True, timeout=120)
if args.compile_only:
    print(f'PASS {args.platform}: extracted startup flow compiled')
    raise SystemExit(0)
sim('install', args.device, str(app))
try:
    result_file = Path(sim('get_app_container', args.device, bundle, 'data')) / 'Documents/result.txt'
    cases = [('control', 'authenticated'), ('interrupt', 'authenticated')]
    if not args.expect_stall:
        cases += [('server-change', 'authenticated'), ('slow', 'authenticated'), ('missing-token', 'needsLogin'),
                  ('profile', 'needsProfile'), ('unavailable', None)]
    for mode, route in cases:
        result_file.unlink(missing_ok=True)
        sim('launch', args.device, bundle, '--' + mode)
        expected = ('AFTER 10s route=loading overlay=true started=false'
                    if args.expect_stall and mode == 'interrupt'
                    else 'credential alert true' if route is None
                    else 'overlay false route=' + route)
        captured = False
        for _ in range(80):
            time.sleep(0.25)
            result = result_file.read_text() if result_file.exists() else ''
            if args.capture_loading and mode == 'slow' and 'dots visible' in result and not captured:
                sim('io', args.device, 'screenshot', str(args.capture_loading))
                captured = True
            if expected in result:
                break
        else:
            raise AssertionError(f'{mode}: expected {expected}\n{result}')
        assert result.count('startup task entered') == (2 if mode == 'server-change' else 1), result
        assert ('dots visible' in result) == (mode == 'slow'), result
        if route is None:
            assert 'first content' not in result, result
        print(f'PASS {mode}: {expected}', flush=True)
        sim('terminate', args.device, bundle)
finally:
    sim('terminate', args.device, bundle, check=False)
    sim('uninstall', args.device, bundle)
