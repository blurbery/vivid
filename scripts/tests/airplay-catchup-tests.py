#!/usr/bin/env python3
"""Exercise the actual Lucid override with the pinned upstream scheduler."""
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
packages, cache = map(Path, sys.argv[1:])

def method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

upstream = method((packages / 'Sources/KSPlayer/AVPlayer/KSOptions.swift').read_text(), 'open func videoClockSync(')
override = method((repo / 'iosApp/iosApp/Playback/LucidFF.swift').read_text(), 'override func videoClockSync(')
source = '''import Foundation
enum ClockProcessType { case next, remain, dropNextFrame, dropGOPPacket, seek, flush }
struct KSClock { var value: Double = 100; func getTime() -> Double { value } }
func KSLog(_ message: String) {}
enum PortType { case airPlay, hdmi }
struct Port { var portType: PortType }
struct Route { var outputs = [Port(portType: .airPlay)] }
class AVAudioSession {
 static let instance = AVAudioSession()
 static func sharedInstance() -> AVAudioSession { instance }
 var currentRoute = Route()
}
class KSOptions { var videoDelay = 0.0; var videoClockDelayCount = 0
 var usesDisplayLayer = true
 func isUseDisplayLayer() -> Bool { usesDisplayLayer }
''' + upstream + '''
}
class LucidOptions: KSOptions {
 struct Dolby { var isNative = false }; var dolbyAudio = Dolby()
 class PCMOutput {
  var admission: (gap: Double, enqueue: Bool)?
  func pcmVideoAdmission(nextTime: Double, fps: Double) -> (gap: Double, enqueue: Bool)? { admission }
 }
 var dolbyAudioOutput: PCMOutput?
''' + override + '''
}
var checks = 0
func expect(_ value: Bool) { precondition(value, "Check \(checks + 1) failed"); checks += 1 }
let options = LucidOptions()
let clock = KSClock()
func action(_ gap: Double, _ fps: Double = 24, _ count: Int = 10) -> ClockProcessType {
 options.videoClockSync(main: clock, nextVideoTime: clock.value + gap, fps: fps, frameCount: count).1
}
// The observed step must recover, while an aligned frame must not be dropped.
expect(action(-0.046) == .dropNextFrame)
expect(action(-0.004) == .next)
expect(action(0.030) == .remain)
expect(action(-0.046, 24, 1) == .next)
for fps in [23.976, 24, 25, 30, 50, 60] {
 expect(action(-1.1 / fps, fps) == .dropNextFrame)
 expect(action(-0.9 / fps, fps) == .next)
 // Existing upstream action discards an additional frame, advancing the next candidate.
 var gap = -0.150
 for _ in 0..<20 { if action(gap, fps) == .dropNextFrame { gap += 1 / fps } }
 expect(gap >= -1 / fps - 0.000001 && gap <= 0.000001)
}
options.dolbyAudio.isNative = true
expect(action(-0.046) == .next)
let pcm = LucidOptions.PCMOutput()
options.dolbyAudioOutput = pcm
pcm.admission = (0.05, true)
expect(action(0.05) == .next)
pcm.admission = (0.2, false)
expect(action(0.2) == .remain)
options.usesDisplayLayer = false
pcm.admission = (0.05, true)
expect(action(0.05) == .remain)
options.usesDisplayLayer = true
options.dolbyAudioOutput = nil
options.dolbyAudio.isNative = false
AVAudioSession.instance.currentRoute.outputs = [Port(portType: .hdmi)]
expect(action(-0.046) == .next)
AVAudioSession.instance.currentRoute.outputs = []
expect(action(-0.046) == .next)
AVAudioSession.instance.currentRoute.outputs = [Port(portType: .airPlay), Port(portType: .hdmi)]
expect(action(-0.046) == .next)
print("Passed \\(checks) AirPlay scheduling checks. Audible sync requires device verification.")
'''
with tempfile.TemporaryDirectory(prefix='vivid-catchup-') as temp:
    file = Path(temp) / 'main.swift'
    file.write_text(source)
    exe = Path(temp) / 'checks'
    subprocess.run(['swiftc', '-D', 'VIVID_ATMOS_TRIAL', '-module-cache-path', str(cache), str(file), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
