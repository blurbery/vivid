<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Player engine core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../playback/README.md">Playback</a></p>

---

VividKit is Vivid’s player engine core. It handles media reads, demuxing, decoding, rendering, buffering and seeking. The Vivid core owns the interface and playback coordination; server cores supply authenticated sources and session reporting.

## Audio support

Vivid supports TrueHD 7.1 playback through HomePod (2nd generation) speakers connected to Apple TV, using Silo or Emby.

<table width="100%">
  <thead><tr><th align="left">Format</th><th align="left" width="10000">Playback</th></tr></thead>
  <tbody>
    <tr><td>TrueHD 7.1</td><td>Supported through HomePod (2nd generation) speakers on Apple TV. Locally decoded to PCM, with direct source delivery from Silo and Emby.</td></tr>
    <tr><td>E-AC-3</td><td>Native compressed-audio rendering on compatible Apple audio routes.</td></tr>
    <tr><td>DTS</td><td>Local decoding to PCM.</td></tr>
  </tbody>
</table>

Source channel counts describe the input track. Final channel output depends on the Apple audio route. TrueHD playback is not TrueHD bitstream passthrough; Atmos and DTS:X object preservation are not claimed.

## Picture and container support

<table width="100%">
  <thead><tr><th align="left">Format</th><th align="left" width="10000">Playback</th></tr></thead>
  <tbody>
    <tr><td>4K HEVC</td><td>Hardware-first video decoding.</td></tr>
    <tr><td>Dolby Vision</td><td>Compatible Dolby Vision sources, subject to profile and display support. Not all profiles or enhancement layers are supported.</td></tr>
    <tr><td>MKV</td><td>Direct-file playback with local demuxing and decoding.</td></tr>
  </tbody>
</table>

On Apple TV, frame-rate and dynamic-range matching follow the system’s Match Content settings. Server Direct Play describes delivery to Vivid, not the final video or audio output format.

## Playback recovery

Apple TV audio recovery replays retained samples after renderer interruptions and checks that the playback clock advances. If replay stalls, it attempts one seek recovery before reporting an error. Recovery is bounded and respects pauses, user seeks and playback changes.

The Vivid core coordinates credential renewal with the active server core and restores playback from the current position. Next-episode loading clears the outgoing controls while retaining the video surface.

## Implementation

- [VividPlayer](../../VividKit/Sources/VividKit/VividPlayer.swift): playback clock, transport and bounded audio recovery.
- [VividMediaSession](../../VividKit/Sources/VividKit/VividMediaSession.swift): decoding, sample queues and audio replay.
- [Playback guide](../playback/README.md): audio selection, controls and playback behaviour.
