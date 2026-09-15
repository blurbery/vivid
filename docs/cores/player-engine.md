# Vivid playback engine

## Lucid playback engine on Apple TV

`ksplayer-trial` is a temporary experiment. At the owner’s request, the former tvOS engine, its source, adapter, dependency and tests are removed from this branch. Compare against the unchanged baseline commit in Git history. iPhone/iPad retain VividKit. Nothing here establishes approval to merge or distribute an Apple binary.

Lucid is Vivid’s playback-engine name. `LucidPlayer` owns the existing app-facing wrapper, `LucidCore` supplies its identity, `LucidVideo` hosts the video surface and `LucidFFOptions` configures the public KSPlayer/FFmpeg path (LucidFF). `VividEngine` and `VividPlayerSurface` remain compatibility aliases for the shared app. LucidAV is reserved for a future independent AVFoundation path, not an implemented alternative. Upstream KSPlayer identifiers, copyright and licence notices remain intact.

Generate the tvOS trial with `xcodegen generate --spec iosApp/project.yml` and build scheme `VividTV`. For the retained iOS targets, generate `iosApp/project-ios.yml` instead. Shared settings stay in `project-common.yml`; the two generated projects deliberately resolve separate package graphs because VividKit and FFmpegKit contain identically named binary modules. Do not combine both specs in one generated project.

The trial pins public [KSPlayer](https://github.com/kingslay/KSPlayer/tree/7862a2b175b50db71135e57fd144ea0e441d47d6) and its public FFmpegKit 6.1.4 dependency. No Premium/LGPL private code is used. The tvOS target links neither the old engine nor VividKit’s playback binaries; a Foundation-only retry-budget source is shared with the app.

`LucidPlayer` keeps the existing `VividEngine` interface and controls. It uses `KSMEPlayer` directly for HTTP(S), local files, MKV/MP4/HLS, demuxing, decode, buffering, pause/play, rate, resume and seeking. The adapter projects audio/subtitle tracks and chapters into Vivid and renders subtitles in its existing overlay. These are implementation paths, not a claim of passed media/device tests. External ASS uses the basic text parser; complex typesetting, PiP and receiver-fetchable AirPlay video are outside this baseline. Normal audio uses KSPlayer’s decoded PCM path. The opt-in JOC experiment below adds a compressed packet adapter; native Atmos output is not yet hardware-verified.

KSPlayer’s default 3-second preferred/30-second maximum buffer settings are retained. No second reservoir or loopback server is added. Saved buffer and lossless-bridge preferences are disabled for the experiment because they do not control KSPlayer. Match Content requests KSPlayer's existing display criteria as soon as the selected video's format description is available, while remaining preparation continues. Requests are dispatched to the main actor; cancelled loads cannot apply them, and later renderer metadata can correct the mode. Identical requests within the load are skipped while the same criteria remain installed. The existing Dolby admission policy and HDR10 fallback are retained. Display criteria still reset on stop. Earlier switching and HDMI behaviour require physical verification.

### Ordered hybrid development

Keep KSPlayer responsible for networking, demuxing, buffering, decoding, seeking, clocks and normal playback. Work on tvOS in this order: startup measurement and optimisation, Dolby Vision P8, P5, then EAC3/JOC Atmos. Report measurements and regressions before moving to the next stage. Keep P7 on a valid HDR base-layer fallback for now. Complete all tvOS stages before migrating iOS to the shared Lucid hybrid. Do not start future stages while startup work remains active.

### Startup and seek measurements

`PlaybackTrialTrace` emits source-free lines in the `PlaybackTrial` log category (`com.blurbery.vivid`). Each load gets a session UUID. T0 is Vivid’s fresh playback request before server preparation; automatic successors also begin a fresh trace. Reloads without a new app request explicitly report `origin=engine_load` and must not be mixed into Play-to-picture comparisons.

Events include `prepare_requested`, `source_open_begins`, `source_open_completed`, `probe_completed`, first audio/video packet, decode submission and decoded-frame retrieval timestamps, `player_ready`, `playing`, `audio_render_callback` and `first_picture_ready`. Times use the same monotonic clock. Upstream decode timestamps follow submission, not necessarily completion; retrieval proves a decoded frame exists but includes time spent queued. The open-begins event uses the public URL-processing hook immediately before `avformat_open_input`. The exact decoder-created timestamp is not publicly exposed and remains unavailable, not replaced with a guess. The PCM audio callback is submission to Apple’s engine, not proof of audible receiver output. The native audio trial reports compressed retrieval and timebase callbacks separately; neither proves Atmos rendering.

`first_picture_ready` requires the current sample-buffer display layer to report ready for display while attached to a window. It is independent of ready/playing state. Sampling adds up to 50 ms; TV HDMI mode changes may add visible delay after that signal, so compare against a physical recording. Metal-only rendering does not currently produce this metric and must be marked unavailable rather than timed as ready. Seek completion and picture readiness are separate; seek-to-picture is accepted only after flushing the old image and observing a new pixel buffer and a ready layer; requested and actual landed positions are logged separately because upstream can seek to a keyframe. Superseded, failed and timed-out seeks are logged separately. One-second samples record source bytes, throughput, playable buffer and stall count. Buffer values are KSPlayer’s own playable-time measurement, not a second cache.

Summarise an exported log with `python3 scripts/summarise-ksplayer-trial.py playback.log`. JSON output keeps startup, seeks, reloads and missing picture measurements separate. Add `--text` for a chronological trace and stage intervals. The report distinguishes app preparation, source opening, probing with adjacent setup, post-probe source setup, main-thread wait plus audio preparation, Vivid's ready callback and the remaining wait for picture readiness. Overlapping intervals must not be summed. Missing or reversed boundaries remain unavailable. Parser checks run with `--self-test`.

Additional wrapper-only events record player construction, selected audio/video streams, option processing, app track enumeration and display-criteria call duration. `upstream_ready` is KSPlayer's existing timestamp before main-thread audio preparation, not decoder completion. Display-criteria return does not mean the physical display has switched. Exact probe entry, decoder opening and decode completion are not exposed by these public hooks; do not substitute approximate events for them. No KSPlayer source or buffer settings are changed for this instrumentation.

Use the same file version, device, build configuration, route, start/resume position, subtitles and network for comparisons. Debug and optimised builds must be recorded separately. Record three cold/warm runs separately and several seeks. Do not compare KSPlayer Pro on iPhone to this GPL Apple TV branch as if it were a controlled benchmark.

### First baseline, pending device tests

The owner selected Dune 1 and Dune 2. Their exact media paths/versions are not supplied yet. A third identical file is still needed, preferably H.264 SDR with AAC. No startup, HDR10, AC3 or EAC3 result has been measured on this branch.

| Case | KSPlayer Play → picture | Baseline Play → picture | Seek → picture | Display/audio/stalls |
| --- | --- | --- | --- | --- |
| Dune 1, exact version pending | Not measured | Not measured | Not measured | Not tested |
| Dune 2, exact version pending | Not measured | Not measured | Not measured | Not tested |
| Third file, not selected | Not measured | Not measured | Not measured | Not tested |

For each run record source commit, app build, device/OS, stable file identifier, start position, decoded video/audio formats, DV profile/compatibility, actual television display mode, receiver output, fallback and rebuffer events. Extend this matrix to H.264/AAC, H.264/AC3 5.1, 4K SDR HEVC, HDR10, DV P5/P8/P7, EAC3 5.1, JOC, high-bitrate UHD, subtitle MKV and multiple-audio MKV. TV speakers, HDMI/eARC and HomePods remain separate audio checks. Builds do not prove these results.

### Profile 8 trial

`VividDolbyVideo` classifies selected stream metadata as SDR, HDR10, HLG, DV P5/P7/P8 or unknown. It records Dolby profile, level, compatibility ID, base/enhancement-layer flags and RPU presence. HDR classification uses transfer characteristics rather than assuming every ten-bit stream is HDR. No filename detection is used.

The native experiment is opt-in with the `VIVID_P8_TRIAL` Swift compilation condition. Normal builds keep the baseline HDR fallback. The first candidate is P8.1 with a PQ base layer, RPU present, no enhancement layer and version 1.0 configuration. The fixed hardware test is the 4K **80 for Brady**, Silo media file **4**, approximately 11 GB. Its actual stream was probed as P8, level 6, compatibility 1. Use the same file and start position for repeated comparisons. Dune and Dune: Part Two are P7 fallback tests, not substitutes.

`FFmpegAssetTrack` exposes Dolby configuration, but its immutable HEVC format description does not include that record. The video portion of the trial's public-source patch adds an optional format-description provider at the existing VideoToolbox session boundary. Vivid adds the source `dvvC` configuration alongside the unchanged `hvcC` data, preserving HEVC subtype, colour properties and compressed packets. It does not generate per-frame metadata. KSPlayer already enables per-frame HDR metadata propagation and passes the decoded pixel buffers into its existing sample-buffer display layer.

The first hardware run detected P8.1 but never entered the format hook: KSPlayer defaults `asynchronousDecompression` to false, selecting its FFmpeg decoder. The corrected trial selects KSPlayer's existing direct VideoToolbox decoder only for eligible P8.1 streams, with hardware decoding enabled and no video filters. This selection occurs after upstream stream processing and respects its software-decode requirements. A separate `p8_decoder_selection` event records this gate. The initial HDR10 run measured 3,284 ms to layer readiness, not confirmed HDMI visibility, and logged zero stalls during approximately 35 seconds; it is not a native-DV result.

On tvOS 17 or later, an accepted P8 configuration requests display matching using Apple's format-description-based `AVDisplayCriteria` initializer. Decoder configuration rejection retries the original HDR format. A reported decode failure disables further native attempts for that load and returns display matching to the base format while KSPlayer retains its existing decode-error handling. This is an experimental fallback, not a guarantee that every runtime error can recover. Network, demuxing, buffering, clock, seeking, track selection, subtitles, normal audio and the renderer remain KSPlayer-owned.

To reproduce using the existing dependency cache:

```sh
python3 scripts/prepare-p8-trial.py /path/to/retained/checkouts/KSPlayer
```

The script requires pinned revision `7862a2b175b50db71135e57fd144ea0e441d47d6`, refuses unrelated local changes and applies `scripts/patches/ksplayer-p8-format-hook.patch` idempotently. Add `OTHER_SWIFT_FLAGS='$(inherited) -D VIVID_P8_TRIAL'` to the normal tvOS build command. Do not clean or duplicate the cache. The app compiles against unmodified upstream without that flag. No fork or published dependency change is made for this local trial.

Diagnostics distinguish the decoder attempt, accepted/rejected configuration, requested display criteria and output attachment keys. Trial builds retain only the latest session in `Library/Caches/LucidP8Trial.log`, capped at 256 KiB and written asynchronously. Metadata payloads and source URLs are not recorded. Read it from the app's data container after testing. Neither decoder acceptance, attachment presence nor a display-mode request proves native Dolby Vision. Verify the TV's Dolby Vision indicator, colour and brightness, pause/resume, seeking, stalls and startup against the same file. Native P8 support beyond the tested P8.1 file remains unverified. If this narrow path cannot work without replacing major KSPlayer components, stop and report before redesigning.

### P8.1 hardware result, 15 September 2026

Living Room Apple TV, 80 for Brady (4K, Silo file 4): the owner confirmed the TV reported Dolby Vision, colours looked correct, and pause/resume and forward/backward seeking worked while remaining in Dolby Vision. The trace independently recorded successful native decoder configuration, no Dolby fallback, and `DolbyVisionRPUData` in the output attachments initially and after all three seeks. This validates the narrow native P8.1 path for this file and setup, not every P8 variant or display.

Layer-readiness times were 3,190 ms and 2,496 ms across two native runs, against 3,284 ms in the preceding HDR10 run. These are individual app-layer measurements, not physical HDMI visibility or controlled performance benchmarks. The latest three seeks recovered a picture in 6,673 ms, 2,753 ms and 1,859 ms. The four logged buffering transitions corresponded to initial loading and the three seeks; no additional transition was observed during normal playback in that captured session. The longest seek remains a performance item to investigate before claiming no seeking regression. No equivalent HDR baseline seek timings are available yet.

Second P8.1 file: A Boy Called Christmas (4K, Silo file 6, approximately 12.8 GB) was independently probed as profile 8, level 6, compatibility 1, BL/RPU present and no enhancement layer. The owner confirmed playback, pause and seeking remained in TV-reported Dolby Vision. The subsequent trace showed accepted native configuration without fallback, Dolby RPU attachments initially and after both completed seek sequences, and 2,943 ms to layer readiness. The completed seek sequences took 5,952 ms and 3,253 ms; intervening scrub requests were superseded. These results extend functional confirmation to a second P8.1 file, while seek-performance comparison and ordinary HDR10/SDR regression checks remain outstanding.

The owner accepted these functional P8.1 results and seek behaviour as the completed tvOS P8.1 milestone, and authorised proceeding to P5. Preserve this implementation in `VividDolbyVideo`; it is a Dolby extension, not a separate playback core. KSPlayer retains its normal pipeline. Broader P8 variants and HDR10/SDR regression testing remain separate validation items. Atmos has not been started.

### Profile 5 prototype

P8.1 is checkpointed locally at `09ff9af`. The next opt-in stage adds `VIVID_P5_TRIAL` alongside `VIVID_P8_TRIAL` to the same tvOS build. The first fixed P5 test file is **A Dog's Way Home**, 4K, Silo media file **5**, approximately 10.6 GB. Direct probing confirmed HEVC Main 10, 3840×1592, P5 level 6, compatibility 0, BL/RPU present and no enhancement layer. The first P5 hardware result is recorded below; wider compatibility remains unverified.

`VividDolbyVideo.profile5Format` supplies the source P5 configuration as `dvcC` with the `dvh1` codec subtype. It keeps HEVC extradata and compressed RPU packets intact and removes guessed ordinary-HDR colour keys from the P5 decoder description. This follows the P5 sample-description approach in [Apple's HDR metadata specification](https://developer.apple.com/av-foundation/High-Dynamic-Range-Metadata-for-Apple-Devices.pdf); it does not implement a shader conversion or a new decoder. The validated P8.1 format builder is unchanged.

P5 uses the same small KSPlayer hook and existing direct VideoToolbox decoder. An installed output gate is required before P5 can pass Vivid's admission check. Video presentation remains blocked until native configuration succeeds; rejection or a reported decode failure blocks further P5 pictures and terminates playback with a colour-protection error. Unlike P8.1, P5 never receives permission to display the ordinary HDR base fallback. Proper P5-to-HDR/SDR conversion is not implemented. KSPlayer continues to own buffering, timing, seeking, subtitles, rendering and normal audio.

The same bounded trial trace records P5 selection, decoder configuration and display requests. Builds and configuration-packing checks do not prove colours, native TV output, pause/resume or seeking. Test those on the fixed P5 file, then recheck 80 for Brady to confirm P8.1 behaviour is retained. Do not install until the owner authorises the new build.

### First P5 hardware result, 15 September 2026

On Living Room, the owner confirmed A Dog's Way Home (4K, file 5) switched the TV to Dolby Vision, showed no unusual colours, and supported pause and seeking. The retrieved session independently recorded P5 level 6, compatibility 0, native configuration accepted with no fallback, ten-bit output with `DolbyVisionRPUData`, and 2,396 ms to layer readiness. Its 37 samples recorded no stalls. This captured session contains no seek events, so pause/seek success is owner-reported rather than independently timed in this trace. This is a successful first-file P5 result; validate another P5 file and recheck P8.1 on the same build before broadening the milestone. No Atmos work has begun.

The owner also confirmed After Yang (4K, file 74) passed the same P5 playback checks, and rechecked 80 for Brady successfully on the P5 build. P5 is now functionally validated on two files on Living Room, with P8.1 retained. Those additional checks are owner-reported; no additional seek measurements are claimed. The owner authorised the Atmos stage, using HomePods.

### Atmos stage: source detection first

P5 is saved in local checkpoint `5c2b93c`, with P8.1 retained. The Atmos test output is HomePods. The fixed JOC candidate is **80 for Brady**, Silo file **4**: a bounded direct audio probe confirmed EAC3, the Dolby Digital Plus + Dolby Atmos profile, 48 kHz and a six-channel base layout. That channel count alone is not Atmos evidence. A Dog's Way Home provides an AC3 comparison; After Yang has ordinary EAC3 in the stored metadata, pending an equivalent direct audio probe.

`VividDolbyAudio` classifies AAC, AC3, EAC3, EAC3 JOC, DTS, TrueHD, PCM and unknown audio. JOC requires EAC3 plus FFmpeg's `AV_PROFILE_EAC3_DDP_ATMOS` value (30). Missing/unknown profile remains unconfirmed. Once positive JOC evidence is seen, a later frame without profile signalling does not erase it for the same stream. Classifications are keyed by track ID and reset for a newly processed stream; unrelated codecs never inherit an Atmos label.

The corrected on-device detection run confirmed profile 30 at both probe and decoded-frame stages. Classification uses FFmpeg's canonical `avcodec_get_name`, because KSPlayer's display codec name includes a parenthesised profile label. The owner confirmed HomePods are Living Room Apple TV's Default Audio Output. The captured PCM route still reported AirPlay and two output channels; this is not proof of multichannel or native Atmos output.

### Native JOC prototype, awaiting hardware validation

Build with all three trial conditions (`VIVID_P8_TRIAL`, `VIVID_P5_TRIAL`, `VIVID_ATMOS_TRIAL`) after applying the pinned dependency patch using `scripts/prepare-p8-trial.py`. The cumulative patch now covers ten upstream files; its historical filename is retained. P5/P8 format handling is unchanged. No network, demux, packet queue, frame queue or clock is replaced.

`VividDolbyAudioBridge` admits only an initially selected EAC3 track with FFmpeg JOC profile 30, no audio filters and normal playback speed. A profile discovered only after PCM decoding does not change the output mid-queue. `VividEAC3Sample` accepts one independent six-block EC-3 syncframe per packet, verifies its byte length, sample rate and channel count, then copies the original bytes into an Apple compressed sample buffer. Dependent/multiple syncframes, other block counts, invalid timestamps or unsupported headers trigger the normal PCM recovery. No invented JOC metadata or `dec3` cookie is supplied.

The optional `KSAudioPacketProvider` intercepts eligible packets before FFmpeg audio decoding and places a compressed carrier in KSPlayer's existing `AudioFrame` queue, preserving timestamps, duration and position. The output factory chooses between KSPlayer's `AudioEnginePlayer` for ordinary PCM and its existing `AudioRendererPlayer` for the trial. The latter enqueues compressed samples without the PCM conversion/merge step, retains the first compressed packet when starting its existing synchroniser, and serialises flush with enqueueing. Compressed carriers do not enter optional PCM speech recognition. Vivid does not impose a preferred PCM channel count on the native route.

The existing telemetry ticker checks renderer errors, startup status, timebase movement and the queued audio endpoint. Renderer configuration changes, automatic flushes, audio route changes, a stalled audio timeline/queue, unsupported packet layouts, audio-track changes or non-unit speed request one PCM recovery. Recovery waits for an in-flight load/seek, then uses Vivid's existing KSPlayer load/resume path at the current position with native audio disabled. This discards the old queues and preserves play/pause intent and subtitle selection. Ordinary audio track changes remain upstream; changing a track during the native experiment returns that load to PCM. PCM channel count remains subject to KSPlayer and the actual route, rather than a guaranteed 5.1/7.1 output.

`audio_classified` describes the source only. Native packet, renderer and clock events remain marked `native_atmos=unverified`; a working timebase, a six-channel source or a successful build is not an Atmos output result. A PCM recovery appends its replacement session and reason to the existing bounded trace, retaining the preceding seek and failure events within the same 256 KiB limit. The same `Library/Caches/LucidP8Trial.log` is reused, without media URLs or payload logging.

Focused construction checks cover exact payload preservation, one compressed packet per sample buffer, timestamps, 1,536-frame duration, sample rates, channel mismatch and unsupported headers. Run from the task's work directory:

```sh
swiftc -module-cache-path device-build/ModuleCache.noindex \
  vivid/iosApp/iosApp/Playback/VividEAC3Sample.swift \
  vivid/iosApp/iosApp/Playback/VividDolbyAudio.swift \
  vivid/scripts/tests/eac3-sample-tests.swift -o eac3-sample-tests
./eac3-sample-tests
```

The 23 checks passed on macOS, and the six startup-trace parser checks passed. A read-only probe of the first actual 80 for Brady audio packet confirmed 3,072 bytes, one independent six-block syncframe, 48 kHz, six channels and 32 ms duration, matching the adapter. These checks validate construction and admission, not decoding or native Atmos. The signed tvOS build passed with the existing bundle and shared Keychain identity. Device validation is pending: use **80 for Brady** on Living Room's default HomePods, verify audible output, dialogue sync, pause/resume, seeks, DV retention and startup, and inspect whether native playback or PCM recovery occurred. Only after that succeeds, test the bedroom soundbar. Installation still requires the owner's approval; retain the shared build cache and Keychain.

Public API references: [Apple's compressed audio renderer](https://developer.apple.com/documentation/avfoundation/avsamplebufferaudiorenderer), [Apple's EC-3 format identifier](https://developer.apple.com/documentation/coreaudiotypes/kaudioformatenhancedac3), and [Chromium's public AudioToolbox EC-3 input format setup](https://chromium.googlesource.com/chromium/src/+/main/media/filters/mac/audio_toolbox_audio_decoder.cc). These establish the input API approach, not a guarantee of Atmos on HomePods or HDMI.

### Native JOC synchronisation follow-up

The first HomePod prototype produced late dialogue according to the owner, and seeking did not restore sync. A subsequent trace recorded automatic PCM recovery with `audio_timeline_stopped`. The preceding native queue levelled off around 130 seconds ahead; queue size alone does not establish the cause. Buffer limits remain unchanged. Bluey ordinary EAC3 playback remained in sync according to the owner, with no JOC detected, decoded PCM, two reported output channels and zero stalls in its captured trace.

The native-only follow-up connects KSPlayer's existing sample-buffer video layer to its existing Apple audio render synchroniser. Video uses source presentation timestamps instead of zero timestamps and immediate display. KSPlayer still selects and schedules frames, supplies packets and owns normal playback. The shared Apple timeline controls presentation of the existing audio and video renderers. Dolby pixel-buffer attachments and format descriptions are retained.

Native audio explicitly anchors to the first packet after a flush; pause/resume retains the current timeline even when queued packets are far ahead. A seek resets the shared timeline on the main thread before its completion callback permits playback to resume. Empty post-seek queues wait for a fresh packet, with bounded recovery to PCM. Ordinary PCM output does not opt into these changes.

`scripts/tests/audio-timeline-tests.swift` compiles alongside the patched upstream `AudioRendererPlayer.swift`. Nine checks passed using real macOS Apple renderers and muted synthetic PCM, covering packet anchors, pause/resume, backward seeks, empty-queue retry and video renderer membership in the synchroniser. These checks do not measure audible sync, physical video presentation or Atmos preservation. The synchroniser manages renderer timing internally; adding a video renderer does not populate its public `controlTimebase` property. The follow-up signed tvOS build passed, with the existing bundle, team, shared Keychain and app group verified unchanged. The 23 EC-3 checks and six trace-parser checks also passed. The HomePod retest remains required before claiming the fix or proceeding to the bedroom soundbar. The update has not been installed.

### HomePod retest and PCM comparison

The shared-timeline build was installed in place on Living Room. In session `745B3089-D121-4642-BFA1-4B79EB4FBC7B`, native JOC stayed active, the video renderer remained connected, and no PCM recovery was logged. Two completed seeks recorded approximately 3,952 ms and 2,500 ms to layer readiness; other rapid requests failed or were superseded. Steady-state scheduling gaps were approximately 19 ms. The owner reported improved seek behaviour but persistent dialogue mismatch, and could not confidently establish whether audio was early or late. Scheduling gaps do not measure audible HomePod synchronisation.

The working `AudioEnginePlayer` subtracts its cached `AVAudioSession.outputLatency` before reporting the audio clock to KSPlayer, refreshing that latency on flush. `AudioRendererPlayer` instead reports its Apple synchroniser time. Do not assume that subtracting the PCM latency from an already compensated Apple clock is correct.

The next native-only trial enables Apple's `delaysRateChangeUntilHasSufficientMediaData`, with an eight-second readiness timeout returning to PCM. Diagnostics distinguish requested rate from effective timebase rate and record reported session latency and I/O buffer duration. PCM comparison diagnostics report the same session values plus output-node presentation latency; they do not change its working timing policy. The debug-only launch argument `-VividJOCPCMControl` disables native audio for that process, allowing the same **80 for Brady** file and selected track to be tested through PCM without altering saved settings or video handling. A normal launch restores native trial eligibility. Hardware comparison remains pending; no manual sync offset has been introduced.

The readiness trial was installed and tested on Living Room. Session `A900245A-596B-4FC7-8C42-A61AC6192268` stayed native with no PCM recovery. Apple initially held effective rate at zero until readiness, then advanced normally at rate 1. The route reported 2.0 seconds of output latency and approximately 23.2 ms I/O buffer duration throughout. After approximately two minutes, video scheduling gaps were around 8 ms and the stall counter remained at its initial value of 1. The owner still reported audible mismatch. Neither reported route latency nor scheduling gap measures the actual lip-sync error. Readiness gating alone did not solve it; the same-file PCM control remains outstanding.

The owner authorised a relaunch with `-VividJOCPCMControl`. Session `21919B3C-C4B5-42AF-9337-2695E14399AD` confirmed forced PCM, no native audio renderer, and ordinary KSPlayer audio timing. Both the session and output node reported 2.0 seconds latency, with approximately 23.2 ms I/O buffer duration. The owner thought dialogue still mismatched. Steady-state video scheduling was approximately 154 ms behind the reported audio clock, rather than the native run's approximately 8 ms gap. Upstream video scheduling tolerates up to four frames of lateness before its correction threshold, approximately 167 ms at 24 fps. This is a code observation, not proof of the audible error or a reason to copy a fixed offset. Native P8 video remained active in both comparisons. A same-scene check using TV speakers can help separate the HomePod route from shared source/video timing. The app remains in process-scoped PCM control mode until a fresh normal launch.

### AirPlay PCM presentation-latency correction

The owner confirmed the same file was in sync through TV speakers. Session `56094D52-6473-4126-88E8-DF9486927C32` confirmed forced PCM on HDMI with six reported output channels, approximately 80 ms session/output-node latency, zero stalls and approximately 41 ms scheduling lag. This supports investigating route-specific timing; it does not establish a measured acoustic offset.

AirPlay PCM now opts into the source node's `outputPresentationLatency`, which includes downstream processing and device presentation latency. The existing PCM implementation used only a device-latency value cached at initialisation or flush. The optional hook queries the graph on the main thread after play, on route changes and through the existing telemetry ticker. Its render callback reads the latest override with a non-blocking lock attempt, otherwise retaining its last snapshot. Invalid or unavailable graph latency falls back to upstream timing. Device latency is not added again. Other PCM routes keep the upstream calculation; native JOC retains its existing synchroniser policy. No network, buffering, Dolby Vision or manual sync-offset changes are included.

Diagnostics record `source_presentation_latency_s` and the active clock policy. The cumulative dependency patch adds only the optional PCM latency hook in `AudioEnginePlayer.swift` for this change. Validate **80 for Brady** in forced PCM mode on default HomePods before retesting native JOC. A successful build is not proof of audible synchronisation.

The full-latency trial was installed. Session `9381161E-B012-4DB8-907E-22F4F6934018` confirmed AirPlay PCM using 2.085333 seconds source presentation latency, compared with 2.0 seconds device latency. The owner still reported mismatch. Scheduling remained approximately 148 ms late with zero stalls, so the additional 85 ms compensation did not resolve the observed problem.

The next PCM-only AirPlay change uses the existing `KSOptions.videoClockSync` override to request upstream's existing frame-drop catch-up action when a frame is more than two frames late and another decoded frame is available. It preserves upstream waiting and stronger recovery actions, does not change audio timestamps or add a fixed offset, and leaves native JOC and non-AirPlay routes unchanged. This targets measured persistent scheduling lateness. Focused checks using the actual override and upstream scheduling method confirmed convergence from 150 ms lateness to within two frames, while retaining native/HDMI and single-frame behaviour. The signed tvOS build passed with the existing app and shared Keychain identity. Audible HomePod sync and smooth motion still require a device retest.

The catch-up trial was installed and tested in forced PCM. Session `88A94A43-A192-47A3-8CDC-8C599949481E` reported the same 2.085333-second source presentation latency and zero stalls. Scheduling lag reduced from approximately 148 ms to approximately 68 ms, remaining stable from five seconds through two minutes (20-second window means between -67.8 and -67.6 ms). The owner reported initially close sync but suspected worsening audible drift. The trace does not confirm a growing scheduling error and cannot exclude downstream audible drift. Do not claim sync is fixed or infer an acoustic offset solely from these clock measurements.

### Public fork and Apple clock investigation

A targeted public GitHub investigation compared the pinned revision `7862a2b175b50db71135e57fd144ea0e441d47d6` with KSPlayer fork histories and audio sources. The upstream [HomePod fix ac68175](https://github.com/kingslay/KSPlayer/commit/ac6817507caaea11427033a850f26aa49b341e13) initialises cached device latency. Git ancestry confirms it is already included in the pinned revision. The current `AudioEnginePlayer.swift` files in `tapframe/KSPNUVIO`, `nyc-design/KSPlayer` and `IgorFedorchuk/KSPlayer` matched the pinned upstream file byte-for-byte. The [qoli tvOS fork change](https://github.com/qoli/KSPlayer/commit/8fd5d167b205aa0ee5097096ae2370e9be57f3e5) adds engine preparation and startup-error handling, not a different playback-clock calculation. The older IPTVX fork has substantially different graph/channel setup, without verified evidence that its public change solves this HomePod case. These findings do not establish that all forks were exhaustively checked.

Upstream [issue 362](https://github.com/kingslay/KSPlayer/issues/362) reports the exact tvOS/HomePod symptom. [Issue 412](https://github.com/kingslay/KSPlayer/issues/412) contains a historical maintainer warning about sample-buffer audio with video; it is context, not proof that current Apple APIs cannot synchronise them. [Issue 157](https://github.com/kingslay/KSPlayer/issues/157#issuecomment-1456987877) links VLC's AirPlay latency work. The public Atmos discussion [issue 875](https://github.com/kingslay/KSPlayer/issues/875) explores AVPlayer/HLS, which would exceed the current narrow integration and is not adopted.

The concrete reference difference is in [VLC's Apple CoreAudio backend](https://github.com/videolan/vlc/blob/master/modules/audio_output/apple/coreaudio_common.c): it uses valid render host timestamps, computes the rendered buffer end time, and reports that time plus device/AudioUnit latency alongside the corresponding media position. It resets the mapping on flush. Its [iOS output backend](https://github.com/videolan/vlc/blob/master/modules/audio_output/apple/audiounit_ios.m) explicitly avoids adding I/O buffer duration twice. KSPlayer's pinned `audioPlayerDidRenderSample(sampleTimestamp _: AudioTimeStamp)` ignores the timestamp and reports its source-frame cursor minus latency. This is a concrete clock-mapping difference and a stronger next investigation target than more fixed offsets or tighter drop thresholds. It is not yet proven as the cause of Vivid's audible mismatch. No fork, dependency upgrade, replacement renderer or new device build was introduced by this research.

### AirPlay PCM render-host mapping

Following the public-source investigation, the AirPlay PCM trial now reports its audio clock from the source callback, where the copied media endpoint and source render timestamp belong to the same buffer. At normal playback speed, a valid host timestamp is mapped as `media endpoint - (render host time - host time now) - copied buffer duration - source presentation latency`. The latency already includes downstream processing/device delay and is not added twice. Actual copied frames, rather than requested frames containing underrun silence, determine buffer duration. The next timestamp independently re-anchors the calculation, including after a seek; no synthetic cumulative sample clock is introduced.

When this source mapping is used, the later output callback does not overwrite it with the source cursor. Invalid timestamps or unavailable graph latency retain the previous calculation. Non-AirPlay routes and non-unit speeds retain the prior policy. Native JOC, the existing sample-buffer video path, demux, buffers, queue ownership and track handling are unchanged. `audio_pcm_timing` reports render host delay, rendered buffer duration, mapped media time and the actual mapping/fallback policy.

`scripts/tests/pcm-presentation-tests.py` compiles the pure calculation extracted from the actual patched `AudioEnginePlayer.swift`. Its 25 checks passed for timestamp mapping, buffer-size and sample-rate invariance, late callbacks, long playback/seek anchors and invalid inputs. These are arithmetic checks, not hardware lip-sync measurements. Run with the patched source path and the retained Swift module-cache path. Retest the same **80 for Brady** scene in PCM control mode on default HomePods before claiming success or returning to native JOC.

### Public Dolby behaviour and future extension points

- **Profile 5:** default builds reject P5. The opt-in native-only prototype above has passed its first owner-confirmed hardware test; an ordinary PQ fallback is never permitted. Proper HDR/SDR conversion is not implemented.
- **Profile 8:** default builds retain KSPlayer's HDR fallback. The opt-in P8.1 metadata experiment is described above. Correct output and actual TV Dolby Vision remain hardware checks.
- **Profile 7:** BL-present, HDR10-compatible metadata (compatibility ID 6) permits baseline playback. No FEL reconstruction or custom RPU path is attempted.
- **EAC3 JOC:** default playback uses decoded PCM. The opt-in compressed Apple audio prototype above remains experimental, with HomePod synchronisation and native Atmos output unverified.

The small future `VividDolbyRouter` should wrap public `Sources/KSPlayer/AVPlayer/MediaPlayerProtocol.swift` (`MediaPlayerTrack`, `DOVIDecoderConfigurationRecord`) and `Sources/KSPlayer/MEPlayer/FFmpegAssetTrack.swift`. Decoder/output investigation belongs at `MEPlayerItem.swift`, `VideoToolboxDecode.swift`, `DecompressionSession` inside `VideoToolboxDecode.swift`, `MetalPlayView.swift`, `FFmpegDecode.swift`, `AudioEnginePlayer.swift`, `AudioRendererPlayer.swift` and `AVPlayer/KSOptions.swift`. Some decoder classes are internal; exposing compressed samples or decoder-profile evidence would require an explicit, reviewed public-source patch. No large custom Dolby subsystem is implemented before baseline results.

## VividKit mini cores

These sections describe the retained iPhone/iPad VividKit engine. Its earlier HDMI helpers are not used by the KSPlayer tvOS trial.

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

On iOS, DTS-family and TrueHD playback uses local decoding to PCM. The tvOS trial uses KSPlayer’s decoded PCM audio path. These are engine bridge formats, not a guarantee of the signal reaching the receiver. For these formats, source playback does not imply bitstream passthrough or preservation of DTS:X or TrueHD Atmos object metadata. Surround output depends on the audio route.

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
    <tr><td>ASS</td><td>Embedded styled text subtitles. iPhone/iPad use libass; the tvOS trial currently projects text/image cues and does not promise full libass animation/typesetting parity.</td></tr>
  </tbody>
</table>

## Playback recovery

The retained VividKit Apple TV implementation replays retained samples after renderer interruptions and checks that the playback clock advances. AirPlay additionally requires queued-audio progress and retains flush notifications received during recovery. If replay stalls, it attempts one seek recovery before reporting an error. The HDMI component handles blocked audio delivery with an audio-only reset. It is enabled in Release only when every active output is HDMI; Debug builds retain the launch-argument gate. Recovery is bounded and respects pauses, user seeks and playback changes.

The Vivid core coordinates credential renewal with the active server core. VividKit direct playback updates credentials in the existing network reader and controller snapshot, preserving buffered media; an in-flight 401 uses bounded authenticated resumption. Native HLS and unsupported recovery cases retain reconstruction from the current position. Transient delivery failures also support validated byte-range resumption before requesting another route, including proactive recovery while playable headroom is shrinking. See [direct-network recovery](../playback/architecture.md#direct-network-recovery) for eligibility and shared retry limits. Next-episode loading clears the outgoing controls while retaining the video surface.

## Implementation

- [tvOS adapter](../../iosApp/iosApp/Playback/LucidPlayer.swift): public KSPlayer session, track selection, PCM audio and measured startup.
- [VividPlayer](../../VividKit/Sources/VividKit/VividPlayer.swift): playback clock, transport and bounded audio recovery.
- [VividMediaSession](../../VividKit/Sources/VividKit/VividMediaSession.swift): decoding, sample queues and audio replay.
- [VividHDMIAudioCore](../../VividKit/Sources/VividKit/VividHDMIAudioCore.swift): route-gated HDMI audio-stall detection and recovery policy.
- [VividAirPlayRecovery](../../VividKit/Sources/VividKit/VividAirPlayRecovery.swift): pending flush tracking and audio-progress confirmation.
- [HDMI policy tests](../../VividKit/Tests/VividKitTests/VividHDMIAudioCoreTests.swift): route exclusion, stall detection, bounded recovery and cancellation of pending confirmation.
- [Playback guide](../playback/README.md): audio selection, controls and playback behaviour.
