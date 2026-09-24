#!/usr/bin/env python3
"""Exercise the adapter's actual stream/track ID translations without a player."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'iosApp/iosApp/Playback/MPV/VividMPVPlayer.swift').read_text()

def method(name):
    start = source.index('    private func ' + name + '(')
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

swift = '''import Foundation
final class Mapping {
    var rawTracks: [[String: Any]] = []
''' + method('sourceTrackID') + '\n' + method('mpvTrackID') + '''
    func run() {
        rawTracks = [
            ["type": "video", "id": Int64(1), "ff-index": Int64(0)],
            ["type": "audio", "id": Int64(1), "ff-index": Int64(1)],
            ["type": "sub", "id": Int64(1), "ff-index": Int64(2)],
            ["type": "audio", "id": Int64(2), "ff-index": Int64(3)],
            ["type": "sub", "id": Int64(2), "ff-index": Int64(4)]
        ]
        precondition(sourceTrackID(mpvID: 1, type: "audio") == 1)
        precondition(sourceTrackID(mpvID: 1, type: "sub") == 2)
        precondition(sourceTrackID(mpvID: 2, type: "audio") == 3)
        precondition(sourceTrackID(mpvID: 2, type: "sub") == 4)
        precondition(mpvTrackID(sourceID: 3, type: "audio") == 2)
        precondition(mpvTrackID(sourceID: 2, type: "sub") == 1)
        precondition(mpvTrackID(sourceID: 2, type: "audio") == nil)
        precondition(mpvTrackID(sourceID: 0, type: "video") == 1)
        precondition(sourceTrackID(mpvID: nil, type: "audio") == nil)
        precondition(sourceTrackID(mpvID: 99, type: "audio") == nil)
        precondition(mpvTrackID(sourceID: 99, type: "sub") == nil)
        rawTracks = [["type": "audio", "id": Int64(8)]]
        precondition(sourceTrackID(mpvID: 8, type: "audio") == 8)
        precondition(mpvTrackID(sourceID: 8, type: "audio") == 8)
        rawTracks = []
        precondition(sourceTrackID(mpvID: 8, type: "audio") == nil)
        precondition(mpvTrackID(sourceID: 8, type: "audio") == nil)
        print("15 production track-mapping checks passed")
    }
}
Mapping().run()
'''
with tempfile.TemporaryDirectory(prefix='vivid-mpv-tracks-') as temp:
    folder = Path(temp)
    path = folder / 'main.swift'
    path.write_text(swift)
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'module-cache'), str(path), '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=10)

# Run the production teardown/ownership block with deferred native-core doubles.
start = source.index('        core?.delegate = nil\n', source.index('    func stop('))
end = source.index('        core = nil; delegateProxy', start)
teardown = source[start:end]
group_declaration = next(line.strip().removeprefix('private ') for line in source.splitlines()
                         if 'let audioTeardown = DispatchGroup()' in line)
group_access = 'Self.audioTeardown' if group_declaration.startswith('static ') else 'audioTeardown'
swift = r'''
import Foundation
@MainActor final class AVAudioSession {
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    enum Options { case notifyOthersOnDeactivation }
    var deactivations = 0
    func setActive(_ active: Bool, options: Options) throws { if !active { deactivations += 1 } }
}
final class Core {
    var delegate: Int?
    var completion: (@Sendable () -> Void)?
    func dispose(preserveDisplayCriteria: Bool, completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }
    func finish() { completion?(); completion = nil }
}
@MainActor final class Player {
    static var audioSessionOwner: UUID?
    var audioSessionToken: UUID?
    ''' + group_declaration + r'''
    var deactivatesAudioSessionOnStop = false
    var core: Core?
    func activate() {
        let token = UUID(); audioSessionToken = token; Self.audioSessionOwner = token
        core = Core()
    }
    func stop(resetDisplayCriteria: Bool = true) {
''' + teardown + r'''
        core = nil
    }
    func settled() async {
        await withCheckedContinuation { continuation in
            ''' + group_access + r'''.notify(queue: .main) { continuation.resume() }
        }
    }
}
@main struct Checks {
    @MainActor static func main() async {
        let session = AVAudioSession.sharedInstance()
        let player = Player()
        player.activate(); let first = player.core!
        player.stop() // replacement does not release the session
        player.activate(); let second = player.core!
        player.deactivatesAudioSessionOnStop = true
        player.stop(); player.stop() // repeated stop must not release early
        precondition(session.deactivations == 0)
        second.finish()
        precondition(session.deactivations == 0) // first still tearing down
        first.finish(); await player.settled()
        precondition(session.deactivations == 1 && Player.audioSessionOwner == nil)

        player.activate(); let retired = player.core!
        player.stop()
        let successor = Player(); successor.activate()
        let owner = Player.audioSessionOwner
        retired.finish(); await player.settled()
        precondition(session.deactivations == 1 && Player.audioSessionOwner == owner)

        let successorCore = successor.core!
        successor.stop() // final stop while only a previous replacement is pending
        successor.deactivatesAudioSessionOnStop = true
        successor.stop()
        precondition(session.deactivations == 1)
        successorCore.finish(); await successor.settled()
        precondition(session.deactivations == 2 && Player.audioSessionOwner == nil)
        // Final stop in a replacement instance must wait for its predecessor too.
        for olderFinishesFirst in [false, true] {
            let before = session.deactivations
            let older = Player(); older.activate(); let olderCore = older.core!
            older.deactivatesAudioSessionOnStop = true; older.stop()
            let newer = Player(); newer.activate(); let newerCore = newer.core!
            newer.deactivatesAudioSessionOnStop = true; newer.stop()
            (olderFinishesFirst ? olderCore : newerCore).finish()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            if session.deactivations != before {
                print("FAIL: replacement released the session before all player instances retired")
                exit(1)
            }
            (olderFinishesFirst ? newerCore : olderCore).finish()
            await newer.settled()
            precondition(session.deactivations == before + 1 && Player.audioSessionOwner == nil)
        }
        print("10 production audio teardown checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='vivid-audio-teardown-') as temp:
    folder = Path(temp)
    path = folder / 'main.swift'
    path.write_text(swift)
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                    str(folder / 'module-cache'), str(path), '-o', str(binary)],
                   check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=10)
