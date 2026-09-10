<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Player engine core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../playback/README.md">Playback</a></p>

---

VividKit is Vivid’s player engine core. It handles media reads, demuxing, decoding, rendering, buffering and seeking. The Vivid core owns the interface and playback coordination; server cores supply authenticated sources and session reporting.

## tvOS Aether experiment

`test/aether-playback` uses one AetherEngine session on tvOS, behind Vivid's existing playback controller. Native playback prepares local HLS for AVPlayer; unsupported native video uses Aether's software path automatically. There is no player selector. iOS continues using VividKit.

The local `AetherEngine` package derives from upstream 6.80.0 (`89ef0c347a17180739d8ca7a1a1cfbb163135271`). Its source retains the upstream LGPL-3.0 licence and Apple Store exception. Vivid's adapter remains Apache-2.0. The package reuses Vivid's existing FFmpegBuild 3.0.0 revision, rather than introducing a second FFmpeg binary set. Upstream's later legacy Flash and Windows Media codec additions are therefore not promised by this experiment.

The integration resolves audio-list ordinals inside the initial probe. It uses Vivid's existing 2 MB probe and two-second media-analysis limits, with Aether's buffering and display-settling safeguards retained. Subtitle readers start on demand. Sidecars with a non-zero timeline offset stay on Vivid's overlay, with the offset applied before publication. `PlaybackStartup` logs record elapsed time at each checkpoint through the first displayed frame, without source URLs or credentials. The target is the reported 3–4 second opening on the same video; no improvement has yet been measured on a device.

Credential changes use Vivid's existing reload boundary because Aether does not expose in-place request-header replacement. HDMI surround, AirPlay audio, HDR/Dolby Vision matching, seeking, subtitle timing and cancellation require device comparison before adopting the engine. This branch is an experiment, not a validated replacement for the released player.

## Mini cores

One engine, smaller areas of responsibility. The mini cores describe where work belongs so an audio-output fix does not become a rewrite of playback. Code can stay where it is; these names are a map of the engine, not separate copies of it.

<table width="100%">
  <thead><tr><th align="left" width="25%">Mini core</th><th align="left" width="75%">Responsibility</th></tr></thead>
  <tbody>
    <tr><td>Source and buffering</td><td>Media reads, demuxing and bounded compressed-packet queues.</td></tr>
    <tr><td>Playback timing</td><td>Shared clock, transport state, startup readiness, seeking and cancellation.</td></tr>
    <tr><td>Video</td><td>Hardware-first decoding, sample delivery and display-format information.</td></tr>
    <tr><td>Shared audio</td><td>Compressed or decoded audio samples, channel descriptions, enqueueing and retained replay buffers.</td></tr>
    <tr><td>AirPlay audio</td><td>Existing AirPlay/HomePod output behaviour using shared latency and interruption-recovery helpers.</td></tr>
    <tr><td>HDMI audio</td><td>Route-gated detection and bounded recovery of stalled HDMI audio delivery.</td></tr>
    <tr><td>Route selection</td><td>Output-route checks and admission to route-specific recovery.</td></tr>
    <tr><td>Subtitles</td><td>Embedded subtitle decoding and timed cues or rendered overlays.</td></tr>
  </tbody>
</table>

These are responsibility boundaries inside VividKit. `VividHDMIAudioCore` owns the HDMI recovery policy, while `VividAirPlayRecovery` tracks pending AirPlay flushes and checks audio progress. The mini cores still span existing types and share state; documentation does not enforce implementation isolation.

### Source, timing and video

`VividNetwork` reads the supplied source, `VividDemuxer` separates streams, and `VividBuffer` holds compressed packets. Provider authentication and playback planning remain outside VividKit, behind the active server core.

`VividPlayer` owns the `AVSampleBufferRenderSynchronizer`, transport state and startup-readiness decisions. `VividMediaSession` owns decoding workers and seek execution. The video path supplies samples to `AVSampleBufferVideoRenderer` and exposes display-format information to the app's display-matching integration. Route-specific audio work must preserve normal startup thresholds, video decoding and display matching unless a shared change is explicitly required and validated.

### Shared audio

`VividMediaSession` supplies supported compressed audio packets or locally decoded PCM to `AVSampleBufferAudioRenderer`. PCM conversion and channel descriptions live in `CVividMedia`; audio and video remain attached to the same synchroniser.

Sample enqueueing and audio-recovery queue operations use the session's condition lock. The retained replay buffer belongs to this shared layer. A route-specific policy requests a queue operation through the session rather than directly changing decoder state or creating another playback clock.

On Apple TV, `TVPCMAudioSession` declares multichannel content and requests an output channel count for HDMI video playback using decoded PCM. Requests respect the selected track and the active route's reported maximum. Native compressed audio, HLS and other output routes retain their existing configuration. Rejected requests are logged without failing playback; repeated identical requests are suppressed, and previous preferences are restored where still applicable when playback ends. Release logs under `AudioSession` record source, maximum, preferred and actual output channels without device identifiers. These APIs do not identify ARC or force Dolby Digital, and surround output with Apple TV set to Auto still requires receiver testing.

### AirPlay audio

This names the existing AirPlay output path, including HomePod playback. It is not a new class or a HomePod-only decoder. The existing tvOS helpers are also used by other routes.

Audio enqueue look-ahead follows the reported output latency: `min(8, max(1, latency + 1))` seconds for finite latency values. Renderer flush and output-configuration notifications invoke bounded recovery. It first replays retained samples; if playback progress is not restored, it attempts seek-based recovery. Unlike the HDMI audio-only reset, this seek coordinates both audio and video workers.

AirPlay confirmation requires playback-clock movement and queued-audio progress beyond the current playhead. Flush notifications received during recovery are coalesced and replayed within the existing attempt budget and confirmation deadline. Cancellation, pauses, seeks and route changes invalidate stale confirmation. Queue progress is not a direct measurement of audible output, and AirPlay receivers can differ in behaviour.

### HDMI audio

`VividHDMIAudioCore` owns the stall-detection state and returns `none`, `flushAudio`, `recovered` or `failed`. It does not own a decoder, renderer or clock. `VividPlayer` supplies observations and applies actions through `VividMediaSession`.

- **Admission:** tvOS Release builds admit a non-empty output list containing only `HDMIOutput`. Debug builds require `-VividHDMIAudioCore` and the same pure-HDMI route. AirPlay, HomePod, Bluetooth, empty and mixed output lists remain excluded.
- **Detection:** active playback with unfinished audio and no existing audio-recovery task. The clock advances, the queued-audio endpoint stays stationary, the renderer refuses more samples, and the clock is over 0.25 seconds ahead of that endpoint. Before the first reset, a renderer reporting sufficient media permits recovery after 0.5 seconds of sustained blockage; otherwise the threshold remains six seconds. Temporary buffering cannot start a reset.
- **Reset:** flush only the audio renderer under the session lock and clear retained replay samples. During catch-up, discard pending samples ending at or before the later of the captured recovery position and the current playhead. Clear the discard boundary after enqueueing a sample starting at or beyond that boundary. No source seek, video flush or clock reset is requested by this action.
- **Confirmation:** within six seconds, the queued-audio endpoint must advance by more than 0.1 seconds from its pre-reset value and exceed the current clock by more than 0.04 seconds. This confirms queue progress, not sound reaching the speakers.
- **Budget:** one HDMI reset per loaded session. Temporary buffering preserves pending confirmation without extending its deadline. Pause, seek, ineligible playback and departure from HDMI suspend pending detection or confirmation without replenishing the attempt. A new load resets the component through `stop()`.
- **Failure:** a confirmation timeout or a second sustained six-second stall returns `failed`; the player reports a renderer error and stops the session. It does not retry indefinitely.

### Route selection

Route selection is currently a small integration in `VividPlayer.poll()`, not a separate routing service. It reads `AVAudioSession.currentRoute` and applies the HDMI admission rule. AirPlay, Bluetooth, empty and mixed output lists bypass the HDMI component and retain existing handling. Leaving HDMI clears its pending observations and sample-discard boundary.

Existing notification-driven recovery takes precedence: the HDMI component suspends while that task is active. The buffered-clock-stall detector is excluded while HDMI recovery is awaiting confirmation. These checks coordinate shared state; they do not create independent playback pipelines.

### Subtitles

`VividSubtitleEngine` manages subtitle cues and rendering, with `VividASSRenderer` handling ASS rendering. Subtitle selection and presentation remain connected to the shared playback position. Audio-route recovery must not change the selected subtitle tracks.

### Working within the boundaries

Keep route-specific policy in its mini core and shared mechanisms in the session. Changes to a shared decoder, queue or clock require validation across affected routes. Moving files is not required to follow these boundaries, and a successful test on one output does not establish compatibility with every output.

## Audio support

Vivid supports the following audio formats. On Apple TV, audio playback is supported over HDMI and AirPlay, including HomePod. Available output channels and spatial audio depend on the source, connected audio system and system settings.

<table width="100%">
  <thead><tr><th align="left" width="25%">Format</th><th align="left" width="75%">Playback</th></tr></thead>
  <tbody>
    <tr><td>AAC</td><td>Supported stereo playback.</td></tr>
    <tr><td>AC-3<br><sub>Dolby Digital</sub></td><td>Supported stereo playback.</td></tr>
    <tr><td>DTS</td><td>Supported stereo and 5.1 source playback.</td></tr>
    <tr><td>DTS-HD Master Audio</td><td>Supported 5.1 source playback.</td></tr>
    <tr><td>DTS:X 7.1</td><td>Supported source playback.</td></tr>
    <tr><td>TrueHD 7.1</td><td>Supported source playback.</td></tr>
    <tr><td>Opus 5.1 / 7.1</td><td>Supported source playback.</td></tr>
    <tr><td>FLAC</td><td>Supported stereo playback.</td></tr>
    <tr><td>E-AC-3<br><sub>Dolby Digital Plus</sub></td><td>Supported 5.1 source playback, with Dolby Atmos playback from Atmos-enabled sources on compatible audio routes.</td></tr>
  </tbody>
</table>

DTS-family and TrueHD playback uses local decoding to PCM. For these formats, source playback does not imply bitstream passthrough or preservation of DTS:X or TrueHD Atmos object metadata. Surround output depends on the audio route.

E-AC-3/JOC Atmos playback support does not imply independently verified end-to-end bitstream passthrough or Atmos-object preservation.

## Picture and container support

<table width="100%">
  <thead><tr><th align="left" width="25%">Format</th><th align="left" width="75%">Playback</th></tr></thead>
  <tbody>
    <tr><td>H.264 / AVC</td><td>1080p playback supported.</td></tr>
    <tr><td>4K HEVC</td><td>Hardware-first video decoding.</td></tr>
    <tr><td>AV1</td><td>1080p and 4K playback supported. Performance depends on device decoding capabilities.</td></tr>
    <tr><td>HDR10</td><td>Playback supported on compatible HDR displays.</td></tr>
    <tr><td>Dolby Vision</td><td>Compatible Dolby Vision sources, subject to profile and display support. Not all profiles or enhancement layers are supported.</td></tr>
    <tr><td>MKV</td><td>Direct-file playback with local demuxing and decoding.</td></tr>
  </tbody>
</table>

On Apple TV, frame-rate and dynamic-range matching follow the system’s Match Content settings. Server Direct Play describes delivery to Vivid, not the final video or audio output format.

## Subtitle support

<table width="100%">
  <thead><tr><th align="left" width="25%">Format</th><th align="left" width="75%">Playback</th></tr></thead>
  <tbody>
    <tr><td>PGS</td><td>Embedded image-based subtitles.</td></tr>
    <tr><td>ASS</td><td>Embedded styled text subtitles.</td></tr>
  </tbody>
</table>

## Playback recovery

Apple TV audio recovery replays retained samples after renderer interruptions and checks that the playback clock advances. AirPlay additionally requires queued-audio progress and retains flush notifications received during recovery. If replay stalls, it attempts one seek recovery before reporting an error. The HDMI component handles blocked audio delivery with an audio-only reset. It is enabled in Release only when every active output is HDMI; Debug builds retain the launch-argument gate. Recovery is bounded and respects pauses, user seeks and playback changes.

The Vivid core coordinates credential renewal with the active server core. Direct playback updates credentials in the existing network reader and controller snapshot, preserving buffered media; an in-flight 401 uses bounded authenticated resumption. Native HLS and unsupported recovery cases retain reconstruction from the current position. Transient delivery failures also support validated byte-range resumption before requesting another route, including proactive recovery while playable headroom is shrinking. See [direct-network recovery](../playback/architecture.md#direct-network-recovery) for eligibility and shared retry limits. Next-episode loading clears the outgoing controls while retaining the video surface.

## Implementation

- [VividPlayer](../../VividKit/Sources/VividKit/VividPlayer.swift): playback clock, transport and bounded audio recovery.
- [VividMediaSession](../../VividKit/Sources/VividKit/VividMediaSession.swift): decoding, sample queues and audio replay.
- [VividHDMIAudioCore](../../VividKit/Sources/VividKit/VividHDMIAudioCore.swift): route-gated HDMI audio-stall detection and recovery policy.
- [VividAirPlayRecovery](../../VividKit/Sources/VividKit/VividAirPlayRecovery.swift): pending flush tracking and audio-progress confirmation.
- [HDMI policy tests](../../VividKit/Tests/VividKitTests/VividHDMIAudioCoreTests.swift): route exclusion, stall detection, bounded recovery and cancellation of pending confirmation.
- [Playback guide](../playback/README.md): audio selection, controls and playback behaviour.
