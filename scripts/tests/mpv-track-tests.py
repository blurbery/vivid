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
