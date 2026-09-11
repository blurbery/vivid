<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Player engine core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../playback/README.md">Playback</a></p>

---

Vivid uses AetherEngine on tvOS and VividKit on iOS. Each engine handles media reads, demuxing, decoding, rendering, buffering and seeking. The Vivid core owns the interface and playback coordination; server cores supply authenticated sources and session reporting.

## Apple TV playback

Vivid uses one AetherEngine session on tvOS, behind Vivid's existing playback controller. Native playback prepares local HLS for AVPlayer; unsupported native video uses Aether's software path automatically. There is no player selector. iOS continues using VividKit.

The local `AetherEngine` package derives from upstream 6.80.0 (`89ef0c347a17180739d8ca7a1a1cfbb163135271`). Its source retains the upstream LGPL-3.0 licence and Apple Store exception. Vivid's adapter remains Apache-2.0. The package reuses Vivid's existing FFmpegBuild 3.0.0 revision, rather than introducing a second FFmpeg binary set. Upstream's later legacy Flash and Windows Media codec additions are therefore not promised by this integration.

The integration resolves audio-list ordinals inside the initial probe. It uses Vivid's existing 2 MB probe and two-second media-analysis limits, with Aether's buffering and display-settling safeguards retained. Native subtitle readers prepare receiver-readable captions, matching Sodalite’s external-playback integration. Sidecars with a non-zero timeline offset stay on Vivid's overlay, with the offset applied before publication. `PlaybackStartup` logs record elapsed time at each checkpoint through the first displayed frame, without source URLs or credentials. The target is the reported 3–4 second opening on the same video; no improvement has yet been measured on a device.

On tvOS, both native routes use a persistent AVPlayerViewController, which owns the native Now Playing session. Vivid forwards title and artwork as item metadata; the software route keeps its shared-session fallback. Local HLS permits Aether’s AirPlay host rewrite, while direct remote HLS with custom headers remains blocked for receiver fetching. The tvOS adapter follows Sodalite’s subtitle handoff: actual external video or PiP selects native renditions and hides the local overlays; returning to fullscreen restores the overlays. Item and track changes reapply the handoff, with duplicate notifications coalesced. Normal HDMI audio does not trigger it. Bitmap subtitles and secondary captions do not gain native rendition support from this change. Vivid retains its custom controls and countdown screen. Public AVKit flags hide the native transport and info panels, while Aether remains the sole display-criteria writer. UIKit activity indicators inside the native host are suppressed so Vivid owns the loading dots. This uses public view types, without matching private AVKit class names; the visible result still needs checking on the target tvOS version. PiP remains disabled in this tvOS host. The countdown preview and fullscreen reuse one controller. Next-episode loads retain Vivid’s in-place item replacement, matching Sodalite’s no-stop handoff. Native first-picture reporting comes from AVKit’s displayed-frame signal and rejects the outgoing item; software playback retains Aether’s readiness signal. These guards do not substitute for a device test of consecutive episodes. The reported startup pause still needs device verification.

On tvOS, Automatic buffering uses Aether’s ten-segment read-ahead target (roughly 40 seconds beyond the consumer’s requests). Stats distinguish AVPlayer’s loaded-range buffer from Read-ahead available, calculated from Aether’s contiguous buffered frontier minus the playhead on the same display timeline. The latter includes consumer-fetched media plus contiguous prepared segments, and is omitted during seeks, live streams and routes without that measurement. Both Apple TV timeline bars use this measured read-ahead when available, falling back to the consumer buffer on other routes. Playback recovery continues using the separate consumer-buffer value. The target is not substituted for measured availability. Presets offer 1, 5 and 10 minutes and a disk-limited whole-file window. The existing 80-second selection remains available so saved preferences keep their actual buffer depth. Producer and cache windows stay under Aether’s control. Prefer Lossless Audio appears directly below Buffer Ahead in the Apple TV playback settings and defaults off; enabling it selects Aether’s lossless bridge for the next load. Multichannel PCM requires a compatible output route and may become stereo through some TV/ARC connections. Fullscreen subtitle styling and language choices remain Vivid’s; shifted sidecars still use its overlay.

Credential changes use Vivid’s existing reload boundary because Aether does not expose in-place request-header replacement. blurbery accepted the local Apple TV build 11 for adoption after testing. That feedback does not establish coverage of every HDMI receiver, AirPlay route, HDR/Dolby Vision profile or subtitle format; those combinations still need device verification.

## Audio ownership by platform

| Platform/path | Audio handling | Playback owner |
| --- | --- | --- |
| Apple TV, native | Compatible compressed audio can be copied. Audio requiring conversion uses E-AC-3 up to 5.1 for multichannel sources by default; mono/stereo sources use FLAC. Prefer Lossless Audio selects FLAC up to 7.1. AVPlayer renders the prepared stream. | One AetherEngine session owns picture, sound and their timeline. |
| Apple TV, software fallback | Aether decodes audio and sends it to its Apple audio output alongside software-path video. | The same AetherEngine session selects the fallback automatically. |
| iPhone/iPad | VividKit uses supported compressed-audio rendering or FFmpeg-decoded PCM. | VividKit owns the synchronised audio/video session. |

Vivid owns the interface, server integration and IntroDB prompts. It does not run VividKit audio beside Aether video on Apple TV. The receiver’s final signal depends on Apple TV audio settings and the TV/receiver connection; the bridge codec is not proof of the receiver’s output format. TrueHD Atmos and DTS:X objects are not preserved by conversion to E-AC-3 or FLAC.

The Info route, route diagnostics and Stats route use the platform engine name: AetherEngine on tvOS and VividKit on iPhone/iPad.

## Aether capability reference

This is a summary of AetherEngine 6.80.0 at `89ef0c347a17180739d8ca7a1a1cfbb163135271`, checked against its [format guide](https://github.com/superuser404notfound/AetherEngine/blob/89ef0c347a17180739d8ca7a1a1cfbb163135271/docs/formats.md), [API reference](https://github.com/superuser404notfound/AetherEngine/blob/89ef0c347a17180739d8ca7a1a1cfbb163135271/docs/api.md) and [feature overview](https://github.com/superuser404notfound/AetherEngine/blob/89ef0c347a17180739d8ca7a1a1cfbb163135271/README.md). It records engine capabilities, not certification of every combination in Vivid. Upstream describes several hosts and newer FFmpeg packages; Vivid uses Aether only on tvOS and keeps FFmpegBuild 3.0.0. Changes to that pin need their own compatibility checks.

### Containers, video and HDR

| Capability | Engine behaviour and Vivid boundary |
| --- | --- |
| Containers | MKV, MP4, WebM, MPEG-TS, MPEG-PS/VOB, AVI, OGG and FLV demuxing. Container support does not guarantee that its video/audio decoders are included. Vivid supplies authenticated provider URLs. |
| Native video | H.264, HEVC and Main10 use the native Apple path when the hardware accepts the profile. Aether prepares compatible HLS/fMP4 and selects software fallback when necessary. |
| Software video | AV1/dav1d, VP8/VP9, MPEG-4 Part 2, MPEG-2, VC-1 and other codecs with compiled decoders use the software path. Apple TV hardware without AV1 decoding uses software AV1, with higher CPU cost. Unsupported high-bit-depth/chroma profiles also depend on the hardware probe and bundled decoder. |
| Interlaced video | Aether detects interlacing and has deinterlacing paths with CPU fallback. Progressive sources keep their ordinary route. Vivid has no separate deinterlacing preference; filter availability depends on its FFmpeg pin. |
| SDR, HDR10 and HLG | Colour signalling reaches Apple’s rendering pipeline; the display and system settings determine presentation. Vivid passes its Match Content preferences to Aether, which owns display criteria. |
| HDR10+ | HEVC stream-copy retains ST 2094-40 metadata. Displaying the dynamic grade needs a compatible Apple/display route; preserving metadata alone is not end-to-end verification. |
| Dolby Vision P5 | Native Dolby Vision signalling handles the DV-only colour space. Upstream documents Apple-managed conversion for non-DV presentation; Vivid still needs device/source coverage for those combinations. |
| Dolby Vision P8.1 / P8.4 | HDR10- and HLG-compatible bases respectively, with DV metadata/signalling for compatible presentation. P8.2 uses its SDR base, not Dolby Vision output. |
| Dolby Vision P7 | Converted to single-layer P8.1 where eligible, using LibDovi. The enhancement layer is discarded, including FEL data; this is not full dual-layer Profile 7 reproduction. Non-DV routes can use the HDR10 base. |
| AV1 Dolby Vision P10 | Native DV depends on hardware AV1 support. P10.0 has incorrect colours in software decoding; P10.1/P10.4 offer HDR10/HLG bases and P10.2 an SDR base. Do not advertise full P10 support on software-only Apple TV hardware. |
| 3D | MVC can fall back to a 2D base view. Frame-packed pictures and MV-HEVC base-layer playback do not mean Vivid provides stereoscopic output or eye-selection controls. |
| Damaged timing/configuration | The engine includes narrowly gated H.264 composition-timing repairs and HEVC parameter-set normalisation. These preserve ordinary media routing and do not establish support for arbitrary damaged files. |

The upstream overview also lists ASF/WMV with WMA, and older Flash video/audio families. Its detailed guide attributes complete WMA/ASF support to FFmpegBuild 3.1.0 and the Flash additions to 3.2.0. Vivid’s 3.0.0 pin therefore does **not** promise those later combinations. Remote DASH manifests are not a supported input path.

### Audio formats and output

| Source or feature | Handling |
| --- | --- |
| AAC-LC, AC-3, E-AC-3, FLAC, ALAC | Eligible native-path stream-copy. HE-AAC/HE-AACv2 depend on usable codec configuration; transport-framed AAC may need bridging. |
| TrueHD/MLP, DTS/DTS-HD MA, MP3/MP2, Opus, Vorbis and PCM/LPCM | Decoded and re-encoded where the native fMP4 route needs it, subject to decoder availability. Software playback uses its decoded audio output. |
| Default compatibility bridge | More than two channels selects E-AC-3, capped at 5.1 by the bundled encoder. Mono/stereo selects lossless FLAC. Audio and video keep the same session timeline. |
| Prefer Lossless Audio | Selects the FLAC bridge, carrying up to 7.1 to AVPlayer for PCM decoding. The output route must accept multichannel PCM. This setting does not recover information absent from a lossy source. |
| E-AC-3/JOC Atmos | The engine preserves eligible JOC packets through stream-copy and lets Apple handle output. Atmos indication/rendering depends on the system route. Vivid has not certified every receiver or headphone combination. |
| TrueHD Atmos / DTS:X | Conversion preserves supported channel-based audio, not the source’s object metadata. Neither bridge creates Atmos/JOC objects. |
| Unsupported audio | Upstream identifies AC-4 and MPEG-H as lacking decoders. A named codec or container is not a guarantee that a decoder exists in this build. |
| Track selection and delay | Vivid maps real engine track IDs, language preferences and audio delay. Additional upstream audio-delivery diagnostics and opt-in Atmos confirmation APIs are not automatically exposed by this adapter. |

HDMI, AirPlay/HomePod and Bluetooth are output routes, not separate player choices. Aether’s bridge selection cannot force a television or receiver to accept a format. Keep source codec, bridge codec and actual receiver output distinct when diagnosing sound.

### Subtitles and captions

| Capability | Engine support | Vivid integration |
| --- | --- | --- |
| Text | SubRip/SRT, ASS/SSA, WebVTT and mov_text; plain and rich-text cues with placement. | Primary selection, off, language preferences, timing and appearance pass through Vivid’s overlay. Rich-text attributes and placement are mapped by the adapter. |
| Bitmap | PGS/HDMV PGS, DVB and DVD subtitle images, including composition positioning. | Bitmap cues are mapped to the fullscreen overlay. Actual source/layout coverage still needs playback tests. |
| Authored ASS | Optional raw markup and embedded-font access for a host renderer. | Vivid sets `preserveASSMarkup` false on this path. Basic styled cues are not full libass animation/typesetting parity. |
| Two tracks | Simultaneous primary and secondary subtitle cues. | Vivid exposes secondary selection in its overlay. Native external presentation does not guarantee both tracks. |
| External files | Register sidecars or subtitle containers as selectable tracks, with headers, language and stream identity. | Adapter plumbing exists, including timeline offsets, but external-file browsing/search is not exposed by the current library player. |
| Native renditions | Generated WebVTT for native external playback/PiP; upstream can derive text from bitmap tracks using on-device OCR. | Vivid prepares native renditions and switches rendering during actual external playback. OCR is lossy, not pixel-equivalent PGS output; this route has not been verified for every bitmap track. Shifted sidecars remain overlay-only. |
| Broadcast captions | CEA-608 CC1 from caption tracks or video side data; DVB teletext text/colour and selectable pages. | Compatible decoded cues can reach the overlay. A teletext page selector and broader broadcast workflow are not exposed. Upstream does not claim complete CEA-708/field-2 support here. |
| Live HLS captions | Can discover and fetch selected HLS subtitle renditions. | Engine capability only; this integration does not establish a Vivid live-TV subtitle workflow. |

### Other engine capabilities and app boundaries

| Area | Upstream capability | Vivid status |
| --- | --- | --- |
| Seeking and buffering | Cached backward/forward seeks, bounded packet/segment storage, reconnect handling and configurable read-ahead. | Integrated through Vivid transport and Buffer Ahead. Stats distinguish prepared read-ahead from AVPlayer’s consumer buffer. |
| Playback speed | Video up to 2× and audio-only up to 3×, bounded by the engine’s supported rate. | Vivid forwards its playback-rate control; upstream limits do not add new UI choices. |
| Chapters and metadata | Container chapters and media tags/artwork. | Container chapters and Vivid/server metadata are integrated. Disc chapters are a separate upstream API. |
| Thumbnails and stills | Independent keyframe thumbnails and frame-accurate snapshots, including HDR-to-SDR still conversion. | Vivid uses the preview extractor. Exact still export is not implied. DV stills can differ from fully graded video. |
| Native/system presentation | AVPlayer, Now Playing, external playback and host-built PiP. | Vivid’s persistent AVKit host owns native presentation/Now Playing; controls and episode countdown remain Vivid’s. tvOS PiP is disabled in this host. |
| Software PiP | Sample-buffer PiP source and subtitle composition for supported platforms. | Apple TV does not gain software PiP from this API; mobile still uses VividKit. |
| Audio-only/background | Lean audio-only playback and platform-specific background lifecycle. | Audio-only is forwarded when requested; upstream music/audiobook/background APIs do not imply a complete Vivid library feature or tvOS background guarantee. |
| Live/DVR | Live HLS, timeshift, raw MPEG-TS, clear-key AES-128 and SSAI discontinuity handling, with source restrictions. | No complete live-TV/DVR control integration is claimed. Clear-key HLS is not FairPlay/Widevine DRM support. |
| Decrypted discs | DVD-Video/Blu-ray ISO parsing, titles and chapters. | No disc-title/menu UI is wired. Upstream excludes CSS/AACS decryption, BD-J, menus and multi-angle navigation. |
| Custom byte input | `IOReader` sources with seek/cancellation contracts. | The Vivid adapter loads provider URLs; it does not expose arbitrary custom sources. |
| SMB | Optional upstream SMB product for read-only network sources. | Not included in Vivid’s local package products/dependencies. No direct SMB browser or share support is implied. |
| Audio tap | Optional session-bound PCM output for transcription/fingerprinting integrations. | Not wired; no transcription or recognition feature is added. |
| Certificate trust | A host-supplied evaluator can handle private/self-signed origins. | Vivid does not wire that evaluator here. Do not assume arbitrary certificates are accepted. |
| Diagnostics | Playback phases, decoder/route information, timing, buffering, audio delivery and error reporting. | Vivid projects selected measurements into its Stats UI. Unmapped upstream fields are not automatically visible. |

Aether does not supply Vivid’s server authentication, library, profiles, downloads, IntroDB lookups, controls or episode queue. Support for an engine API is separate from Vivid exposing it. These tables describe code and upstream documentation; the [release record](../release/versioning.md) describes actual build and device checks.

## VividKit mini cores

These sections describe VividKit, used on iPhone and iPad, and its retained earlier tvOS implementation. The HDMI and AirPlay recovery helpers below are not the active AetherEngine tvOS pipeline.

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

On iOS, DTS-family and TrueHD playback uses local decoding to PCM. On tvOS, Aether’s native bridge defaults to compatible E-AC-3 up to 5.1 for audio requiring conversion; Prefer Lossless Audio selects FLAC up to 7.1 instead. Native-compatible audio can be copied without conversion. These are engine bridge formats, not a guarantee of the signal reaching the receiver. For these formats, source playback does not imply bitstream passthrough or preservation of DTS:X or TrueHD Atmos object metadata. Surround output depends on the audio route.

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

The retained VividKit Apple TV implementation replays retained samples after renderer interruptions and checks that the playback clock advances. AirPlay additionally requires queued-audio progress and retains flush notifications received during recovery. If replay stalls, it attempts one seek recovery before reporting an error. The HDMI component handles blocked audio delivery with an audio-only reset. It is enabled in Release only when every active output is HDMI; Debug builds retain the launch-argument gate. Recovery is bounded and respects pauses, user seeks and playback changes.

The Vivid core coordinates credential renewal with the active server core. VividKit direct playback updates credentials in the existing network reader and controller snapshot, preserving buffered media; an in-flight 401 uses bounded authenticated resumption. Native HLS and unsupported recovery cases retain reconstruction from the current position. Transient delivery failures also support validated byte-range resumption before requesting another route, including proactive recovery while playable headroom is shrinking. See [direct-network recovery](../playback/architecture.md#direct-network-recovery) for eligibility and shared retry limits. Next-episode loading clears the outgoing controls while retaining the video surface.

## Implementation

- [tvOS adapter](../../iosApp/iosApp/Playback/VividAetherEngine.swift): Aether session, AVKit host, track selection, native subtitle handoff and measured read-ahead.
- [AetherEngine](../../AetherEngine): tvOS preparation, decoding and automatic native/software route selection.
- [VividPlayer](../../VividKit/Sources/VividKit/VividPlayer.swift): playback clock, transport and bounded audio recovery.
- [VividMediaSession](../../VividKit/Sources/VividKit/VividMediaSession.swift): decoding, sample queues and audio replay.
- [VividHDMIAudioCore](../../VividKit/Sources/VividKit/VividHDMIAudioCore.swift): route-gated HDMI audio-stall detection and recovery policy.
- [VividAirPlayRecovery](../../VividKit/Sources/VividKit/VividAirPlayRecovery.swift): pending flush tracking and audio-progress confirmation.
- [HDMI policy tests](../../VividKit/Tests/VividKitTests/VividHDMIAudioCoreTests.swift): route exclusion, stall detection, bounded recovery and cancellation of pending confirmation.
- [Playback guide](../playback/README.md): audio selection, controls and playback behaviour.
