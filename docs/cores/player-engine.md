<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Player engine core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../playback/README.md">Playback</a></p>

---

VividKit is Vivid’s player engine core. The local Swift package handles media reads, demuxing, decoding, rendering, buffering and seeking. The Vivid core owns the interface and playback coordination; server cores supply authenticated sources and session reporting. This documents existing ownership, not a new engine or package split.

## Confirmed playback results

**TrueHD 7.1 source playback works on the tested Apple TV and HomePod setup.** On 9 September 2026, blurbery confirmed sound and picture for Dune: Part Two through both Silo and Emby, using Vivid 0.14.3 (1), branch revision `1ccee12`, Apple TV 4K (3rd generation) and HomePod (2nd generation) speakers.

<table width="100%">
  <thead><tr><th align="left">Format</th><th align="left" width="10000">Recorded success and scope</th></tr></thead>
  <tbody>
    <tr><td>TrueHD 7.1</td><td>Dune: Part Two played with sound through Silo and Emby. Owner-supplied screenshots show direct audio delivery, including Emby’s TRUEHD 7.1 label and Silo’s TrueHD Atmos 7.1 source label. Emby recorded playback through 13:06 before the owner stopped it.</td></tr>
    <tr><td>4K HEVC / Dolby Vision source</td><td>The same Dune test played with picture. Emby’s screenshot reports 4K Dolby Vision HEVC with Direct Play; Silo reports HEVC 2160p direct delivery. The owner also reported matching TV information. This is one successful source, not certification of every Dolby Vision profile or enhancement layer.</td></tr>
    <tr><td>MKV, approximately 56 Mbps</td><td>Both screenshots show direct delivery of the Dune container. Direct server delivery does not exclude decoding inside Vivid.</td></tr>
    <tr><td>E-AC-3</td><td>Apple TV probe output shows advancing playback through the HomePod AirPlay route during the September 2026 episode tests.</td></tr>
    <tr><td>DTS</td><td>The owner confirmed Harry Potter playback through HomePod on 8 September 2026. See the playback guide for that earlier test’s scope. DTS:X object preservation was not verified.</td></tr>
  </tbody>
</table>

The Dune screenshots were supplied at 1:14 pm (Silo) and 1:18 pm (Emby), Sydney time. They establish server delivery and source metadata; the owner’s listening/viewing report establishes the functional result. Private screenshots and server addresses are not committed here.

### Source playback and output format

TrueHD source playback is confirmed. TrueHD bitstream passthrough, discrete 7.1 output at the speakers and Atmos-object preservation are not established by this test. The TV probe reported `codec=truehd`, `native=false` and a two-channel AirPlay output route. VividKit’s corresponding path decodes audio locally to PCM. Server Direct Play labels describe delivery to Vivid, not the final speaker format.

Physical iPhone/iPad TrueHD tests, other receivers and a complete audio/video format matrix remain outstanding. Add successful formats with the tested revision, hardware, source and observed result rather than inferring support from a build or filename.

## Recovery test, 9 September 2026

On revision `1ccee12`, the owner reported a successful episode transition and a later Rubble & Crew interruption that loaded again and continued playing. At 1:41:30 pm Sydney time, Silo recorded a progress 401 followed by a successful authentication refresh. Successful media and progress requests continued afterwards, and the TV probe subsequently showed an advancing clock. This confirms continuation after that event, but the retained probe excerpt does not identify the exact recovery step used for that interruption. It is not a claim that every failure mode is fixed.

## Implementation

- [VividPlayer](../../VividKit/Sources/VividKit/VividPlayer.swift): playback clock, transport and bounded audio recovery.
- [VividMediaSession](../../VividKit/Sources/VividKit/VividMediaSession.swift): decoding, sample queues and audio replay.
- [Playback guide](../playback/README.md): selection policy, earlier device results and remaining limits.
