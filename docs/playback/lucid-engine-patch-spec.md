<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Lucid Engine Patch Specification</h1>
<p align="center">Behaviour contract for Vivid's own mpv and FFmpeg patches.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

This guide specifies, by behaviour, every change Lucid Engine needs on top of pristine upstream mpv and FFmpeg. It is written for a clean-room reimplementation and is the implementer's only description of how the current engine behaves.

Contents:

1. [Purpose, status, licence and reading rules](#1-purpose-status-licence-and-reading-rules)
2. [Frozen interface shared with Vivid](#2-frozen-interface-shared-with-vivid)
3. [Audio output](#3-audio-output)
4. [Video output](#4-video-output)
5. [Dolby Vision and FFmpeg VideoToolbox](#5-dolby-vision-and-ffmpeg-videotoolbox)
6. [Other kept behaviour](#6-other-kept-behaviour)
7. [Dropped patches, omissions and deliberate differences](#7-dropped-patches-omissions-and-deliberate-differences)
8. [Build and CI provenance](#8-build-and-ci-provenance)
9. [Constants, parity hazards, tests and device checklist](#9-constants-parity-hazards-tests-and-device-checklist)
10. [Harness rewrites](#10-harness-rewrites)
11. [Decisions, open items and documents to update](#11-decisions-open-items-and-documents-to-update)
12. [Amendments after implementation](#12-amendments-after-implementation)
13. [Amendments after the fix rounds and the library work](#13-amendments-after-the-fix-rounds-and-the-library-work)

## 1. Purpose, status, licence and reading rules

### 1.1 What this document covers

Lucid Engine is libmpv 0.41.0 with FFmpeg n8.0.1 for iPhone, iPad and Apple TV. The engine Vivid ships today comes from the previous third-party package, at the revision Vivid's app pins on `main`. Its engine carries that package's own GPL-3.0 Apple patch series, plus three Vivid patches on top, and it links the previous third-party build of the libraries listed in 8.3.

Vivid now builds the engine itself from pristine upstream sources, with its own patch series, in its engine build pipeline (`engine/`, described in `docs/cores/lucid-engine-build.md`; it was developed on the branch `experiment/lucid-engine-build`). When this document was first written, that series held four patches (8.2). The patches this document specifies are the rest, written to apply on top of that series, and all of them are now implemented, reviewed and in the series (8.2, 12, 13):

- the AVFoundation audio output (section 3);
- the AVFoundation video output (section 4);
- Dolby Vision decoding in FFmpeg's VideoToolbox path (section 5);
- a libdovi change that turns its aborts into errors (5.13);
- a small set of other mpv and FFmpeg changes (section 6).

Section 7 lists what is not carried over, what is omitted and what deliberately changes. Section 8 states what the build pipeline must prove about the result. Section 13 adds the libass series and the libraries the pipeline now also builds from upstream source.

### 1.2 Status and baseline

| Item | Value |
| --- | --- |
| mpv | Upstream tag `v0.41.0`, commit `41f6a645068483470267271e1d09966ca3b9f413` |
| FFmpeg | Upstream tag `n8.0.1`, commit `894da5ca7d742e4429ffb2af534fcda0103ef593` |
| libass | Upstream tag `0.17.5`, commit `4a05d8127f525943ebf45fdc6497c9e665947f0d`, built with upstream libass commit `057a5334`, upstream libass pull request #951 at `f96a521` and Vivid's own patch `0010` (13.4) |
| dav1d | Upstream tag `1.5.3`, commit `b546257f770768b2c88258c533da38b91a06f737`, built unpatched |
| FreeType, FriBidi, HarfBuzz, libunibreak, libplacebo, Little CMS (lcms2), MoltenVK, shaderc, uavs3d, libbluray, uchardet | 2.12.1, 1.0.12, 8.1.1, 6.1, 7.351.0, 2.17, 1.4.1, 2025.5, 1.2, 1.4.0 and 0.0.8, today's versions. Vivid's pipeline now builds all eleven from upstream source with today's options, in place of the previous third-party build of these libraries; only libbluray and uavs3d carry patches, both Vivid's own (13.5) |
| libdovi | `dolby_vision` crate 3.3.2 (tag `libdovi-3.3.2` of `quietvoid/dovi_tool`, MIT). Vivid's pipeline now builds it from source with Vivid's own patch, in place of the prebuilt it used to pin (5.13, 8.3, 12.6) |
| Build | Vivid's pipeline: `engine/lucid.py`, `engine/pins.ini`, `engine/patches/<library>/series`, `.github/workflows/lucid-engine.yml`; Xcode 26.6; minimum OS 14.0 for Vivid's own libraries, while the eleven libraries above keep today's per-library minimum OS (13.5); four arm64 slices (2.11) |
| Target behaviour | The engine in Vivid device builds today: upstream plus the third-party common and Apple series plus Vivid's three old patches. blurbery describes playback as perfect, so any observable difference not listed in section 7, 12 or 13 is a regression. |

Upstream behaviour that this document does not mention must stay exactly as upstream has it.

### 1.3 Licence target

- Every new patch to mpv and FFmpeg is Vivid-owned and licensed `LGPL-2.1-or-later`, written by clean implementers against the pristine sources in 1.2 plus Vivid's existing series.
- That includes the video output, whatever licence header the old file carried.
- Use the header form of Vivid's existing patches in `engine/patches/`: author `blurbery` with the account's noreply address, a subject line, a plain description of the change, and a closing licence paragraph naming LGPL-2.1-or-later.
- mpv's upstream commit `1388a453950f202a29d1c0346797d730a9710d72` is already in the series unchanged, with its upstream attribution (6.3).
- The libdovi patch (5.13) is Vivid-owned too, with the same header form. Because libdovi itself is MIT, it is proposed under MIT rather than LGPL-2.1-or-later; blurbery confirms that choice (11.2).
- The libass series carries two upstream libass changes unchanged, with their upstream attribution, and Vivid's own libass patch `0010`, licensed ISC like libass (13.4). Vivid's own libbluray patch is `LGPL-2.1-or-later` and its own uavs3d patch `BSD-3-Clause`, each under its library's licence (13.5).

### 1.4 Clean-room reading rules

**Clean implementers may read:**

| Source | Notes |
| --- | --- |
| This document | The only description of the current engine's behaviour. |
| `docs/playback/player-bridge-spec.md` | The bridge side of the same contract (sections 6.3, 6.18, 6.19, 7.1 to 7.6, 8). Where the two differ, this document wins for engine behaviour; 11.3 and the bridge editor's correction list cover the differences. |
| Vivid's engine build pipeline | Everything under `engine/` (`lucid.py`, `pins.ini`, `config/`, `patches/` with its series files and patches, `tests/`), `.github/workflows/lucid-engine.yml`, `docs/cores/lucid-engine-build.md` and `docs/cores/lucid-engine-libs-build-facts.md` (the audited facts for the eleven libraries of 8.3). Both guides link to the build facts document, and some pipeline comments (in `engine/pins.ini`, for example) cite its sections: do not follow those links or look up those citations. |
| Pristine upstream mpv at `v0.41.0`, and upstream mpv history | |
| Pristine upstream FFmpeg at `n8.0.1`, libass `0.17.5` and dav1d `1.5.3`; upstream libass commit `057a5334` and pull request #951 at `f96a521`; the upstream sources of the eleven libraries of 8.3 at their pinned versions | Any file. |
| libdovi 3.3.2 source and its public C header | MIT. |
| Apple developer documentation and SDK headers | AVFoundation, AVFAudio, CoreMedia, CoreVideo, CoreImage, CoreGraphics, QuartzCore, Metal, IOSurface, VideoToolbox, UIKit, Security. |
| Vivid's app source, tests and documentation | Except the files listed below. |

**Clean implementers must not read:**

- anything from the previous third-party package (its build repository and its binary package repository) or from the build repositories that produced the previous third-party build of its libraries, other than mpv's four public headers inside the binary package: no patch files, series files, harness scripts, build scripts, sources or documents, in the repositories, their history or a resolved SwiftPM checkout;
- forks of mpv, FFmpeg, libass or the previous third-party package, by that package's author or by any other third party;
- the third-party media app from which Vivid's old player bridge was derived, in any form;
- Vivid's old bridge files (`MpvPlayerCoreBase.swift`, `MpvPlayerCore.swift`, `ExternalDisplayManager.swift`) or any history that shows them;
- Vivid's old `patches/` folder at the repository root (`patches/mpv/`, the unrebased `patches/ffmpeg/` file and the subfolder of patches for the previous third-party build) on `main` and `fix/lgpl-media-engine`;
- `scripts/tests/compressed-audio-recovery-tests.py`;
- `scripts/tests/playback-end-recovery-tests.py`;
- `.github/workflows/mpv-audio-driver.yml`;
- `docs/cores/lucid-engine-build-facts.md`, a dirty-side fact sheet about the old binaries, which these patches do not need;
- the dirty side's working notes, drafts and audits.

If something here seems incomplete or contradictory, ask the spec editor. Do not look at the current engine or its patches to settle it.

### 1.5 How to read this document

- **Names.** Upstream mpv, FFmpeg, libdovi and Apple names are used exactly, because the implementer may read those sources. Every other name (functions, fields, files, macros, queues, test cases) is the implementer's choice, except where section 2 freezes it. Nothing here asks for any particular split into helper functions.
- **Requirements.** "Must" is required for parity. "Should" is a recommendation. Where an ordering is stated, it is observable and must be kept; anything given as a set may happen in any order.
- **Ranges.** Option ranges are inclusive. "At least" is inclusive; "below" and "less than" are exclusive. Boundaries such as "1 s minus 1 ns" in the test vectors matter.
- **Times.** Seconds unless marked ms or ns.
- **Platforms.** Vivid ships iOS and iPadOS 18 and later and tvOS 26 and later, and runs in the iOS and tvOS simulators. "iOS" below includes iPadOS. macOS, Mac Catalyst and visionOS are not Vivid targets (2.11).
- **No code.** Arithmetic that decides pixel or timing parity is given as equations in prose. Any faster implementation (for example vectorised) must give bit-identical results.

### 1.6 Terms

| Term | Meaning |
| --- | --- |
| AO | The audio output driver named `avfoundation`. |
| VO | The video output driver named `avfoundation`. |
| PCM sink | The AO's `AVSampleBufferAudioRenderer` and `AVSampleBufferRenderSynchronizer` path for decoded audio. |
| Compressed sink | The AO's `AVPlayer` path for AC-3 and E-AC-3 passthrough. |
| Carrier rate | The sample rate mpv opens the AO with for an spdif format. Codec rate: the audio rate of the AC-3 or E-AC-3 bitstream inside it. |
| Burst | One IEC 61937 data burst as FFmpeg's `spdif` muxer emits it: an 8-byte preamble, the payload, then padding up to the repetition period. |
| Carry-over buffer | Bytes read from mpv that have not yet been resolved into accepted bursts or discarded. |
| Stream window | The elementary-stream bytes the AO can still hand to `AVPlayer`, indexed by their offset from the start of the item's stream. Write head: the offset just past the newest byte. |
| Fed duration | How much audio the item's stream holds: one burst period for every payload accepted into the window. |
| Consumed carrier frames | How many carrier frames `ao_read_data` has returned for the current item. |
| Dropped duration | One burst period for every payload that was read from mpv but rejected. |
| Compressed clock | The item's playhead, read as in 3.4.8. Engaged: the compressed clock is strictly above zero. |
| Rate requested | `AVPlayer` has been asked for rate 1 for the current item. |
| Recovery seek | The single seek to time zero of 3.4.10. Fallback: giving up on the compressed sink so mpv reopens audio as decoded PCM (3.4.13). |
| Passthrough block | The process-wide record of formats the compressed sink has given up on (3.2.3). |
| Initial-start mode | The AO state that shortens the first recovery deadline until the AO's first engagement (3.4.10). |
| AO queue | The AO's private serial dispatch queue. |
| Detail window | The 8 s after any `trace edge` line, during which diagnostics are logged more often. |
| Host layer | The `AVSampleBufferDisplayLayer` whose address Vivid passes as `wid`. |
| Subtitle layer | The second, transparent `AVSampleBufferDisplayLayer` the VO creates for subtitles. |
| Host time | mpv's monotonic clock, `mp_time_ns()`, in nanoseconds. Media time: a frame's timestamp on mpv's playback timeline (`mp_image.pts`, seconds). |
| DV | Dolby Vision. VT: VideoToolbox. Profile numbers are Dolby Vision bitstream profiles. |
| The bridge | Vivid's Swift layer between its adapter (`VividMPVPlayer`) and libmpv, specified in `docs/playback/player-bridge-spec.md`. |
| Trial build | A Vivid build with the `VIVID_P8_TRIAL` compilation condition, which only the tvOS Debug configuration defines. It switches engine logs to level `v`. Every other build, iOS Debug included, uses `warn` (2.8). |

### 1.7 What Vivid does with the engine, for context

**Options set before `mpv_initialize`** (with `mpv_set_option_string` unless stated):

| Option | Value | Condition |
| --- | --- | --- |
| `wid` | the host layer's address, as `MPV_FORMAT_INT64` with `mpv_set_option` | always |
| `vo` | `avfoundation` | always |
| `avfoundation-composite-osd` | `no` | always, every platform and simulator |
| `avfoundation-presentation` | `host` | tvOS devices only (not the tvOS simulator) |
| `hwdec` | `videotoolbox` on devices, `no` in simulators | |
| `hwdec-codecs` | `all` | always |
| `hwdec-software-fallback` | `yes` (the value 1) | always |
| `target-colorspace-hint` | `auto` | always; the VO never reads it |
| `keep-open` | `yes` | always |
| `ao` | `avfoundation` | always |
| `audio-spdif` | `ac3,eac3` when the initial rate is exactly 1 and neither Volume Boost nor Enhanced Dialogue is on, otherwise the empty string | |
| `volume-gain` | the Volume Boost gain in dB, from `1.94` to `6.02` | only while Volume Boost is on |
| `af` | Enhanced Dialogue's `lavfi` `firequalizer` graph | only while Enhanced Dialogue is on |
| `ao-avfoundation-manage-audio-session` | `no` | always |
| `audio-exclusive` | `yes` | always |
| `audio-channels` | `7.1,5.1,stereo` on tvOS when the route is AirPlay at load, otherwise `auto-safe` | |
| `ao-avfoundation-max-lookahead` `4`, `ao-avfoundation-compressed-anchor-start` `yes`, `ao-avfoundation-compressed-start-grace` `1`, `ao-avfoundation-compressed-first-start-grace` `0.25`, `ao-avfoundation-compressed-anchor-resume` `yes`, `ao-avfoundation-compressed-buffer` `1.25` | | tvOS, AirPlay route at load only; never on iOS |
| `osd-level` | `0` | always, so the OSD carries subtitles only |
| `pause` | `no` when autoplaying, otherwise `yes` | |
| `start` | the start position in seconds | |
| `hr-seek` | `no` when the start position is above 0 (a resume starts on the keyframe at or before it), otherwise `default` | |
| `speed` | the initial rate | |
| `volume` | the initial volume × 100 | |
| `sid`, `secondary-sid` | `no` | always |
| `cache` | `yes` | always |
| `demuxer-max-bytes`, `demuxer-max-back-bytes` | `268435456`, `16777216` | always |
| `cache-secs` | `60` | tvOS only |
| `alang` | the preferred audio languages, comma-separated | |
| `config`, `input-default-bindings`, `input-vo-keyboard`, `terminal` | `no` | always |
| `http-header-fields` | a string array, with `mpv_set_option` and `MPV_FORMAT_NODE`; an empty array when the server needs no headers | every load; the result is not checked |
| `vid` | `no` | audio-only loads |
| `tls-verify` | `yes` | app code on `fix/lgpl-media-engine` (not yet on `main`): only where the linked FFmpeg's configuration string contains `--enable-securetransport`, which every build of Vivid's pipeline does; applied in both mpv contexts below |

Vivid also registers its own `vividstream` protocol with `mpv_stream_cb_add_ro` when its managed reader is used.

No GPU context is configured on iOS or tvOS: the old bridge sets `gpu-api` `vulkan` and `gpu-context` `moltenvk` only in its macOS branch, which iOS and tvOS builds do not compile, and the new bridge sets neither. The `avfoundation` video output never uses a GPU context. The new engine has no MoltenVK context and rejects `gpu-context=moltenvk`; it must not accept that value as a no-op (8.8).

**Run-time writes and commands.**

- Straight after `mpv_initialize` and before `loadfile`, the adapter sends the subtitle style as asynchronous property writes, and sends the same set again whenever the viewer changes subtitle appearance or timing, at any moment, mid-play and while paused included: `sub-ass-override` and `secondary-sub-ass-override` `no`; `sub-font`; `sub-bold`; `sub-font-size`; `sub-color`; `sub-border-style` `background-box` or `outline-and-shadow`; `sub-back-color`; `sub-outline-color`; `sub-outline-size`; `sub-shadow-offset` (negative for a raised edge); `sub-align-y` `top` or `bottom`; `sub-margin-x`; `sub-margin-y`; `sub-pos` and `secondary-sub-pos`; `sub-scale-with-window` `no`; `sub-use-margins` `no`; plus `sub-delay` and `secondary-sub-delay`. The style values are worked out from the text overlay's own sizes (`LucidSubtitleStyle` in the adapter), and when the shown video changes size or shape (a layout pass, new video parameters or Picture in Picture starting or stopping) the adapter writes again only the style keys whose values changed. Selecting a primary subtitle track writes `sid` and `sub-delay`, and selecting a secondary one writes `secondary-sid` and `secondary-sub-delay`; clearing either writes only its own `sid` or `secondary-sid` (`no`). Each such change must show on the next frame or redraw, in both subtitle modes.
- `avfoundation-pip-composite-osd` `yes` or `no` (iOS only), as an asynchronous property write whenever the Picture in Picture flag is assigned.
- `pause`, `aid` and `volume` at any time. Vivid's mute is `volume` 0, which has no effect during passthrough (3.4.14).
- `hr-seek` `default` at the first `playback-restart` of a resumed load.
- `vid` `no` on entering the background without Picture in Picture, and `vid` `auto` on every return to the foreground and, on iOS, on every scene activation (Control Centre, banners, alerts, app-switcher peeks), whether or not the load is audio-only.
- Commands: `loadfile`; `seek <t> absolute+exact`; `seek 0 relative+exact` (the paused redraw, and before some `audio-spdif` changes, below); `sub-add <path> auto` for external subtitle files added during playback (ASS sidecars, and on iOS an unselected copy of each plain-text sidecar for Picture in Picture). An `on_preloaded` hook may write `aid` synchronously.
- **Speed changes.** Every change of rate writes both `speed` and `audio-spdif`: towards 1x, `speed` first and then `audio-spdif` `ac3,eac3`; away from 1x, `audio-spdif` empty first and then `speed`. So `audio-spdif` changes value on every crossing of 1x, whatever the audio codec. The exception is a load with Volume Boost or Enhanced Dialogue on: `audio-spdif` is empty from the start and every write keeps it empty, so no crossing changes it and the adapter never queues the seek below. It is an `UPDATE_AD` option, so each crossing that changes it tears down and rebuilds the audio decoder and filter chain, for every codec. Whether the AO is replaced depends on the track:
  - on an AC-3 or E-AC-3 track the crossing switches between passthrough and decoded PCM, so mpv closes the AO and opens a new one, which starts again from `init` (3.1);
  - on any other track (DTS, TrueHD, AAC and the rest, decoded to PCM either way) the output format does not change, so mpv's default weak gapless handling keeps the same AO: it gets no `init`, no driver `reset`, no fresh sink and no `start-fresh` edge. mpv's queued audio is kept and the AO keeps pulling through the rebuild. If that queue runs dry before the new chain refills it, mpv later starts the AO again with a plain `start` (on bounded tvOS PCM, at most one `start` edge, with the renderer and its enqueued end kept).

  Only when the active track is AC-3 or E-AC-3 and the change crosses 1x does the adapter queue `seek 0 relative+exact` just before the `audio-spdif` write. On iOS, touch-and-hold 2x makes two crossings in quick succession.

**A second mpv context.** Vivid's subtitle probe opens its own headless context, possibly while a player is alive in the same process. It sets `config` and `terminal` `no`; `vo` and `ao` `null`; `track-auto-selection`, `vid`, `aid` and `sid` `no`; `pause`, `idle` and `keep-open` `yes`; `cache` `no`; `network-timeout` `10`; `demuxer-max-bytes` `4194304`; `http-header-fields` (as above, unchecked); and `tls-verify` as above. A rejected option among the others, `tls-verify` included, or a failed `mpv_initialize` aborts the probe. It reads `track-list` after `file-loaded`. Upstream's `null` audio and video outputs must therefore stay available. The probe never selects the `avfoundation` outputs, so it never touches the AO's passthrough block.

**Audio session.** "AirPlay" is decided once per load on tvOS: the current `AVAudioSession` route has an output whose port type is AirPlay. Vivid activates the shared session itself (category playback, mode moviePlayback, route-sharing policy longFormAudio) before creating each player, and deactivates it only after every retired player has finished tearing down.

**Never used.** Vivid never sets `video-zoom`, `video-pan-x`, `video-pan-y`, `video-scale-x`, `video-scale-y`, `panscan`, `video-aspect-override`, `video-rotate`, `avfoundation-queue-lead-ms`, `avfoundation-osd-max-height`, `avfoundation-osd-video-res`, `audio-buffer`, `audio-device`, `ao-volume`, `ao-mute`, `mute`, `ao-avfoundation-accept-compressed`, `ao-avfoundation-compressed-lead`, `sub-video-rect-aspect`, `deinterlace`, `hwdec-image-format`, `tone-mapping`, any `target-*` option other than `target-colorspace-hint`, `af`, `vf`, `lavfi-complex`, `display-fps`, `override-display-fps`, `video-sync` or `force-window`. Its app code sends no `cycle`, `add`, `set`, `af`, `vf`, `ao-reload` or `script-message` command (the new bridge's own tests send a `set`), sets no process environment variable on iOS or tvOS, and has no viewer zoom.

## 2. Frozen interface shared with Vivid

Everything in this section is depended on by Vivid's app code, scripts, CI or documentation, or by mpv's own player logic. A change here is a regression even if playback looks and sounds the same.

### 2.1 Driver identity and registration

**Audio output.**

- Driver name `avfoundation`, selected with `ao=avfoundation`. mpv derives the log prefix `ao/avfoundation` from it; Vivid filters log messages on that exact prefix.
- Options prefix `ao-avfoundation` (upstream's `options_prefix` mechanism), so every option in 2.2 is `ao-avfoundation-<name>` and can be set with `mpv_set_option_string` before initialisation.
- Pull-based driver with `init`, `uninit`, `control`, `reset`, `start` and `set_pause`, and no `write` or `get_state`. Because `set_pause` exists, mpv uses the hardware-pause branch of `ao_set_paused` for this driver, including its end-time bookkeeping across pause and resume. Every `set_pause` path returns true.
- On iOS and tvOS the driver has no `list_devs`: Vivid's existing build patch (`engine/patches/mpv/0002-ao_avfoundation-build-for-ios-and-tvos.patch`) leaves it out wherever the CoreAudio HAL is missing, and the AO patch must keep it that way. mpv then lists the driver itself as one device in `audio-device-list` (7.4). `audio-device` is ignored.
- The description string is free.

**Video output.**

- Driver name `avfoundation`, selected with `vo=avfoundation`. Log prefix `vo/avfoundation`.
- Registered in `video/out/vo.c` at the head of mpv's video output list, before `gpu-next`. With `vo` unset, autoprobe tries it first; its creation fails cleanly without `wid`, so autoprobe moves on.
- Compiled when the meson feature option `vo-avfoundation` (type feature, default `auto`) is enabled. That name is frozen: the build configuration passes `-Dvo-avfoundation=enabled` once the VO patch is in the series (8.4). It is separate from upstream's existing `avfoundation` feature, which is the audio output.
- The feature depends on the Apple frameworks AVFoundation, CoreMedia, CoreVideo, CoreImage, QuartzCore, Metal and UIKit, and the VO also calls CoreGraphics and IOSurface. The meson option, the meson feature and the registration in `vo.c` are the only changes outside the VO source file. The file's name and location under `video/out/` are free. Upstream mpv compiles Objective-C without ARC; the rewrite may use either memory model if it keeps the ownership rules in 4.16.
- Its options are global options in one sub-option group with the prefix `avfoundation`, registered through `vo_driver.global_opts` (2.3). `vo_driver.options` is empty, so there are no `--vo=avfoundation:...` sub-options.
- The description string is free.

**Hardware decoding device.** At creation the VO adds one entry to `vo->hwdec_devs` with driver name `avfoundation`, an `av_device_ref` to a libavutil VideoToolbox device (`AV_HWDEVICE_TYPE_VIDEOTOOLBOX`, allocated and initialised) and `hw_imgfmt` `IMGFMT_VIDEOTOOLBOX`. This is what lets `hwdec=videotoolbox` decode straight into frames the VO accepts. `hwdec-interop` then reports `avfoundation`, and `hwdec-current` reports `videotoolbox` while the VideoToolbox hwaccel is in use.

### 2.2 Audio output options

| Option | Type | Default | Range | Exists on | Vivid's value |
| --- | --- | --- | --- | --- | --- |
| `ao-avfoundation-accept-compressed` | flag | `yes` | | iOS, tvOS | not set |
| `ao-avfoundation-manage-audio-session` | flag | `yes` | | iOS, tvOS (acts only there) | `no`, every platform |
| `ao-avfoundation-compressed-lead` | double, seconds | 8 | 1 to 30 | iOS, tvOS | not set |
| `ao-avfoundation-compressed-start-grace` | double, seconds | 2 | 1 to 30 | iOS, tvOS | `1` on tvOS AirPlay, which sits on the minimum, so the minimum must stay inclusive |
| `ao-avfoundation-compressed-first-start-grace` | double, seconds | 2 | 0 to 30 | iOS, tvOS | `0.25` on tvOS AirPlay |
| `ao-avfoundation-compressed-buffer` | double, seconds | 2 | 0.5 to 2 | iOS, tvOS | `1.25` on tvOS AirPlay |
| `ao-avfoundation-compressed-anchor-start` | flag | `no` | | iOS, tvOS | `yes` on tvOS AirPlay |
| `ao-avfoundation-compressed-anchor-resume` | flag | `no` | | iOS, tvOS | `yes` on tvOS AirPlay |
| `ao-avfoundation-max-lookahead` | double, seconds | 0 | 0 to 10 | **tvOS only; it must not exist on iOS** | `4` on tvOS AirPlay |

What each one controls (sections 3.2 to 3.4 give the detail):

- `accept-compressed`: off makes `init` refuse every spdif format before touching the audio session.
- `manage-audio-session`: on, the AO sets the session's category and mode and activates and deactivates it; off, it does none of those three. The multichannel declaration and the preferred channel count happen either way.
- `compressed-lead`: how far the stream is kept filled ahead of the compressed clock in steady state, and with it the stream window's size. Before the clock moves, the target is twice this.
- `compressed-start-grace`: the ordinary supervision deadline (3.4.10): before the recovery seek, between it and fallback, and for each slow-source extension.
- `compressed-first-start-grace`: the shorter deadline used in initial-start mode, capped at `compressed-start-grace`.
- `compressed-buffer`: the AO's `ao->device_buffer` for the compressed sink, in seconds of carrier frames. mpv's queue in front of the AO is the larger of that and `audio-buffer`, so with Vivid's settings it is `compressed-buffer`, and mpv starts audio only once that queue is full.
- `compressed-anchor-start` and `compressed-anchor-resume`: extra small reads that keep mpv's audio clock on an `AVPlayer` playhead that has not started moving, at start-up and after an unpause (3.4.11).
- `max-lookahead`: on tvOS, a value above 0 switches the PCM sink to the bounded mode of 3.3.3; 0 leaves it unbounded, whatever `audio-buffer` says.

Setting an option that does not exist fails with mpv's "option not found" error; Vivid's error check only logs it to the console and set-up continues. Keeping `max-lookahead` absent on iOS is exact parity: Vivid never sets it there.

### 2.3 Video output options

All are global options with the prefix `avfoundation`. They exist whenever the VO is compiled in, even while another video output is in use, and can be set before `mpv_initialize` and at run time as properties (flag values `yes` and `no`). The VO reads them through an `m_config_cache` whose wakeup callback calls `vo_wakeup`, and applies changes on the VO thread at the next `VOCTRL_CHECK_EVENTS` or `VOCTRL_VO_OPTS_CHANGED` (4.14.9).

| Option | Type and range | Default | Effect | Vivid |
| --- | --- | --- | --- | --- |
| `avfoundation-composite-osd` | flag | `no` | Registered only so that Vivid's `no` is accepted. `yes` is accepted and has no effect (7.2). | `no` before init, every platform. |
| `avfoundation-pip-composite-osd` | flag | `no` | `yes` burns subtitles into the video samples on the frame's own pixel grid (4.14.7). | Written at run time on iOS. |
| `avfoundation-queue-lead-ms` | integer, 0 to 1000 | 128 | How long before a frame's display time mpv hands it to `flip_page`, applied with `vo_set_queue_params(lead in ns, 1)` at creation and whenever it changes. | Default. |
| `avfoundation-presentation` | choice `media` or `host` | `host` when built for tvOS (device and simulator), otherwise `media` | Timing model (4.8). Read once per VO, at creation. | `host` on tvOS devices; the tvOS simulator gets `host` through the default; iOS keeps `media`. |

`avfoundation-osd-max-height` and `avfoundation-osd-video-res` are not registered (7.2).

### 2.4 `wid`

- `wid` is the upstream option (int64, default -1, flagged `UPDATE_VO`). The bridge writes the host layer's object address as an int64 before `mpv_initialize`, without retaining it.
- The VO reads `wid` once, at creation. With -1, creation logs an error and fails, so mpv reports a video output failure for any file with video. Any other value is taken, without validation, to be the address of an `AVSampleBufferDisplayLayer` (a subclass is fine).
- The VO keeps its own strong reference to the host layer from creation to teardown, so the host may remove the layer from its tree, or drop its own reference, while the VO is alive. The bridge relies on this when it disposes a player.
- Because `wid` is `UPDATE_VO`, writing it at run time rebuilds the VO. The bridge never does this.

### 2.5 The host layer: what the VO does, and what it requires

**The VO does:** set and clear the layer's `controlTimebase`; enqueue to and flush the layer's sample buffer renderer; insert the subtitle layer into the host layer's superlayer (or into the host layer itself when it has none); add and remove key-value observers for `bounds` and `contentsScale`.

**The VO never** changes the host layer's `frame`, `bounds`, `position`, `transform`, `videoGravity`, `contentsScale`, opacity, background, `preferredDynamicRange` or `wantsExtendedDynamicRangeContent`, and never removes it from its superlayer.

**The VO requires of the host:**

| Requirement | Detail |
| --- | --- |
| The host layer is an `AVSampleBufferDisplayLayer`, alive until the VO has taken its reference. | 2.4. |
| The host layer has a superlayer whenever the VO is created. | The subtitle layer goes into that superlayer as a sibling. Without one, it goes inside the host layer and a warning is logged; subtitles still work, but the system can no longer present the video layer directly. The VO is created again after every `vid=no` then `vid=auto` cycle (4.16.1), so this must hold then too. |
| Move the parent, never the host layer alone. | The subtitle layer stays in whichever superlayer it was put in at creation. The bridge moves the container view, which carries both layers. |
| Geometry is read from `bounds` and `contentsScale`. | Output pixel width is the larger of 1 and the integer part (truncated) of `bounds.size.width × scale + 0.5`, where the multiplication and the addition are one fused multiply-add in double precision, rounded once; the same for height. `scale` is `contentsScale` when it is above 0, otherwise `UIScreen.main.scale` (not `nativeScale`). If either bounds dimension is 0 or negative, `frame.size` is used instead. The read is a synchronous hop to main. |
| `bounds` and `contentsScale` are written only with final values, with animations disabled. | A notification counts as a change unless its old and new values are both present and equal, so a missing value counts too (4.15.2). While subtitles are on the separate layer, a change makes the VO resync subtitle geometry and flush the subtitle layer with removal, which briefly blanks a displayed subtitle; while compositing, it does nothing more. Writing an identical value does nothing. |
| `position` is not observed. | The subtitle layer copies the host layer's `frame` whenever a resync runs. The bridge always sets `bounds` and `position` together. |
| Main must stay responsive and must never wait on mpv. | The VO blocks on main at the points listed in 4.16.6. |
| The host never touches `controlTimebase`. | The VO owns it. |
| The host may flush the host renderer on iOS activation. | On every iOS scene activation without Picture in Picture, the bridge calls the host layer's `flush` (never flush-and-remove) when `requiresFlushToResumeDecoding` is set or `status` is failed, and then issues the paused redraw seek. The VO is not told. Its readiness and recovery logic (4.10, 4.11) must cope with a flush made between its own enqueues. |
| `videoGravity`, `transform`, EDR and dynamic range belong to the host. | The VO sets `videoGravity` only on its own subtitle layer (always `AVLayerVideoGravityResize`). |

**Two things Vivid's app tests already rely on.** `PlayerSurfaceLayoutTests` (run on the iOS simulator) loads a short H.264 and AAC file and needs: the host layer's `isReadyForDisplay` to become true once the VO has enqueued frames, and to stay true through resizes and rotations; a paused position to stay put through resizes; `currentTime` never to go backwards during resizes; and a following load to reach its first frame. So frames the VO enqueues must make the host report `isReadyForDisplay`, and a host resize must never flush the host layer.

### 2.6 What the VO reports back

| Output | Detail |
| --- | --- |
| `vo->dwidth`, `vo->dheight`, `vo->monitor_par` | The host layer's pixel size (2.5) with `monitor_par` 1.0, updated on every geometry read. Upstream derives the OSD resolution and related properties from these. |
| Drop count | Each frame the VO drops at its readiness deadline (4.10) adds exactly 1 through `vo_increment_drop_count`. Subtitle sample drops are not counted. |
| `vo->want_redraw` | Set after a real host resize while subtitles are on the separate layer (4.15.2). |
| Capabilities | `vo_driver.caps` is 0: no `VO_CAP_ROTATE90`, no `VO_CAP_FRAMEDROP`, no untimed or no-retain flags, no film grain, no vertical flip. |
| Not implemented | `get_vsync`, `get_image`, `wait_events`, `wakeup`, and every `VOCTRL_*` request not listed in 4.16.4, including `VOCTRL_GET_DISPLAY_FPS`, display resolution queries and `VOCTRL_SCREENSHOT`. Implementing any of them would change `display-fps`, `vo-delayed-frame-count`, `frame-drop-count` or the filter chain. |
| Events | The VO raises no `VO_EVENT_*` of its own. |

### 2.7 Properties, events and statistics Vivid reads

All are upstream mpv properties and events. The engine must leave each producing the same values at the same moments as today.

| Property or event | Reader | What the engine decides, and what must hold |
| --- | --- | --- |
| `audio-out-params` | adapter (`format`, `channel-count` only) | `format` is upstream's `spdif-ac3` or `spdif-eac3` during passthrough, with the 2-channel carrier reported as is. For PCM, as upstream: a planar format becomes its interleaved equivalent (3.3.1) and the AO changes nothing else. The E-AC-3 carrier rate (four times the codec rate, 6.4) is engine parity, not something Vivid reads. |
| `hwdec-current` | adapter | `videotoolbox` while the VideoToolbox hwaccel is in use, including after FFmpeg's internal retry with a plain HEVC session (5.3), which mpv cannot see; `no` after mpv's software fallback and in simulators. |
| `video-params`, `video-out-params` | adapter and bridge | `w`, `h`, `par`, `gamma`, `sig-peak`, `primaries`, `colormatrix`. `video-out-params` depends on the VO's accepted format set (4.1). |
| `track-list` and `current-tracks/video`: `dolby-vision-profile`, `dolby-vision-level` | adapter and bridge | Upstream values from the container record. Profile 7 stays 7: the converted profile is never reported. |
| `dolby-vision-compatibility-id` | adapter, as a key of the selected video track's `track-list` entry | No `track-list` or `current-tracks/video` entry may carry this key, and no such property may exist. The adapter then labels profile 8 "DV Profile 8", profile 5 "DV Profile 5" and profile 7 "DV Profile 8.1". |
| `time-pos`, `avsync` | adapter (position; the statistics overlay and the session report's maximum and seconds over 100 ms) | Both follow from the end times the AO hands mpv (3.3.1, 3.4.8), the compressed clock and anchoring. They must match today. |
| `paused-for-cache` | adapter (buffering state, rebuffer and stall counts) | The prefetch guards (3.3.3, 3.4.9) exist to keep it false while enough audio is queued. |
| `eof-reached`, `end-file` (reason and error) | adapter | Their timing follows AO end of file and drain. |
| `playback-restart` | adapter and bridge | Sets the first-frame flag and is where the bridge takes its Match Content snapshot. |
| `MPV_EVENT_VIDEO_RECONFIG` | bridge | Where it reads `video-out-params`, `current-tracks/video`, `container-fps`, `estimated-vf-fps` and `deinterlace-active`. Emitted when the VO is destroyed and whenever the video configuration changes (upstream). |
| `frame-drop-count` | adapter | Upstream core drops plus the VO's deadline drops, one each. |
| `decoder-frame-drop-count`, `vo-delayed-frame-count` | adapter | Upstream; the latter comes from upstream's fallback timing, because the VO reports no vsync. |
| `display-fps` | adapter | Unavailable: the VO does not implement `VOCTRL_GET_DISPLAY_FPS` and Vivid never sets `override-display-fps`. |
| `seeking`, `pause`, `file-loaded`, `aid`, `sid`, `secondary-sid`, `audio-codec-name`, `chapter-list`, `demuxer-cache-state`, `demuxer-cache-duration`, `container-fps`, `estimated-vf-fps`, `deinterlace-active`, `video-bitrate`, `width`, `height`, `video-params/sig-peak` | adapter and bridge | Upstream; the engine patches must not change them. |
| `hwdec-interop` | nobody today | `avfoundation`, frozen as the device name (2.1). |

Vivid also calls FFmpeg's public `avformat_configuration()` by symbol name and turns on `tls-verify` only when the returned string contains `--enable-securetransport`. Vivid's pipeline checks that flag (8.5).

### 2.8 Log levels and how Vivid consumes logs

- Both bridges request `warn` when they create the mpv context. The adapter then requests `v` in trial builds and `warn` in every other build. Only lines at or above the requested level reach the app as `log-message` events, so **the level of every engine log line is part of the interface**.
- Both bridges drop every `log-message` while the app is in the background, so nothing logged then is recorded (for example AO faults during iOS background audio).
- mpv maps FFmpeg levels as follows: `AV_LOG_ERROR` becomes `error`, `AV_LOG_WARNING` becomes `warn`, `AV_LOG_INFO` becomes `v`, `AV_LOG_VERBOSE` becomes `debug`. FFmpeg decoder messages arrive with the prefix `ffmpeg/video`. mpv's video decoder wrapper logs as `vd`.
- The adapter trims whitespace from each message and then decides, in this order of precedence:
  1. for any prefix, a message beginning `Too many packets in the demuxer packet queues:` is a fault;
  2. for prefix `ao/avfoundation`, the exact line `resuming compressed feed after audio EOF` is an event;
  3. for prefixes `demux`, `demuxer`, `cplayer`, `ad`, `ffmpeg`, anything beginning `ffmpeg/` and anything beginning `demux/`, a message containing (case-sensitive) `Too many packets`, `queue overflow`, `EOF`, `End of file`, `timed out`, `Connection reset`, `Error decoding` or `Invalid data` is a fault, and nothing else is looked at;
  4. for prefix `ao/avfoundation`: the remaining exact strings, then the seven anchored patterns, then the fault substrings, all in 2.9. A line that matches an exact string or a pattern is never checked against the fault substrings; whether it is a fault is fixed by its own row in 2.9;
  5. every other prefix, including `vo/avfoundation` and `vd`, is ignored.
- Fault labels feed Vivid's playback session recorder in every build, and every matched line is also written to the device's unified log. Pipeline snapshots fire whenever a heartbeat, item-status, PCM transport or trace-edge line arrives, which in practice means at level `v`. Raising or lowering a line's level therefore changes both fault recording and log volume.

### 2.9 Log lines other code consumes

All lines in this table come from the AO and carry the prefix `ao/avfoundation`. Each row is one log line: do not merge or split lines.

**Number formats are part of the interface.** Every `%.3f` must print digits, a point and digits, whatever the locale, and no consumed value may print `inf` or `-nan`. Lowercase `nan` is accepted only in the flush-time line. That line's flush time is also the one value allowed to print `inf` or `-inf`, for an infinite flush time, as today; the line then fails its pattern and is dropped (12.1). Negative values such as `-0.000` and `-1.000` occur and are accepted. The heartbeat's `status` and `tc`, and `anchors` in the engaged and resumed lines, must be non-negative. `seeked` and `current` print exactly 0 or 1. A line that fails its pattern is then checked against the fault substrings.

| Exact format | Level | Consumer |
| --- | --- | --- |
| `trace edge %s: clock %.3f, fed %.3f, latency %.3f` | verbose | Anchored pattern; the edge is one of `start`, `start-fresh`, `pause`, `resume`, `reset`, `restart`. The format must literally begin `trace edge %s: clock` (2.10). |
| `first start recovery after %.3f s` | verbose | Binary marker only. |
| `resuming compressed feed after audio EOF` | verbose | Exact match; binary marker. |
| `compressed clock engaged after %.3f s, seeked %d, anchors %d` | verbose | Anchored pattern. |
| `compressed clock resumed after %.3f s, anchors %d` | verbose | Anchored pattern. |
| `item status %d -> %d, time control %d -> %d, pos %.3fs, fed %.3fs` | verbose | Anchored pattern. |
| `heartbeat: raw pos %.3fs, clamped %.3fs, fed %.3fs, status %d, tc %d, reader gap %lld B` | verbose | Anchored pattern (the reader-gap part is optional in the pattern). |
| `pcm: clock %.3f, fed %.3f, ahead %.3f, rate %.3f, status %d, latency %.3f, sufficient %d` | verbose | Anchored pattern (latency and sufficient optional; status non-negative). |
| `notification name: %s` | verbose | Prefix `notification name: ` plus the substring `AVSampleBufferAudioRendererWasFlushedAutomatically` or `AVSampleBufferAudioRendererOutputConfigurationDidChange`. The `%s` is the notification's name. Upstream string. |
| `notification flush time %.3f, current %d` | verbose | Anchored pattern. |
| `pcm fresh sink after reset` | verbose | Exact match. |
| `pcm fresh sink failed; requesting audio reload` | warn | Exact match; fault. |
| `pcm renderer failed; requesting audio reload` | warn | Exact match; fault. |
| `restarting due to system notification; this will cause desync` | warn | Exact match; fault. Upstream string. |
| `elementary stream window overflow; falling back to PCM` | error | Substring `elementary stream window overflow`; fault; binary marker. |
| `discarding burst with odd payload length` | warn | Substring; fault. |
| `discarding burst without syncframe` | warn | Substring; fault. |
| `skipping unexpected IEC 61937 data type 0x%x` | warn | Substring `skipping unexpected IEC 61937 data type`; fault. |
| `skipping burst with invalid payload length %d` | warn | Substring `skipping burst with invalid payload length`; fault. |
| `no IEC 61937 sync found in %d bytes; falling back to PCM` | error | Substring `no IEC 61937 sync found`; fault. |
| `loader requested offset %lld below the retained window at %lld` | error | Substring `loader requested offset`; fault. |
| `playback did not engage; seeking to the stream start` | warn | Substring `playback did not engage`; fault. |
| `native compressed playback did not start; falling back to PCM` | error | Substring `native compressed playback did not start`; fault. |
| `player rejected the compressed stream: %s (%s:%ld)` | error | Substring `player rejected the compressed stream`; fault. The arguments are the error's localised description, domain and code. |
| `falling back to PCM` | error | Substring `falling back to PCM`; fault. A separate line logged straight after the rejection line, so that a rejection records two faults. |

The fault substrings are checked in this order and the first match wins: `elementary stream window overflow`, `discarding burst with odd payload length`, `discarding burst without syncframe`, `skipping unexpected IEC 61937 data type`, `skipping burst with invalid payload length`, `no IEC 61937 sync found`, `loader requested offset`, `playback did not engage`, `native compressed playback did not start`, `player rejected the compressed stream`, `falling back to PCM`. Because of that order, the three other lines containing `falling back to PCM` (window overflow, lost sync and playback that did not start) are recorded only under their own fault.

**Rules for every other line (wording free, constraints frozen):**

- Other AO lines exist and nothing parses them: an info line at compressed `init` naming the route's first output port type (or `none`) and the maximum output channel count; a verbose line when compressed input is refused by option; a verbose line per loader request (whether it has content-information and data parts, the offset, the length and the to-end flag) and per cancelled request; a verbose line for each refused request beyond the write head (offset and write head); a trace line per served chunk; a warning when the tvOS PCM timer cannot be created; a fatal line when a format is refused by the passthrough block (naming the format as `af_fmt_to_str` prints it, for example `spdif-eac3`); a fatal line for an unsupported spdif format; fatal lines when the player, timer, queue, renderer, synchroniser, block buffer, sample buffer or format description cannot be created. Where upstream follows a fatal creation line with a verbose detail line, keep it (the three CoreMedia ones carry the `OSStatus`); the player and feed-timer failures have none. Their wording is free, but each must keep its level and information, and none may contain a fault substring, begin with `notification name: `, match an anchored pattern or equal an exact string above. For example, the block's refusal line fires on every fallback reload and reaches Release builds; if it said "falling back to PCM", every fallback would record a second fault.
- Upstream's fatal `avfoundation does not support SPDIF` no longer exists. Upstream's fatal `please use coreaudio_exclusive instead` stays, but only where `HAVE_COREAUDIO` is true, which excludes iOS and tvOS.
- FFmpeg messages added or changed by section 5 and 6.6, and mpv messages added or changed by section 6 with the prefixes `ad`, `cplayer`, `demux` or `demuxer`, must contain none of the fault substrings in 2.8. Today's lines contain none. Their levels are fixed in 5.9 and section 6.
- VO lines (`vo/avfoundation`) and mpv's `vd` lines are not consumed. Their wording is free; keep each message's level (4.18).

### 2.10 Binary markers checked by scripts and CI

Only `first start recovery after` and `trace edge %s` (together with the licence strings) are checked in the linked app binary, where they prove the new engine is present. Every other marker below is checked only in standalone Libmpv binaries: most of them also appear in Vivid's Swift code or its compiled option strings, so finding them in the app would prove nothing.

| Checker | Where it looks | Strings |
| --- | --- | --- |
| `scripts/release/use-patched-libmpv.sh install` | the artefact's Libmpv for the slice | `first start recovery after`, `trace edge %s`, `-Dgpl=false` |
| `scripts/release/use-patched-libmpv.sh verify` | one candidate binary (the app executable, its Debug `.debug.dylib`, or a Libmpv framework) | `first start recovery after`, `trace edge %s`, `LGPL version 2.1 or later` and `-Dgpl=false` all present, and `GPL version 3 or later` absent |
| The old audio-driver workflow | on `main` and `fix/lgpl-media-engine`, every rebuilt Libmpv; on `fix/lgpl-media-engine` only, all eight rebuilt frameworks (Libmpv and the seven FFmpeg libraries) | on both branches, the five driver markers: `resuming compressed feed after audio EOF`, `manage-audio-session` followed by a NUL byte, `trace edge %s: clock`, `compressed-anchor-start` followed by a NUL byte and `first start recovery after`. On `fix/lgpl-media-engine` only: no OpenSSL symbol prefixes and no `_SecIdentityCreate` in any of the eight, `-Dgpl=false` in Libmpv, the LGPL licence string (and no GPL one) in each FFmpeg library, no `delogo` in Libavfilter and `--enable-securetransport` in Libavformat |
| `.github/workflows/mpv-experiment.yml` | the Libmpv SwiftPM resolves | `elementary stream window overflow`, `compressed-lead` |
| Vivid's pipeline (`engine/lucid.py check`) | every slice | see 8.5; 8.6 adds the 25 strings of 2.9 and the markers above |

Notes:

- The option-name markers hold because the option table stores the short name (`manage-audio-session`), as upstream's `options_prefix` mechanism does.
- `mpv-experiment.yml` checks the binary package SwiftPM resolves, so today it proves only that the old package has the old driver. Keep both strings so it would also pass on a package built by Vivid's pipeline.
- On `main` the install script still matches workflow runs on `patches/mpv` only and checks no licence strings; on `fix/lgpl-media-engine` it matches the whole `patches/` folder. The script must be updated for the pipeline's slice names and artefacts before it can install them (8.7).

### 2.11 Build requirements

- **Pipeline.** Patches are built by `engine/lucid.py` for four slices, each arm64 only: `ios-arm64`, `ios-arm64-simulator`, `tvos-arm64` and `tvos-arm64-simulator`. There is no arm64e, x86_64, macOS, Mac Catalyst or visionOS slice. Every Vivid patch must compile and link for all four.
- **Deployment target.** The pipeline compiles with a minimum OS of 14.0, although Vivid itself requires iOS 18 and tvOS 26. Every API newer than 14.0 therefore needs an availability check; 7.2 says what happens below the floors this document relies on.
- **mpv meson options** (from `engine/config/mpv-meson.txt`, in alphabetical order): `-Daudiounit=enabled`, `-Davfoundation=enabled`, `-Dcplayer=false`, `-Dgl=enabled`, `-Dgpl=false`, `-Diconv=enabled`, `-Dios-gl=enabled`, `-Djavascript=disabled`, `-Djpeg=disabled`, `-Dlibbluray=enabled`, `-Dlibmpv=true`, `-Dlua=disabled`, `-Dplain-gl=enabled`, `-Drubberband=disabled`, `-Dswift-build=disabled`, `-Duchardet=enabled`, `-Dvapoursynth=disabled`, `-Dvideotoolbox-gl=disabled`, `-Dvideotoolbox-pl=enabled`, `-Dvulkan=enabled`, `-Dzimg=disabled`. `cocoa` and `coreaudio` are left to auto-detection. The VO patch adds the meson option `vo-avfoundation`, and the build configuration then adds `-Dvo-avfoundation=enabled` (8.4).
- **Feature truth in the shipped slices**, checked by the pipeline's feature list (`engine/config/expected-mpv-features.txt`):
  - `HAVE_COREAUDIO` is false: there is no `coreaudio` feature and no `audio_out_coreaudio` symbol.
  - `HAVE_MACOS_11_3_FEATURES` and `HAVE_MACOS_12_FEATURES` are true. Upstream mpv derives them from the build host's macOS SDK, not the target SDK, and upstream's AO already uses them to guard the delayed-rate-change setting and the output-configuration notification. The behaviour they gate (3.2.4, 3.3.1) is required on iOS and tvOS. The clean AO may keep upstream's guards plus `@available`, or use `@available` alone; either way the shipped result must be "enabled".
- **Platform macros.** `TARGET_OS_IPHONE` is true on iOS and tvOS. This document's "iOS and tvOS" audio-session behaviour is keyed on it; the tvOS-only behaviour (bounded PCM, `max-lookahead`, the `host` default) is keyed on `TARGET_OS_TV`.
- **Applying on top of the series.** The pipeline applies each series in order with `patch -p1` and zero fuzz, refuses a patch whose SHA-256 differs from its series line, and fails if the files a series changes differ from the files its patches name. Each new patch must therefore apply with zero fuzz to the tree that the existing series (8.2) produces.
- **What remains for the AO to guard.** Vivid's existing mpv patch `0002` already keeps the CoreAudio HAL helpers (device lists, device selection, HAL properties, the device channel-map queries and the HostTime latency branch) out of iOS and tvOS, keeps the AO's output-device selection macOS-only, and leaves the AO's `list_devs` out where the HAL is missing. The rewritten AO must keep all of that, must call no HAL helper on iOS or tvOS, and needs only its own guards: `AVAudioSession` code behind `TARGET_OS_IPHONE`, the tvOS-only behaviour behind `TARGET_OS_TV`, and availability checks for every API above the 14.0 floor. The channel-layout helpers it uses (`ca_get_acl`, `ca_find_standard_layout`, `ca_log_layout`, `ca_fill_asbd`) stay available.
- **`0002` builds the string helpers.** Upstream's AO calls `cfstr_get_cstr` (from `osdep/utils-mac.c`) when it logs a notification name, and upstream builds that file only with the macOS-only `cocoa` feature. Since commit `546e11f`, Vivid's `0002` builds `osdep/utils-mac.c` whenever `cocoa` is off, so the helper exists on all four slices, and the pipeline's link checks (8.5) show that Libmpv links. Write the AO patch on top of that `0002`. The AO must still log the frozen verbose line `notification name: %s` (2.9) with the notification's full name, on iOS and tvOS, in the order 3.3.1 and 3.3.3 give. The pipeline's check for that format (8.5) and the 25-string check (8.6) only prove the format string exists, so a device or unit test must also check the printed name.

## 3. Audio output

The file in scope is upstream's `audio/out/ao_avfoundation.m` at `v0.41.0`, as Vivid's existing patch `0002` leaves it (2.11). Upstream plays decoded PCM through `AVSampleBufferAudioRenderer` and refuses every spdif format. The required AO keeps upstream's PCM path almost unchanged and adds a compressed passthrough sink for AC-3 and E-AC-3 through `AVPlayer`, a bounded PCM mode for tvOS, control over the shared audio session, and diagnostics.

### 3.1 Overview

| Path | When | Summary |
| --- | --- | --- |
| PCM sink | Any non-spdif format | Upstream's renderer and synchroniser, with the session rules of 3.2.4 and a `reset` trace edge. On tvOS with `max-lookahead` above 0, the bounded mode of 3.3.3. |
| Compressed sink | `AF_FORMAT_S_AC3` or `AF_FORMAT_S_EAC3`, `accept-compressed` on, format not blocked | Turns the IEC 61937 stream back into a plain AC-3 or E-AC-3 bitstream and serves it to `AVPlayer` through an `AVAssetResourceLoader` delegate (3.4). |
| Refusal | Any other spdif format (DTS, DTS-HD, TrueHD, AAC, MP3), or a blocked format | `init` fails with a fatal line, so mpv falls back to decoded PCM. |

On tvOS only `AVPlayer` renders the Atmos objects carried in E-AC-3 (as Dolby MAT over HDMI), while the sample-buffer renderer would give the channel bed alone, so all AC-3 and E-AC-3 passthrough goes through `AVPlayer`.

Whenever mpv reopens the audio output (a reload, a fallback, or a change of output format), a new AO starts from `init`. Vivid's speed changes cause that at every crossing of 1x on an AC-3 or E-AC-3 track, where passthrough and decoded PCM swap, so everything below starts again from `init` at each such crossing, on every route. On any other track a crossing rebuilds only mpv's decoder and filter chain and keeps the same AO (1.7): no `init`, no `reset`, no fresh sink and no `start-fresh` edge, and at most one plain `start` if mpv's queue ran dry meanwhile.

### 3.2 Shared infrastructure

#### 3.2.1 AO queue

- Each AO instance creates one serial dispatch queue at quality of service user-interactive, as upstream does. The queue carries queue-specific data identifying its AO, so code can tell whether it is already running there.
- `init` creates the queue straight after the session steps (3.2.4), before any sink object and before a refused format is detected, whatever the sink. Upstream creates it later, after the renderer and synchroniser. Failing to create it is fatal (2.9).
- All compressed-sink state, and on bounded tvOS all PCM-sink state, is touched only on this queue.
- Work requested from the AO queue itself runs inline; work requested from anywhere else is dispatched synchronously. This matters for a reset started by a notification that is being handled on the queue. Upstream already dispatches `reset` synchronously; keep that and add the same-queue check.
- The resource loader delegate is attached to this queue, so loader callbacks, feed timer ticks and transport calls never overlap.

#### 3.2.2 Timers

- **Compressed sink.** One repeating dispatch timer source on the AO queue, created during `init` and resumed straight away. It stays resumed until it is cancelled (Apple's dispatch documentation does not allow releasing a suspended source). "Idle" means rescheduled to fire never. "Armed" means first fire 50 ms from now, then every 50 ms, with 25 ms leeway. `start` and unpause arm it; pause, `reset` and fallback idle it.
- **Bounded PCM on tvOS.** One dispatch timer source on the AO queue with the same lifetime rules, used as in 3.3.3. If it cannot be created, a warning is logged and the PCM sink runs unbounded.
- Before `uninit` returns, every timer is cancelled from a block on the AO queue and only then released, so no handler outlives the AO.

#### 3.2.3 Passthrough block (process-wide)

- Two process-wide atomic flags, one for AC-3 and one for E-AC-3.
- A fallback (3.4.13) sets the flag for the format that failed.
- `init` with an spdif format whose flag is set fails with a fatal line naming the format, so the reload that the fallback requested ends in decoded PCM.
- `init` with any non-spdif format clears both flags before anything else that could fail (the `accept-compressed` check applies only to spdif), so even a PCM `init` that later fails has cleared them.
- Observable outcomes: after a PCM `init`, the next track, reload or playback session tries passthrough again; a flag set in one mpv instance that is destroyed before any PCM `init` is still set in the next instance in the same process.

#### 3.2.4 Audio session (iOS and tvOS)

Inside `init`, before any sink is created, in this order. Each step can change what the next one sees: the category, mode and multichannel declaration must be in place before activation, and the maximum channel count is read from the session as configured and activated.

1. If `manage-audio-session` is on: set category `AVAudioSessionCategoryPlayback` and mode `AVAudioSessionModeMoviePlayback`, ignoring errors.
2. On iOS and tvOS 15 and later: if the format is spdif or the channel count is above 2, call `setSupportsMultichannelContent:error:` with YES, ignoring errors. This happens whatever `manage-audio-session` says, and the AO never sets it back to NO.
3. If `manage-audio-session` is on: activate with `setActive:YES withOptions:0`.
4. Read `maximumOutputNumberOfChannels`.
5. For spdif: log the info route line (the port type of the first current route output, or `none`, and the maximum channel count). Set no preferred channel count.
6. For PCM: call `setPreferredOutputNumberOfChannels:error:` with the smaller of the maximum and the AO's channel count, ignoring errors, whatever `manage-audio-session` says.

Deactivation, both on the `init` error path and in `uninit`: only when `manage-audio-session` is on, `setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation`. With it off, as Vivid sets it, no AO ever activates or deactivates the session: not a failed `init` probe, and not an old AO being torn down after its replacement has started. If one did, the next episode in a Next Up chain could start silent.

Upstream, for comparison, always sets category, mode and activation, always sets the preferred channel count, and never declares multichannel content.

#### 3.2.5 `init`

Orderings that must hold:

- With an spdif format and `accept-compressed` off, `init` fails at once with a verbose note, before any session call or allocation.
- A non-spdif `init` clears the passthrough block first (3.2.3).
- The session steps (3.2.4) come before any sink object is created. A refused format (unsupported or blocked) is detected after them, so it has already declared multichannel content and, when managing, set the category and activated.
- An spdif `init` that succeeds creates no PCM object at all: no renderer, synchroniser, format description or notification observer.

The PCM objects are created as upstream does it, with the tvOS bound and its timer (3.3.3) set up after the renderer and synchroniser exist. The compressed sink's objects are listed in 3.4.3.

On any failure `init` releases whatever it created (cancelling timers first, and invalidating the loader before releasing it), runs the conditional deactivation of 3.2.4, and returns an error. On this path the cancelling and invalidating may run on the calling thread or on the AO queue: nothing can be running on the queue yet, so the choice is not observable.

#### 3.2.6 `uninit`

- It first runs the driver's own `reset`, which for the compressed sink tears the item down (3.4.4).
- Compressed sink: the feed timer is cancelled and the loader invalidated, both on the AO queue, before either is released; after invalidation the delegate refuses new requests and forgets pending ones. The player and the queue are then released.
- PCM sink: the bounded timer, if any, is cancelled on the AO queue before release. The renderer, synchroniser, queue and format description are released and the notification observer is removed and released in upstream's order, which releases the renderer before removing the observer.
- Finally, the conditional deactivation of 3.2.4.

### 3.3 PCM path

#### 3.3.1 Common to iOS and tvOS

Unchanged from upstream unless stated:

- Only interleaved formats are used: planar formats are converted with `af_fmt_from_planar`; failure is fatal (`planar audio formats are unsupported`).
- The `AudioStreamBasicDescription` comes from `ca_fill_asbd`, the channel layout from `ca_get_acl`, and the format description from `CMAudioFormatDescriptionCreate`.
- `ao->device_buffer` is 2 s of frames.
- Each feed asks `ao_read_data` for up to 100 ms (`samplerate / 10` frames), blocking and without silence padding. The new buffer's position on the renderer timeline is the later of the last enqueued end and the synchroniser's current time. The end time passed to mpv is now plus (that position minus the synchroniser time) plus the duration of the requested 100 ms. The samples go into a block buffer and a ready sample buffer whose presentation time is that position (nanosecond timescale) and whose per-sample duration is one frame. After enqueueing, the end advances by the frames actually returned. Failing to create either buffer is fatal and requests a reload.
- The last enqueued end starts at 0 when the AO is created. Only the unbounded `start`, the bounded `reset` and a fresh sink set it to −1 ns, so the first lines after `init` print `fed 0.000`.
- On end of file from `ao_read_data`: stop requesting media data and call `ao_stop_streaming` (plus the bounded additions in 3.3.3).
- The synchroniser has the renderer added and, on iOS and tvOS 14.5 and later, `setDelaysRateChangeUntilHasSufficientMediaData:NO`.
- Observers for `AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification` and (iOS and tvOS 15 and later) `AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification`, scoped to the renderer object, trigger a restart: `reset` then `start`. Only the PCM sink has them.
- The driver's `reset`, on the AO queue: stop requesting media data, flush the renderer, set the synchroniser rate to 0. **New:** before that it logs a `trace edge` line with edge `reset` (clock = the synchroniser time; fed = the last enqueued end, which may be −1 ns and print as `-0.000`; latency = `AVAudioSession` `outputLatency`) and opens the detail window. This applies on iOS too.

#### 3.3.2 iOS, and tvOS without a bound

Apart from 3.2.4, the `reset` trace edge and the same-queue check, the PCM sink behaves exactly as upstream on iOS, and on tvOS whenever `max-lookahead` is 0 (Vivid's case on every non-AirPlay route, HDMI included):

- no bound, no timer, no prefetch guard, no fresh sink, no `pcm:` line;
- feeding driven by readiness callbacks (`requestMediaDataWhenReadyOnQueue:usingBlock:` on the AO queue);
- `start` sets the end to −1 and the rate to 1;
- pause and resume set the synchroniser rate to 0 and 1 from the calling thread;
- volume and mute are applied directly;
- no `start`, `pause` or `resume` trace edges.

`audio-buffer` plays no part here.

#### 3.3.3 tvOS with a bound (Vivid: AirPlay, bound 4 s)

Purpose: a short, timer-driven renderer queue (mpv applies volume as samples leave it, so a short queue makes volume changes prompt), and a new renderer for every seek.

**When it applies.** On tvOS only, when `max-lookahead` is above 0 at `init` and the timer could be created.

**Bound.** The larger of `max-lookahead` and mpv's `audio-buffer` option (default 0.2 s); `audio-buffer` can only raise it. "Ahead" means the renderer's last enqueued end minus the synchroniser's current time.

**Feeding.** Readiness callbacks are never used in this mode. A repeating timer on the AO queue (period 50 ms, leeway 5 ms) refills the renderer while feeding is on. Turning feeding on or off always cancels any outstanding readiness request and idles the timer; turning it on then restarts the timer with an immediate first fire. `start` and unpause turn feeding on; pause, `reset`, end of file and renderer failure turn it off.

**One tick** makes at most four 100 ms reads, and stops early as soon as feeding is off, the renderer is not `readyForMoreMediaData`, "ahead" (measured again before every read) is at or above the bound, or a read did not move the enqueued end forward. Before asking mpv for data, each read must also pass the prefetch guard of 3.4.9 with "ahead" as the reserve and one 100 ms request as the planned read. A read that passes is the common feed of 3.3.1.

**Renderer failure.** A tick that finds the renderer's `status` failed logs the warning `pcm renderer failed; requesting audio reload`, turns feeding off and requests a reload, and enqueues nothing.

**Transport line.** A tick with feeding on logs the `pcm:` line (2.9) when at least 2 s have passed since the previous one, or 250 ms inside the detail window. The time of the previous line is mpv's clock origin (`mp_time_ns()` 0, which is the start of the first mpv context in the process) when the AO is created, and goes back to it at a fresh sink, so the first such tick after either logs at once unless the process started less than the interval ago. The fields are the synchroniser time, the last enqueued end, ahead, the synchroniser rate, the renderer `status` (`AVQueuedSampleBufferRenderingStatus` as an integer), `AVAudioSession` `outputLatency`, and `hasSufficientMediaDataForReliablePlaybackStart` as 0 or 1 (tvOS 14.5 and later; −1 otherwise). The line comes before the failure check, so a failed status still appears in it.

**End of file.** In addition to 3.3.1, feeding is turned off. The renderer, synchroniser and enqueued end are kept.

**Transport calls**, all on the AO queue:

| Call | Effect |
| --- | --- |
| `reset` | The common reset of 3.3.1, then enqueued end −1, a fresh sink marked pending, feeding off. |
| `start` | If a fresh sink is pending, replace the renderer and synchroniser first (below); if that fails, do nothing else. Then trace edge `start-fresh` after a replacement or `start` otherwise, synchroniser rate 1, feeding on. A start with no replacement keeps the renderer and the enqueued end: the first after `init`, one after end of file, and one after mpv's queue ran dry while the AO was kept, as when a speed change that crosses 1x rebuilds the decoder on a decoded track (1.7), which therefore logs a plain `start` edge, never `start-fresh`. |
| `set_pause` | While a fresh sink is pending, ignored entirely: no trace edge, no rate change, no feeding change. Otherwise trace edge `pause` or `resume`, synchroniser rate 0 or 1, feeding off or on. Returns true. |
| `control` (volume, mute) | On the AO queue (inline if already there), so it never overlaps a replacement. |

**Fresh sink** (renderer replacement):

- Only a `reset` leads to one; pause and end of file never do. The format description is reused.
- The renderer and the synchroniser are both new objects. If either cannot be created, whichever was created is released, the warning `pcm fresh sink failed; requesting audio reload` is logged, a reload is requested, and the old objects stay installed with the replacement still pending.
- The new renderer starts with the old renderer's `volume` and `muted`.
- The new synchroniser has the new renderer added and delayed rate change turned off (tvOS 14.5 and later).
- Every observer registration for the old renderer is removed before the old objects are released, and the two restart notifications (`OutputConfigurationDidChange` from tvOS 15) are registered for the new renderer.
- Afterwards the enqueued end is −1, the transport-line time is back at mpv's clock origin, the pending mark is cleared, and the verbose line `pcm fresh sink after reset` is logged.

**Restart notifications in this mode**, handled on the AO queue:

1. Log the verbose line `notification name: %s`. If the notification's user info has `AVSampleBufferAudioRendererFlushTimeKey`, also log the verbose line `notification flush time %.3f, current %d` (the time through `CMTimeGetSeconds`, unchanged, so it prints `inf` or `-inf` for an infinite time and `nan` for an invalid or indefinite one, 12.1; current = whether the notification came from the current renderer).
2. Nothing more happens if it came from a renderer other than the current one, or if a fresh sink is pending.
3. Otherwise log trace edge `restart`, then the warning `restarting due to system notification; this will cause desync`, then run `reset` and `start` inline, which continues the log with trace edge `reset`, `pcm fresh sink after reset` and trace edge `start-fresh`.

Outside this mode, upstream's order stays: the warning, then the notification name, then `reset` and `start`.

### 3.4 Compressed passthrough (AC-3 and E-AC-3 through `AVPlayer`)

#### 3.4.1 Acceptance

- Only `AF_FORMAT_S_AC3` and `AF_FORMAT_S_EAC3` are accepted, and only when `accept-compressed` is on and that format is not blocked (3.2.3).
- `init` must leave `ao->samplerate`, `ao->format` and `ao->channels` as mpv opened it. mpv's `reinit_audio_filters_and_output` (in `player/audio.c`) compares them afterwards and treats any change as "Passthrough format unsupported".
- Any other spdif format fails `init` with a fatal line (wording free, 2.9).
- `audio-exclusive` has no effect: the AO never reads `ao->init_flags`.
- The AO does not negotiate or alter the channel map in either sink. The PCM format description follows whatever layout mpv opened it with (upstream).

#### 3.4.2 Per-format parameters

| | AC-3 | E-AC-3 |
| --- | --- | --- |
| IEC 61937 data type (low 7 bits of Pc) | 0x01 | 0x15 |
| Codec rate used for timing | the carrier rate | the carrier rate divided by 4 |
| Burst repetition size | 6144 bytes | 24576 bytes |
| Unit of the Pd value | bits | bytes |
| Uniform type identifier declared to AVFoundation | `public.ac3-audio` | `public.enhanced-ac3-audio` |
| Stream URL path extension | `ac3` | `eac3` |
| Duration credited per accepted burst | 1536 frames at the codec rate (32 ms at 48 kHz) | 1536 frames at the codec rate (32 ms at 48 kHz, about 34.83 ms at 44.1 kHz) |

The divide-by-4 must agree with the carrier rate set in 6.4.

#### 3.4.3 Player, asset and item

**Created at `init`:** one `AVPlayer` (plain initialiser) with `automaticallyWaitsToMinimizeStalling` NO, so that start-up is decided by 3.4.10 alone, and `allowsExternalPlayback` NO, so that AirPlay audio stays on the system route; the loader delegate; the feed timer, idle and resumed; the carry-over buffer and the stream window (3.4.6); `ao->device_buffer` from `compressed-buffer`; initial-start mode on; no pending resume.

**Nothing else is configured.** No other `AVPlayer` property is set. The asset is an `AVURLAsset` with options nil, the item is created from it with AVFoundation's plain initialiser, so the default automatically loaded keys (`duration`) apply (12.1), and the item's only property set is `canUseNetworkResourcesForLiveStreamingWhilePaused` YES. The content-information request gets exactly the three values in 3.4.4. Everything else keeps AVFoundation's default.

**Item creation.** A new asset and item are made on `start` whenever there is no current item: the first start, and every start after a `reset`. Each item's stream begins at byte 0 and time 0; an item is never reused across a reset. The asset's URL uses a custom, non-network scheme, so AVFoundation must ask the delegate for its bytes, and its path ends in the per-format extension; the scheme and host are the implementer's choice, and every item of a format uses the same URL (12.1). The order is: create the asset; attach the delegate on the AO queue; create the item; set its property; make it current with `replaceCurrentItemWithPlayerItem:`. The delegate must be attached before the item exists, so that AVFoundation's first loading request reaches it, and the property is set before the item becomes current, so that it applies from the first load.

**State lifetimes:**

| Lifetime | State | Starting value |
| --- | --- | --- |
| Process | The passthrough block (3.2.3) | clear |
| AO | Initial-start mode | on until the AO's first engagement |
| AO | Fallback requested | no, never cleared once set |
| AO | Heartbeat counter | 0, never reset |
| AO | Detail window | none; every trace edge extends it |
| Item (reset when an item is created or torn down) | Carry-over buffer contents; stream window contents and base offset; fed duration, consumed carrier frames and dropped duration; rate requested; seek attempted; fill watermark; supervision deadline; pending resume | empty; base offset 0; all 0; no; no; 0; none; none |
| Item, also cleared by every `start` | End-of-file state | clear |
| Item, also cleared by pause | Pending resume | none |
| Set when rate 1 is first requested for the item; an unpause never changes it | Rate-1 time | |
| Set at AO creation; reset when rate 1 is first requested for an item and at every later unpause | Anchor pacing time, anchor count | mpv's clock origin (`mp_time_ns()` 0, 3.3.3), 0 |
| Reset only when an item is created | Last logged item status and time-control status | −1 |
| Set by `start` and unpause, cleared by pause and `reset` | Desired playing state | |

The anchor pacing time's starting value is mpv's clock origin itself, the time 0, not a minimum-value sentinel. The 100 ms test of 3.4.11 measures from it, so the first anchor read after it is reset is eligible at once, unless mpv's clock started less than 100 ms earlier.

#### 3.4.4 Resource loader

Delegate behaviour, all on the AO queue. The delegate object also guards its own state with a lock and, once invalidated, refuses every request by returning NO.

- `resourceLoader:shouldWaitForLoadingOfRequestedResource:`: if there is a content-information request, set `contentType` to the per-format uniform type identifier, `contentLength` to `INT32_MAX` (2147483647) and `byteRangeAccessSupported` to NO. Log the request at verbose. A request with a data request is added to the pending list and one feed step (3.4.7) runs at once; any other request is finished at once. Return YES.
- `resourceLoader:didCancelLoadingRequest:`: remove it from the pending list and log it at verbose.

**Serving**, at the end of every feed step, for each pending request in arrival order:

| Request's current offset | Outcome |
| --- | --- |
| Below the window's base offset | Log the error `loader requested offset %lld below the retained window at %lld`, finish the request with `NSPOSIXErrorDomain` code `ESPIPE`, drop it. The item then fails, which leads to fallback (3.4.7). |
| Below the write head | Respond with the bytes from the current offset up to the smaller of the write head and the request's end (unbounded when the request asks for everything to the end of the resource, otherwise the requested offset plus the requested length). |
| Equal to the write head | Wait. |
| Above the write head | **Never answer it with data.** Log it at verbose, finish it with `NSPOSIXErrorDomain` code `ENOTSUP`, drop it. AVFoundation would later play whatever bytes it was given for those offsets. |
| At the requested end of a bounded request | Finish and drop it. |

After the pass, trim the history: the low-water mark is the smaller of the write head and every remaining request's current offset, and bytes more than 2 MiB (2097152 bytes) below it are discarded, moving the base offset up.

**Item teardown** (on `reset`, and so in `uninit`):

- set the player's rate to 0;
- finish every pending request that is neither finished nor cancelled with `NSURLErrorDomain` `NSURLErrorCancelled`, and empty the list; this happens before the next step;
- detach the delegate (`setDelegate:nil queue:nil`), replace the player's current item with nil, release the item and asset;
- return the per-item state to its starting values (3.4.3). Per-AO state and the passthrough block are untouched.

#### 3.4.5 From IEC 61937 to the elementary stream

**Reading from mpv.** Each read asks `ao_read_data` for `samplerate / 10` carrier frames (100 ms), or fewer when the carry-over buffer has less room (no read at all when it has none), after the prefetch guard (3.4.9). Each carrier frame is 4 bytes (two 16-bit channels); the bytes returned join the carry-over buffer and count towards the consumed carrier frames. End of file from `ao_read_data` sets the end-of-file state and calls `ao_stop_streaming`. A read is "successful" only when it returned frames, did not report end of file and did not lead to a fallback.

**Scanning.** Positions in the carry-over buffer are examined in order, but only positions with at least 8 bytes after them; whatever lies in the last 7 bytes (or all of the buffer, if it is shorter) stays for the next read. A position that does not hold the preamble bytes 0x72 0xF8 0x1F 0x4E (Pa 0xF872 and Pb 0x4E1F as little-endian words) is skipped and its byte discarded. At a preamble, these tests run in this order:

1. **Data type** (byte 4 masked with 0x7F) must be the format's (3.4.2). Otherwise log the warning `skipping unexpected IEC 61937 data type 0x%x` and resume the scan one byte after the preamble's first byte.
2. **Payload length** must be at least 8 bytes and at most the burst size minus 8 (both bounds inclusive). The length is Pd (bytes 6 and 7, little-endian) divided by 8 and rounded down for AC-3, and Pd itself for E-AC-3. Otherwise log the warning `skipping burst with invalid payload length %d` (with the length in bytes) and resume one byte on.
3. **Completeness:** the 8-byte preamble plus the payload rounded up to an even length must all be in the buffer. Otherwise stop scanning; the burst, from its preamble on, stays for the next read.

A burst that passes all three goes to the stream window (below), and the scan resumes after its 8 bytes plus its even-rounded payload, whether the payload was accepted or rejected. If a payload causes a fallback, processing of that read stops at once.

**Lost sync.** After the bytes resolved by a read have been removed from the carry-over buffer, if it still holds more than three burst sizes (18432 bytes for AC-3, 73728 for E-AC-3), log the error `no IEC 61937 sync found in %d bytes; falling back to PCM`, empty the buffer and fall back. With the scanning rules above the buffer can never be that full at this point, so this check never fires today. Keep it where it is and keep it unchanged; do not move it before the trim or turn it into a count of scanned bytes. Garbage without preambles is therefore discarded silently: no warning, no fallback and no growth of the fed duration.

**Payload rules**, in this order. A payload gets exactly one outcome, and when it has more than one fault the order decides which, and so which line is logged:

1. An odd length is rejected: log the warning `discarding burst with odd payload length` and add one burst period to the dropped duration.
2. A payload that does not fit in the window's free space: log the error `elementary stream window overflow; falling back to PCM` and fall back. The backpressure rule of 3.4.6 means this cannot happen today; keep it as is.
3. The payload is byte-swapped in 16-bit words (the muxer writes little-endian words; AVFoundation needs the bitstream's own byte order).
4. If the swapped payload does not begin with the AC-3 syncword 0x0B 0x77, it is rejected: log the warning `discarding burst without syncframe` and add one burst period to the dropped duration.
5. Otherwise it is written at the write head; the write head moves on by its length and the fed duration by one burst period.

#### 3.4.6 Buffer sizes and backpressure

- **Carry-over buffer:** 100 ms of carrier bytes plus four burst sizes. For 192 kHz E-AC-3 that is 76800 + 98304 = 175104 bytes; for 176.4 kHz, 168864; for 48 kHz AC-3, 19200 + 24576 = 43776.
- **Stream window:** 2 MiB of history + 1 MiB of slack + 2 × the steady lead × 786432 bytes per second (768 KiB/s, which is E-AC-3's maximum of 6.144 Mb/s), truncated to an integer. With the default 8 s lead: 15728640 bytes.
- **Backpressure:** a read (filling or anchoring) is attempted only when the window's free space is at least the whole carry-over buffer's size.
- **`ao->device_buffer`** for this sink is `compressed-buffer` seconds of carrier frames (2.2). It does not set how far ahead the stream is kept; the lead does.

#### 3.4.7 Feed step

A feed step runs on every feed timer tick (50 ms), on every new loader data request, at the end of `start` and at the end of an unpause. With a fallback already requested, or with no item, it does nothing.

Its parts:

- **Diagnostics:** the status-change line and the heartbeat (3.4.15).
- **Failure detection:** when the item's status is failed or the player has an error, log the error `player rejected the compressed stream: %s (%s:%ld)` (the error's localised description, domain and code, from the item's error when present, otherwise the player's; `unknown`, `-` and 0 when there is none), then the error `falling back to PCM` as a separate line, fall back, and end the step there: nothing else in it runs (no read, anchoring, resume detection, serving or supervision).
- **Filling:** read (3.4.5) until the fed duration is at least the target ahead of the feed position (3.4.8). The target is the steady lead while the feed position is above 0 and twice the steady lead while it is 0. Filling also stops at end of file, when the window's free space is below the carry-over buffer's size, after a read that was not successful, or after 64 reads in one step.
- **Anchoring** (3.4.11): start anchoring, then resume detection, then resume anchoring.
- **Serving** the loader (3.4.4).
- **Supervision** (3.4.10).

These orderings are observable and must be kept:

1. Diagnostics and failure detection come before any read, so a rejected item is never fed again.
2. Anchor reads are considered only after filling has stopped in the same step.
3. A rejection found by failure detection ends the step at once, so resume detection does not run after it and a pending resume stays pending. A fallback requested by a read earlier in the same step (window overflow or lost sync during filling or the start-anchor read, 3.4.5) makes the step skip the remaining anchor reads, serving and supervision, but resume detection still runs: if the clock has moved past the recorded value, the `compressed clock resumed after %.3f s, anchors %d` line is logged and the pending resume ends.
4. Serving comes after the reads of the same step, and supervision comes last.
5. In compressed `start`, the end-of-file state is cleared before anything can read from mpv (3.4.12).
6. In bounded tvOS PCM `start`, the renderer replacement completes before rate 1 and feeding.
7. Observer registrations for a replaced PCM renderer are removed before it is released.
8. Timers are cancelled, and the loader invalidated, on the AO queue before release (on `init`'s error path, either thread, 3.2.5).
9. Item teardown finishes outstanding loader requests before the delegate is detached.
10. In `init`, the `accept-compressed` refusal comes before any session call, and a PCM `init` clears the passthrough block first.

Measured fact behind the 8 s default: with a 2 s lead, tvOS E-AC-3 passthrough had brief dropouts about every 1.8 s; with 8 s it had none.

#### 3.4.8 Clocks and what mpv is told

- **Compressed clock.** With no item, 0. Otherwise the item's `timebase` read with `CMTimebaseGetTime`; if there is no timebase or its time is not numeric, the item's `currentTime`; if that is not numeric either, 0. Converted to nanoseconds and clamped to the range 0 to the fed duration.
- **Feed position** (used only to pace filling and for the prefetch guard): the later of the compressed clock and the item's `currentTime` (when numeric), clamped to 0 to the fed duration. Pacing against the earlier reading leaves too little queued on some HDMI routes.
- **End time given to `ao_read_data`.** mpv takes it as its audio clock, and video follows it. It is now plus (written duration minus compressed clock) plus the duration of the requested read, where the written duration is the consumed carrier frames before this read, converted at the carrier rate, minus the dropped duration. The fed duration must not be used here: it moves in whole burst periods, and video would show those steps.
- **Rounding.** Every conversion from frames to nanoseconds uses CoreMedia's default rounding at a nanosecond timescale. Burst periods are converted to whole nanoseconds once each and then accumulated (fed and dropped durations); the written duration is converted from the total frame count each time. Option values in seconds, and `compressed-buffer` in frames, are truncated.
- Reads never pad with silence and always block on mpv's buffer lock, which is safe because the AO queue never holds that lock.

#### 3.4.9 Prefetch guard (both sinks)

Before any read that would ask mpv for data, the guard skips the read (treating it as "no data this time", without calling `ao_read_data`) when both of these hold:

- the reserve is at least 1 s (compressed sink: the fed duration minus the feed position; bounded PCM: "ahead");
- the number of frames waiting in mpv's AO input queue (upstream's `mp_async_queue_get_samples` applied to the queue that `ao_get_queue` returns) is below the planned read.

Short reads would make mpv pause to rebuffer although audio is still queued downstream. With less than 1 s in reserve, the read goes ahead even if it will come back short. The very first compressed read of an item, with nothing fed yet, is never skipped.

#### 3.4.10 Supervision

Supervision runs at the end of each feed step, and only while the desired state is playing, an item exists and no fallback has been requested. It keeps one deadline per item. Vectors in 9.3.1 pin the exact outcomes.

**Rule precedence.** Each evaluation applies the first row that matches, top to bottom, and nothing after it. The precedence is a requirement: engagement must win over every deadline, and progress after the seek must win over the deadline, so a later row never runs in the same evaluation as an earlier one.

| # | Condition | Outcome |
| --- | --- | --- |
| 1 | Rate 1 not yet requested, and the stream is not primed (fed duration below 1 s and no end of file) | Deadline = now + ordinary grace. |
| 2 | Rate 1 not yet requested, and the stream is primed | Request rate 1 on the player (whether or not the item reports ready). Record the rate-1 time; reset the anchor pacing time to mpv's clock origin (0, 3.4.3) and the anchor count to 0. Deadline = now + initial grace in initial-start mode, otherwise now + ordinary grace. |
| 3 | Deadline already cleared for this item | Nothing. |
| 4 | Compressed clock above 0 | Clear the deadline for good (a later clock of 0 changes nothing); end initial-start mode for this AO; log `compressed clock engaged after %.3f s, seeked %d, anchors %d` (time since the rate-1 time, whether the recovery seek was attempted, anchor reads since rate 1). |
| 5 | Seek attempted, and the fed duration is above the fill watermark and below the start-up lead | Watermark = fed duration; deadline = now + ordinary grace. |
| 6 | Now is before the deadline | Nothing. |
| 7 | Seek not attempted, initial-start mode, the item is not `AVPlayerItemStatusReadyToPlay`, and less than the ordinary grace has passed since the rate-1 time | Nothing. |
| 8 | Seek not attempted | The recovery seek (below). |
| 9 | Otherwise | Log the error `native compressed playback did not start; falling back to PCM` and fall back (3.4.13). |

Here "ordinary grace" is `compressed-start-grace` and "initial grace" is the smaller of `compressed-first-start-grace` and `compressed-start-grace`. The fill watermark starts at 0 for each item and is not changed by the seek. An unpause also moves the deadline (3.4.12).

**The recovery seek** has these effects, as a set: the seek is marked attempted; the deadline becomes now + ordinary grace; the item is sought to `kCMTimeZero` with `seekToTime:completionHandler:` and a nil handler (12.1); rate 1 is requested again. Its log lines come in this order: in initial-start mode only, the verbose `first start recovery after %.3f s` (time since the rate-1 time); then the warning `playback did not engage; seeking to the stream start`.

**No other player or item calls.** Apart from reading the item's status and the clock, supervision requests rate 1 (once at row 2 and again at the seek, so at most two requests per item), makes the one seek, and the fallback sets rate 0. It makes no other call on the player or the item.

**Initial-start mode** is on when the AO is created and ends only at the AO's first engagement. It survives resets, so an item created after a seek that came before the first engagement still uses the initial grace. Items created after that use `compressed-start-grace` throughout.

On AirPlay to HomePod speakers, Vivid's own measurements on Apple TV 4K found that a new item's clock does not move after rate 1 until the recovery seek runs, and then moves about 0.85 s later, while seeks and resumes in the middle of a title move it in about 0.5 to 0.6 s without the seek. That is why Vivid's AirPlay graces are short.

#### 3.4.11 Anchoring mpv's clock to a stationary playhead

Purpose: while `AVPlayer`'s playhead still sits where mpv last heard it was, small extra reads stop mpv's audio clock from advancing on its own (3.4.8), so video holds instead of getting ahead of the sound.

**Start anchoring**, once per feed step after filling: one read when all of these hold:

- `compressed-anchor-start` is on;
- rate 1 has been requested;
- no end of file;
- the compressed clock is exactly 0;
- the fed duration is below the start-up lead plus 4 s;
- at least 100 ms since the last anchor read;
- no fallback requested;
- the window's free space is at least the carry-over buffer's size.

**Resume detection**, once per feed step after start anchoring, while a resume is pending: if the compressed clock is strictly above the value recorded at the unpause, log the verbose line `compressed clock resumed after %.3f s, anchors %d` (time since the unpause, anchor count) and end the pending resume. This does not depend on `compressed-anchor-resume`. It runs even when a read earlier in the same step has requested a fallback, but never after a rejection, which ends the step before it (3.4.7).

**Resume anchoring**, after resume detection: one read when a resume is still pending and all of these hold:

- `compressed-anchor-resume` is on;
- no end of file;
- the compressed clock is at or below the recorded value;
- less than 2 s since the unpause;
- at least 100 ms since the last anchor read;
- no fallback requested;
- the window's free space is at least the carry-over buffer's size.

Both kinds of anchor read share the pacing time and the count. The pacing time is recorded before the read; the count goes up only when the read was successful. Every anchor read still passes through the prefetch guard (3.4.9). A pending resume is recorded only by an unpause after rate 1 was requested, as the compressed clock at that moment (0 is a valid value) and the time. Pause, item creation and teardown clear it.

#### 3.4.12 Start, pause, resume, reset and end of file

All of these run on the AO queue (inline when already there).

| Call | Effect |
| --- | --- |
| `start` | Desired state playing. If end of file had been reached, log the verbose line `resuming compressed feed after audio EOF`. Clear the end-of-file state before anything can read from mpv: mpv calls `start` again, with no reset, when audio arrives after the AO reported end of file. Then, with no item, create one (3.4.3); with an item whose rate 1 was already requested, request rate 1 again (same item, same stream). Log trace edge `start`, arm the feed timer, run one feed step. All of this also happens after a fallback was requested (12.1). |
| `reset` | Log trace edge `reset`, desired state not playing, idle the feed timer, tear the item down (3.4.4). |
| `set_pause(true)` | Desired state not playing; trace edge `pause`; idle the feed timer; player rate 0; clear any pending resume. The item, the window and supervision are kept. Returns true. |
| `set_pause(false)` | Desired state playing; trace edge `resume`. If rate 1 was already requested: request it again; if the deadline is not cleared, deadline = now + ordinary grace (in initial-start mode too); record the pending resume (the compressed clock, read again after the rate-1 request, and the time; 12.1); reset the anchor pacing time to mpv's clock origin and the count to 0. The rate-1 time is not changed. If rate 1 was not yet requested, nothing more (today's engine also sets an item-ready deadline here, omitted under 7.2). Then arm the feed timer and run one feed step. All of this also happens after a fallback was requested (12.1). Returns true. |

**End of file from mpv:** the end-of-file state stops filling and anchoring and counts as primed. The timer keeps running, so loader requests are still served and supervision continues, and `AVPlayer` plays out what was written.

Trace-edge lines in this sink report the compressed clock as `clock` and the fed duration as `fed`.

#### 3.4.13 Fallback to PCM

- Triggers: item failure or player error (3.4.7), window overflow or lost sync (3.4.5, neither reachable today), and supervision row 9 (3.4.10).
- At most once per AO.
- It sets the passthrough block for the current format, sets the player's rate to 0, idles the feed timer and calls `ao_request_reload`. Every later feed step does nothing, so supervision stops; `start` and unpause still act as 3.4.12 says until the reload (12.1).
- mpv's `reload_audio_output` reruns `init`, which fails for the blocked format, and mpv continues with decoded PCM through its existing "Falling back to PCM output" path. 6.2 keeps the audio chain from stalling after that reload.

#### 3.4.14 Volume and mute

In the compressed sink, `control` maps `AOCONTROL_GET_MUTE`, `AOCONTROL_GET_VOLUME`, `AOCONTROL_SET_MUTE` and `AOCONTROL_SET_VOLUME` onto the player's `muted` and `volume` (mpv's value ÷ 100), directly on mpv's thread, not on the AO queue. Other commands are unknown. mpv's `volume` property is software gain and has no effect in passthrough (upstream). In the PCM sink, `ao-volume` and `ao-mute` set the renderer's `volume` and `muted` (upstream), carried across a replacement (3.3.3).

#### 3.4.15 Diagnostics

- **Status changes.** At the start of each feed step, when the item status (`AVPlayerItemStatus` as an integer) or the player's `timeControlStatus` differs from the last logged pair, log the verbose line `item status %d -> %d, time control %d -> %d, pos %.3fs, fed %.3fs` (old and new values, compressed clock, fed duration) and remember the new pair. The first step after item creation logs from −1.
- **Heartbeat.** The AO's heartbeat counter goes up on every feed step that runs, of any kind (timer ticks, loader-triggered steps, the steps at the end of `start` and unpause), and is never reset. A step that does nothing because a fallback was already requested or there is no item (3.4.7) does not count. The heartbeat line is logged when the counter is a multiple of 100, or of 5 inside the detail window. Fields: raw position = the item's `currentTime` in seconds, or −1.000 when not numeric; clamped = the compressed clock; fed duration; item status; time-control status; reader gap = the smallest distance from the write head back to the current offset of a pending data request at or behind the write head, or −1 if there is none.
- **Trace edges.** Every edge sets the detail window to end 8 s later. `latency` is `AVAudioSession` `outputLatency`.

### 3.5 Threading

- mpv's core thread calls `init`, `uninit`, `control`, `reset`, `start` and `set_pause`, outside mpv's AO buffer lock for pull drivers. The AO queue runs feed steps, the loader delegate, PCM readiness callbacks and timers. Renderer notifications arrive on whatever thread posts them.
- Compressed sink: all state except volume and mute lives on the AO queue, and `ao_read_data` is called only from there.
- PCM on iOS and unbounded tvOS: upstream's threading.
- Bounded PCM on tvOS: every state change, tick, notification and control runs on the AO queue.
- Anything that can be reached while already on the AO queue runs inline.
- Teardown: timers cancelled on the queue before release; the loader invalidated on the queue before release; for a fresh sink, observers removed before the old renderer is released (`uninit` keeps upstream's order, 3.2.6).

### 3.6 Where the audio behaviour came from

These behaviours came from Vivid's old audio-driver patch (blurbery) rather than the third-party series. They are in today's shipped binaries, and that patch cannot apply to pristine mpv or to Vivid's series, so **the new AO must carry every one of them, with their options, log lines and binary markers. None of them is optional**:

- the end-of-file restart in the compressed sink and its log line (3.4.12);
- `manage-audio-session` and the session rules when it is off (3.2.4);
- `compressed-start-grace`, `compressed-first-start-grace` with the readiness hold and initial-start mode (3.4.10), and `compressed-buffer` (2.2, 3.4.6);
- both anchoring options, resume detection and its log line (3.4.11);
- the recovery seek no longer postponed by progress, with slow-source extensions only after it (3.4.10);
- the prefetch guard in both sinks (3.4.9);
- the bounded tvOS PCM mode (3.3.3);
- the trace edges, the detail window, the faster heartbeat, the engagement and initial-start lines and the PCM transport line.

## 4. Video output

The VO is new: pristine mpv 0.41.0 has no `avfoundation` video output. It puts decoded frames, hardware or software, on the host layer as timed sample buffers, owns that layer's timebase, and draws subtitles either on its own sibling layer or, during Picture in Picture on iOS, into the frames. It never scales, tone-maps or re-renders the picture apart from the Picture in Picture subtitle composite.

### 4.1 Accepted image formats (`query_format`)

Accept exactly these and refuse every other, so that upstream's automatic conversion handles the rest:

- `IMGFMT_VIDEOTOOLBOX`;
- `IMGFMT_NV12`;
- `IMGFMT_420P`;
- `IMGFMT_P010`;
- the two formats mpv maps from `AV_PIX_FMT_YUV420P10` and `AV_PIX_FMT_YUV420P12` through upstream `pixfmt2imgfmt` (upstream has no named constant for them).

This set decides whether mpv inserts a converter, and therefore what `video-out-params` reports to the bridge for Match Content. Keep it exactly. `IMGFMT_VIDEOTOOLBOX` is accepted whatever CoreVideo pixel format the buffer holds (8-bit or 10-bit, 4:2:0, 4:2:2 or 4:4:4).

### 4.2 Hardware (VideoToolbox) frames

- As upstream does, the decoded `CVPixelBufferRef` sits in plane 3 of the `mp_image`. The VO enqueues that same buffer, with no copy and no conversion.
- The buffer keeps whatever colour attachments VideoToolbox and FFmpeg gave it (primaries, transfer, matrix, colour space, mastering display, content light level, chroma siting, clean aperture). **The VO must not tag hardware buffers from mpv's parameters**: Dolby Vision profile 5 in particular must keep primaries and matrix unset.
- Before enqueueing, the VO changes the decoder's buffer in at most three ways: the pixel-aspect attachment (4.5); a missing transfer function on Dolby Vision frames (4.4); and, while Picture in Picture compositing is on and a subtitle is showing, the subtitle composite (4.14.7 and 7.3).

### 4.3 Software frames: upload and colour tags

Software frames occur in the simulators (Vivid sets `hwdec=no` there), after a software fallback on a device, and for embedded cover art (4.16.1).

**Destination format.** Every software frame is copied into a biplanar CoreVideo buffer:

| mpv format | CoreVideo format |
| --- | --- |
| `IMGFMT_NV12`, `IMGFMT_420P` | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (`420v`) |
| `IMGFMT_P010`, 10-bit planar 4:2:0, 12-bit planar 4:2:0 | `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`x420`) |

The video-range codes are used even for full-range sources. Keep this (hazard V14).

**Upload pool.**

- One `CVPixelBufferPool` for uploads, keyed on width, height and format, sized to the image's `w` and `h`. When any of the three changes, the old pool's excess buffers are flushed and a new pool replaces it.
- Pool attributes: minimum buffer count 3, maximum buffer age 1.0 s.
- Buffer attributes: the pixel format, width and height, `kCVPixelBufferMetalCompatibilityKey` true, and an empty `kCVPixelBufferIOSurfacePropertiesKey` dictionary (so buffers are IOSurface-backed).
- Every pool the VO creates (upload, subtitle, composite output) uses these attributes.

**Copy rules.** Chroma dimensions are half the luma dimensions, rounded up.

- 8-bit planar 4:2:0: luma copied row by row, `w` bytes per row, or as one block when source and destination strides are equal. Each chroma output row interleaves the U and V rows sample by sample, U first, for ceil(w/2) samples over ceil(h/2) rows.
- 10-bit planar 4:2:0: every 16-bit sample (luma, U and V) is shifted left by 6 bits, so the 10 significant bits sit at the top of the word; chroma is interleaved as above.
- 12-bit planar 4:2:0: as 10-bit, but shifted left by 4 bits, so the 2 extra low bits stay in the word.
- NV12 and P010: each destination plane is copied row by row for the destination plane's height, each row copying the smaller of the two strides in bytes, or the whole plane as one block when the strides are equal. Missing source planes are skipped.

**Failures** (an unsupported format, pool creation failure, no buffer from the pool) log at error level and skip the frame: nothing is enqueued for that flip and the drop counter does not change.

**Colour tags.** After the upload, from the held image's own `mp_image_params` (per frame, not `vo->params`):

| mpv value | Attachment set |
| --- | --- |
| Primaries BT.709 | `kCVImageBufferColorPrimariesKey` = `kCVImageBufferColorPrimaries_ITU_R_709_2` |
| Primaries BT.2020 | `kCVImageBufferColorPrimariesKey` = `kCVImageBufferColorPrimaries_ITU_R_2020` |
| Transfer sRGB | `kCVImageBufferTransferFunctionKey` = `kCVImageBufferTransferFunction_sRGB` |
| Transfer BT.1886 | `kCVImageBufferTransferFunctionKey` = `kCVImageBufferTransferFunction_ITU_R_709_2` |
| Transfer PQ | `kCVImageBufferTransferFunctionKey` = `kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ` |
| Transfer HLG | `kCVImageBufferTransferFunctionKey` = `kCVImageBufferTransferFunction_ITU_R_2100_HLG` |
| Colour system BT.601 | `kCVImageBufferYCbCrMatrixKey` = `kCVImageBufferYCbCrMatrix_ITU_R_601_4` |
| Colour system BT.709 | `kCVImageBufferYCbCrMatrixKey` = `kCVImageBufferYCbCrMatrix_ITU_R_709_2` |
| Colour system BT.2020 non-constant, BT.2020 constant, BT.2100 PQ, BT.2100 HLG | `kCVImageBufferYCbCrMatrixKey` = `kCVImageBufferYCbCrMatrix_ITU_R_2020` |
| Any other primaries, transfer or colour system | nothing for that key |

- All attachments use `kCVAttachmentMode_ShouldPropagate`.
- If at least one of the three was set, a colour space made from the buffer's propagatable attachments with `CVImageBufferCreateColorSpaceFromAttachments` is attached as `kCVImageBufferCGColorSpaceKey`, when that succeeds.
- The VO only adds tags; it never removes one it cannot map.
- No mastering display, content light level or chroma siting metadata is added: a software-decoded HDR10 frame carries only primaries, transfer, matrix and colour space.

### 4.4 Dolby Vision transfer repair

**Detection key (cross-component contract).** A pixel buffer is a Dolby Vision passthrough frame when it carries a CoreVideo attachment whose key is the string `DolbyVisionRPUData`. That attachment is VideoToolbox's own: no public constant names it and nothing in the engine creates it. It appears on frames from the native Dolby Vision HEVC sessions that section 5 sets up. The string must match exactly.

**Repair.** For hardware frames whose buffer is the decoder's own (including one composited in place) or a YUV composite copy made under 7.3, never for the Core Image composite output. All three must hold:

1. the held image's own parameters (per frame) give the colour system as Dolby Vision (`PL_COLOR_SYSTEM_DOLBYVISION`, which upstream mpv sets from the frame's Dolby Vision metadata);
2. the buffer carries `DolbyVisionRPUData`;
3. the buffer has no `kCVImageBufferTransferFunctionKey`.

Then set the transfer function from the image's transfer value with the table in 4.3 (PQ for Dolby Vision), or nothing if the value has no mapping. Primaries and matrix are never touched here. The repair comes after the pixel-aspect step and before the format description is chosen. In practice it is the only PQ tag profile 5 frames keep, since FFmpeg's attachment step removes the transfer VideoToolbox gave them when their VUI leaves it unspecified (5.7, 12.4).

### 4.5 Pixel aspect

For the buffer about to be enqueued, after any composite, using `vo->params`:

- when `vo->params` is absent, the buffer is left as it is;
- **attach** `kCVImageBufferPixelAspectRatioKey` when the buffer's width and height equal `vo->params` `w` and `h`, `p_w` and `p_h` are both positive, and they differ. The value is a dictionary with `kCVImageBufferPixelAspectRatioHorizontalSpacingKey` = `p_w` and `kCVImageBufferPixelAspectRatioVerticalSpacingKey` = `p_h`, propagatable;
- **otherwise remove** that attachment.

Without the attachment the layer shows non-square pixels as square. Removing it elsewhere stops a pool buffer from keeping an earlier frame's value.

### 4.6 Format descriptions and sample buffers

- **Video format description.** One cached `CMVideoFormatDescriptionRef`, reused while `CMVideoFormatDescriptionMatchesImageBuffer` is true for the buffer and otherwise replaced by a new one from `CMVideoFormatDescriptionCreateForImageBuffer`. The description therefore follows the buffer's size, format and attachments. No codec-specific extensions are added (no `dvcC`, `dvvC` or `hvcC`). If creation fails, log an error and skip the frame.
- **Video sample.** Created with `CMSampleBufferCreateReadyWithImageBuffer`. The presentation time is in nanoseconds (timescale 1,000,000,000), chosen per presentation mode (4.8). Duration and decode time are invalid. No sample attachments are set. If creation fails, log an error and skip the frame.
- **Subtitle buffers and samples** carry no attachments of any kind (no colour space, primaries, transfer, matrix or pixel aspect), on the buffer or the sample. A subtitle sample gets a new format description every time (not cached), and its presentation time equals that flip's video sample time.

### 4.7 Use of the sample buffer renderer

- Every renderer operation goes through the layer's `sampleBufferRenderer` (`AVSampleBufferVideoRenderer`, iOS and tvOS 17 and later): `enqueueSampleBuffer:`, `isReadyForMoreMediaData`, `status`, `requiresFlushToResumeDecoding`, `flush`, and `flushWithRemovalOfDisplayedImage:YES completionHandler:nil`.
- Enqueues, readiness polls, the reset and teardown flushes, and the subtitle-layer flushes for a consumed resize and a composite-mode change run on the VO thread. Recovery flushes and the status reads made during recovery run on main (4.11). `controlTimebase` is assigned and cleared on main.
- Below iOS 17 and tvOS 17 the VO is not supported (7.2).

### 4.8 Presentation clock

**One timebase per VO.**

- Created at VO creation with `CMTimebaseCreateWithSourceClock` on `CMClockGetHostTimeClock()`. If creation fails, log an error, drop the host layer reference and fail creation.
- The same timebase is the host layer's `controlTimebase` (set at creation, on main, synchronously) and the subtitle layer's (set when it is created). At teardown it is cleared from both (on main, synchronously) and released.
- The mode is read from `avfoundation-presentation` once, when the VO is created.
- **Reading the timebase.** A timebase time is converted to nanoseconds with `CMTimeConvertScale` at a nanosecond timescale and `kCMTimeRoundingMethod_Default`; a time that is not numeric reads as 0.

#### 4.8.1 Host mode (tvOS)

- At creation and at every reset (4.13), the timebase time is set to the current host time (`mp_time_ns()` as a nanosecond CMTime) and its rate to 1.0. From then on the timebase reads the same value as `mp_time_ns()`.
- Each sample's presentation time is the frame's target display time (`vo_frame.pts`) if positive, otherwise the host time at `draw_frame`. Redraws arrive with `pts` 0 and so present at once.
- No anchoring, no rate changes after the reset. `VOCTRL_PAUSE` and `VOCTRL_RESUME` are ignored, so frames already handed over (up to the queue lead, 128 ms) still show after a pause.

#### 4.8.2 Media mode (iOS)

- At creation and at every reset, the timebase time is set to 0 and its rate to 0.
- Each sample's presentation time is the frame's media time in nanoseconds, when `pts` is valid (not `MP_NOPTS_VALUE` and finite): `pts` × 1,000,000,000 plus 0.5 (minus 0.5 when `pts` is negative), evaluated in double precision as one fused multiply-add, rounded once, and then truncated towards zero. A finite value outside the int64 range is still valid and saturates to the int64 limits (12.2). Otherwise the best earlier media time: the last media time the VO anchored or followed; else the timebase's current time; else 0.
- Media mode exists for Picture in Picture, which reads the layer's timebase; Vivid's source there reports a range of 0 to the duration in seconds.

**Anchoring** is `CMTimebaseSetRateAndAnchorTime` with the rate, the frame's media time, and a source time equal to the timebase source clock's current time plus (target host time minus `mp_time_ns()` now), where that `mp_time_ns()` reading is taken straight after the source clock is read (12.2). The source clock's time comes from `CMTimebaseCopySource` and `CMSyncGetTime`, or from the host time clock with `CMClockGetTime` if that is not numeric. If the call fails, log a warning.

**Per enqueued frame**, after the readiness wait succeeds and before the samples go to the layers, the VO either anchors or adjusts the rate. Frames without a valid media time leave the timebase alone.

*Nominal rate.* The VO keeps a nominal playback rate, reading any value of 0 or below as 1.0. It changes only when an anchor stores the rate it used, or when the frame carries a rate estimate (4.8.3) that differs from the nominal rate by more than 1% of it while playback is not paused; the estimate then becomes the nominal rate and the frame anchors.

*Anchor or slew.* The frame anchors when any of these holds: no valid anchor exists (after creation, a reset, a recovery or a resume); playback is paused or the timebase is marked paused (the anchor rate is then 0); the nominal rate has just changed; or the phase error is above 50 ms in either direction (logged at verbose in milliseconds; the nominal rate stays). Otherwise it slews.

*State after an anchor:*

- the servo starts over: integral 0, no previous evaluation time, last rate write = now;
- the remembered nominal rate and the applied rate both equal the anchor rate (so an anchor while paused stores 0, which later reads as 1.0);
- the anchor is valid, and the timebase's paused mark equals playback's paused state;
- the anchor counts towards the pacing summary.

*Phase error.* With *A* the rate currently applied to the timebase (the nominal rate if none is recorded): *e* = frame media time − (timebase time now + projection), where the projection is (target host time − now) × *A*, computed in double precision and truncated towards zero to whole nanoseconds before it is added. Positive *e* means the timebase is behind. The largest |*e*| is kept for the pacing summary, sampled only on the frames that reach this decision: a valid anchor, neither playback nor the timebase marked paused, and no nominal-rate change on that frame. A frame whose |*e*| is above 50 ms after a valid anchor is still sampled, before it re-anchors (4.18, 13.1).

*Slewing.* With horizon *H* = 2 s, integral time *Ti* = 8 s and limit *L* = 0.015:

- *P* = clamp(*e* ÷ *H*, −*L*, +*L*);
- the integral gains *P* × Δ ÷ *Ti* (Δ and *Ti* in nanoseconds, multiplied before dividing, 12.2) and is clamped to ±*L*, where Δ is the host-clock interval back to the previous evaluation, only when 0 < Δ ≤ 500 ms (the first evaluation after an anchor adds nothing);
- *R* = nominal × (1 + clamp(*P* + integral, −*L*, +*L*)).

*Rate writes.* `CMTimebaseSetRate` with *R* only when |*R* − *A*| > 0.0001 × nominal and at least 200 ms have passed since the last rate write or anchor; *R* then becomes the applied rate and counts as a rate update. Otherwise the rate stays, though the integral has been updated.

In every case, the frame's media time becomes the last media time.

**Pause** (`VOCTRL_PAUSE`, media mode only): playback is marked paused; the timebase is anchored at rate 0 at its own current time with source time "now" (if the timebase time is not numeric: the held frame's media time when valid, otherwise the VO's last media time, otherwise 0), with a warning if that fails; the applied rate becomes 0 and the timebase is marked paused.

**Resume** (`VOCTRL_RESUME`, media mode only): playback and the timebase are marked not paused and the anchor becomes invalid, so the next frame anchors at the nominal rate.

#### 4.8.3 Estimating the playback rate

The estimator divides how far media time advanced by how long mpv says those frames last at the current speed. It runs in `draw_frame` in both modes; only media mode uses the result.

**Inputs per frame with a valid media time:** the media time *m* in nanoseconds; a duration *d*, which is `ideal_frame_duration` × 10⁹ truncated towards zero when the frame is display-synced and `ideal_frame_duration` is positive (a result of 0 is then an unusable duration, 12.2), otherwise `vo_frame.duration` rounded to the nearest nanosecond with ties to even when positive, otherwise 0; and the nominal rate *n* (1.0 if 0 or below).

**State:** the previous sample (*m₀*, *d₀*), a fast window (media and duration sums, and a count), and an averaging window (media and duration sums). Let Δ = *m* − *m₀* and *r* = Δ ÷ *d₀*.

**Outcome by input class.** The classes are tested in the order given, and the first that applies decides; a zero step must leave the stored sample untouched, and a discontinuity must clear the windows before any ratio is used.

| Class | Condition | Previous sample | Windows | Estimate |
| --- | --- | --- | --- | --- |
| Unusable duration | *d* ≤ 0 | unchanged | unchanged | none |
| First sample | no previous sample | becomes this frame | unchanged | none |
| No media step | Δ = 0 | unchanged | unchanged | none |
| Discontinuity | Δ < 0; or \|*d* − *d₀*\| > max(250 µs, \|*d₀*\| div 100) with integer division; or *r* outside 0.05 to 8.0 | becomes this frame | both emptied | none |
| Near nominal | \|*r* − *n*\| ≤ 4% of *n* | becomes this frame | fast emptied; averaging gains (Δ, *d₀*) | when the averaging duration sum reaches 500 ms: averaging media sum ÷ duration sum, and only the averaging window is emptied |
| Far from nominal | \|*r* − *n*\| > 4% of *n* | becomes this frame | if the fast window already holds samples whose ratio differs from *r* by more than 4% of the window's own ratio (12.2), it is emptied first; then the fast window gains (Δ, *d₀*) | if the fast window now holds 2 or more samples: fast media sum ÷ fast duration sum, and both windows are emptied. Otherwise the averaging window also gains (Δ, *d₀*) and may complete as in the row above |

Any estimate outside 0.05 to 8.0 counts as none. Every reset (4.13) clears the estimator completely, previous sample included.

**An estimate belongs to its frame.** It is used only if that frame reaches the timebase step above with playback not paused. If the frame is dropped or skipped, or playback is paused, the estimate is discarded at the next `draw_frame` and never carried forward.

### 4.9 Per-frame sequence

Upstream background, unchanged: without display sync (Vivid keeps mpv's default `video-sync=audio`), the core calls `draw_frame` when it takes a new frame, waits until the frame's target time minus the queue lead, then calls `flip_page`. Repeat frames are not sent in this mode. The core may drop late frames before `draw_frame`. Redraws call `draw_frame` and then `flip_page` at once, with `pts` 0, `duration` −1, `repeat` false and `redraw` true, except that a redraw arrives with `redraw` false when the previous frame was dropped; the VO treats both alike.

**`draw_frame`** releases any image held from before. If the frame has no current image, or is a repeat that is not a redraw, it holds nothing, sets the target time to now, marks the media time invalid and the estimate absent, and succeeds. Otherwise it holds a new reference to the current image (failing if that fails); takes the media time from the image's `pts`, or the frame's current image `pts` if the image has none; takes the target host time from `vo_frame.pts` if positive, otherwise now; and runs the estimator.

**`flip_page`.** These orderings are required:

1. A pending presentation resync (4.12) runs its forced recovery (4.11) before anything is enqueued.
2. With an image held, subtitles are rendered for that image (4.14.4) before the video sample is built, and the subtitle sample (if one is due on the separate layer) is enqueued immediately before the video sample, with the same presentation time, which keeps every cue on its own frame.
3. The video sample is built as: upload or pass-through; the Picture in Picture composite if it applies; pixel aspect; Dolby Vision repair; format description; sample.
4. The readiness wait (4.10) comes before the timebase step (media mode, 4.8.2), which comes before the enqueues. On a drop nothing is enqueued and the timebase is not touched.
5. If the subtitle layer's renderer is not ready, the subtitle sample is dropped (verbose line, counted for statistics) and the video sample is still enqueued. If a subtitle sample was due but not enqueued, change tracking is reset so the next frame renders again; the pending mark stays. This holds whatever the reason, including a video sample that could not be built and a deadline drop (12.2).

Also in every `flip_page`, in any order: the pacing summary is updated (4.18); every 60th call (whether or not an image was held) flushes excess buffers (`kCVPixelBufferPoolFlushExcessBuffers`) in the composite output, subtitle and upload pools and forgets dirty-tracking entries idle for more than 2 s (4.14.5); the subtitle performance summary is emitted when due; the samples and the held image are released.

### 4.10 Readiness wait, drops and high speed

**Before enqueueing:**

- If the host layer's renderer needs recovery (`status` failed, or `requiresFlushToResumeDecoding`), run a throttled recovery with the reason "layer recovery request".
- If the renderer is ready, the not-ready run is cleared and the frame proceeds.
- Otherwise the frame may wait until 4 ms before its target host time. If that moment is now or already past, the frame is dropped (verbose line with the remaining milliseconds). Otherwise the VO polls every 1 ms (the order of the checks in each round, and where the sleep falls, are in 12.2) until the renderer is ready (proceed, and record the wait for the pacing summary), the moment arrives (drop), or the renderer needs recovery (run a throttled recovery with the reason "not-ready wait"; if the renderer still needs recovery afterwards, whether the recovery ran or the throttle suppressed it, drop; otherwise keep polling). A redraw's target is now, so a redraw with the renderer not ready is dropped at once.

**A drop** adds exactly 1 to mpv's VO drop count (`vo_increment_drop_count`), counts in the pacing summary and in the not-ready run, and enqueues nothing (neither subtitle nor video sample).

**Not-ready run.** A drop more than 500 ms after the previous drop restarts the run at 0 before adding 1. On every drop at which the run is 3 or more, and either nothing has been enqueued yet or the last video enqueue was at least 500 ms ago, a throttled recovery with the reason "repeated not-ready drops" is attempted. The run goes back to 0 in four ways: a recovery that actually runs (one suppressed by the throttle does not); a ready renderer; a drop more than 500 ms after the previous drop, which then counts as 1; and `VOCTRL_RESET` (4.13).

**Speed changes and high speed.** Host mode needs nothing special. In media mode, when a new speed is adopted follows from the table in 4.8.3 and the 1% rule of 4.8.2:

- a change of more than 4% is adopted on the third frame at the new frame duration when that duration is under 500 ms: the first of those frames is a discontinuity, and the next two fill the fast window. At 500 ms or more it is adopted on the second frame (12.2);
- a change of more than 1% and at most 4% is adopted when an averaging window of 500 ms of frame duration completes. For example, with frames under 500 ms, that takes about 520 to 580 ms of frame time when the change in frame duration restarts the window, and about 710 ms at 59.94 fps for changes of 1.1% to 1.5%, whose duration step stays inside the 250 µs gate, so the window does not restart. A frame of 500 ms or more completes the window on its own, so such a change is adopted on the second frame (12.2);
- a change of less than 1% is never adopted: the nominal rate stays, and the servo slews to absorb it. At exactly 1%, rounding in the estimate decides.

Until a change is adopted, the old rate stays applied, so after a slow-down to less than about half the old speed each widely spaced frame can be more than 50 ms out and re-anchor at the old rate; such a change can take three anchors in all.

Ratios and estimates are accepted from 0.05 to 8.0 inclusive, so a speed at either end is tracked only as far as its ratios round inside that range: at exactly 0.05×, the ratios that round below 0.05 are rejected. Above 8× the nominal rate stays, and the servo re-anchors whenever the error exceeds 50 ms.

### 4.11 Display layer recovery

- **Throttle.** Unless forced, at most once per 500 ms, measured from the previous recovery. `VOCTRL_RESET` lifts the throttle.
- **On main, synchronously:** read the host renderer's status, `requiresFlushToResumeDecoding` and readiness and the timebase's time and rate; flush the host layer's renderer **without** removing its displayed image; flush the subtitle layer's renderer the same way.
- **Log** a warning with the reason, the status, both flags, the media time, the timebase time and the rate (wording free).
- **Afterwards:** the not-ready run, the last drop time and the last enqueue time are reset; the anchor becomes invalid (media mode re-anchors on the next frame); the timebase's paused mark follows playback; subtitle change tracking and the pending subtitle mark are reset, so a showing subtitle is rendered and enqueued again on the next frame. Nothing else of the subtitle cache is cleared.
- **Triggers:** forced, for a pending resync after the app becomes active (4.12); throttled, for renderer failure or `requiresFlushToResumeDecoding` seen before or during the readiness wait; throttled, for a run of not-ready drops (4.10).

### 4.12 App-active resync

- **Registration**, at creation, on main and synchronously: two block observers on the default notification centre, object nil, delivered on the main operation queue. `UIApplicationWillResignActiveNotification` marks presentation as suspended; `UIApplicationDidBecomeActiveNotification`, if suspended, clears the mark, sets a pending-resync flag atomically and calls `vo_wakeup`.
- **Consumption.** Whichever comes first, the next `VOCTRL_CHECK_EVENTS` or the next `flip_page`, consumes the flag and runs a forced recovery with the reason "presentation resume".
- Becoming inactive pauses the layer's presentation without raising `requiresFlushToResumeDecoding`.
- **Removal.** Both observers are removed at teardown, on main and synchronously, before any VO state is freed.
- This applies to every VO, including one created for an audio-only title's cover art (4.16.1), whenever the app resigns and regains active state without the VO being destroyed (Control Centre, banners, alerts, app-switcher peeks). The bridge's own activation handling (2.5) is in addition.

### 4.13 Seek, reset and redraw

**`VOCTRL_RESET`** (upstream's `vo_seek_reset`, at each seek and at track changes and stops):

- Subtitle state is cleared: the cache (4.14.4) is cleared, the bounding box emptied, and an asynchronous flush with removal of the subtitle layer is queued on main.
- The not-ready run, the last drop time, the last recovery time (lifting the throttle) and the last enqueue time are cleared.
- Media timing is reset: next and last media times cleared, the anchor invalid, the servo (integral, evaluation time, last rate write) and the estimator reset; the nominal rate kept (1.0 if not positive); the applied rate set to the nominal rate; playback's paused state kept and the timebase's paused mark set to match.
- The host layer's renderer is flushed **without** removing its displayed image and the subtitle layer's renderer **with** removal, both on the VO thread.
- The timebase is reseeded: host mode, time = now (`mp_time_ns()`) and rate 1.0; media mode, time 0 and rate 0.

All the state changes above happen before the two flushes and the reseed. Outcomes: the old picture stays until a frame from after the seek is shown, so a seek never goes black; subtitles vanish at the reset; in media mode the first new frame anchors, at rate 0 when paused, so a paused seek and the bridge's paused redraw (`seek 0 relative+exact`) show and hold the new frame.

**`VOCTRL_REDRAW`:** change tracking is reset so subtitles are rendered again. Upstream then calls `draw_frame` and `flip_page` with a redraw frame, which enqueues the current image again: in host mode at the current host time; in media mode at the image's media time (paused: an anchor at rate 0).

### 4.14 Subtitles

Vivid sets `osd-level=0`, so in practice the OSD carries subtitles only: the primary subtitle and, when the viewer selects one, the secondary subtitle.

#### 4.14.1 Modes

| Mode | Condition | Where subtitles go |
| --- | --- | --- |
| Separate layer | `avfoundation-pip-composite-osd=no` | Timed BGRA samples on the subtitle layer, laid out in display space (host layer pixels). Every platform, default. |
| Frame-space composite | `avfoundation-pip-composite-osd=yes` | Burned into the video samples, laid out on the frame's own pixel grid. iOS while Picture in Picture is starting or active. |

While compositing, the subtitle layer stays in the tree; it is flushed with removal when the mode switches, so it shows nothing.

#### 4.14.2 The subtitle layer

**Creation**, at VO creation, on main and synchronously. A plain `AVSampleBufferDisplayLayer` with `backgroundColor` nil, `opaque` NO, `videoGravity` `AVLayerVideoGravityResize`, `anchorPoint` (0.5, 0.5), `controlTimebase` = the VO's timebase, `contentsScale` = the host layer's if positive (otherwise the main screen's `scale`) and `frame` = the host layer's `frame`. If the host layer has a superlayer, the subtitle layer is added to it with `addSublayer:` (so above the existing siblings) and then given the host layer's `zPosition` + 1. Otherwise it is added inside the host layer, its `frame` set to the host layer's `bounds`, and a warning logged. No `CATransaction` wraps creation; all properties are set before insertion except `zPosition` (sibling case) and `frame` (nested case).

**Sync** runs at reconfiguration, at an option change (4.14.9), at `VOCTRL_SET_PANSCAN` and at a real host resize while subtitles are on the separate layer:

1. On the VO thread: re-read the host geometry synchronously on main (2.5) and mark the canvas geometry invalid.
2. Only if subtitles are on the separate layer: queue an **asynchronous** block on main that, inside one `CATransaction` with actions disabled, sets the subtitle layer's `frame` (to the host layer's `bounds` if nested, otherwise to the host layer's `frame`, and then its `zPosition` to the host's + 1), copies `contentsScale` (the main screen's `scale` if the host's is not positive) and sets `videoGravity` to resize.

**Teardown.** Flushed with removal, `controlTimebase` cleared, removed from its superlayer on main synchronously, and released (4.16.5).

#### 4.14.3 Subtitle canvas and geometry

The canvas is the pixel grid subtitles are drawn into.

- **Caching.** The canvas geometry is invalid at creation and after every subtitle-layer sync, and otherwise cached. The first `flip_page` that holds an image after it became invalid recomputes it, and before doing so re-reads the host geometry with a synchronous hop to main (updating `dwidth`, `dheight` and `monitor_par`). This happens in both modes, before any of the rendering skip checks below, and whether or not a subtitle track is selected.
- **Separate layer.** Upstream `vo_get_src_dst_rects` with the host layer's pixel size as `dwidth` × `dheight` and `monitor_par` 1.0. The canvas is that OSD resolution: the layer's pixels, mpv's letterbox bars as margins, and mpv's `display_par`. mpv's letterbox always assumes an aspect fit inside the layer (plus `panscan`, alignment, margins and crop), whatever `videoGravity` the host chose, so with `fill` or `stretch` subtitles are still placed against the aspect-fit rectangle.
- **Frame space.** The canvas is the held image's pixel grid (or `vo->params` `w` and `h` if there is no image). Source and destination rectangles are both the whole frame, all margins 0, and `display_par` is `p_h ÷ p_w` from `vo->params` (1.0 if either is missing), as upstream's `osd_res_from_image_params` computes it. A frame size that is not positive gives an empty geometry. With no margins, `sub-pos` is measured against the frame.
- **Canvas change.** When the OSD resolution differs from the one used for the previous render (upstream `osd_res_equals`), change tracking is reset so subtitles render again.

#### 4.14.4 Rendering on each frame

For every held image, redraws included, on the VO thread inside `flip_page` (4.9). Skipped with no state change if mpv has no OSD state, if subtitles are on the separate layer but no subtitle layer exists, or if the canvas geometry is empty.

1. Ask upstream for the frame's subtitle bitmaps with `osd_render`, passing the OSD state, the canvas resolution, the image's media time in seconds (as mpv gave it, which may be `MP_NOPTS_VALUE`), draw flags 0, and the accepted formats `SUBBITMAP_LIBASS` and `SUBBITMAP_BGRA` only. It returns every OSD object that has content, in mpv's object order (primary subtitle, secondary subtitle, then OSD and external objects). Keep that list until drawing and the bounding box (4.14.5) are finished, then free it. `osd_draw` must not be used: the skip check in step 4 needs every object's `render_index` and `change_id` before anything is drawn, but `osd_draw` frees its list as soon as its callbacks return, so objects kept from its callbacks would be used after they are freed, and drawing inside each callback cannot skip the whole set.
2. **All objects are drawn, into one canvas, in that order**, later objects painted over earlier ones (deliberate difference 3, 7.3). When exactly one object has content, the result must be identical to drawing that object alone.
3. **Nothing to draw.** If the call produced no object and a subtitle is cached: drop the cached image and buffer, mark no subtitle present, reset change tracking and, on the separate layer, mark a transparent subtitle sample as pending.
4. **Skip check.** Rendering is skipped when the objects are the same as last rendered, position by position, by `render_index`, each with the same `change_id` (each object's own `sub_bitmaps` value; 0 never counts as a match), a subtitle is present, and every cached item the mode needs exists.
5. **Render.** Compositing needs a CoreGraphics image and a BGRA buffer; the separate layer needs only the BGRA buffer. Each item is replaced only if it was rendered. The render counts as successful if either item was made; if neither was, nothing changes. After a successful render: record the objects and their `change_id` values, mark a subtitle present and, on the separate layer, mark a subtitle sample as pending. The bounding box (4.14.5), and the buffer's dirty record, are updated only when the buffer was rendered.
6. A render taking more than 8 ms is logged at verbose, at most once per second and only when verbose logging is enabled.

**Clearing the subtitle cache**, wherever this document says so: release the cached image and buffer, mark no subtitle present, forget the recorded objects and `change_id` values, clear the pending-sample mark and empty the bounding box. Clearing flushes no layer. `VOCTRL_VO_OPTS_CHANGED` and `VOCTRL_SET_PANSCAN` clear and sync but add no flush of their own (only 4.14.9 step 3 flushes, when the composite flag has just changed), so the separate layer keeps showing its last sample; if that cue has ended by the next frame, the next render finds nothing to draw and nothing cached, and the old cue remains visible until the following cue change, reset or flush. Keep this.

#### 4.14.5 Rasterising

**The BGRA buffer.** From the subtitle pool: `kCVPixelFormatType_32BGRA` at the canvas size, with the pool attributes of 4.3. The pool is recreated when the canvas size changes, and all dirty-tracking entries are dropped then. Before drawing, the buffer is cleared using dirty tracking (below).

**Path per object.** An object is drawn on the direct path when its format is `SUBBITMAP_LIBASS` or `SUBBITMAP_BGRA` and every part that is not skipped (below; 12.3) is drawn at its own size (`dw` and `dh` equal `w` and `h`, a `dw` or `dh` of 0 or below counting as `w` or `h`); otherwise on the CoreGraphics path. Both paths write into the same buffer, object after object. Parts with no bitmap, or a width or height of 0 or below, are skipped on both paths.

**Direct libass blend**, for each part at its (`x`, `y`) position, clipped to the buffer:

- The part colour is 0xRRGGBBTT, where TT is transparency. Let *a* = 255 − TT. If *a* is 0, skip the part.
- For each covered pixel with mask value *m*: skip it if *m* is 0; let *A* = *a* · *m* and *I* = 65025 − *A*; each of B, G and R becomes (*m* · *c* · *a* + *d* · *I* + 32512) div 65025, where *c* is the part's channel value and *d* the existing one; alpha becomes (*A* · 255 + *d*ₐ · *I* + 32512) div 65025. "div" is integer division rounding towards zero.
- The result is premultiplied BGRA.

**Direct BGRA blend.** Parts are premultiplied BGRA. For each covered pixel: skip it if the source alpha is 0; copy the source pixel if its alpha is 255 or the destination pixel is all zero; otherwise each of the four channels becomes min(255, *s* + (*d* · (255 − *sₐ*) + 127) div 255).

**CoreGraphics path.**

- A bitmap context over the buffer's memory: device RGB, `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`, the buffer's stride. Nothing else is set on the context: interpolation quality, antialiasing and blend mode keep their defaults.
- Each part is drawn in the rectangle with origin (`x`, canvas height − `y` − `dh`) and size `dw` × `dh` (y flipped), using the part's own `dw` and `dh` as they are, with no defaulting (12.3).
- BGRA parts are drawn as images made with `CGImageCreate` (8 bits per component, 32 per pixel, the part's stride, device RGB, premultiplied first, 32-bit little-endian, a null decode array, `shouldInterpolate` false, default rendering intent).
- libass parts are drawn as masks made with `CGImageMaskCreate` (8 bits, the part's stride, an inverted decode so that 255 paints, `shouldInterpolate` false). The rectangle is clipped to the mask and filled with the colour R ÷ 255, G ÷ 255, B ÷ 255, alpha 1 − TT ÷ 255, inside a saved and restored graphics state.

**Bounding box.** The union, over every object drawn, of every drawn part's destination rectangle from (`x`, `y`) to (`x` + `dw`, `y` + `dh`) with the same defaulting rule, each of its four edges clamped to the canvas separately before the union is taken (12.3). If no part qualifies, the box is empty (x0 = canvas width, y0 = canvas height, x1 = y1 = 0). Any box with x1 ≤ x0 or y1 ≤ y0 is empty and behaves the same, whichever form an empty box is given (all zeros after a clear, or the form above).

**Dirty tracking:**

- up to 4 IOSurfaces are tracked, each by its `IOSurfaceRef` with a retain held; a fifth replaces the least recently used;
- a surface seen for the first time is cleared entirely; a known surface only within the rectangle last drawn into it, clamped to the canvas; a buffer with no IOSurface entirely;
- after clearing, the recorded rectangle is empty; after drawing, it is the bounding box;
- at the 60-flip maintenance, entries unused for more than 2 s are dropped; all entries are dropped when the pool is recreated, and at teardown.

**CoreGraphics image (compositing only).** An RGBA bitmap at the canvas size (device RGB, `kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big`, stride width × 4), cleared, drawn with the CoreGraphics path for every object in order, then snapshotted into a `CGImage`.

Faster versions of the two direct blends and of the upload copies are allowed if bit-identical.

#### 4.14.6 Timed subtitle samples (separate layer)

- Built only when a subtitle change is pending: from the cached BGRA buffer if a subtitle is present, otherwise from a freshly cleared pool buffer, so that the change clears the screen.
- The presentation time is the flip's video presentation time. The subtitle layer shares the host layer's timebase, so a subtitle change shows on the same frame as its video.
- Enqueued immediately before the video sample, and only if the subtitle renderer is ready. The pending mark clears only when the sample is enqueued.
- The subtitle layer is flushed with removal at every reset, at every reconfiguration (asynchronously on main), at every composite-mode change, at every real host resize while subtitles are on the separate layer, and at teardown.

#### 4.14.7 Compositing into video samples (Picture in Picture)

**When.** Compositing is on and a subtitle is present.

**Biplanar YUV sources** (`420v`, `420f`, `x420`, `xf20`: 8-bit and 10-bit, video and full range) use the integer YUV blend below; 7.3 decides which buffer it writes into. If the blend produces nothing, the Core Image fallback is used. "Produces nothing" covers: no cached buffer, an empty bounding box, a zero size, a blend rectangle that misses the frame, and a lock or pool failure.

**Blend rectangle.**

- The subtitle bounding box, in canvas coordinates, is intersected with the destination rectangle and with the canvas.
- It is mapped into frame pixels through the source and destination rectangles: start = src origin + floor((box start − dst origin) · src size ÷ dst size) − 1; end = src origin + ceil((box end − dst origin) · src size ÷ dst size) + 1, one pixel of slack on each side. In frame space both rectangles are the whole frame.
- The result is clamped to the source rectangle, itself clamped to the frame. If any rectangle involved is empty, or the result is, the blend produces nothing.

**Per-pixel YUV blend.** For each frame pixel (*x*, *y*) in the blend rectangle:

- Nearest subtitle sample, with 64-bit integer division: *sx* = clamp(dst.x0 + ((*x* − src.x0) · dst width) div src width, 0, canvas width − 1); *sy* = clamp(dst.y0 + ((*y* − src.y0) · dst height) div src height, 0, canvas height − 1).
- Its premultiplied B, G, R and alpha, each divided by 255. Skip the pixel if alpha (*α*) is 0 or below.
- Coefficients from the frame buffer's `kCVImageBufferYCbCrMatrixKey`: BT.2020 gives *Kr* 0.2627, *Kb* 0.0593; BT.601 gives *Kr* 0.299, *Kb* 0.114; anything else or missing gives *Kr* 0.2126, *Kb* 0.0722. *Kg* = 1 − *Kr* − *Kb*.
- Luma: *Y′* = *Kr*·R + *Kg*·G + *Kb*·B, from the premultiplied values with no transfer-function conversion. New luma = old · (1 − *α*) + *Yoff* · *α* + *Yrange* · *Y′*.
- Chroma, only where both *x* and *y* are even, from that pixel's sample: *Cb′* = (B − *Y′*) ÷ (2(1 − *Kb*)), *Cr′* = (R − *Y′*) ÷ (2(1 − *Kr*)). New Cb = old · (1 − *α*) + *Ccentre* · *α* + *Crange* · *Cb′*, likewise Cr. The sample written is at row *y* ÷ 2, positions (*x* ÷ 2)·2 and (*x* ÷ 2)·2 + 1 of the interleaved plane.
- Rounding: every written value is rounded by adding 0.5 and truncating towards zero, then clamped to 0 to 255 (8-bit) or 0 to 1023 (10-bit). 10-bit samples are read as the 16-bit value shifted right by 6 and written back shifted left by 6.
- Range comes from the pixel format code (full-range codes are full range), not from attachments.

**Evaluation order.** The equations above must be evaluated in this exact order for the result to be bit for bit today's. All of it is IEEE 754 double precision with round-to-nearest-even. Below, fma(*a*, *b*, *c*) means *a*·*b* + *c* computed with one rounding (a fused multiply-add), and every other operation rounds on its own. Write the fused steps as explicit fused multiply-adds; do not rely on the compiler contracting expressions, because that depends on build flags.

1. B, G, R and *α* are each the byte divided by 255, and 1 − *α* is rounded once.
2. *Kr* and *Kb* are the doubles nearest the decimal values above, and *Kg* is (1 − *Kr*) − *Kb*, two rounded subtractions.
3. *Y′* = fma(*Kb*, B, fma(*Kr*, R, *Kg*·G)), where *Kg*·G is rounded on its own first.
4. New luma, before rounding = fma(*Yrange*, *Y′*, fma(old, 1 − *α*, *Yoff*·*α*)), where *Yoff*·*α* is rounded on its own first and old is the stored sample (after the 10-bit shift) as a double.
5. *Cb′* = (B − *Y′*) ÷ (2 × (1 − *Kb*)) and *Cr′* = (R − *Y′*) ÷ (2 × (1 − *Kr*)), each operation rounded.
6. New Cb, before rounding = fma(*Crange*, *Cb′*, fma(old, 1 − *α*, *Ccentre*·*α*)), where *Ccentre*·*α* is rounded on its own first; Cr likewise with *Cr′*.
7. The 0.5 of the rounding rule is a separate addition, never fused, before truncation and clamping.

Evaluating every operation separately instead gives a result one code value different in a small fraction of samples (up to about 2 in 100,000 for some formats and matrices). The bit-exact tests (9.4) use the order above.

| Format | *Yoff* | *Yrange* | *Ccentre* | *Crange* |
| --- | --- | --- | --- | --- |
| 8-bit video range | 16 | 219 | 128 | 224 |
| 8-bit full range | 0 | 255 | 128 | 255 |
| 10-bit video range | 64 | 876 | 512 | 896 |
| 10-bit full range | 0 | 1023 | 512 | 1023 |

**Core Image fallback** (non-biplanar sources such as 4:2:2 or 4:4:4 hardware buffers, or when the YUV blend produced nothing):

- Needs the cached CoreGraphics image, a Core Image context and a video buffer that Core Image can wrap as an image; when it cannot, there is no composite and the frame goes out without the subtitle (12.3).
- Output size: the canvas size (in frame space, the frame size). Output format: `kCVPixelFormatType_64RGBAHalf` for `x420` and `xf20` sources only, otherwise `kCVPixelFormatType_32BGRA` (12.3), from the composite output pool, which is recreated on any size or format change.
- Steps: copy the metadata (below); wrap the video buffer as a `CIImage` with its own colour space (`CVImageBufferGetColorSpace`), or sRGB if it has none; crop it to the source rectangle (y flipped: origin at frame height − src.y1), move it to the origin, scale it to the destination size, move it to (dst.x0, output height − dst.y1); composite it over opaque black cropped to the output; scale the subtitle image to the output size if it differs and composite it over; render into the output buffer with bounds equal to the output and the video buffer's colour space (or none). All inside an autorelease pool.

**Metadata copy** (YUV copies and the Core Image output):

1. Propagate the source's attachments to the destination (`CVBufferPropagateAttachments`).
2. For each of these keys, copy it with its mode, or remove it from the destination if the source lacks it: `kCVImageBufferCGColorSpaceKey`, `kCVImageBufferICCProfileKey`, `kCVImageBufferGammaLevelKey`, `kCVImageBufferColorPrimariesKey`, `kCVImageBufferTransferFunctionKey`, `kCVImageBufferYCbCrMatrixKey`, `kCVImageBufferMasteringDisplayColorVolumeKey`, `kCVImageBufferContentLightLevelInfoKey`, `kCVImageBufferChromaLocationTopFieldKey`, `kCVImageBufferChromaLocationBottomFieldKey`, `kCVImageBufferChromaSubsamplingKey`, `kCVImageBufferCleanApertureKey`, `kCVImageBufferPreferredCleanApertureKey`, `kCVImageBufferPixelAspectRatioKey`.
3. For a non-biplanar destination, remove the matrix, and derive a colour space from the attachments if none is present.

7.3 adds a stronger rule for YUV composites of hardware frames.

**Frame-space size guard.** If a composite's width or height differs from the original frame's, the composite is discarded and the frame shown without the subtitle, with a warning once per VO lifetime.

**Core Image context.** Created on demand on `MTLCreateSystemDefaultDevice()`, with `kCIContextHighQualityDownsample` NO and `kCIContextUseSoftwareRenderer` NO. If the device or context cannot be made, an error is logged and the frame goes out without the subtitle; a failed context drops the device too (12.3), and creation of both is tried again, and the error logged again, each time the fallback is reached. Released when an option refresh finds `avfoundation-pip-composite-osd` off, and at teardown.

#### 4.14.8 Frame-space requirements

- In Picture in Picture the window shows the enqueued samples, not the layer tree, so subtitles must be inside the samples.
- The sample size must be the same whether or not a cue is showing. Frame space guarantees this: the canvas is the frame, so the YUV blend always fits it, and even the Core Image output is frame-sized.
- While frame space is on, host resizes do not resync the subtitle layer (4.15.2).

#### 4.14.9 Option changes at run time

**On every `VOCTRL_CHECK_EVENTS`**, after the resync and resize checks (4.16.4):

1. Refresh the option cache; stop if nothing changed.
2. If the queue lead changed, call `vo_set_queue_params(new lead in ns, 1)`.
3. If `avfoundation-pip-composite-osd` changed: log the new value at verbose; clear the subtitle cache; if it is now off, release the Core Image context; flush the subtitle layer's renderer with removal (VO thread); sync the subtitle layer (4.14.2). Nothing else: no video buffer is written, so a decoder buffer that carries a composited cue keeps it (13.1).

**On `VOCTRL_VO_OPTS_CHANGED`:** the same refresh (steps 1 to 3, so a composite flag that changed at that moment still gets step 3, flush included), then clear the subtitle cache and sync the subtitle layer, whatever changed. It adds no flush of its own.

**On `VOCTRL_SET_PANSCAN`:** clear the subtitle cache and sync the subtitle layer. No flush.

**No redraw is requested** by any of these. Turning compositing on while paused shows no subtitle until the next frame or redraw; turning it off while paused leaves the last composited sample, with its burned-in cue, visible until the following frame or redraw (hazard V15).

**Buffers that may be on screen (13.1).** Switching compositing off touches no buffer: a decoder buffer composited in place (12.3) is not written at the switch. Its original rows, kept from the composite, are written back only immediately before that same buffer is presented again, so that sample carries no cue. If a different buffer is presented first, or the VO is torn down, the kept rows are released and the composited buffer is not written. A same-buffer redraw while compositing is on builds the new composite away from the buffer and then writes into it only the rows whose bytes change, so the displayed picture never passes through a state without its cue.

The bridge also re-lays out the host on every Picture in Picture flag change, which leads to a redraw only if `bounds` or `contentsScale` really changed and subtitles are on the separate layer.

### 4.15 Geometry

#### 4.15.1 Who places the picture

- The VO enqueues frames at their decoded size and never scales the picture.
- Placement, scaling, letterboxing and fill come from the host layer's `videoGravity`, which Vivid sets to `.resizeAspect`, `.resizeAspectFill` or `.resize`.
- The subtitle layer always uses resize gravity over the same frame as the host layer, so its canvas maps pixel for pixel onto the host layer.

#### 4.15.2 Following host layer size changes

- **Observation.** At creation, an observer object is registered on main, synchronously, for key-value observation of `bounds` and `contentsScale` on the host layer, with old and new values. Notifications arrive on the thread that made the change (main in Vivid). One whose old and new values are both present and equal is ignored; any other sets a pending-resize flag atomically and calls `vo_wakeup`.
- **Consumption,** at the next `VOCTRL_CHECK_EVENTS`, on the VO thread. With subtitles on the separate layer: log at verbose; clear the subtitle cache; flush the subtitle layer's renderer with removal; sync the subtitle layer; set `vo->want_redraw`, so that upstream draws the current frame again even when paused. While compositing: nothing more, because composited subtitles travel inside the samples.
- **Equal values must be filtered** (every resync blanks the subtitle on screen).
- **Removal** at teardown, on main and synchronously, before the observer object or any VO state is released.

#### 4.15.3 Upstream geometry options and host transforms

- `panscan`, `video-aspect-override`, `video-unscaled`, `video-align-*`, `video-margin-ratio-*`, `video-crop`, `video-zoom`, `video-pan-x`, `video-pan-y`, `video-scale-x` and `video-scale-y` never change the picture: every frame reaches the layer untouched (7.2). They do change the rectangles upstream `vo_get_src_dst_rects` returns, and so where separate-layer subtitles are placed: for example a non-default zoom would move subtitles away from the picture. A change triggers `VOCTRL_SET_PANSCAN` and `VOCTRL_VO_OPTS_CHANGED` upstream (4.14.9).
- A `transform` on the host layer does not change its `bounds`, so the VO does not notice it. The subtitle layer is a sibling and does not inherit it, but the next subtitle-layer sync copies the host layer's transformed `frame`, after which subtitles are scaled with the video, and they stay scaled after the transform is removed until a later sync.
- Neither case is reachable today: Vivid never sets those options and has no viewer zoom.

#### 4.15.4 Rotation and capabilities

The VO declares no rotation capability, so rotated sources get upstream's handling for outputs that cannot rotate. Keep `caps` 0.

### 4.16 Lifecycle and threading

#### 4.16.1 When mpv creates and destroys the VO (upstream behaviour)

| Moment | Upstream path | In Vivid |
| --- | --- | --- |
| Created | The core first builds a video chain for a selected video track (`reinit_video_chain_src` in `player/video.c` calls `init_best_video_out`, which calls `vo_create`). | At file start for a file with video, before the first decoded frame. Also for an audio-only load whenever `vid=auto` selects embedded cover art: mpv's default `audio-display` is `embedded-first`, and the bridges write `vid=auto` on every return to the foreground and every iOS activation, with no audio-only check. |
| Kept | Across files in the same context while the next file has video. | One mpv context per load, so one VO per load plus rebuilds. |
| Destroyed by deselecting video | Track switch to none: `uninit_video_chain`, then `handle_force_window(mpctx, true)`, which with `force-window` off calls `uninit_video_out` and so `vo_destroy`. | The bridge's background `vid=no` (iOS without Picture in Picture, and tvOS): picture removed (the host layer shows its black background), subtitle layer removed, `controlTimebase` cleared, observers removed. |
| Created again | Selecting video again (`vid=auto`) runs `reinit_video_chain_src` with no VO. | Everything in 4.16.2 runs again, including the superlayer check and the main-thread hops. |
| Destroyed with mpv | `mp_destroy` calls `uninit_video_out`. | The bridge's queued `mpv_terminate_destroy`. |
| Rebuilt on option change | `vo` and `wid` are `UPDATE_VO`. | Never after init. |

`uninit_video_out` tears down the video chain, decoder included, before `vo_destroy`.

**Cover art.** A VO made for an embedded still image behaves as for any software frame: upstream decodes it in software and converts it to an accepted format, the VO uploads it (4.3), mpv delivers one frame with no regular cadence, and presentation then rests on that frame.

#### 4.16.2 Creation (`preinit`)

Orderings that must hold:

- `wid` is checked first: with −1, log an error and fail. Below iOS 17 or tvOS 17, log an error and fail (7.2). Neither failure leaves anything behind.
- The timebase is created before anything is put on the host layer; if it cannot be, log an error, drop the host layer reference and fail.
- The presentation mode is latched, media timing reset (as in 4.13, with nominal rate 1.0) and the timebase seeded (host mode: time = now, rate 1.0; media mode: time 0, rate 0) before the timebase becomes the host layer's `controlTimebase`, which happens before any frame can be enqueued.
- The host geometry is read before the subtitle layer is created.

Creation must also, in any order consistent with the above:

- allocate the option cache for the `avfoundation` group with `vo_wakeup` as its wakeup callback;
- take a strong reference to the host layer and log, at verbose, the layer address and the composite flag;
- call `vo_set_queue_params(queue lead in ns, 1)`;
- create the subtitle layer (4.14.2);
- create `vo->hwdec_devs` and add the VideoToolbox entry (2.1); if the device cannot be allocated or initialised, log an error and still add the entry, without a device;
- register the two app-state observers (4.12) and the key-value observers on the host layer (4.15.2).

The main-thread work (setting `controlTimebase`, reading geometry, creating the subtitle layer, registering each kind of observer) is done as separate synchronous hops; nothing guarantees a layout pass cannot happen between them.

#### 4.16.3 Reconfiguration (`reconfig`)

Log the new size at verbose; clear the subtitle cache and queue an asynchronous flush with removal of the subtitle layer on main; sync the subtitle layer (synchronous geometry read, asynchronous frame copy); succeed. The host layer is not flushed and the timebase is untouched; frames in the new format are simply enqueued, and the cached format description follows them (4.6).

#### 4.16.4 Control requests (`control`)

| Request | Action | Result |
| --- | --- | --- |
| `VOCTRL_CHECK_EVENTS` (every VO thread loop iteration) | In order: a pending resync runs a forced recovery (4.11); a pending resize is handled (4.15.2); options are refreshed (4.14.9). | `VO_TRUE` |
| `VOCTRL_PAUSE`, `VOCTRL_RESUME` | Media mode: 4.8.2. Host mode: nothing. | `VO_TRUE` |
| `VOCTRL_REDRAW` | Reset subtitle change tracking (4.13). | `VO_TRUE` |
| `VOCTRL_RESET` | 4.13. | `VO_TRUE` |
| `VOCTRL_SET_PANSCAN` | Clear the subtitle cache, sync the subtitle layer, no flush. | `VO_TRUE` |
| `VOCTRL_UPDATE_WINDOW_TITLE` | Nothing. | `VO_TRUE` |
| `VOCTRL_VO_OPTS_CHANGED` | Refresh options (4.14.9), clear the subtitle cache, sync the subtitle layer; no flush beyond the refresh's own. | `VO_TRUE` |
| Anything else | Nothing. | `VO_NOTIMPL` |

#### 4.16.5 Teardown (`uninit`)

Orderings that must hold:

- Both kinds of observer are removed, on main and synchronously, before any state their callbacks touch is freed.
- The host layer's renderer is flushed **with** removal of its displayed image, and the subtitle layer's renderer likewise (VO thread), before `controlTimebase` is cleared on both layers (on main, synchronously); the timebase is released after that. The host layer then shows its own background (black in Vivid) until a new VO enqueues.
- The subtitle layer is removed from its superlayer on main, synchronously, before it is released.
- The VideoToolbox entry is removed from `vo->hwdec_devs` (`hwdec_devices_remove`) and its device reference released before the list itself is destroyed (`hwdec_devices_destroy`, 7.3).

Teardown must also, in any order consistent with the above: emit the subtitle performance summary (verbose, if any renders happened); release the held image; release the cached subtitle image and buffer; release the three pools (dropping every dirty-tracking entry and its surface retain); release the cached format description; release the Core Image context and the Metal device; drop the host layer reference (the host layer is never removed from its superlayer); free the option cache. The final releases of both layers happen on main (12.3).

#### 4.16.6 Thread map

| Work | Where it runs |
| --- | --- |
| `preinit`, `reconfig`, `control`, `draw_frame`, `flip_page`, `uninit` | mpv's VO thread |
| Synchronous main hops | Creation: setting `controlTimebase`, the geometry read, subtitle layer creation, registering each kind of observer. Every geometry read: reconfiguration, option or `panscan` changes, a consumed resize, a composite-mode change, and the first `flip_page` with an image after creation and after any subtitle-layer sync (4.14.3). Every recovery: status reads and both non-removing flushes. Teardown: removing both kinds of observer, clearing `controlTimebase`, removing the subtitle layer. |
| Asynchronous main hops | The subtitle layer frame copy (4.14.2); the subtitle-layer flush with removal queued at reset and reconfiguration; the final release of both layers at teardown (12.3). |
| Directly on the VO thread | Every enqueue to both layers; readiness polls; the reset and teardown flushes; the subtitle-layer flushes with removal for a consumed resize and a composite-mode change; every timebase time, rate and anchor change; all pixel work and Core Image renders. |
| Key-value observer callback | The thread that changed the layer (main in Vivid); only sets an atomic flag and calls `vo_wakeup`. |
| App-state notification blocks | The main operation queue; only set a flag (and, on becoming active, an atomic flag plus `vo_wakeup`). |

A synchronous hop runs inline if already on main, otherwise with `dispatch_sync` to the main queue. The VO thread is never main, so in practice every synchronous hop blocks the VO thread until main has run it.

#### 4.16.7 Deadlock rule

- The core waits on the VO thread while the VO is created (until `preinit` finishes), during every reconfiguration and other synchronous VO calls, and at destruction (joining the VO thread, which runs `uninit`).
- The VO waits on main at the points in 4.16.6.
- So main must never wait on the core: no synchronous libmpv call that needs the core may run on main, nor `mpv_terminate_destroy` or `mpv_destroy`, and main must not wait on a queue that is doing either. The risk exists at file start, every reconfiguration, every `vid=auto`, every `vid=no`, option and geometry changes, recoveries, the first frame after any subtitle-layer sync, and final destruction. The bridge queues `mpv_terminate_destroy` on its own serial queue and makes blocking reads only there (bridge spec 5.3, 6.17).
- The hops must stay synchronous: `controlTimebase` must be set before the first enqueue, observers must be gone before state is freed, and geometry must be current when the canvas is computed.

#### 4.16.8 Ownership

| Object | Owner and lifetime |
| --- | --- |
| Host layer | App-owned; the VO holds a strong reference from creation to teardown. |
| Subtitle layer | VO-owned; created at creation, removed and released at teardown. |
| Timebase | VO-owned; both layers' `controlTimebase` until teardown clears it. |
| Pools, cached format description, cached subtitle image and buffer | VO-owned; released at teardown. |
| Dirty-tracking entries | Each holds a retain on its `IOSurfaceRef`; released on eviction, pruning, pool recreation and teardown. |
| Core Image context and Metal device | VO-owned; created on demand; released when compositing switches off and at teardown. |
| Observers | Registered at creation; removed synchronously on main at teardown. |
| VideoToolbox device and the device list | Created at creation; entry removed, reference released and list destroyed at teardown. |
| Held image | A new reference per `draw_frame`; released after `flip_page`, at the next `draw_frame` and at teardown. |

### 4.17 What the VO relies on from FFmpeg

- VideoToolbox buffers arrive untouched by mpv; the VO sets or removes the pixel aspect itself (4.5), whatever FFmpeg's attachment step did (5.7, 12.4).
- `DolbyVisionRPUData` exists only if FFmpeg opens `dvh1` sessions, forwards RPUs in-band and enables per-frame HDR metadata propagation (5.2 to 5.5). If any of the three regresses, the repair silently stops firing and profile 5 loses its PQ tag.
- Profile 7: mpv's frame parameters describe the source profile 7 RPU (no Dolby Vision mapping, because its `disable_residual_flag` is 0), while VideoToolbox renders the converted 8.1 RPU. The VO must not try to reconcile them.
- VideoToolbox destination buffers request Metal compatibility (5.10), as the VO's own pools do (4.3).
- The VO has no Vulkan or MoltenVK dependency.

### 4.18 VO log messages

Nothing in Vivid parses `vo/avfoundation` lines. Wording is free; keep each message's level, because the requested level (`warn`, or `v` in trial builds) decides which ones reach the app.

| Level | Messages |
| --- | --- |
| Error | No layer given through `wid` (verbose instead while mpv is autoprobing video outputs, which Vivid never makes it do, 13.1); system below iOS 17 or tvOS 17; timebase creation failed; VideoToolbox device allocation or initialisation failed; a pool could not be created (naming it); no buffer from a pool (upload, subtitle, YUV composite, Core Image composite); an unsupported software format or a failed upload; format description or sample buffer creation failed (video or subtitle); the Metal device or Core Image context could not be created (each time it is tried); the kept rows of a composite could not be written back because the buffer could not be locked (13.1). |
| Warning | The host layer has no superlayer at creation; a timebase anchor or pause failed; every display layer recovery (reason, status, flags, media time, timebase time, rate); once per VO, a frame-space composite discarded for changing the sample size. |
| Verbose | The creation summary; the reconfiguration size; a pool created (name, size, format); a nominal rate change; a re-anchor (error in ms); deadline drops (already past, reached while waiting, unrecovered layer); a subtitle sample dropped because its layer was not ready; a host resize resync; a composite-mode change; the slow subtitle render line; the pacing summary; the subtitle performance summary. |

The two summaries should keep their cadence, so trial traces stay comparable:

- **Pacing summary,** when a 5 s window ends with a non-zero count of readiness waits, deadline drops, anchors or rate writes, or a non-zero largest phase error. Recoveries alone never trigger it, although the line may report them. The largest phase error is sampled only on frames that reach the slew decision of 4.8.2 (a valid anchor, neither playback nor the timebase marked paused, and no nominal-rate change on that frame); a frame whose error is above the 50 ms re-anchor limit after a valid anchor still counts. So the first frame after creation, a reset, a resume or a recovery, every paused frame and the frame that adopts a new nominal rate are not sampled (12.2 says when the first window opens; 13.1). The line gives how often and how long frames waited for readiness, deadline drops, anchors, rate writes and the resulting offset from nominal in ppm (applied ÷ nominal − 1, × 10⁶), and the largest phase error in ms.
- **Subtitle performance summary,** when at least 32 renders have accumulated, or at least 1 render and 300 frames, and at teardown: canvas size, render count with average and maximum render time and the split between clearing, blending, CoreGraphics and the bounding box, skipped and empty renders, enqueue time, video sample and wait time per frame, subtitle enqueue margin (average and minimum), and subtitle sample drops. Counters always accumulate; the text is built only when verbose logging is on. Exactly what the skipped and empty counters count is free.

## 5. Dolby Vision and FFmpeg VideoToolbox

Summary: for HEVC streams with a usable Dolby Vision configuration of profile 5, 7 or 8, FFmpeg opens a `dvh1` decode session (Apple's Dolby Vision HEVC decoder) instead of an HEVC one. Profile 7 is presented to VideoToolbox as profile 8.1: a rewritten configuration record, RPUs converted per frame by libdovi, and no enhancement layer. Per-frame RPUs are sent in-band. The session asks VideoToolbox for per-frame HDR metadata. Decoded buffers get pristine FFmpeg's attachments, as they do in today's shipped engine (5.7, 12.4). When VideoToolbox refuses the Dolby Vision session and the stream has an HDR-compatible base (5.1), FFmpeg makes one more attempt with an ordinary HEVC session. Every other path is pristine, apart from the explicit sample size in 5.5, which applies to all codecs.

All of this apart from 5.13, which patches libdovi, lives in `libavcodec/videotoolbox.c` (and, if needed, `libavcodec/vt_internal.h`) and is written to apply on top of Vivid's existing FFmpeg series (8.2), whose `0002` already makes the destination buffers Metal-compatible (5.10). Nothing reads a new option, user default or environment variable: the behaviour below is unconditional.

### 5.1 Inputs and classification

**Inputs.**

| Input | Source | Rule |
| --- | --- | --- |
| Coded side data `AV_PKT_DATA_DOVI_CONF` on the `AVCodecContext` (`coded_side_data`), payload `AVDOVIDecoderConfigurationRecord` | mpv's Matroska demuxer (from the `dvcC`/`dvvC` block addition mapping) or libavformat (MP4 `dvcC`/`dvvC`/`dvwC`, Matroska through lavf, the MPEG-TS Dolby Vision descriptor), carried onto the codec context by `avcodec_parameters_to_context` | Treated as absent unless its size is at least `sizeof(AVDOVIDecoderConfigurationRecord)`. It may be looked up at session start or at each use; coded side data does not change after the decoder opens, so both give the same result. Per-packet `AV_PKT_DATA_DOVI_CONF` is never consulted for these decisions. |
| Record fields | `dv_version_major`, `dv_version_minor`, `dv_profile`, `dv_level`, `rpu_present_flag`, `el_present_flag`, `bl_present_flag`, `dv_bl_signal_compatibility_id` | `dv_md_compression` is ignored (5.2). |
| The HEVC decoder's NAL list for the current input packet | The raw escaped bytes of each NAL, header included | RPUs are the NALs of type 62, selected by type alone (5.5). |
| `AVCodecContext.codec_id` | | Only `AV_CODEC_ID_HEVC` is affected, apart from the sample-size rule (5.5). |

**Classification**, HEVC only. A record is "usable" when it is present, large enough, and has both `rpu_present_flag` and `bl_present_flag` set.

| Class | Condition | Session codec type | Notes |
| --- | --- | --- | --- |
| Native, profile 5 | usable, `dv_profile` 5 | `dvh1` | No colour extensions, no fallback. |
| Native, profile 8 | usable, `dv_profile` 8 | `dvh1` | Every compatibility id qualifies. |
| Converted, profile 7 | usable, `dv_profile` 7 | `dvh1` | Presented as 8.1 (5.2, 5.5, 5.6). Always converted; there is no other profile 7 mode. |
| Plain HEVC | anything else: no record, record too small, RPU or BL flag clear (any profile, 7 included), or profile 4, 9, 10 or any other | `kCMVideoCodecType_HEVC` | Pristine behaviour throughout. |

`dvh1` is CoreMedia's `kCMVideoCodecType_DolbyVisionHEVC`; the literal four-character code may be used to avoid SDK availability guards.

Two derived predicates:

- **HDR-compatible base:** profile 8 (any compatibility id), or profile 7 with RPU and BL flags set. Profile 5 never qualifies, because its base layer is not a picture a plain HDR decode can show.
- **HLG base:** profile 8 with compatibility id 4. The rest of the HDR-compatible set is treated as PQ, including profile 8 with compatibility id 2 (an SDR base) or 0 (hazard D3).

A verbose line says which path was chosen, for Dolby Vision sessions only, once per session start (the first start and every restart), before the first creation attempt; a plain HEVC retry gets only its warning (5.3). Plain HEVC logs nothing here.

### 5.2 Session description for Dolby Vision sessions

The format description extensions and the decoder specification are the same dictionary, as in pristine FFmpeg.

1. **Hardware.** `kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder` true, as pristine does for HEVC; never the Require key.
2. **Atoms.** Inside `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`: pristine FFmpeg's `hvcC` (its existing builder, unchanged) and one Dolby Vision configuration atom:
   - key `dvvC` when the effective profile is above 7 (profile 8, and converted profile 7); `dvcC` otherwise (profile 5);
   - a 24-byte `DOVIDecoderConfigurationRecord` laid out as ETSI TS 103 572 defines it: byte 0 `dv_version_major`; byte 1 `dv_version_minor`; bytes 2 and 3, big-endian, from the most significant bit: profile (7 bits), level (6 bits), `rpu_present_flag`, `el_present_flag`, `bl_present_flag` (1 bit each); byte 4: `dv_bl_signal_compatibility_id` in the top 4 bits, then the 2-bit metadata compression field, then 2 reserved bits; bytes 5 to 23 zero;
   - version, level, RPU flag and BL flag come from the source record. Profile and level are masked to their field widths, the three presence flags are written as 0 or 1, and the compatibility id is masked to 4 bits;
   - profiles 5 and 8 keep their profile, EL flag and compatibility id;
   - converted profile 7 writes profile 8, EL flag 0 and compatibility id 1;
   - **the compression field and the reserved bits are always 0.** VideoToolbox refuses a record with a non-zero compression value (`kVTVideoDecoderUnsupportedDataFormatErr`, -12910), and FFmpeg's MPEG-TS demuxer can report compression 3 for some files.
3. **Colour extensions**, only for an HDR-compatible base (so never for profile 5), at the dictionary's top level next to the atoms: `kCMFormatDescriptionExtension_ColorPrimaries` = `kCMFormatDescriptionColorPrimaries_ITU_R_2020`; `kCMFormatDescriptionExtension_TransferFunction` = `kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ` (`kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG` for an HLG base); `kCMFormatDescriptionExtension_YCbCrMatrix` = `kCMFormatDescriptionYCbCrMatrix_ITU_R_2020`.

### 5.3 Session creation and fallback

- The session is created as pristine does it, with the Dolby Vision description.
- **One retry.** If creation fails with any non-zero status, the session was `dvh1` and the stream has an HDR-compatible base: log a warning with the status and make exactly one more attempt with a plain HEVC description (codec type `kCMVideoCodecType_HEVC`, `hvcC` only, no Dolby Vision atom, no colour extensions, the Enable-hardware key), the same destination buffer attributes and the same callback. The status that reaches pristine's status-to-error mapping is the retry's, or the original one if the plain description could not be built.
- Profile 5 never retries. A refused profile 5 session returns the pristine error and mpv's software fallback takes over (`hwdec-current` becomes `no`).
- After a retry, the session counts as plain HEVC for every per-frame decision (5.5 item 2); only the profile 7 NAL filter (5.5 item 1) follows the stream class instead.

### 5.4 Session properties

Only when the final session is `dvh1` (never after a retry):

- `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata` true where the OS has it (iOS and tvOS 14 and later);
- `kVTDecompressionPropertyKey_GeneratePerFrameHDRDisplayMetadata` true where the OS has it (iOS and tvOS 17 and later).

Both are kept; which of them `DolbyVisionRPUData` depends on was never isolated. Each failure is logged at verbose and otherwise ignored. Both are gated by OS availability, so the code builds at the 14.0 deployment target.

### 5.5 Building each compressed sample

Pristine HEVC sample assembly is unchanged: parameter-set and slice NALs are each appended as a 4-byte big-endian length followed by the NAL bytes. On top of that:

1. **Profile 7 NAL filter.** For converted profile 7 streams (by stream class, retry or not), a NAL reaching the slice submission path is dropped instead of appended when its type is 62 (`HEVC_NAL_UNSPEC62`, RPU) or 63 (`HEVC_NAL_UNSPEC63`, enhancement layer). The type is the 6 bits after the first bit of the first header byte. NALs shorter than 2 bytes pass through unchanged. hevcdec never routes these types to the slice path in practice, and it skips type 63 itself, so no enhancement layer reaches VideoToolbox either way.
2. **RPU forwarding.** At the end of every HEVC frame, before the sample is submitted, when the session is `dvh1` and the stream is native or converted Dolby Vision:
   - every NAL of type 62 in the current input packet whose escaped size, header included, is more than 2 bytes is appended in packet order, after the slices: unchanged (2-byte header included) for native profiles 5 and 8, or converted (5.6) for profile 7;
   - a NAL whose append or conversion fails is skipped with the warnings of 5.9, and the frame is still submitted; RPU handling never makes FFmpeg fail a frame (how VideoToolbox answers a frame without its RPU is in 12.4);
   - when the frame's bitstream is still empty at frame end, no RPU is appended and nothing is submitted (an accepted difference, 12.4);
   - after submission, the bitstream buffer is reset as in pristine FFmpeg;
   - the "session is `dvh1`" test uses the session as it stands at frame end, before pristine's pending-restart check runs. So the frame that triggers a restart carries RPUs according to the session that is being replaced.
   - This forwards every type-62 NAL; it does not use hevcdec's own choice of RPU (last NAL, layer 0, temporal id 0).
3. **Explicit sample size (all codecs).** Every sample handed to VideoToolbox is created with `CMSampleBufferCreate` with one sample, no timing entries, and a one-entry sample-size array equal to the whole bitstream length; pristine passes no size array. The `dvh1` decoder is reported to fail samples without it with `kCMBlockBufferBadLengthParameterErr`. This applies to H.264, HEVC, AV1, VP9, MPEG and ProRes alike.

### 5.6 Profile 7 to 8.1 RPU conversion (libdovi 3.3.2, mode 2)

The conversion calls libdovi's public C API (header `libdovi/rpu_parser.h`): `dovi_parse_unspec62_nalu`, `dovi_rpu_get_error`, `dovi_convert_rpu_with_mode`, `dovi_write_unspec62_nalu`, `dovi_data_free` and `dovi_rpu_free`. libdovi stays linked, built from source with Vivid's patch (5.13); do not reimplement the conversion. On this path only RPUs from streams classified as converted profile 7 (5.1) reach libdovi, whatever profile their own RPU header gives. (mpv also hands every RPU that hevcdec exports to libplacebo, which parses it with libdovi; 5.13 covers that path.)

Contract:

- **Input:** the escaped type-62 NAL exactly as it appears in the packet, 2-byte header included.
- **Guard (deliberate difference 4, 7.3).** Before calling libdovi, the RPU is skipped as a parse failure, without calling libdovi, when all of these hold: it is at least 25 bytes long; its first five bytes are 0x7C 0x01 0x19 0x08 0x09; and, after dropping the 2-byte header, removing every 0x03 byte whose two preceding bytes in that header-less input are both 0x00 (the first two bytes are always kept), and then dropping the run of 0x00 bytes at the end, 5 or fewer bytes remain. Unpatched libdovi 3.3.2 aborts the whole process on such input, because its library is built to abort on a panic. Vivid's patched libdovi (5.13) would return an error instead, but the guard stays: it is exact, costs almost nothing and does not depend on which libdovi build is linked.
- **Transformation:** libdovi 3.3.2 conversion mode 2 ("To81").
- **Output:** the escaped NAL that libdovi writes for the converted RPU, appended length-prefixed like any other NAL. It begins with `0x7C 0x01`. The bytes must be identical to libdovi 3.3.2's for every RPU.
- **Failure:** if parsing, conversion or writing fails for any reason (including an output longer than a 32-bit length can describe, and the guard above), that RPU is skipped (5.5). With Vivid's patched libdovi, every input that unpatched libdovi 3.3.2 aborts on fails here instead and is skipped the same way (deliberate difference 4, 7.3).
- **What "skipped" means.** The RPU's NAL is not appended to the sample. Any other type-62 NAL in the same packet is still handled separately, and the frame is still submitted, with the slices and whichever RPUs succeeded. The log gets the warnings of 5.9 for that RPU: the stage line (with libdovi's error text, or the guard's own text), then the stripped line. Nothing else changes in FFmpeg: the session, the next frames and hevcdec's frame side data are untouched (VideoToolbox's own response is in 12.4).

What mode 2 does in libdovi 3.3.2, as a parity reference. It follows the RPU's own header, not the container record: an RPU whose header says profile 7 or 8 is changed as below; one whose header says profile 5 gets libdovi's profile 5 to 8.1 conversion; a header profile of 0 or 4 fails conversion, which is a failure as above. For profile 7: the header's enhancement-layer spatial resampling filter flag is cleared and `disable_residual_flag` is set; the mapping's NLQ method, pivots and NLQ data are removed and the partition fields become 0, which means one partition; only when the source enhancement layer is FEL are the luma and chroma reshaping curves replaced by libdovi's identity ("empty 8.1") mapping, while MEL keeps its curves; in display management the Y'CbCr-to-RGB and RGB-to-LMS coefficient sets, their offsets included, become libdovi's fixed profile 8.1 values and `signal_color_space` becomes 0; the input's trailing zero bytes are kept; the CRC is recomputed and the trailing `0x80` written. libdovi rejects inputs shorter than 25 bytes (header included) and inputs whose first bytes are not a recognised RPU start, and those count as failures.

Mode numbering and meaning differ between libdovi releases, so the version is part of the contract (hazard D7). The conversion runs once per frame on the decode thread and changes only the bytes sent to VideoToolbox; hevcdec still parses the original profile 7 RPU for frame side data (5.11).

**Linking.** FFmpeg's `configure` has no libdovi switch. The build passes libdovi's include path and `-ldovi` through FFmpeg's compiler and linker flags, and the static `libavcodec` keeps undefined `dovi_*` references that the app link resolves against the libdovi archive the pipeline provides, Vivid's own patched build (5.13). The pipeline has passed these flags since the Dolby Vision patch landed with them (8.4, 13.3).

### 5.7 Decoded frame attachments

Replaced after implementation (12.4). At frame output every VideoToolbox frame, from a `dvh1` session or any other, gets pristine FFmpeg's post-processing, including `av_vt_pixbuf_set_attachments`, which sets or removes primaries, transfer, matrix, gamma, chroma location, pixel aspect ratio and a derived colour space from the `AVFrame` fields. This holds at every decoder thread count, and nothing Dolby Vision specific happens at frame output. That is what today's shipped engine gives every frame, because Vivid decodes with mpv's default of 4 frame threads, under which today's engine never runs its Dolby Vision output step. Crop handling, `data[3]` and `hw_frames_ctx` are as pristine.

### 5.8 Restarts and reconfiguration

- Classification, codec type, atoms and the retry all happen inside pristine session start, which runs on hwaccel init and again on every pristine restart: reconfiguration when the callback delivers no image for any reason other than a missing reference frame, after a malfunction or invalid-session decode status, and after parameter changes that reinitialise the hwaccel.
- Each restart classifies again, tries `dvh1` first and may retry again.
- Per-frame decisions follow the session as 5.5 says. Frame attachments do not depend on the session (5.7).

### 5.9 FFmpeg log levels for this section

| Message (wording free) | Level |
| --- | --- |
| The path chosen, for Dolby Vision sessions, once per session start, before the first creation attempt (a retry logs only the warning below) | `AV_LOG_VERBOSE` |
| A session property could not be set (one line per property) | `AV_LOG_VERBOSE` |
| The Dolby Vision session was refused (with the status); one plain HEVC attempt follows | `AV_LOG_WARNING` |
| The Dolby Vision configuration could not be added to the decoder specification: at most once per failed Dolby Vision session start, followed by pristine FFmpeg's own decoder specification error; no plain HEVC retry follows, and the line contains no fault substring of 2.8 (13.2) | `AV_LOG_ERROR` |
| A profile 7 RPU could not be parsed, converted or written (including the 7.3 guard, whose line has its own single-line text, wording free), with libdovi's error text (or "unknown error") | `AV_LOG_WARNING` |
| An RPU was stripped; the line says "convert" for converted profile 7 streams and "append" for native ones, whatever stage failed | `AV_LOG_WARNING` |

Warning count per failed RPU, for exact parity: when libdovi parses the NAL but reports an error, or conversion or writing fails, or the guard skips it, two lines are logged (the stage line, then the stripped line). When libdovi returns nothing at all from parsing, when the converted NAL is too long, when appending a converted RPU fails, or when a native RPU cannot be appended, only the stripped line is logged. libdovi's error text for unrecognised start bytes contains one line break, so mpv delivers that stage line as exactly two `warn` events, three with the stripped line. An input that Vivid's libdovi patch turns from an abort into an error (5.13) has a single-line error text, so it gives exactly two `warn` events.

These levels are interface (2.8): `AV_LOG_ERROR` becomes `error` and `AV_LOG_WARNING` becomes `warn`, both of which Release builds receive, and `AV_LOG_VERBOSE` becomes `debug`, which no Vivid build receives. None of these messages, libdovi's error texts included, may contain the fault substrings of 2.8; today's do not, and the error texts that Vivid's libdovi patch adds (5.13) must not either.

### 5.10 Metal compatibility for VideoToolbox output buffers

VideoToolbox's destination buffer attributes ask for `kCVPixelBufferMetalCompatibilityKey` true and for neither OpenGL compatibility key. Vivid's existing FFmpeg patch `0002` already does this, in place of the third-party build's unrecorded source edit. The Dolby Vision patch applies on top of it, must keep it, and must not reintroduce `kCVPixelBufferOpenGLESCompatibilityKey` or `kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey`. The pipeline checks both (8.5).

### 5.11 Contract with mpv, the VO and the bridge

- `dolby-vision-profile` and `dolby-vision-level` come from the container record through upstream mpv. Profile 7 stays 7. No `dolby-vision-compatibility-id` key or property exists (2.7).
- Frame side data `AV_FRAME_DATA_DOVI_METADATA` and `AV_FRAME_DATA_DOVI_RPU_BUFFER` come from pristine hevcdec, from the source RPU, and stay unconverted for profile 7. mpv's `mp_image_from_av_frame` applies Dolby Vision mapping only when the RPU header's `disable_residual_flag` is set, so profile 7 frames keep `repr.sys` from the VUI. hevcdec must not export the converted RPU.
- The bridge requests profile 8 with compatibility id 1 for profile 7 sources (filling missing tags with PQ, BT.2020 and BT.2020 non-constant), which relies on the conversion always being on.
- The VO's transfer repair and Dolby Vision recognition depend on 5.2, 5.4 and 5.5 together (4.17).

### 5.12 Outcome by source

| Source | VideoToolbox session | Bytes VideoToolbox sees | FFmpeg buffer tags | mpv `dolby-vision-profile` | Notes |
| --- | --- | --- | --- | --- | --- |
| Profile 5 (`dvcC`, compatibility 0) | `dvh1`, no colour extensions | slices + native RPUs | none (VideoToolbox's only) | 5 | A refused session goes to mpv's software fallback. The VO adds PQ. |
| Profile 7 FEL | `dvh1` as 8.1 (`dvvC` profile 8, EL 0, compatibility 1) | base-layer slices + converted RPUs (mapping made identity) | BT.2020 / PQ / BT.2020 where absent, plus colour space | 7 | If refused, decodes as plain HEVC (base layer, HDR10). Frame side data stays profile 7. |
| Profile 7 MEL | as FEL | base-layer slices + converted RPUs (mapping kept) | as FEL | 7 | |
| Profile 8.1 (compatibility 1) | `dvh1`, `dvvC` | slices + native RPUs | BT.2020 / PQ / BT.2020 where absent | 8 | Retry gives an HDR10 hardware decode. |
| Profile 8.4 (compatibility 4) | `dvh1`, `dvvC` | slices + native RPUs | BT.2020 / HLG / BT.2020 where absent | 8 | Retry gives an HLG hardware decode. |
| Profile 8.2 (compatibility 2) or compatibility 0 | `dvh1`, `dvvC` | slices + native RPUs | BT.2020 / PQ / BT.2020 where absent (hazard D3) | 8 | |
| Dolby Vision in MPEG-TS with compression bits 3 | as its profile | as its profile | as its profile | its profile | Accepted because the bits are written as 0. |
| Dolby Vision without a container record | plain HEVC | slices only | pristine | absent | Plays as HDR10 or HLG from the VUI; RPUs not sent. |
| Profile 4, 9 (AVC), 10 (AV1) | pristine | pristine | pristine | its profile | |
| HDR10 or SDR HEVC without Dolby Vision | plain HEVC | pristine | pristine | absent | |

The "FFmpeg buffer tags" column is superseded by 5.7 and 12.4: every row gets pristine FFmpeg's attachments from the frame's own colour fields (so the tags follow the VUI, and on Apple TV no frame carries a colour space).

### 5.13 libdovi: errors instead of aborts

This is a patch to libdovi 3.3.2 itself (Rust, MIT), not to FFmpeg. Vivid's pipeline builds libdovi from source with it and links that build in place of the prebuilt (8.3, 8.4).

**Why.** Unpatched libdovi 3.3.2 is built to abort the process on any panic, and several kinds of malformed RPU make its parser or writer panic. Two callers in the engine hand it RPUs taken from the media: FFmpeg's profile 7 conversion (5.6), and libplacebo, whose `pl_hdr_metadata_from_dovi_rpu` mpv calls for every frame that carries an RPU buffer from hevcdec, whatever the Dolby Vision profile. So today a malformed RPU in any Dolby Vision title can end the app. blurbery chose to fix this now (deliberate difference 4, 7.3).

**Entry points covered:** exactly those that FFmpeg and libplacebo call: `dovi_parse_unspec62_nalu`, `dovi_rpu_get_error`, `dovi_rpu_get_header`, `dovi_rpu_get_vdr_dm_data`, `dovi_convert_rpu_with_mode`, `dovi_write_unspec62_nalu`, `dovi_data_free`, `dovi_rpu_free`, `dovi_rpu_free_header` and `dovi_rpu_free_vdr_dm_data`. (libplacebo 7.351.0, today's build and the one Vivid's pipeline now builds from source alike (13.5), references the parse, header and display-management queries and the three matching frees.) Other entry points may stay as they are.

**Required behaviour:**

1. For any input bytes of any length, no call to a covered entry point aborts the process, and no panic unwinds across the C boundary. The existing preconditions on pointers stay: callers never pass a null buffer or a foreign pointer.
2. Where unpatched 3.3.2 would abort, the call reports an error through the channel the API already has, and never returns null where the API has always returned an object:
   - parsing always returns an object; on failure it carries the error, whose text `dovi_rpu_get_error` returns, and the header and display-management queries return null for it;
   - conversion returns −1 and records the error; writing returns null and records the error;
   - the header query returns null if it cannot finish, and also whenever the display-management query for the same object would fail although the header says display-management data is present. libplacebo 7.351.0 checks the header for null but reads the display-management result without checking it (seen in its compiled code), so after a header with `vdr_dm_metadata_present_flag` set, that query must never return null;
   - the free functions accept whatever the others returned, null included.
3. Every input on which unpatched 3.3.2 does not abort gives the same result as before: the same success or failure, the same output bytes and the same structures. Error texts stay the same too, except where a check added by the patch fires before an existing error would. The header rule in item 2 is the one exception, in a case neither caller reaches (12.5).
4. Every error text the patch adds is a single line (no line break), contains none of the fault substrings of 2.8, and is otherwise free.
5. Allocation failure ends a Rust program whatever its panic setting, so a count read from the RPU (an extension-block count, a pivot count, a piece count and the like) must be checked against what the rest of the input could hold, or against a fixed limit no valid RPU reaches, before memory is reserved for it. A count that fails the check is a parse error. 12.5 adds a related writing case.
6. How is free: for example, catching a panic at each covered entry point (which needs the library built to unwind rather than abort), removing each panic site, or both. Whatever is chosen must satisfy 1 to 5.

**What "skipped" means for each caller.** In FFmpeg's conversion the RPU is skipped as in 5.6: its NAL is left out of the sample, the frame is still submitted, and the stage and stripped warnings are logged (5.9). In libplacebo the header query returns null, and libplacebo then skips the RPU, so mpv fills nothing from it into the frame's HDR metadata and keeps whatever the stream's other metadata gave; nothing is logged.

**Abort classes known in 3.3.2.** The test corpus (9.4) must hold at least one RPU of each:

- a reshaping mapping-method code of 2 or more;
- the linear-interpolation flag set in a first-order polynomial piece;
- the class FFmpeg's guard already skips (5.6), which unpatched libdovi aborts on when it computes the CRC range;
- a CM v4.0 level 8, 9 or 10 extension block whose length libdovi does not know;
- a very large Exp-Golomb count (the extension-block count, or a pivot or piece count) that overflows a capacity or fails an allocation (which values abort depends on the platform, 12.5);
- when writing, a reshaping curve whose pieces mix the polynomial and MMR methods, in an RPU whose curves the conversion keeps (any profile 7 or 8 header except FEL).

All six have since been confirmed by running unpatched 3.3.2 (12.5). For every class, the tests first show that unpatched 3.3.2 aborts on the corpus entry (in a separate process), so that the corpus really reaches each abort site; if an entry does not abort there, report it to the spec editor (1.4) instead of dropping it. libdovi has other panic sites, such as unchecked unwraps of optional data, and rule 1 covers them all, listed or not.

## 6. Other kept behaviour

### 6.1 mpv: tolerate a short burst of hardware decode errors (`video/decode/vd_lavc.c`)

Pristine `vd_lavc` counts consecutive decode errors while hwdec is in use; when the count reaches `hwdec-software-fallback` (N), hwdec is marked failed and mpv moves to the next hwdec, here software, for the rest of the file; a decoded frame resets the count. Vivid sets N to `yes`, which `OPT_CHOICE` maps to 1, so with pristine mpv a single VideoToolbox error after playback has started would end hardware decoding (and Dolby Vision output) for the title.

Required behaviour:

1. A second counter counts keyframe packets during an error run: when a packet with the keyframe flag is accepted by `avcodec_send_packet` (any return other than `AVERROR(EAGAIN)` or `AVERROR_EOF`, errors included) while hwdec is in use and the consecutive-error counter is above zero, it goes up by one, before that packet's own error, if any, is counted.
2. When an error brings the consecutive counter to N or above: if mpv's existing `hwdec_notified` flag is not set (no frame has been output since the last full decoder reinit, as during initial probing), hwdec is marked failed at once, as pristine does. Otherwise only when at least 2 keyframes have been counted during this run, or the consecutive counter has reached 240.
3. Both counters are reset only by a successfully received frame (which logs, when the run was non-zero, a warning that hardware decoding recovered and how many frames had failed; wording free, prefix `vd`, not consumed) and by tearing down the decoder context. Neither counter is reset by a decoder flush: not by a seek, a decoder reset or the flush for a hwaccel reinit request. A run that spans a seek carries on.
4. The copy-back failure path, which forces the counter close to `INT_MAX`, still fails over at once because it exceeds 240.

What happens after hwdec is marked failed (packet requeue only while probing) is pristine. Upstream mpv does not contain this change.

### 6.2 mpv: output chain after a hard reset (`filters/f_output_chain.c`)

At the end of `mp_output_chain_reset_harder`, after the pristine reset work (including the audio-specific clearing), call `mp_filter_wakeup` on the output chain's own filter. Otherwise a chain reset through `reset_harder` can sit idle, with a request from downstream still pending, until some unrelated wakeup arrives.

`reset_harder` runs on `reload_audio_output` (the `ao-reload` command, an AO reload request such as the AO's fallback or renderer-failure reloads, and audio option changes that reload the output), on mpv's spdif-to-PCM fallback in `reinit_audio_filters_and_output`, and on video's hardware-fallback path. Vivid depends on it after every reload the AO requests: each passthrough fallback (3.4.13) and each renderer-failure or fresh-sink failure reload on bounded tvOS PCM (3.3.3). Upstream mpv does not contain this change.

### 6.3 mpv: recreate the S/PDIF muxer on reset (upstream commit `1388a45`)

Already in Vivid's mpv series as `0001`, unchanged from upstream commit `1388a453950f202a29d1c0346797d730a9710d72` and keeping its upstream attribution; the clean side has nothing to write. Its behaviour, for reference: on decoder reset the spdif muxer is discarded and recreated on the next usable packet; codec parameters (profile, sample rate) probed from the first packet are cached and reused; TrueHD packets are dropped until an access unit with a major sync arrives, with a periodic warning meanwhile. 6.4 uses its cached sample rate.

### 6.4 mpv: E-AC-3 carrier rate (`audio/decode/ad_spdif.c`)

Required, on top of 6.3: when building the muxer for E-AC-3, the carrier sample rate is four times the codec rate cached for the stream, or 4 × 48000 when that rate is unknown. The muxer's stream rate and the output frame format both use it. AC-3 keeps upstream behaviour (carrier = codec rate, 48000 when unknown), the channel count stays 2, and no log line is added. The AO divides the E-AC-3 carrier by 4 (3.4.2), so the two must agree. Upstream mpv does not contain this change.

Background: upstream uses a 192000 Hz carrier for all E-AC-3, which meets the rule above only for streams coded at 48 kHz; with a 44.1 kHz stream, mpv's audio timestamps then run about 9% fast.

### 6.5 mpv: CoreAudio HAL guards for iOS and tvOS

Already covered by Vivid's mpv series `0002` (2.11): it keeps every CoreAudio HAL helper out of iOS and tvOS builds and makes the AO's device list and device selection macOS-only. The clean AO patch keeps those guards and adds only the platform guards listed in 2.11. The required outcome, which the pipeline checks: the iOS and tvOS slices build with `HAVE_COREAUDIO` false and contain no `audio_out_coreaudio` symbol.

### 6.6 FFmpeg: two hevcdec log levels (`libavcodec/hevc/hevcdec.c`)

- The upstream message `Multiple Dolby Vision RPUs found in one AU. Skipping previous.` is logged at `AV_LOG_VERBOSE` instead of `AV_LOG_WARNING`. Parsing is unchanged.
- The upstream message `Skipping NAL unit %d` is logged at `AV_LOG_VERBOSE` instead of `AV_LOG_INFO`. Decoding is unchanged.

The second fires once per skipped NAL, so at least once per profile 7 frame (type 63). At the pristine levels, mpv would deliver these to the app as `warn` and `v` events once or more per frame. Pristine hevcdec's other messages, such as the warning `Error parsing DOVI NAL unit.`, keep their pristine levels.

### 6.7 FFmpeg: Secure Transport without the private identity call

Already in Vivid's FFmpeg series as `0001`, rebased onto pristine n8.0.1. On iOS and tvOS (`HAVE_SECITEMIMPORT` 0) the client-certificate path, which needs the private `SecIdentityCreate`, is compiled out; loading a client certificate then fails with `AVERROR_PATCHWELCOME`, as pristine already does there, and server trust evaluation is unchanged. The pipeline checks `HAVE_SECITEMIMPORT` 0, `--enable-securetransport` and the absence of `_SecIdentityCreate` (8.5).

## 7. Dropped patches, omissions and deliberate differences

### 7.1 Third-party patches not carried over

Everything not listed here is carried over as behaviour: the third-party mpv patches 0004, 0006 to 0009, 0011, 0012 and 0014 to 0024, with Vivid's old audio-driver patch, as sections 3 and 4; mpv 0003 as 6.5 (already covered by Vivid's `0002`); mpv 0025 as 6.1; mpv 0026 as the upstream commit in 6.3 (already Vivid's `0001`); mpv 0027 as 6.4; mpv 0102 as 6.2; FFmpeg 0002 to 0005, 0008, 0009 and 0012 to 0014 as section 5; FFmpeg 0010 and 0015 as 6.6; Vivid's old Secure Transport patch as 6.7 (Vivid's FFmpeg `0001`); and the third-party build's Metal key edit as 5.10 (Vivid's FFmpeg `0002`). The numbering is the third-party pool's.

| Component | Patch | What it did | Evidence for dropping it |
| --- | --- | --- | --- |
| mpv | 0001 | Added a MoltenVK GPU context and a meson option for it. | Vivid uses `vo=avfoundation` only and never sets `gpu-api` or `gpu-context` on iOS or tvOS. Upstream meson rejects the option, so Vivid's build configuration no longer passes it. Vulkan and MoltenVK stay linked for now (`-Dvulkan=enabled`, `-Dvideotoolbox-pl=enabled`), and the pipeline's four green slices show that builds without the patch. |
| mpv | 0002 | Reverted a macOS Swift static-build choice. | Only the macOS Swift build reads it; iOS and tvOS pass `-Dswift-build=disabled`. |
| mpv | 0005 | Made `ao_audiounit` refuse spdif formats. | Vivid sets `ao=avfoundation` with no fallback list, and the subtitle probe uses `ao=null` with `aid=no`, so `ao_audiounit` never initialises. |
| mpv | 0013 | Gated MoltenVK presentation on a hidden layer. | Patched only 0001's context file. |
| mpv | 0201 | Added the option `sub-video-rect-aspect`. | Never set on any branch, a no-op at its default, and `config=no` stops user configuration setting it. The VO never read it. |
| FFmpeg | 0001 | Guarded the OpenGL buffer keys for visionOS and Catalyst. | No effect on iOS or tvOS, and 5.10 removes those keys anyway. |
| FFmpeg | 0011 | Disabled PEM import for Catalyst in the Secure Transport backend. | No effect on iOS or tvOS, where `HAVE_SECITEMIMPORT` is already 0. |
| FFmpeg | 0020 | Sized libavfilter audio frame pools exactly to each request. | Only libavfilter audio graphs reach it; Vivid sets no `af` and no `lavfi-complex`, and mpv's own audio chain does not use libavfilter. Re-evaluate if a loudness or night mode is ever added. |
| libass | 0001 | Opt-in narrow blur kernels, behind a new feature flag. | Opt-in; nothing enables it. |
| libass | 0002 | Parser and rasteriser speed-ups, no API change. | Same output intended; covered by the subtitle device checks (9.5). |
| libass | 0003 | Thread-safe caches, threaded event rendering with a new public threading call, an image pool, opt-in layout and motion caches, and a meson `threads` option. | mpv never calls the new API and the build passes no `threads` option. The patched library did default to rendering on every CPU, so today's app renders ASS multithreaded; upstream renders on one thread. Output should match; speed may not: today's library gives byte-identical output with its threading on and off (13.4). This is a measured device check (9.5), not a behaviour to emulate. |

None of the three third-party libass patches is carried over. The integrated parity check later found that dropping them changes no pixel but costs more on static events, and that today's library also behaves as a later upstream symbol-font change does. libass `0.17.5` is therefore built with two upstream libass changes and Vivid's own patch, which restore today's change reports, pixels and font behaviour without today's patches; rendering stays on one thread (13.4). dav1d is built from upstream `1.5.3` with no patches.

### 7.2 Behaviour omitted from carried-over areas

Each item exists in today's engine but is unreached by Vivid or has no observable effect. Evidence was checked on `main`, on `experiment/vivid-player-bridge` (both bridges) and on `fix/lgpl-media-engine`, through options, run-time properties, commands, gestures, environment variables, schemes and configuration files. Indirect routes are closed: Vivid sets `config=no`, `input-default-bindings=no` and `input-vo-keyboard=no`, and mpv is built with `-Dlua=disabled`, so no configuration file, key binding, on-screen control or script can set an option.

| Omitted | Evidence and what replaces it |
| --- | --- |
| A five-second item-ready deadline in the compressed sink, set when an item is created and by an unpause before rate 1 is requested | Unobservable: a feed step, and with it supervision, follows each of those at once, and before rate 1 every evaluation overwrites the deadline, row 1 with the ordinary grace and row 2 with the initial or ordinary grace (3.4.10). |
| macOS audio paths (a bounded PCM mode for macOS, output-device selection, latency branches for platforms without `AVAudioSession`) | Exist today, unreached, not carried over. Vivid builds no macOS slice; `max-lookahead` exists on tvOS only. |
| `ao_audiounit` spdif refusal | mpv 0005 (7.1). |
| Display-space compositing (`avfoundation-composite-osd=yes`) | Vivid sets `no` on every path and nothing writes `yes`. The option stays registered so `no` is accepted; `yes` is accepted and ignored, the subtitle layer is always created, and the Core Image context is created only when 4.14.7 needs it. |
| The Core Image geometry render for `video-zoom`, `video-pan-x`, `video-pan-y`, `video-scale-x` and `video-scale-y`, and its Dolby Vision exception | Exist today, unreached, not carried over: nothing sets those options and Vivid has no viewer zoom (iOS pinch only cycles gravity). Frames always reach the layer untouched; the options still move separate-layer subtitles through upstream's rectangles (4.15.3). |
| `avfoundation-osd-max-height`, `avfoundation-osd-video-res` | No reference anywhere. Not registered; setting one fails with "option not found". |
| Renderer fallbacks below iOS 17 and tvOS 17 | Vivid requires iOS 18 and tvOS 26. The VO checks availability and, below iOS 17 or tvOS 17, logs an error and fails creation (4.16.2). |
| macOS video branches (an AppKit screen-scale lookup, an autoresizing mask) | No macOS slice. |
| Alternative profile 7 modes selected by a process environment variable | Vivid sets no environment variable on iOS or tvOS (its last writes were removed in commit `d5108a5`). Profile 7 is always converted to 8.1 (5.1). |

### 7.3 Deliberate differences

These four changes are intentional. 12.3 and 13.1 record how item 1 is implemented, and 12.8 and 13.8 list the differences accepted after implementation. Everything else must match today's engine.

**1. Picture in Picture subtitles are blended exactly once per displayed image.**

Today the YUV composite writes into the decoder's own buffer, so when mpv presents the same image again (a redraw while paused, after a subtitle change, after a host resize, or after compositing is switched off) the subtitle is blended again over pixels that already carry it: a heavier subtitle, a stale cue under a new one, or a burned-in cue under the separate-layer subtitle after Picture in Picture ends. This was found by reading the code and has not been seen on a device.

The rewrite must guarantee all of the following; how is the implementer's choice (for example, always compositing into a pool buffer, or keeping the original pixels of the blended region so they can be restored first):

- every sample enqueued while compositing is on shows the decoded picture with the current subtitle blended exactly once, by the arithmetic of 4.14.7, with no trace of any earlier cue;
- every sample enqueued while compositing is off shows the decoded picture with no burned-in subtitle;
- the sample keeps the frame's coded size;
- for hardware frames, the composited sample carries exactly the attachments the decoder's buffer would carry after 4.5 and 4.4, with the same modes, including `DolbyVisionRPUData` when present and the transfer repair. This also covers a composite copy, which today misses the repair in the rare case where the decoder's buffer cannot be locked;
- the Core Image fallback is unchanged;
- a buffer that may be on screen is written only as 4.14.9 and 13.1 say: never when compositing switches off, and on a same-buffer redraw only row by row from a composite built elsewhere;
- a copy's buffer comes from a pool with the attributes of 4.3, covered by the 60-flip maintenance (no copy is made since 12.3).

**2. The hardware device list is freed at teardown.** Today the VO removes its VideoToolbox entry but never frees the list. The rewrite destroys the list after removing the entry and releasing the device reference (4.16.5), as upstream's other hardware-device VOs do. `uninit_video_out` tears the decoder down before `vo_destroy`, and FFmpeg's frames hold their own references to the device.

**3. Every subtitle object is drawn.** Today, when more than one OSD object has content in the same frame (in Vivid, a primary and a secondary subtitle shown together), the VO treats each object as a complete replacement of the last, so only the secondary subtitle is visible, in both subtitle modes, and both objects are re-rendered (and on the separate layer re-enqueued) on every frame. blurbery chose to show both. The rewrite draws all objects with content into one canvas, in mpv's object order, later objects over earlier ones, in the separate layer and in the Picture in Picture composite alike, with one bounding box and one subtitle sample per change (4.14.4, 4.14.5). It re-renders only when the set of objects or one of their `change_id` values changes, apart from the change-tracking resets in 4.9, 4.11, 4.13 and 4.14.3. When exactly one object has content, the output must be identical to today's.

Two consequences, both accepted:

- Today, when one object's cue ends on the same frame that another object's cue starts and the two carry an equal `change_id`, the new cue is skipped and the old one stays visible until something else changes. The rewrite, which also compares `render_index`, renders the new cue. This is a harmless fix.
- In the Picture in Picture composite, two cues far apart (a primary at the top and a secondary at the bottom) make the union bounding box, and so the YUV blend rectangle, cover most of the frame: measured on a Mac, about 3.2 ms per 4K frame instead of about 0.5 ms for one cue, with identical output. The implementation may instead blend only within each object's own mapped rectangle, computed from that object's parts as 4.14.7 computes the blend rectangle, provided every sample is identical to blending the union. Device check 44 measures this.

**4. No RPU can make libdovi abort the app.** Unpatched libdovi 3.3.2 aborts the process on any panic, and several kinds of malformed RPU make it panic, both in FFmpeg's profile 7 conversion and in libplacebo, which mpv calls with every RPU hevcdec exports, for any Dolby Vision profile (5.13). Today such an RPU ends the app. blurbery chose to fix this now, in two parts:

- FFmpeg keeps an exact guard for zero-filled or truncated profile 7 RPUs: one that, after its header, emulation-prevention bytes and trailing zero bytes are removed, holds 5 bytes or fewer is skipped as a parse failure without calling libdovi (5.6).
- Vivid's pipeline builds libdovi 3.3.2 from source with a Vivid-owned patch that makes every entry point FFmpeg and libplacebo use return an error instead of aborting, for any input (5.13).

So every RPU that libdovi cannot parse, convert or write is skipped. On the conversion path the frame goes to VideoToolbox without it, after the stage and stripped warnings (5.6, 5.9). On libplacebo's path, mpv takes nothing from it into the frame's HDR metadata, silently. Every RPU on which today's libdovi does not abort, including every malformed RPU it rejects without aborting, is handled exactly as today, apart from the libdovi error text that 5.13 allows to change in a stage warning.

### 7.4 Differences already in Vivid's series and build

Vivid's existing series and pipeline already differ from today's engine in ways nothing in Vivid reads. They are accepted; the clean patches neither add nor undo them:

| Difference | Effect |
| --- | --- |
| The AO has no `list_devs` on iOS and tvOS (mpv `0002`) | `audio-device-list` also lists the driver itself, as `avfoundation`: today it holds `auto` and `audiounit`, and with `0002` it holds `avfoundation` as well. Vivid never reads it and never sets `audio-device`, so the difference is harmless. |
| Version strings | FFmpeg reports `8.0.1` instead of `n8.0.1`, and mpv `v0.41.0` instead of `v0.41.0-dirty`. Vivid reads neither. |
| FFmpeg components | No `delogo` filter (GPL-only), and no `whip` muxer or `dtls`, `ffrtmpcrypt`, `rtmpe` and `rtmpte` protocols (they need OpenSSL). Vivid uses none of them. |
| Slices | arm64 only; the tvOS device slice is `tvos-arm64`, not arm64 plus arm64e. |
| libdovi linking | Resolved: FFmpeg has been given libdovi again since the Dolby Vision patch landed, and its libdovi references equal today's (8.4, 13.3). |
| The eleven libraries of 8.3 | Built from upstream source with Xcode 26.6 instead of today's older toolchain; the differences are accepted in 13.5. |

## 8. Build and CI provenance

### 8.1 Scope and who does the work

Vivid's engine pipeline (`engine/lucid.py`, `engine/pins.ini`, `engine/config/`, `engine/patches/`, `.github/workflows/lucid-engine.yml`, described in `docs/cores/lucid-engine-build.md`) already builds every slice from pinned upstream sources plus Vivid's series and checks the result. Clean implementers may read and change it. What this section asks for is the configuration and checks that must arrive with the new patches.

Retiring the old workflows and scripts that embed or extract the old engine's source (`.github/workflows/mpv-audio-driver.yml`, `scripts/tests/compressed-audio-recovery-tests.py`) needs someone who may read them: the dirty side or blurbery (11.2).

### 8.2 Series

Each library's `engine/patches/<library>/series` lists its patches in order, one line per patch with the patch's SHA-256 and file name. The pipeline applies them in order with `patch -p1` and zero fuzz, refuses a patch whose hash differs, and fails if the files a series changes differ from the files its patches name. Each new patch is written against the tree the series before it produces, and is added to the end of its series with its hash.

The series as they stand once the integration, the libass work and the library work are merged into the pipeline branch (13):

| Library | In the series now | To add |
| --- | --- | --- |
| mpv `v0.41.0` | `0001` upstream `1388a45` (6.3); `0002` build for iOS and tvOS, including mpv's CoreFoundation string helpers since `546e11f` (2.11, 6.5); `0010` the E-AC-3 carrier rate (6.4); `0011` the output-chain wake (6.2); `0012` to `0016` the AO (section 3); `0020` to `0025` the VO (section 4), `0025` with its meson option and `vo.c` registration; `0040` the hardware decode error tolerance (6.1) | nothing |
| FFmpeg `n8.0.1` | `0001` Secure Transport without the private identity call (6.7); `0002` Metal-compatible VideoToolbox buffers (5.10); `0010` the explicit sample size (5.5 item 3); `0011` the Dolby Vision VideoToolbox work (section 5); `0012` the hevcdec log levels (6.6) | nothing |
| libass `0.17.5` | `0001` upstream commit `057a5334`; `0002` upstream pull request #951 at `f96a521`; `0010` Vivid's own (13.4) | nothing |
| dav1d `1.5.3` | empty | nothing |
| libdovi `3.3.2` | `0001`, the patch of 5.13, built from source (12.6) | nothing |
| libbluray `1.4.0` | `0001` Vivid's own (13.5) | nothing |
| uavs3d `1.2` | `0001` Vivid's own (13.5) | nothing |
| FreeType, FriBidi, HarfBuzz, libunibreak, Little CMS, shaderc, MoltenVK, libplacebo, uchardet | empty | nothing |

The split of the new work into patch files, and their order within the "to add" column, are the implementer's choice, as long as each applies with zero fuzz in series order.

### 8.3 Inputs and what is built

- Sources come from the release archives pinned in `engine/pins.ini` (URL, version, embedded commit and SHA-256), and `lucid.py fetch` refuses a file whose hash differs. Every source tree is extracted fresh for each build; only the hash-checked downloads are cached between runs.
- Built from source for each of the four slices, with Xcode 26.6:
  - dav1d, libass, FFmpeg (seven libraries), libmpv and libdovi, at minimum OS 14.0 (libdovi's Rust standard library objects as 12.6 says), as eleven static frameworks (`Libdav1d`, `Libass`, `Libmpv`, `Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample`, `Libswscale`, `Libdovi`);
  - the other eleven libraries in the table below, which today come from the previous third-party build of these libraries, at today's versions, options and per-library deployment targets (13.5), as ten more static frameworks (`Libfreetype`, `Libfribidi`, `Libharfbuzz`, `Libunibreak`, `lcms2`, `Libuavs3d`, `Libbluray`, `Libuchardet`, `Libshaderc_combined`, `Libplacebo`) and MoltenVK's bare static library, `libMoltenVK.a`, as today.
- No library comes as a prebuilt binary any more, apart from the Rust standard library inside libdovi, from the Rust project's pinned `rust-std` archives.

| Library | Version | Licence | Notes |
| --- | --- | --- | --- |
| FreeType, FriBidi, HarfBuzz, libunibreak | 2.12.1, 1.0.12, 8.1.1, 6.1 | FTL, LGPL-2.1-or-later, MIT, Zlib | libass dependencies; unpatched |
| libplacebo | 7.351.0 | LGPL-2.1-or-later | mpv dependency, with its five submodules; requires libdovi; unpatched |
| Little CMS (lcms2) | 2.17 | MIT | unpatched |
| libdovi | 3.3.2 | MIT | used by libplacebo and by the profile 7 conversion (5.6); Vivid's patch (5.13, 12.6) |
| MoltenVK | 1.4.1 | Apache-2.0 (its parts include cereal, BSD-3-Clause, and Vulkan-Headers, Apache-2.0 or MIT) | linked because Vulkan stays enabled; unpatched |
| shaderc | 2025.5 | Apache-2.0 (glslang BSD-3-Clause and others; SPIRV-Headers MIT) | with glslang, SPIRV-Tools and SPIRV-Headers; unpatched |
| uavs3d | 1.2 | BSD-3-Clause | Vivid's patch `0001` (13.5) |
| libbluray | 1.4.0, with libudfread 1.2.0 | LGPL-2.1-or-later | Vivid's patch `0001` (13.5) |
| uchardet | 0.0.8 | LGPL-2.1-or-later (MPL-1.1, GPL-2.0-or-later or LGPL-2.1-or-later) | unpatched |

Nothing links OpenSSL any more: FFmpeg uses Secure Transport.

### 8.4 Configuration changes that land with the patches

All of these have landed (13.3); they stay listed as the record of what came with each patch.

- **With the VO patch:** add `-Dvo-avfoundation=enabled` to `engine/config/mpv-meson.txt`, and `vo-avfoundation` to `engine/config/expected-mpv-features.txt`. The VO uses Core Image (4.14.7), which `engine/config/app-link.txt` does not list, so add `CoreImage` there too, plus any other framework the symbol closure check (8.5) then reports; otherwise the closure and test-link checks fail.
- **With the Dolby Vision patch:** pass libdovi's include path and `-ldovi` to FFmpeg through its compiler and linker flags again (libdovi is already staged for libplacebo), and record those flags in the provenance report.
- **With the libdovi patch (5.13):** replace `[prebuilt:libdovi]` in `engine/pins.ini` with a source entry for the `libdovi-3.3.2` release archive of `quietvoid/dovi_tool` (URL, embedded commit `4fd2b2235c9f93582dd4a00e65ee34a07800afd7` and SHA-256), and add `engine/patches/libdovi/series` with the patch. Pin the Rust toolchain version and every crate dependency: use the lock file in the archive's `dolby_vision` folder, fetch each crate by checksum, and resolve nothing at build time. Build libdovi's C API as a static library for the four slices; if the pinned toolchain ships no standard library for the tvOS targets, build that from source with the same toolchain (the stable toolchain chosen ships one, 12.6). Keep the public header and the pkg-config name unchanged, and stage the result where the prebuilt was, so that libplacebo's pkg-config requirement and FFmpeg's flags find it. Record the source and patch hashes and the toolchain in the provenance report. Then bring the checks into line: the framework-set check expects `Libdovi` as an eleventh framework, libdovi leaves the prebuilt set that is staged and passed to the test link, and the fetch allowlist (`FETCH_ALLOWED` in `lucid.py`, enforced by `lucid.py check-allowlist`) gains the libdovi source project and the hosts the pinned Rust toolchain and crates come from, each still fetched only through `lucid.py` with its SHA-256.
- Nothing else in the configuration changes: the FFmpeg configure line, its expected components and switches, and the libass and dav1d options stay as they are. The libass series (13.4) and the configuration of the eleven libraries built from source (13.5) came later.

### 8.5 Checks the pipeline already makes

`lucid.py check` already verifies, for every slice:

- **Inputs and trees:** archive hashes and embedded commits match `pins.ini`; the applied patches match the series; each source tree was not changed by the build and equals a fresh extraction of the pristine archive with the series applied again.
- **Form:** exactly the frameworks built, now 21 with libdovi and ten of the eleven libraries of 8.3 built from source, plus MoltenVK as a bare static library (8.4, 12.6, 13.5); arm64 only; the slice's platform and minimum OS (14.0 for Vivid's own libraries, each of the eleven libraries' own as today, 13.5); the Info.plist values and module maps; FFmpeg's header counts.
- **The eleven libraries of 8.3** (13.5): each against what today's build of it ships: form, minimum OS, Info.plist, module map and headers; defined global symbols by visibility; weak definitions and imports, with the recorded toolchain differences; pkg-config files; the configuration read back; and the per-library facts that decide output.
- **FFmpeg:** the configuration in `config.h` and the string `avformat_configuration()` returns both equal the configured arguments; they contain `--enable-securetransport` and none of `--enable-gpl`, `--enable-version3`, `--enable-openssl`, `--enable-nonfree` or `delogo`; every library's licence string is `LGPL version 2.1 or later`; the expected `CONFIG_*` switches are on or off, and `HAVE_SECITEMIMPORT` is 0; the enabled components and the filter registry symbols match exactly.
- **Symbols:** no OpenSSL symbols; no reference to `_SecIdentityCreate`; no `delogo` filter; `Libavformat` defines `_avformat_configuration`; `Libavcodec` references `_kCVPixelBufferMetalCompatibilityKey` and neither OpenGL compatibility key.
- **mpv:** the recorded meson options; `-Dgpl=false` and no `-Dgpl=true` in the binary; the feature list matches `expected-mpv-features.txt` exactly (so `coreaudio` is absent and `macos-11-3-features` and `macos-12-features` are present, 2.11); the binary contains the text of `0001`; client API version 2.5 with the four expected headers.
- **libass and dav1d:** versions 0.17.5 and API 7.0.0, both with their arm64 assembly.
- **Linkability** (since `ad498b4`, green on all four slices): a symbol closure in which every undefined symbol in every built archive is defined by another archive in the link set, by the compiler runtime, or by a public `.tbd` stub in the slice's SDK. Only `___dso_handle` and the Objective-C selector stubs (`_objc_msgSend$<selector>`), which the linker synthesises, are exempt, and compiler-runtime symbols count as defined. Every SDK symbol must come from a framework or library in `engine/config/app-link.txt`, following re-exports, or from libSystem or libobjc. Then a dead-stripped test link, without forced whole-archive loading, of a small C program that calls `mpv_create`, `mpv_initialize`, `mpv_terminate_destroy` and `avformat_configuration`, against the built frameworks, MoltenVK's library and `app-link.txt`, at Vivid's own deployment targets (iOS 18.0, tvOS 26.0). A forced whole-archive link would not be a usable check: FFmpeg compiles its Vulkan helpers into three libraries, so such a link fails on duplicate symbols, as today's binaries do too. This is the check that would have caught the earlier `0002` link failure (2.11).
- **Notification name:** Libmpv contains the format `notification name: %s` (2.9).

Each check that looks at a binary first finds it (the framework-set check fails on a missing framework), and the uploads fail when files are missing.

### 8.6 Checks to add

All six are now in place: items 1 to 4 as per-slice checks, and items 5 and 6 as test steps and jobs of the pipeline (the video output tests once per run, in the `ios-arm64-simulator` job; the libdovi corpus in its own host job), all passing (13.3).

1. **All 25 frozen log formats.** Every exact format string in the 2.9 table appears verbatim in every slice's Libmpv, searched together with its trailing newline (each format ends in one in the source, as mpv's log calls expect). For the standalone `falling back to PCM`, also require a NUL byte straight before it: three other frozen formats end with the same text, so without that anchor the check would still pass if the separate line were dropped or merged into the rejection line. Validate the check once against a slice that contains the AO, and once against a binary that lacks the standalone line, which it must reject.
2. **The remaining binary markers** of 2.10 in every slice's Libmpv: `manage-audio-session` followed by a NUL byte, `compressed-anchor-start` followed by a NUL byte, and `compressed-lead`. Also `max-lookahead` followed by a NUL byte in both tvOS slices and absent from both iOS slices (2.2).
3. **AO behaviour compiled in:** every slice's Libmpv references `_AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification` and contains the selector names `setDelaysRateChangeUntilHasSufficientMediaData:` and `setSupportsMultichannelContent:error:`.
4. **libdovi re-enabled with the Dolby Vision patch:** every slice's `Libavcodec` has undefined references to `_dovi_parse_unspec62_nalu`, `_dovi_convert_rpu_with_mode` and `_dovi_write_unspec62_nalu`, and to `_kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata` and `_kVTDecompressionPropertyKey_GeneratePerFrameHDRDisplayMetadata` (pristine FFmpeg references none of them).
5. **Tests from the patched trees:** the audio and video tests of section 10 compile against the mpv tree the pipeline has just patched; the decoder tests of 9.4 (the libdovi guard vectors, the 24-byte configuration record tests and the profile 7 conversion test) compile against the patched FFmpeg tree; the libdovi tests (item 6) use the patched libdovi build. Each runs as a pipeline step on the build host and fails when no vector ran.
6. **libdovi never aborts** (5.13): the malformed-RPU corpus of 9.4 goes through every covered entry point of the patched libdovi, built from the same patched tree for the build host, in the order each caller uses them. The step fails on any abort or crash, on any vector that does not give its expected result, and when no vector ran. The unpatched build of the same pinned source runs the parity vectors alongside, and runs each abort-class entry in a separate process to show that it does abort there.

### 8.7 Install, package and the old workflows

> [!NOTE]
> **Status:** the app pins release `0.1.0` of `blurbery/lucid-engine`, which serves all 21 frameworks and MoltenVK's library. The install script and the old audio-driver and experiment workflows have been removed, and `scripts/ci/check-engine-package-pin.py` checks the pin. The requirements below are kept as written.

- The pipeline's packaging job already publishes `<Name>.xcframework.zip` for each of the 21 frameworks and for MoltenVK's library (13.5) with a `SHA256SUMS` file (also the SwiftPM checksums) and each slice's provenance report; artefacts are kept for 3 days.
- The Swift package that serves these builds is `blurbery/lucid-engine`, and Vivid's app links its release `0.1.0` (13.5). It must serve every framework the pipeline builds, all 21 and MoltenVK's library, `Libass` and `Libdav1d` included. If the install script is kept rather than retired, it must be updated for the pipeline's slice names and artefacts, install the same set, and its `verify` must check each installed binary against `SHA256SUMS` and the provenance reports.
- `scripts/release/use-patched-libmpv.sh` today expects the old artefact (`mpv-<platform>-audio-driver`, slices `ios-arm64` and `tvos-arm64_arm64e`) and searches the 30 newest successful runs of the old workflow. On `main` and `experiment/vivid-player-bridge` it replaces Libmpv alone; on `fix/lgpl-media-engine`, Libmpv and the seven FFmpeg frameworks (eight in all). It never replaces Libass or Libdav1d, so an install that followed its pattern would leave the app linking the third-party threaded libass and its dav1d, with no visible error.
- Wherever the app does not yet link the package (on `main`, for example), simulator builds, the player-regression tests and the experiment tests run the old engine, which rejects `ao-avfoundation-manage-audio-session` on every load (a console line only) and manages the audio session itself. Simulator checks prove nothing about the rewrite there.
- The old audio-driver workflow and its harness are retired when the new AO lands, and `mpv-experiment.yml`'s checks move to the new package (its SwiftPM pin check then compares against the new package instead of the third-party one).

### 8.8 Switch-over notes

What changes for Vivid's other code when the app first links the pipeline's builds. The app now links them through release `0.1.0`; the install script was removed rather than updated.

- **Install script.** `scripts/release/use-patched-libmpv.sh` must install every framework the pipeline builds (8.7), not Libmpv alone, and must use the pipeline's slice identifiers, `ios-arm64` (unchanged), `tvos-arm64` (instead of `tvos-arm64_arm64e`), `ios-arm64-simulator` and `tvos-arm64-simulator`, and the new package's artefact path instead of the previous third-party package's folder under `SourcePackages/artifacts/`. Its marker checks (2.10) pass only once the AO patch is in the series, because `first start recovery after` and `trace edge %s` come from the new AO.
- **Options.** Vivid's `ao-avfoundation-*` options, `audio-spdif` passthrough and the `avfoundation-*` video options work only once the AO and VO patches are in the series; before that, mpv rejects the options (a console line each) and the stock AO refuses spdif formats. Before the VO patch, `vo=avfoundation` is accepted but skipped as an unknown driver, because mpv does not check its video output list for unknown names; mpv then autoprobes its other outputs and plays with no picture. Before the AO patch, upstream's AO sets the session category and mode, activates the shared session, and deactivates it itself on teardown and after a failed `init`.
- **GPU context.** No iOS or tvOS build sets `gpu-context` today (1.7). The new engine rejects `gpu-context=moltenvk`; the bridge must not start setting it, and the engine must not accept it as a no-op. This has no effect with `vo=avfoundation`.
- **TLS.** `LucidTLS` works unchanged: the configuration string has `--enable-securetransport` and `avformat_configuration` is exported.

### 8.9 Licence notes to update

Done when the app moved to release `0.1.0`. Update `THIRD_PARTY_NOTICES.md`, `iosApp/Resources/OpenSourceLicenses/README.txt` and `docs/cores/player-engine.md` once the app links the pipeline's builds: the engine patches are Vivid-owned LGPL-2.1-or-later (plus the upstream cherry-pick), libdovi is built from source with Vivid's patch under its MIT licence (unless blurbery decides otherwise, 11.2), libass carries two upstream changes and Vivid's ISC patch (13.4), dav1d is built unpatched, the eleven libraries of 8.3 are built from upstream source with their parts and licences, two of them with Vivid's own patches under their libraries' licences (13.5), and OpenSSL is gone.

## 9. Constants, parity hazards, tests and device checklist

### 9.1 Constants

**Audio output**

| What | Value |
| --- | --- |
| PCM read size per feed | `samplerate / 10` frames (100 ms) |
| PCM `ao->device_buffer` | 2 s of frames |
| PCM enqueued end at AO creation | 0 (−1 ns after an unbounded `start`, a bounded `reset` or a fresh sink) |
| Compressed read size | `samplerate / 10` carrier frames (100 ms), limited by the carry-over buffer's free room |
| Compressed `ao->device_buffer` | `compressed-buffer` seconds of carrier frames, truncated (default 2, range 0.5 to 2, Vivid AirPlay 1.25) |
| Compressed feed timer | first fire 50 ms after arming, period 50 ms, leeway 25 ms |
| Maximum reads per fill pass | 64 |
| Steady lead | `compressed-lead`, default 8 s, range 1 to 30 |
| Start-up lead (feed position at 0) | 2 × the steady lead (16 s by default) |
| Priming before rate 1 | fed duration of at least 1 s, or end of file |
| Prefetch reserve (both sinks) | 1 s |
| Backpressure (filling and anchoring) | the window's free space must be at least the whole carry-over buffer's size |
| Ordinary grace | `compressed-start-grace`, default 2 s, range 1 to 30, Vivid AirPlay 1 |
| Initial grace | the smaller of `compressed-first-start-grace` (default 2, range 0 to 30, Vivid AirPlay 0.25) and the ordinary grace |
| Anchor pacing | at least 100 ms between anchor reads |
| Start anchoring cap | fed duration below the start-up lead plus 4 s |
| Resume anchoring cap | less than 2 s after the unpause |
| History kept below the low-water mark | 2 MiB (2097152 bytes) |
| Stream window size | 2 MiB + 1 MiB + 2 × lead × 786432 bytes (15728640 at 8 s) |
| Carry-over buffer size | 100 ms of carrier bytes + 4 burst sizes |
| Lost-sync threshold | more than 3 burst sizes left after trimming (unreachable today) |
| IEC 61937 preamble | 0x72 0xF8 0x1F 0x4E; 8-byte header; data type = byte 4 & 0x7F; Pd = bytes 6 and 7, little-endian |
| Data types | AC-3 0x01, E-AC-3 0x15 |
| Burst sizes | AC-3 6144 bytes, E-AC-3 24576 bytes |
| Payload length | AC-3 Pd ÷ 8 rounded down, E-AC-3 Pd; at least 8, at most burst size − 8, both inclusive |
| Frames per burst at the codec rate | 1536 |
| AC-3 syncword after the byte swap | 0x0B 0x77 |
| E-AC-3 carrier rate | 4 × the codec rate (48000 assumed when unknown) |
| Synthetic content length | `INT32_MAX` (2147483647) |
| Loader errors | below the window: POSIX `ESPIPE`; past the write head: POSIX `ENOTSUP`; teardown: `NSURLErrorCancelled` |
| Compressed volume | mpv's value ÷ 100 onto the player's `volume` |
| tvOS PCM bound | none while `max-lookahead` is 0 (its default; range 0 to 10); otherwise the larger of `max-lookahead` (Vivid AirPlay 4) and `audio-buffer` (default 0.2) |
| tvOS PCM timer | fires at once when feeding turns on, then every 50 ms, leeway 5 ms; up to 4 reads per tick |
| PCM transport line cadence | every 2 s; every 250 ms inside the detail window; measured from mpv's clock origin after `init` and after a fresh sink |
| Heartbeat | the never-reset feed-step counter is a multiple of 100, or of 5 inside the detail window |
| Detail window | 8 s after each trace edge |
| Frames to nanoseconds | CoreMedia default rounding at a nanosecond timescale |
| Session calls | category Playback, mode MoviePlayback, multichannel YES from iOS and tvOS 15, activate with options 0, deactivate with `AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation` |
| Availability floors | delayed rate change off from iOS and tvOS 14.5; output-configuration notification and multichannel declaration from iOS and tvOS 15; `hasSufficientMediaDataForReliablePlaybackStart` from tvOS 14.5 |
| AO queue | serial, quality of service user-interactive |

**Video output**

| What | Value |
| --- | --- |
| Driver, option prefix and hardware-device driver name | `avfoundation` |
| `wid` "no layer" value | −1 (creation fails) |
| Queue lead | 128 ms default, range 0 to 1000; `vo_set_queue_params` requested future frames 1 |
| Default presentation mode | `host` on tvOS builds, `media` otherwise |
| CMTime timescale for every sample and timebase time | 1,000,000,000 (nanoseconds) |
| Media seconds to nanoseconds | `pts` × 10⁹ plus 0.5 (minus 0.5 when negative) as one fused multiply-add, truncated towards zero; finite values outside the int64 range saturate (12.2) |
| Timebase reading | `CMTimeConvertScale` to nanoseconds with `kCMTimeRoundingMethod_Default`; not numeric reads as 0 |
| Servo projection | (target − now) × applied rate in double precision, truncated towards zero |
| Frame duration | display-synced `ideal_frame_duration` × 10⁹ truncated, when `ideal_frame_duration` is positive (a truncated 0 is unusable, 12.2); otherwise `vo_frame.duration` rounded to nearest, ties to even |
| Re-anchor threshold | phase error above 50 ms |
| Servo horizon *H*, integral time *Ti*, limit *L* | 2 s, 8 s, ±0.015 (on *P*, the integral and their sum) |
| Smallest rate change written | above 0.0001 × nominal (100 ppm) |
| Minimum time between rate writes | 200 ms (also measured from an anchor) |
| Largest integrated servo step | 500 ms |
| Estimator averaging window | 500 ms of frame duration |
| Accepted playback rate range | 0.05 to 8.0 |
| Nominal-rate change threshold | above 1% of nominal |
| Fast-path threshold and sample count | above 4%, 2 samples |
| Frame-duration step that restarts estimation | above max(250 µs, previous duration div 100) |
| Readiness give-up | 4 ms before the target, inclusive (a frame is dropped once now is at or past it); poll every 1 ms |
| Recovery throttle | 500 ms |
| Not-ready run reset gap and enqueue staleness | 500 ms each |
| Not-ready run that tries recovery | 3 or more, on every drop |
| Pacing summary window | 5 s |
| Maintenance interval | every 60 flips |
| Dirty-tracking idle age; tracked surfaces | 2 s; 4 |
| Pool minimum buffer count; maximum buffer age | 3; 1.0 s |
| Pool buffer attributes | Metal compatible, IOSurface-backed |
| Subtitle performance summary | at least 32 renders, or at least 1 render and 300 frames, and at teardown |
| Slow-render log | above 8 ms, at most once per second |
| Upload shifts | left 6 bits (10-bit), left 4 bits (12-bit) |
| libass blend divisor and bias | 65025, 32512 |
| BGRA blend divisor and bias | 255, 127 |
| *Kr*/*Kb* | BT.709 (default) 0.2126/0.0722; BT.2020 0.2627/0.0593; BT.601 0.299/0.114 |
| YUV blend *Yoff*/*Yrange*/*Ccentre*/*Crange* | 8-bit video 16/219/128/224; 8-bit full 0/255/128/255; 10-bit video 64/876/512/896; 10-bit full 0/1023/512/1023 |
| YUV composite arithmetic | double precision, with the fused multiply-adds and evaluation order of 4.14.7 |
| Host layer pixel size | max(1, truncated fused multiply-add of size × scale + 0.5) (2.5) |
| Blend rectangle slack | 1 pixel on each side |
| Dolby Vision attachment key | `DolbyVisionRPUData` |
| Formats | uploads `420v` and `x420`; subtitles `32BGRA`; Core Image composite output `64RGBAHalf` (`x420` and `xf20` sources only, 12.3) or `32BGRA` |

**Dolby Vision and FFmpeg**

| What | Value |
| --- | --- |
| Dolby Vision session codec type | `'dvh1'` (`kCMVideoCodecType_DolbyVisionHEVC`) |
| Configuration record | 24 bytes; bytes 5 to 23 zero; compression and reserved bits 0; presence flags 0 or 1; compatibility id 4 bits |
| Atom key | `dvvC` when the effective profile is above 7, else `dvcC` |
| Converted profile 7 record | profile 8, EL flag 0, compatibility id 1, other fields from the source |
| Profiles with a native session | 5, 7 (converted), 8, each needing the RPU and BL flags |
| HLG base | profile 8 with compatibility id 4 |
| RPU selection | NAL type 62 (`HEVC_NAL_UNSPEC62`) alone, more than 2 bytes escaped with header; libdovi's output begins `0x7C 0x01` |
| Enhancement-layer NAL type | 63 (`HEVC_NAL_UNSPEC63`) |
| libdovi guard (7.3) | at least 25 bytes, starting 0x7C 0x01 0x19 0x08 0x09, and 5 or fewer bytes left after removing the header, emulation-prevention bytes and trailing zeros |
| Sample NAL framing | 4-byte big-endian length prefix (pristine) |
| libdovi version and mode | 3.3.2, mode 2 ("To81") |
| libdovi build | 3.3.2 from source with Vivid's patch: errors instead of aborts in the ten entry points FFmpeg and libplacebo use (5.13) |
| Per-frame HDR metadata OS floors | propagate: iOS and tvOS 14; generate: iOS and tvOS 17 |
| `CVBufferCopyAttachments` floor | iOS and tvOS 15; no longer needed by section 5, whose frame output is pristine (5.7, 12.4) |
| Session retry trigger | any non-zero create status, `dvh1`, HDR-compatible base |
| hevcdec message levels (6.6) | `AV_LOG_VERBOSE` for both |
| Hardware decode error tolerance (6.1) | 2 keyframes, or 240 consecutive errors; not reset by flushes |
| Vivid `hwdec-software-fallback` | `yes`, which is 1 |

### 9.2 Parity hazards

**Audio**

- A1. mpv's clock must come from the item's timebase, with `currentTime` only as the fallback, and pacing must use the later of the two readings (3.4.8).
- A2. mpv's end time must be built from consumed carrier frames minus dropped duration, never from the fed duration (3.4.8); otherwise video shows small skips and holds.
- A3. Any data returned for an offset beyond the write head corrupts audio later in the title (3.4.4).
- A4. A default lead below 8 s brings back the periodic dropouts in tvOS E-AC-3 passthrough. The start-up target factor also sets the anchoring cap.
- A5. Rate 1 is requested without waiting for item readiness, and `automaticallyWaitsToMinimizeStalling` stays NO (3.4.3, 3.4.10).
- A6. `allowsExternalPlayback` must stay NO.
- A7. Each reset ends its item; the next start always makes a new one from byte 0 and time 0.
- A8. The passthrough block is per format, process-wide, and cleared at the start of every PCM `init` (3.2.3).
- A9. Every level in 2.9 is frozen; the rejection's two lines stay separate; no unconsumed line may contain a fault substring.
- A10. With `manage-audio-session` off, no activation or deactivation at all, but still the multichannel declaration and the preferred channel count (3.2.4).
- A11. In passthrough, `init` must not change the rate, format or channels.
- A12. The E-AC-3 carrier change (6.4) and the AO's divide-by-4 must agree.
- A13. The prefetch guard (3.4.9) must be applied in both sinks, before mpv is asked for data.
- A14. In compressed `start`, the end-of-file state is cleared before anything reads from mpv (3.4.12).
- A15. On bounded tvOS, nothing reaches the renderer while a fresh sink is pending, and notifications from a replaced renderer are ignored (3.3.3).
- A16. Rounding as in 3.4.8: per-burst durations rounded once and accumulated; the written duration converted from the frame total each time.
- A17. Both `HAVE_MACOS_*` feature groups must be on in the shipped slices (2.11, 8.5).
- A18. The heartbeat counter counts every feed step that runs, not only timer ticks, and not the steps that do nothing (3.4.15).
- A19. Initial-start mode survives resets before the first engagement and ends only at engagement.
- A20. Timer leeways are 25 ms (compressed) and 5 ms (tvOS PCM).
- A21. `max-lookahead` must not exist on iOS, and 0 means unbounded on tvOS whatever `audio-buffer` says.
- A22. The rate-1 time is set once per item and never moved by an unpause (3.4.3).
- A23. Lost sync and window overflow stay where 3.4.5 puts them, unreachable; garbage is discarded silently.
- A24. Burst tests run in the order type, length, completeness, and the AC-3 length rounds down (3.4.5).
- A25. Nothing beyond 3.4.3's list is configured on the player, asset, item or content-information request, and the item keeps AVFoundation's default automatically loaded keys (`duration`) (12.1).
- A26. Crossing 1x replaces the AO only on an AC-3 or E-AC-3 track. On a decoded track the same AO carries on through mpv's decoder rebuild, with no `reset`, no fresh sink and no `start-fresh` (1.7, 3.1).
- A27. A rejection ends the feed step before resume detection; only a fallback raised by a read in the same step leaves resume detection running (3.4.7).
- A28. The anchor pacing time starts at mpv's clock origin, the time 0, never at a minimum-value sentinel (3.4.3).

**Video**

- V1. The accepted format set (4.1) decides mpv's conversion chain and `video-out-params`.
- V2. `caps` 0 and the unimplemented hooks (2.6) keep `display-fps`, `vo-delayed-frame-count`, `frame-drop-count` and the filter chain as they are.
- V3. Hardware frames keep their decoder's tags; the VO never tags them from mpv's parameters (4.2).
- V4. Dolby Vision: the exact `DolbyVisionRPUData` key; repair only a missing transfer, after the pixel-aspect step, from the image's own parameters; primaries and matrix untouched (4.4).
- V5. Host mode uses mpv's target host time on a timebase seeded from `mp_time_ns()` at rate 1 and never anchors; media mode follows 4.8.2 exactly, including an anchor while paused storing a nominal rate of 0, read as 1.0 until the estimator adopts a rate.
- V6. In `flip_page`: subtitles rendered before the video sample is built; the timebase updated after the readiness wait; the subtitle sample enqueued just before the video sample with the same time; nothing enqueued on a drop.
- V7. Resets keep the picture and clear subtitles; teardown removes the picture (4.13, 4.16.5).
- V8. Recovery flushes both layers without removal, on main; a 500 ms throttle unless forced; forced after becoming active; lifted by a reset.
- V9. Only deadline drops count, one each; subtitle drops do not.
- V10. The synchronous and asynchronous main-thread hops are exactly those of 4.16.6.
- V11. Resize observation: `bounds` and `contentsScale` only, equal values filtered, ignored while compositing; a real resize with the separate layer flushes the subtitle layer, resyncs it and requests a redraw.
- V12. The subtitle layer goes on top of the parent's sublayers, one `zPosition` above the host, copies the host's `frame`, uses resize gravity, is clear and non-opaque, and shares the timebase.
- V13. Picture in Picture composites keep the coded size, blend each displayed image exactly once, and carry the decoder buffer's attachments (7.3).
- V14. Software uploads always use the video-range format codes.
- V15. No redraw on a composite-mode switch: turning compositing on while paused shows no subtitle until the next frame or redraw; turning it off while paused leaves the last composited sample, with its burned-in cue, on screen until then. Switching compositing off writes no buffer: the kept rows go back into a composited decoder buffer only immediately before that same buffer is presented again, and are released unwritten when a different buffer is presented or at teardown. A same-buffer redraw with compositing on builds the composite away from the buffer and writes only the rows that change (4.14.9, 13.1).
- V16. In host mode on tvOS, up to 128 ms of handed-over frames still show after a pause.
- V17. The presentation mode is fixed per VO at creation; a VO created again after `vid=auto` reads the option then.
- V18. The scale fallback is `UIScreen.main.scale`, not `nativeScale`.
- V19. A frame-space composite that changes the frame's size is discarded.
- V20. Pools: IOSurface-backed, Metal-compatible, minimum 3, maximum age 1 s, excess flushed every 60 flips.
- V21. The VO keeps its own reference to the host layer.
- V22. The picture is never re-rendered for zoom, pan or scale options, and the host layer's geometry, transform and dynamic-range properties are never touched.
- V23. All subtitle objects are drawn, in mpv's order, into one canvas; one object alone gives today's output exactly (7.3).
- V24. Subtitle buffers and samples carry no attachments; CoreGraphics drawing sets no interpolation and leaves the context's defaults (4.14.5).
- V25. "Clearing the subtitle cache" never flushes a layer, and `VOCTRL_VO_OPTS_CHANGED` and `VOCTRL_SET_PANSCAN` never flush (4.14.4).
- V26. The canvas recompute after a sync re-reads the host geometry inside `flip_page` (4.14.3).
- V27. A rate estimate is used only by the frame that produced it (4.8.3).
- V28. Recovery is tried on every drop while the run is 3 or more. The run goes back to 0 only through a recovery that runs, a ready renderer, a drop more than 500 ms after the previous one, or `VOCTRL_RESET` (4.10).
- V29. The YUV composite uses the fused multiply-adds and evaluation order of 4.14.7, and the host pixel size the fused rounding of 2.5, written out explicitly rather than left to the compiler.
- V30. Subtitle objects come from `osd_render`, kept until drawing is done; `osd_draw` is never used (4.14.4).

**Dolby Vision, FFmpeg and build**

- D1. The Enable-hardware key, never Require, for Dolby Vision sessions.
- D2. The compression field is always written as 0.
- D3. Every profile 8 compatibility id except 4 is tagged PQ and BT.2020, including 2 and 0, in the session's colour extensions (5.2). Keep this. Frame tags follow 5.7 (12.4).
- D4. `dvcC` or `dvvC` follows the effective profile (converted 7 uses `dvvC`).
- D5. The plain HEVC retry is only for an HDR-compatible base; profile 5 goes to software.
- D6. Per-frame Dolby Vision steps follow the live session (5.5), except the profile 7 NAL filter, which follows the stream.
- D7. The conversion is libdovi 3.3.2's mode 2; upgrading libdovi changes behaviour and needs device testing. Vivid's patch must leave every input that does not abort today unchanged, apart from the error texts 5.13 allows to change and the header case of 12.5, which neither caller reaches.
- D8. Frame side data stays the unconverted profile 7 RPU.
- D9. Every type-62 NAL in the packet is forwarded; a failed RPU drops only itself.
- D10. The explicit sample size applies to every codec.
- D11. Replaced (12.4): every VideoToolbox frame, `dvh1` included, gets FFmpeg's own attachment setter at frame output, at every decoder thread count; test at 4 threads as well as 1.
- D12. Replaced (12.4): nothing Dolby Vision specific happens at frame output, so no colour tag or colour space is filled in there.
- D13. Decisions use the stream-level record, never per-packet side data.
- D14. A record smaller than the public struct is absent.
- D15. No `dolby-vision-compatibility-id` anywhere; `dolby-vision-profile` stays the container value.
- D16. The FFmpeg log levels and the warning count per failed RPU (5.9, 6.6).
- D17. The keyframe counter counts at packet acceptance, before that packet's error, only during a run; neither counter is reset by a flush; probing still fails over at once.
- D18. Metal-compatible VideoToolbox buffers and no OpenGL keys (5.10).
- D19. libass carries upstream commit `057a5334`, upstream pull request #951 and Vivid's patch `0010`, so static events report no change and repeat no font search, as today (13.4). It still renders on one thread, where today's library renders on every CPU, so heavy animated typesetting may drop frames; device check 46 decides (9.5, 13.4).
- D20. Patches apply with zero fuzz on top of the existing series (8.2).
- D21. libdovi flags and checks return with the Dolby Vision patch (8.4, 8.6).
- D22. Session property failures stay non-fatal and OS-gated.
- D23. FFmpeg's libdovi guard skips exactly the zero-filled or truncated profile 7 class of 5.6, and nothing else; every other RPU goes to libdovi.
- D24. Vivid's libdovi patch: no abort in the ten covered entry points for any input, single-line error texts without fault substrings, counts from the RPU checked before memory is reserved for them, and never a null display-management result after a header that says the data is present, because libplacebo does not check it (5.13).

### 9.3 Audio test vectors

These state, as behaviour, everything Vivid's old native harness checked, plus cases the audits found missing. Every vector is required, including those for behaviour that came from Vivid's old audio-driver patch (3.6). They assume a controllable host clock, compressed clock and feed position, a fake mpv queue depth and stubbed player calls (section 10). Unless a case says otherwise: playing, an item exists, no fallback requested, steady lead 8 s (start-up lead 16 s), ordinary grace 2 s, initial grace 2 s, initial-start mode off, item ready, compressed clock 0. A tick (t, f) sets the host time to t seconds and the fed duration to f seconds and runs one supervision evaluation; (t, f, c) also sets the compressed clock to c. Each case lists every tick from a new item.

#### 9.3.1 Supervision

**Priming**

| Case | Ticks and set-up | Expected |
| --- | --- | --- |
| P1 | (0, 0.4), (6, 0.9) | rate never requested; no seek; no fallback |
| P2 | (0, 0.4), (6, 0.9), (7, 1) | rate requested once; deadline 9 |
| P3 | end of file reached; (3, 0.3) | rate requested once; deadline 5 |
| P4 | paused; (30, 5) | nothing |
| P5 | no item; (30, 5) | nothing |
| P6 | fallback already requested; (30, 5) | nothing |
| P7 | ordinary grace 3; (0, 1), (1, 16) | rate requested once; deadline 3 after both ticks |

**Engagement**

| Case | Ticks and set-up | Expected |
| --- | --- | --- |
| E1 | (0, 1), (1.5, 3, 1 ns) | no seek; deadline cleared; engaged line with 1.500 s, seeked 0 |
| E2 | ordinary grace 3; (0, 1), (2, 16), (2.5, 16, 0.1) | no seek; deadline cleared |
| E3 | (5, 1), (7, 2), (8, 3, 0.2), (20, 3, 0) | one seek at 7; deadline cleared at 8 with engaged line 3.000 s, seeked 1; nothing at 20 |
| E4 | (0, 1); pause at 0.5; unpause at 1.0; (2.5, 2, 0.1) | deadline 3.0 after the unpause; engaged line with 2.500 s |

**Recovery seek**

| Case | Ticks and set-up | Expected |
| --- | --- | --- |
| R1 | (0, 1), (1, 2), (2, 4) | deadline still 2 after (1, 2); one seek at 2 |
| R2 | ordinary grace 3; (0, 1), (3, 16) | one seek at 3 |
| R3 | (0, 1), (2, 1); reset and new item; (5, 1), (7, 1) | one seek on each item |
| R4 | any case above that seeks | per seek: exactly one seek to time zero with no completion handler, and rate 1 requested again (two requests for that item); no player or item call other than these and the status and clock reads |

**Slow source after the seek**

| Case | Ticks | Expected |
| --- | --- | --- |
| W1 | (0, 1), (2, 2), (3, 5), (4.5, 7), (6, 9), (7.9, 9), (8, 9) | seek at 2 (deadline 4); deadlines 5, 6.5 and 8 after the next three ticks; nothing at 7.9; fallback at 8 |
| W2 | (0, 1), (2, 1), (2.05, 1), (4, 1), (4.05, 1) | seek at 2 (deadline 4); deadline 4.05 after (2.05, 1); no fallback at 4; fallback at 4.05 |
| W3 | (0, 1), (2, 16), (4, 16) | seek at 2; fallback at 4 |

**Fallback**

| Case | Ticks | Expected |
| --- | --- | --- |
| F1 | (0, 1), (2, 1), (3, 1), (5, 1), (9, 1) | seek at 2; deadline 5 after (3, 1); fallback at 5; still exactly one fallback request at 9; the passthrough block is set for the format and the player's rate set to 0 |

**Initial-start mode** (ordinary grace 1, initial grace 0.25, initial-start mode on, unless stated)

| Case | Ticks and set-up | Expected |
| --- | --- | --- |
| I1 | (0, 1), (0.2, 2), (0.25, 2) | deadline 0.25; no seek at 0.2; at 0.25 the line `first start recovery after 0.250 s`, then the warning, then one seek |
| I2 | item not ready; (0, 1), (0.6, 2); item becomes ready; (0.65, 2) | no seek at 0.6; one seek at 0.65 |
| I3 | item never ready; (0, 1), (1, 2) | one seek at 1 |
| I4 | initial-start mode off; (0, 1) | deadline 1 |
| I5 | initial grace option 3; (0, 1) | deadline 1 |
| I6 | (0, 1), (0.1, 2, 0.1); reset and new item; (5, 1) | no seek; mode ends at 0.1; the new item's deadline is 6 |
| I7 | (0, 1); pause at 0.1; unpause at 0.2; (0.3, 2), (1.2, 2) | deadline 1.2 after the unpause; no seek at 0.3; at 1.2 the first-start line (1.200 s) and one seek |
| I8 | (0, 1); reset and new item; (10, 1) | deadline 10.25 |

#### 9.3.2 Start anchoring eligibility

All rows: rate 1 requested, no fallback, window space sufficient, start-up lead 16 s, unless the row says otherwise.

| Since last anchor | Fed duration | Clock | End of file | Option | Eligible |
| --- | --- | --- | --- | --- | --- |
| 0.25 s | 10 | 0 | no | on | yes |
| 0.1 s | 19.5 | 0 | no | on | yes |
| 0.1 s − 1 ns | 12 | 0 | no | on | no |
| 1 s | 20 | 0 | no | on | no |
| 1 s | 20 s − 1 ns | 0 | no | on | yes |
| 1 s | 12 | 1 ns | no | on | no |
| 1 s | 12 | 0 | yes | on | no |
| 1 s | 12 | 0 | no | off | no |
| 1 s | 3, rate 1 not requested | 0 | no | on | no |
| 1 s | 12, fallback requested | 0 | no | on | no |
| 1 s | 12, window space below the carry-over size | 0 | no | on | no |
| none since rate 1 was requested (pacing time at mpv's clock origin), host time 30 s | 12 | 0 | no | on | yes |

#### 9.3.3 Resume detection and anchoring

All rows: a resume is pending and the option is on, unless the row says otherwise. An "anchor read" outcome assumes mpv's queue holds at least one 100 ms request, so the prefetch guard (3.4.9) lets the read through.

| Since unpause | Since last anchor | Clock now, clock at unpause | End of file | Outcome |
| --- | --- | --- | --- | --- |
| 0.7 s | 0.3 s | 30, 30 | no | anchor read |
| 0.7 s | 0.3 s | 29.5, 30 | no | anchor read |
| 0.7 s | 0.3 s | 0, 0 | no | anchor read |
| 0.7 s | 0.3 s | 30 + 1 ns, 30 | no | resumed line; resume ends; no read |
| 2 s − 1 ns | 0.3 s | 30, 30 | no | anchor read |
| 2 s | 0.3 s | 30, 30 | no | no read |
| 0.7 s | 0.1 s − 1 ns | 30, 30 | no | no read |
| 0.7 s | 0.3 s | 30, 30 | yes | no read |
| 0.7 s | 0.3 s | 30, 30 | no; option off | no read |
| 0.7 s | 0.3 s | 31, 30 | no; option off | resumed line; resume ends |
| no pending resume | | | | nothing |
| 0.7 s | 0.3 s | 31, 30 | no; a read earlier in the step requested a fallback | resumed line; resume ends; no read, no serving, no supervision |
| 0.7 s | 0.3 s | 31, 30 | no; the item status is failed | the rejection line and the `falling back to PCM` line, one fallback; no resumed line, and the resume stays pending; no read, no serving, no supervision |
| 0 (the feed step at the end of the unpause) | none since the unpause (pacing time at mpv's clock origin), host time 30 s | 30, 30 | no | anchor read |

#### 9.3.4 Prefetch guard, compressed sink (planned read 4800 frames)

| Queued frames | Fed duration | Feed position | Read skipped |
| --- | --- | --- | --- |
| 0 | 3 s | 0 | yes |
| 4799 | 3 s | 0 | yes |
| 4800 | 3 s | 0 | no |
| 0 | 3 s | 2 s | yes |
| 0 | 3 s | 2 s + 1 ns | no |
| 0 | 3 s | 3 s | no |
| 0 | 0 | 0 | no |
| 100 | 12 s | 0 | yes |

#### 9.3.5 Prefetch guard, bounded tvOS PCM (request 4800 frames)

| Queued frames | Ahead | Read skipped |
| --- | --- | --- |
| 0 | 0 | no |
| 0 | 3 s | yes |
| 4799 | 1 s | yes |
| 4800 | 1 s | no |
| 0 | 1 s − 1 ns | no |
| 0 | −0.5 s | no |

#### 9.3.6 Bounded tvOS PCM

**Feed condition (bound 4 s; mpv's queue holds at least one 100 ms request, so the prefetch guard lets reads through):**

| Ahead | Renderer ready | Feeding | A read is attempted |
| --- | --- | --- | --- |
| −0.5 s | yes | on | yes |
| 2 s | yes | on | yes |
| 4 s − 1 ns | yes | on | yes |
| 4 s | yes | on | no |
| 0 | no | on | no |
| 0 | yes | off | no |
| −0.5 s | no | off | no |

In the PCM feed, the bound and the prefetch guard are both checked before any `ao_read_data` call; in the compressed sink, the prefetch guard is checked before `ao_read_data`.

**Mode selection at `init`:**

| `max-lookahead` | `audio-buffer` | Result |
| --- | --- | --- |
| 0 (default) | 0.2 | unbounded: readiness callbacks, no timer, no prefetch guard, no fresh sink, no `pcm:` line, no `start`, `pause` or `resume` trace edges |
| 0 | 5 | unbounded, as above |
| 4 | 0.2 | bounded, bound 4 s |
| 0.1 | 0.2 | bounded, bound 0.2 s |
| 4, timer creation fails | 0.2 | one warning, then unbounded |
| iOS (option absent) | any | unbounded; setting the option fails with "option not found" |

**Fresh sink:**

- With the old renderer at volume 0.6 and muted, a replacement leaves the new renderer at volume 0.6 and muted, the enqueued end −1, the transport-line time back at mpv's clock origin (so the next tick with feeding on logs), the pending mark clear, and delayed rate change off on the new synchroniser. A later replacement after volume 1.0 and unmuted carries 1.0 and unmuted.
- `WasFlushedAutomatically`, and on tvOS 15 and later `OutputConfigurationDidChange`, from the new renderer reach the restart handling; the same notifications from the old renderer do not.
- Renderer creation fails: exactly one reload request; the old renderer stays installed; the replacement stays pending. The same when only the synchroniser cannot be created.
- With a replacement pending: `set_pause(true)` and `set_pause(false)` change nothing and log nothing; a restart notification from the current renderer logs its `notification name: ` line (and the flush-time line when the user info has a flush time) and nothing else.
- With mpv's clock more than 2 s past its origin, the first tick with feeding on after `init` logs the `pcm:` line at once, with `fed 0.000`.
- On iOS and tvOS, bounded or not, a restart notification's `notification name: ` line carries the notification's full name (for example `AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification`).

#### 9.3.7 Audio session ownership

- `manage-audio-session` off: repeated `init` and `uninit` calls on several AO instances, including `init` calls that fail, make no category, mode or activation call.
- `manage-audio-session` off, a 6-channel PCM `init` with a maximum of 8 output channels: no category or mode, no activation, multichannel content declared, preferred output channel count 6. With a maximum of 2: preferred count 2.
- An spdif `init` with `accept-compressed` off makes no session call at all.
- `manage-audio-session` on: activation calls `setActive:YES` with options 0; deactivation calls `setActive:NO` with `AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation`; both the `init` error path and `uninit` deactivate; the option defaults to on.

#### 9.3.8 End of file and restart

- With the end-of-file state set and rate 1 already requested, `start` logs `resuming compressed feed after audio EOF`, clears the state before its feed step, keeps the item and the stream offsets, requests rate 1 again, and the feed step reads from mpv.

#### 9.3.9 Unwrapping

| Input (one read) | Expected |
| --- | --- |
| Valid AC-3 bursts separated by zero padding | every payload reaches the window byte-swapped; the fed duration grows by one burst period per burst |
| E-AC-3 stream with a preamble of data type 0x01 | one `skipping unexpected IEC 61937 data type 0x1` warning; scanning resumes one byte after the preamble start |
| AC-3 preamble with byte 4 = 0x81 | accepted as data type 0x01 |
| AC-3 Pd 100 (bits) | 12-byte payload (rounded down) |
| AC-3 Pd 76 | 9-byte payload: one `discarding burst with odd payload length` warning, one burst period dropped |
| AC-3 Pd 63 | 7 bytes: one `skipping burst with invalid payload length 7` warning, scan resumes one byte on |
| AC-3 Pd 64, 49088 | 8 and 6136 bytes: accepted |
| AC-3 Pd 49096 | 6137 bytes: invalid-length warning |
| E-AC-3 Pd 24568, 24569 | accepted; invalid-length warning |
| E-AC-3 Pd 9 | odd-length warning; one burst period dropped; scanning resumes 18 bytes after the preamble start |
| A preamble with the wrong data type and an out-of-range length | only the data-type warning |
| A valid preamble whose payload is not yet complete | no warning; kept from the preamble on for the next read |
| A burst split across two reads | appended once, complete, after the second read |
| A payload whose swapped start is not 0x0B 0x77 | one `discarding burst without syncframe` warning; one burst period dropped |
| 19200 bytes (one 100 ms AC-3 read at 48 kHz) of bytes with no preamble | no warning, no fallback, the last 7 bytes kept |

### 9.4 Video and decoder acceptance tests

The clean side designs its own scenarios, sizes and durations. The tests must establish these properties.

**Servo and estimator (media mode).**

1. **No needless re-anchors.** With presentation-time noise, or a clock offset between mpv's schedule and the host clock that is constant or varies slowly, so that the rate correction needed stays inside the ±1.5% slew limit, and with no schedule jump above 50 ms, no anchor follows the first one, and the phase error between anchors stays well below the 50 ms re-anchor threshold. As a number: with presentation-time noise within ±0.8 ms and an offset of at most 0.04%, constant or varying with a period of 5 minutes or more, the error stays under 1 ms from 30 s after the first anchor. The error is taken against the schedule the test generated before adding noise: the timebase's time at the host time a frame was due, compared with that frame's media time. (Today's servo stays under 0.5 ms there.)
2. **One anchor per jump.** A schedule jump above 50 ms causes exactly one re-anchor, and leaves the nominal rate unchanged.
3. **Speed changes.** A change of playback speed by more than 1%, to a speed strictly between 0.05× and 8×, ends with the nominal rate within 0.005 of the new speed for a change of at most 4%, and within 0.01 for a larger one (today's estimator gives the new speed exactly when frame durations are exact). It takes one or two anchors, or up to three for a slow-down to less than half the old speed (4.10), and the last of them comes within 5 s of the change. Adoption comes when 4.10 says: for a change above 4%, on the third frame at the new frame duration, or the second when that duration is 500 ms or more; for a change of more than 1% and at most 4%, when a 500 ms averaging window of frame duration completes, which a frame of 500 ms or more does on its own (12.2). A change of less than 1% causes no anchor and leaves the nominal rate unchanged.
4. **Rate writes.** Between anchors the applied rate stays within ±1.5% of nominal, consecutive writes are at least 200 ms apart, no write changes the rate by 100 ppm of nominal or less, the integral stays within ±1.5%, and no step longer than 500 ms is integrated.
5. **Deterministic trace.** For fixed sequences of media times, target times, host times and timebase readings, the implementation's anchors, rate writes and integral values equal those of an independent, straightforward reference implementation of 4.8.2 and 4.8.3, including every rounding rule of 4.8 and 4.8.3 and the integral's evaluation order in 12.2.
6. **Estimator vectors** (nominal 1.0 unless stated; 40 ms = 40,000,000 ns):

| Case | Frames (media time, duration) | Expected |
| --- | --- | --- |
| EV1 | (0, 40 ms) | no estimate |
| EV2 | 14 frames, media time stepping 40 ms, duration 40 ms | the 14th frame yields 1.0; nominal unchanged |
| EV3 | (0, 40), (40, 40), (80, 40), then (120, 20), (160, 20), (200, 20), all ms | no estimate at (120, 20) (duration step); the 6th frame yields 2.0, adopted |
| EV4 | (0, 40), (40, 40), (40, 40), (80, 40) | no estimate; the repeated time changes nothing (the last step is measured from 40) |
| EV5 | (0, 40), (40, 40), (80, 40), (40, 40) | no estimate; windows emptied; previous sample (40, 40) |
| EV6 | (0, 40), (40, 40), (440, 40) | ratio 10: no estimate; windows emptied |
| EV7 | (0, 40); 12 steps of 41.2 ms; one of 44 ms; one more of 44 ms; durations 40 ms | the 14th frame yields about 1.035385 from the averaging window (adopted); the 15th yields 1.1 from the fast window, which kept its sample (adopted) |
| EV8 | (0, 40), (60, 40), (140, 40), (220, 40) | the ratio moves from 1.5 to 2.0, so the fast window restarts; the 4th frame yields 2.0 |
| EV9 | (0, 40), (40, 40.3), (80, 40) | duration change of 300 µs: no discontinuity; averaging holds 80.3 ms |
| EV10 | (0, 40), (40, 40), (80, 40.45) | duration change of 450 µs: discontinuity; windows emptied |
| EV11 | (0, 0), (40, −5 ns) | nothing changes; no previous sample stored |
| EV12 | any estimate whose frame is dropped, or produced while paused | not used, and gone by the next `draw_frame` |

7. **Readiness and recovery**, with a fake renderer: the drop boundary at 4 ms before the target (inclusive); one drop count per dropped frame; recovery throttled to once per 500 ms except when forced; the throttle lifted by a reset; recovery tried on every drop while the run is 3 or more and the staleness rule holds; and the run back at 0 only after one of four things: a recovery that runs, a ready renderer, a drop more than 500 ms after the previous one (which then counts 1), or `VOCTRL_RESET`.

**Frame-space subtitle geometry.**

- The canvas is the frame's own pixel grid; source and destination rectangles cover the whole frame; margins are 0.
- `display_par` follows upstream's `osd_res_from_image_params` convention, including for non-square pixels.
- A non-positive frame size gives an empty geometry.
- For every `sub-pos`, the enqueued sample has the same size with and without a cue.
- A mapped blend rectangle lies inside the frame and within one pixel of the box on every side; a box lying wholly beyond the frame yields no rectangle.

**Pixels.**

- **Uploads and tags:** the 4.3 copies and the colour-tag table, bit for bit, for each accepted software format.
- **Blend arithmetic:** for fixed 8-bit and 10-bit frames and fixed libass and BGRA subtitle lists, the direct libass and BGRA blends (4.14.5) and the YUV composite (4.14.7, with its evaluation order) match a scalar reference implementation bit for bit. The CoreGraphics path is compared against CoreGraphics itself drawing the same parts with the settings of 4.14.5.
- **Several objects:** a primary and a secondary subtitle object drawn together give one canvas holding both, the second painted over the first, with the union bounding box; a single object gives exactly the single-object result; an unchanged pair is not re-rendered; a change to either re-renders.
- **Blend once:** composite the same decoded image twice with the same cue, then with a different cue, then with compositing off. The second sample equals the first, the third shows only the new cue, the fourth shows the original picture, for an 8-bit and a 10-bit biplanar source, and every sample's attachments equal the decoder buffer's after 4.5 and 4.4.

**Decoder.**

- **Profile 7 conversion:** for real profile 7 FEL and MEL samples, every RPU NAL FFmpeg appends is byte-identical to libdovi 3.3.2's mode 2 output.
- **libdovi guard:** a 25-byte RPU of 0x7C 0x01 0x19 0x08 0x09 followed by twenty 0x00 bytes, and one of 0x7C 0x01 0x19 0x08 0x09 0x80 0x80 followed by eighteen 0x00 bytes, are skipped without calling libdovi, with two warnings each, and the frame is still submitted; 0x7C 0x01 0x19 0x08 0x09 0x00 0x00 0x03 followed by seventeen 0x00 bytes is skipped the same way (the 0x03 is an emulation-prevention byte); 0x7C 0x01 0x19 0x08 0x09 0x01 0x02 0x80 followed by seventeen 0x00 bytes is not skipped by the guard (test the guard's decision on its own).
- **libdovi abort classes** (5.13): one RPU of each class listed in 5.13, made from a valid RPU by changing that one field and recomputing the CRC, so that parsing reaches the field and, for the writing class, succeeds. Unpatched libdovi 3.3.2 aborts on each (run it in a separate process; for the large-count class, see 12.5). With Vivid's patched libdovi, each RPU is skipped with exactly two warnings (the stage line, then the stripped line) and the frame is still submitted. In libplacebo's call sequence, every class except the writing class reports a parse error and the header query returns null. The writing class parses successfully in unpatched 3.3.2 and only aborts when written, so libplacebo's sequence handles it exactly as today (parse, header and display-management data unchanged, rule 3), and only the write in FFmpeg's conversion fails and is skipped.
- **Never abort:** a corpus of malformed RPUs (every class above; the guard vectors; every truncation of a valid profile 5, profile 7 FEL, profile 7 MEL and profile 8 RPU; and random bytes, from a fixed seed, after each start pattern libdovi recognises) goes through every covered entry point of the patched libdovi, both in the order FFmpeg's conversion calls them and in the order libplacebo calls them (parse; the header query; when that returns a header with `vdr_dm_metadata_present_flag` set, the display-management query, which must then return a structure, never null; the frees). Nothing aborts or crashes, and every input either succeeds or reports an error. Where a runnable build of libplacebo is at hand, also pass the corpus through its `pl_hdr_metadata_from_dovi_rpu`.
- **Unchanged elsewhere:** for real profile 5, 7 FEL, 7 MEL, 8.1 and 8.4 RPUs, and for every corpus RPU on which unpatched 3.3.2 does not abort, the patched and unpatched builds give the same results and output bytes, and the same error texts apart from those 5.13 allows to change. The header case of 12.5 is the one exception.
- **Configuration record:** for profile 5, 8.1, 8.4 and converted 7 records, and for a record with compression 3, the 24-byte atom matches 5.2 exactly.

**libass.** The acceptance tests of 13.4, on the build host against the patched libass.

### 9.5 Device checklist

Run on the rebuilt engine after the pipeline's checks (8.5, 8.6). Use a trial build (log level `v`) for trace-based checks and a Release build for fault recording, and compare the current engine and the rewrite side by side on the same hardware and titles. For each check record the device, OS, build revision and source (codec, profile, range, frame rate, container, resolution, pixel aspect), the route, and whether the result came from a person or a log. Simulator results count only once the app links the pipeline's simulator slices (8.7); until then run the software-decode checks on a device with a forced fallback. 12.7 adds checks 59 to 64, and 13.7 adds checks 65 to 69.

**AirPlay, Apple TV 4K to a HomePod or HomePod stereo pair** (Vivid's AirPlay options apply)

1. AC-3 and E-AC-3 from 0:00: sound starts and video holds its first frame until it does; never 2 s or more of video ahead. The trace shows `first start recovery after`, then `compressed clock engaged after` about 0.85 s after the seek, with anchors above 0.
2. Resume part-way through (Continue Watching; resumes start on the keyframe at or before the position): engaged roughly 0.8 to 1.3 s after play; picture-to-sound wait under about 0.5 s; no rebuffer straight after starting.
3. Pause and resume five times at different points: the picture holds until the clock moves (about 0.6 s); `compressed clock resumed after` each time; picture and sound end within about 0.03 s of their pre-pause offset; no freeze afterwards.
4. Seek forwards and backwards repeatedly, including while paused: engages in about 0.5 to 0.6 s with no recovery seek; in sync after every seek.
5. Before sound has started at 0:00: (a) pause and resume; (b) seek. Sound starts, video holds until it does, `first start recovery after` appears at most once per AO, and there is no fallback.
6. DTS 7.1 (decoded PCM, bounded tvOS PCM) to HomePods: in sync after seeks; `start-fresh` and `pcm fresh sink after reset` after each seek; volume changes heard within about the 4 s bound. Pause and resume five times; seek while paused, then unpause at once: audio resumes in sync, with one `start-fresh` per seek and no `resume` edge before it.
7. Speed 1.5× and back on an AC-3 or E-AC-3 track: switches to PCM and back in about a second, never a frozen picture with silent audio. The same on a decoded track (DTS or TrueHD) over the bounded AirPlay path: mpv's decoder chain rebuilds at each crossing but the AO is kept, so the trace shows no `reset` edge, no `pcm fresh sink after reset` and no `start-fresh`, and at most one plain `start` edge per crossing; audio returns in sync, with no lasting silence.
8. Route switch mid-play (AirPlay to built-in or HDMI and back), once with a passthrough track and once with a decoded track: no lasting silence; for bounded PCM the trace shows `restart`, then `reset`, `pcm fresh sink after reset` and `start-fresh`.

**AirPlay from iPhone** (defaults apply: grace 2, no anchoring, no bounded PCM)

9. AC-3 and E-AC-3 from 0:00 and from a resume: sound starts; anchors 0; any recovery seek about 2 s after rate 1; no `start-fresh` or `pcm:` lines. Compare timings with today's build rather than with items 1 to 4.

**HDMI to an AV receiver (Apple TV 4K)**

10. AC-3 5.1 and E-AC-3 5.1 and 7.1: the receiver shows Dolby Digital or Dolby Digital Plus; no audible gap over at least 5 minutes, and no small gap roughly every 1.8 s. Over the same 5 minutes, with passthrough over HDMI and over AirPlay, `frame-drop-count` and `vo-delayed-frame-count` match today's build and the picture shows no periodic skip-and-hold.
11. E-AC-3 JOC (Atmos): the receiver shows Dolby Atmos; the statistics show the Atmos badge only when the system rendering mode reports Dolby Atmos.
12. A 44.1 kHz E-AC-3 sample, if available: lips stay in sync for at least an hour (no drift of about 9%).
13. Long session: a Dolby Digital Plus or Atmos title played continuously for at least 45 minutes, through the 30 to 40 minute region: no repeating access unit or loop of stale audio; the heartbeat's reader gap stays bounded; memory stays flat (the window is about 15 MiB). Seek, pause and resume at 35 minutes and later.
14. Decoded 7.1 PCM (TrueHD or DTS-HD) to a 7.1 receiver: the receiver shows 7.1 multichannel PCM.

**Slow and unreliable sources**

15. A server transcode or throttled link delivering at about 1×: passthrough starts late but does not fall back while data keeps arriving (after the recovery seek); `native compressed playback did not start` does not appear.
16. A source that stalls completely at start-up: recovery seek, then fallback after the grace; decoded PCM then plays; the next title, or the next AO reload, tries passthrough again.
17. A stream with corrupt bursts: warnings for the skipped bursts and playback continues. A stretch of bytes with no preamble causes no warning and no fallback, in both builds.
18. A network stall mid-play long enough to drain the reserve: mpv reports a real underrun and recovers; no buffering pauses while at least a second is queued.
19. **Release fault parity:** in a Release build, the forced fallback (16) and the corrupt-burst run (17) record exactly the same fault labels and counts as today's build; the reload's block refusal adds no fault.

**Audio session and lifecycle**

20. Next Up chains of several episodes, including immediate skips: never a silent next episode; other apps' audio is not interrupted unexpectedly.
21. An audio end of file followed by more audio (a track that ends before the video and resumes, or gapless playlist entries): `resuming compressed feed after audio EOF` and the sound continues.
22. iOS routes: speaker, wired and Bluetooth headphones, AirPlay and an HDMI adapter. PCM and compressed both play; multichannel PCM honours the route's maximum.
23. iOS touch-and-hold 2× on an AC-3 or E-AC-3 title, including a release before the first output swap has finished: the audio returns to passthrough at 1× in sync, with no lasting silence.

**Picture and colour**

24. HDR10 film on Apple TV 4K (Match Content on) and an HDR iPhone: correct brightness and colour; HDMI mode HDR10 at the film's rate.
25. HLG broadcast clip: HLG on an HLG-capable TV, otherwise SDR; EDR highlights on iPhone.
26. Dolby Vision profile 5 on Apple TV 4K and an HDR iPhone: Dolby Vision mode, no purple or green cast, label "DV Profile 5". Correct colour here shows `DolbyVisionRPUData` is present and the VO's PQ repair fires.
27. Dolby Vision profile 7 FEL and profile 7 MEL remuxes: Dolby Vision mode through the conversion, label "DV Profile 8.1", brightness plausible against the same title as HDR10, no per-frame log flood in a trial build, Dolby Vision kept through repeated seeks.
28. Dolby Vision profile 8.1 MKV and MP4: Dolby Vision mode, picture correct (not near-black), label "DV Profile 8".
29. Dolby Vision profile 8.4 HLG (an iPhone-recorded HEVC `.mov` through Emby or Jellyfin): Dolby Vision or HLG as tvOS decides, correct gamma.
30. Dolby Vision profile 8 in MPEG-TS with the old reserved bits set: hardware Dolby Vision decode.
31. Dolby Vision on a TV without Dolby Vision: tvOS chooses HDR10 and the picture is correct. On a device whose VideoToolbox refuses `dvh1`, if one is available: profile 8 plays on hardware as HDR10 or HLG with one retry warning and no appended RPUs; profile 5 goes to software (`hwdec-current` `no`).
32. A Dolby Vision file without a container record: plays as HDR10 with no Dolby Vision session.
33. SDR BT.709 and BT.601 sources (H.264 1080p, a DVD remux), HDR10 HEVC without Dolby Vision, and AV1: correct colour, no level shift, hardware decode unchanged.
34. Anamorphic DVD (720×576 or 720×480 with non-square pixels): correct display aspect with `fit`, `fill` and `stretch`.
35. Software decode (8-bit H.264, 10-bit HEVC or AV1) with a forced fallback on a device, and in the simulators once 8.7 allows: correct picture and colours (note full-range sources, V14).
36. Mid-stream VideoToolbox error recovery: a file that makes VideoToolbox reject a single frame keeps playing on hardware after at most two keyframes, with `hwdec-current` still `videotoolbox`, also when the error run spans a seek; sustained errors still reach software after 240.

**Timing and frame rate**

37. 23.976, 24, 25, 29.97, 50 and 59.94 fps on Apple TV with Match Content: smooth cadence, no periodic stutter over 10 minutes; pacing summaries show no recurring anchors on tvOS and very few after start-up on iOS.
38. Match Content frame-rate switching: the HDMI switch at start-up, picture after the TV relocks, audio and video in sync afterwards; no extra switch between episodes of the same format.
39. High speed: 1.25×, 1.5× and 2× on iPhone and Apple TV: smooth video and stable sync; in media mode one or two anchors per speed change, then rate updates only; back to 1×.
40. Pause and resume: on tvOS, note frames after the pause (up to 128 ms, V16); on iOS, an immediate hold; no jump on resume.
41. Many seeks while playing and while paused, on both platforms: the last frame stays until the new one appears; subtitles clear at the seek and come back. The paused redraw on iOS activation (Control Centre pulled down and released while paused) shows the same frame again with no flash.

**Subtitles**

42. Embedded ASS (styled, with positioned signs), PGS bitmaps, and SRT or VTT, on HDR10 and Dolby Vision content: visible, inside the picture, timed to the frame, no dimming of the video on Apple TV; cue changes on scene cuts land on the right frame (frame stepping in both builds). Scaled PGS bitmaps on the separate layer: compare edges side by side with today's build.
43. Separate-layer subtitle brightness on HDR10 and Dolby Vision output: the same as today's build.
44. A primary and a secondary embedded subtitle with cues at the same time: both visible together, the secondary drawn over the primary where they overlap, on the separate layer and in Picture in Picture; a cue change in either updates on the right frame. (Today only the secondary shows; this is deliberate difference 3.) Include a 4K title in Picture in Picture with one cue at the top and one at the bottom, and record the subtitle performance summary and dropped frames against a single cue.
45. Vivid's subtitle appearance presets with an SRT (box, outline, drop shadow, top, lower third) and an external ASS added during playback, on the separate layer and in Picture in Picture: side by side with today's build; a change of preset or subtitle delay shows on the next frame, also while paused.
46. Heavy styled ASS (anime karaoke or dense signs) on Apple TV 4K and an older supported iPhone: measure dropped frames (`frame-drop-count`, `vo-delayed-frame-count`) and the VO's subtitle performance summary against today's build. The new libass renders on one thread, where today's renders on every CPU. Static events now cost what they cost today (13.4), so the difference shows on animated karaoke and motion-tracked typesetting. This check decides whether one thread is acceptable (7.1, 11.2, 13.4).

**Geometry, Picture in Picture and external displays**

47. Rotation on iPhone and iPad, iPad split-view resizing, preview to full screen, the Next Up mini-player: the video snaps to size; subtitles are re-laid out after each resize, also while paused; no old-geometry subtitle left behind.
48. Gravity `fit`, `fill` and `stretch`: the video follows the layer; subtitles stay placed against mpv's aspect-fit rectangle in every mode.
49. Picture in Picture on iPhone and iPad, from the button and automatically by swiping home, with SRT and ASS subtitles at the default and lower-third positions: subtitles burned into the window; the window does not resize when cues come and go; play, pause and skip work and the timeline matches; back to full screen, subtitles return to the separate layer with no burned-in cue left behind.
50. Pause in Picture in Picture while a cue changes, and resize the Picture in Picture window while paused: no doubled, heavier or stale cue (7.3), and the cue never disappears for a moment during such a redraw (13.1).
51. Picture in Picture across Next Up: the window stays and switches to the new episode, with subtitles. With HDR10 and Dolby Vision content and subtitles, the picture stays correct (note subtitle brightness).
52. External displays on iOS (HDMI adapter and AirPlay mirroring): note whether video moves or mirrors; if it moves, subtitles render at the external screen's scale and the container moves with both layers.

**Background, cover art, lock and long sessions**

53. iOS with background playback and Picture in Picture off, and tvOS Home and return: video is off while away (`vid=no`, VO destroyed); on return the picture and subtitles come back (note any brief black frame). Lock and unlock while playing and while paused. App-switcher peeks and banners: the VO's forced recovery runs once (trial log) with no flash.
54. An audio-only title with embedded artwork: play, go to the background and return, and on iOS pull down Control Centre while playing and while paused. A VO is created for the artwork on return (4.16.1); the artwork shows and stays, audio is unaffected, and nothing differs from today's build.
55. Long sessions: 2 hours or more of 4K Dolby Vision on Apple TV, and 1 hour on iPhone in media mode: no drift, no growing stutter, steady memory (pools flushed, no IOSurface growth), no warning-level log stream in Release.
56. HTTPS through Lucid's own reader (Emby or Jellyfin) on a device build: certificates checked, TLS 1.2 servers work (6.7).
57. Statistics parity: `frame-drop-count`, `vo-delayed-frame-count`, `avsync` and `display-fps` (expected unavailable) match today's engine for the same file and actions.
58. Builds: all four slices build; setting Vivid's options gives no "option not found" error on iOS or tvOS.

## 10. Harness rewrites

### 10.1 Why the old checks cannot survive

- `scripts/tests/compressed-audio-recovery-tests.py` extracts parts of the old driver by their internal names, compiles them against stubs and runs vectors against them.
- The old audio-driver workflow runs that script on every compiled `audio/out/ao_avfoundation.m` in its build tree and asserts a source-text ordering inside the driver's start callback (the end-of-file state cleared before the feed step).

Both depend on the old driver's names and layout, so they fail against any clean implementation. Clean implementers must not read either (1.4). Everything they protected is restated as behaviour in 9.3, and section 9.4 adds the video and decoder tests.

### 10.2 What the new audio tests must cover

| Area | Vectors |
| --- | --- |
| Supervision: priming, rate 1, deadlines, engagement, the recovery seek and its calls, slow-source extensions, fallback, initial-start mode, pauses and resets before engagement | 9.3.1 |
| Start anchoring | 9.3.2 |
| Resume detection and resume anchoring, including a step in which a read requested a fallback, a rejected item, and the feed step at the end of an unpause | 9.3.3 |
| The prefetch guard in both sinks, checked before mpv is asked for data | 9.3.4, 9.3.5, 9.3.6 |
| Bounded tvOS PCM: feed condition, mode selection, fresh sink, a pending replacement, the transport line | 9.3.6 |
| Audio session ownership | 9.3.7 |
| End-of-file restart (this replaces the old source-ordering assertion with a behavioural test) | 9.3.8 |
| Unwrapping IEC 61937 | 9.3.9 |

### 10.3 Requirements on the new tests

- **They test the shipped code.** The audio and video tests compile the AO's and VO's decision logic from the mpv tree the pipeline has just patched, the decoder tests compile from the patched FFmpeg tree, and the libdovi tests use the patched libdovi build (8.6). None uses a copy kept beside the tests, so none can drift from its patch.
- **Platform guards do not hide anything.** The logic under test compiles outside platform guards, with guards only where it is called, or the tests run in a simulator target of the platform concerned, so that the tvOS-only and iOS-only logic is really built and run. They use the feature settings of the shipped slices (2.11).
- **They count.** Each test reports how many vectors it ran and fails if that number is zero.
- **Structure is free.** How the code is made testable (fakes for the clock, the player, the renderer and the session; pure functions; an Objective-C test target) is the implementer's choice. Nothing here asks for a particular split into functions, and the vector tables are not a description of any function's parameters.

### 10.4 Who does what

- The clean side writes the new tests with the new patches, and wires them into the pipeline (8.6).
- Removing the old script and the old audio-driver workflow needs someone who may read them: the dirty side or blurbery (11.2).
- The binary marker checks (2.10) move into the pipeline (8.6).
- Vivid's existing `PlayerSurfaceLayoutTests` (2.5) run in the iOS simulator, so they exercise the new VO only once the app links the pipeline's simulator slices (8.7). They must pass then, unchanged.

## 11. Decisions, open items and documents to update

### 11.1 Decisions applied in this document

| Question | Decision |
| --- | --- |
| Should `ao-avfoundation-max-lookahead` exist on iOS? | No, as today (2.2). |
| Should the passthrough block be per instance? | No: process-wide, as today (3.2.3). |
| Should switching Picture in Picture compositing while paused trigger a redraw? | No, as today (4.14.9). |
| Should full-range software uploads be labelled full range? | No: the video-range codes stay (4.3). |
| Should the VO declare capabilities or implement more control requests? | No (2.6). |
| Should profile 8.2 keep PQ and BT.2020 tags? | Yes, in the session's colour extensions (D3). Frame tags follow 5.7 (12.4). |
| Both per-frame HDR metadata session properties? | Yes (5.4). |
| libdovi or a reimplementation? | libdovi 3.3.2 stays, built from source with Vivid's patch (5.6, 5.13). |
| Vulkan and MoltenVK? | Stay linked for now (7.1). |
| Upstream's `HAVE_MACOS_*` guards in the AO, or `@available` alone? | Either; the shipped result must be "enabled", and the pipeline checks it (2.11, 8.5). |
| How free is log wording? | Free where nothing consumes it, within 2.9's constraints. Consumed strings and every level are frozen. |
| Licence of the new patches? | LGPL-2.1-or-later for mpv and FFmpeg, the VO included; MIT for libdovi; ISC for Vivid's libass patch; each library's own licence for the libbluray and uavs3d patches (1.3). |
| Two subtitle objects at once? | Show both, in the separate layer and in Picture in Picture (deliberate difference 3). |
| libdovi aborting on a malformed RPU? | Fix it now (deliberate difference 4). FFmpeg keeps its exact guard for zero-filled or truncated profile 7 RPUs, and Vivid's pipeline builds libdovi 3.3.2 from source with a Vivid-owned patch that makes every entry point FFmpeg and libplacebo use return an error instead of aborting, for any input (5.13). Every RPU libdovi cannot parse, convert or write is skipped (5.6). |
| What is dropped or omitted? | 7.1 and 7.2, each with evidence. |
| What deliberately changes? | The four items of 7.3; 7.4 lists differences already in Vivid's series. |
| libass cost on static events, and repeated font fallback? | Restored to today's by carrying upstream libass commit `057a5334`, upstream pull request #951 and Vivid's own patch `0010` (13.4). |
| Single-threaded libass? | Accepted as a known risk and measured on devices (9.5 item 46); not emulated. |
| The eleven libraries from the previous third-party build? | Built from upstream source by Vivid's pipeline with today's options (13.5). |
| Framework bundle identifiers? | Prefix `com.blurbery.vivid.lucid.` (blurbery's decision, 13.5). |
| mpv 0003, 0025, 0027 and 0102; FFmpeg 0010 and 0015? | Kept (section 6); 0003 is covered by Vivid's `0002`, and mpv 0026 is Vivid's `0001` (upstream `1388a45`). |
| Where do the patches apply? | On top of Vivid's existing series in `engine/patches/`, with zero fuzz (8.2). |

### 11.2 Open items for the coordinator

1. **Retiring the old harness.** Closed: both have been removed. Removing `scripts/tests/compressed-audio-recovery-tests.py` and `.github/workflows/mpv-audio-driver.yml` needs the dirty side or blurbery (10.4).
2. **Linking the pipeline's builds.** Closed: the app pins release `0.1.0` of `blurbery/lucid-engine`, which serves every framework the pipeline builds (8.7, 13.5), and the install script has been retired (8.7, 8.8). Vivid's mpv `0002` already links (`546e11f`), and the pipeline checks linkability on every slice (`ad498b4`, 8.5).
3. **libass threading.** The libass series restores today's cost on static events (13.4), but rendering stays on one thread. Device check 46 decides whether that is acceptable, or whether Vivid wants its own threading work later. Device checks 65 and 66 settle the font-fallback and static-subtitle costs on devices.
4. **Bundle identifiers.** Closed: the pipeline's frameworks use the prefix `com.blurbery.vivid.lucid.` (blurbery's decision, 13.5).
5. **macOS.** Nothing here supports macOS. If Vivid ever builds a macOS slice, the VO's meson feature and the omitted macOS paths need revisiting.
6. **Licence of the libdovi patch.** Closed: MIT, matching libdovi (1.3), as the package's NOTICE and the app's notices state.

### 11.3 Documents to update

- `docs/playback/player-bridge-spec.md`: the earlier corrections (the reason given for the `video-zoom` row in 7.2, the main-thread list and the cover-art case in 7.2, and three corrections to 6.19) landed in commit `8e87834`. One more has been written out for the bridge editor: in 6.19 and 17.7, `ao-avfoundation-compressed-first-start-grace` says every speed change across 1x creates a new audio output instance, which holds only on AC-3 and E-AC-3 tracks (1.7). It is now applied there, with the explanation in the bridge spec's 17.11, and the bridge spec's 2.1 now lists this document.
- `THIRD_PARTY_NOTICES.md`, `iosApp/Resources/OpenSourceLicenses/README.txt` and `docs/cores/player-engine.md`, when the app links the pipeline's builds (8.9). Done for release `0.1.0`.
- `docs/cores/lucid-engine-build.md`: its patch table and "Still to do" list, as each new patch lands.

## 12. Amendments after implementation

Recorded after the first implementations of the audio output, the video output and the decoder work, from their behaviour reviews against today's engine and the coordinator's decisions, as behaviour only. Where this section differs from an earlier one, this section wins. Each implementer numbered its own questions, so the answers are given under the topic they concern.

### 12.1 Audio output

**Player item and asset (3.4.3, A25).**

- Each compressed player item is created from its asset with AVFoundation's plain item initialiser, so AVFoundation's default automatically loaded asset keys apply; Apple documents the plain initialiser as loading `duration`. The earlier statement in 3.4.3 that the item has no automatically loaded keys was wrong. Loading that key can change which loader requests AVFoundation makes while it prerolls, and when the item reports ready, which supervision (3.4.10) depends on.
- Every item of a format uses the same asset URL: one fixed custom-scheme URL per format, whose path ends in the format's extension, used again for each new item. Only the scheme and host are the implementer's choice.

**Recovery seek (3.4.10).** The seek is the item's `seekToTime:completionHandler:` with a nil handler, on the AO queue, followed at once by the second rate-1 request on the player. The log lines come first, and the seek-attempted mark and the new deadline are set before the two calls.

**After a fallback (3.4.12, 3.4.13; audio questions 1 and 2).** A requested fallback stops the feed steps, not the transport calls. Until mpv's reload tears the AO down:

- `set_pause(false)` on an item whose rate 1 was requested asks for rate 1 again, moves the deadline to now plus the ordinary grace when it is not cleared, records a pending resume and resets the anchor pacing time and count, exactly as without a fallback;
- `start` on an item whose rate 1 was requested asks for rate 1 again;
- `start` with no item (after a `reset`) still creates a new asset and item, attaches the loader and makes the item current, but never requests its rate; the item's loader requests are queued, never served, and finished as cancelled when the output is torn down;
- each of these logs its trace edge and arms the feed timer, and the feed step that follows does nothing.

**When clocks are read (3.4.7 to 3.4.12; audio question 6).** Every reading is taken fresh where it is used, not shared across a feed step:

- the feed position at the top of each fill iteration, and again inside each read for the prefetch guard;
- the compressed clock inside each read (together with mpv's clock, for the end time of 3.4.8), at the start-anchor test, once for resume detection and the resume-anchor test together, at supervision's engagement test, and once each for the status line and the heartbeat;
- mpv's clock inside each read; once after filling, shared by start anchoring, resume detection and resume anchoring for their tests and for the anchor pacing time they record; and once at the start of supervision, for every row;
- on `set_pause(false)`, the compressed clock once for the `resume` trace edge and again, after the rate-1 request, for the recorded resume value, and mpv's clock separately for the deadline and for the recorded resume time.

**Flush times (2.9, 3.3.3; audio question 7).** A restart notification's flush time is printed exactly as `CMTimeGetSeconds` returns it: `inf` or `-inf` for an infinite time, `nan` for an invalid or indefinite one. Vivid's adapter accepts only digits or `nan` in that line and the line holds no fault substring, so a line with `inf` is dropped, as today; the `notification name: ` line before it is still recorded.

**Accepted difference: item creation fails (audio question 3).** If the asset or the item cannot be created at `start`, the AO logs a fatal line (wording free within the rules of 2.9, so it records no fault) and falls back to PCM as 3.4.13 says. Today's engine has no such check: the player is left with no current item, the `start` edge is logged, the timer is armed and every feed step does nothing until a later `reset` and `start`, so audio stalls. A valid custom-scheme URL and asset do not fail to create, so the case is unreachable in practice (12.8).

**A hazard both engines share (device check 60).** The feed step at the end of `start` runs on the AO queue before AVFoundation's first loader request can arrive there. If that first step writes more than the 2 MiB of history kept below the write head (3.4.4), the first request, at offset 0, is already below the window and the item fails into a PCM fallback. Draining mpv's queue alone (2 s, or 1.25 s with Vivid's AirPlay setting) would need about 8.4 Mb/s, above E-AC-3's 6.144 Mb/s maximum. But mpv's core thread can refill the queue while the step reads, and with the step's cap of 64 reads (6.4 s) about 2.6 Mb/s is enough: a legal E-AC-3 rate, though above common streaming and disc rates. Today's engine behaves the same, so parity keeps it; device check 60 looks for it.

### 12.2 Video output: timing

- **Anchor offset (4.8.2).** The `mp_time_ns()` reading in the anchor's source time is taken immediately after the timebase source clock is read, inside the anchoring step. A reading taken earlier in the frame makes each anchor land late by the time in between, which can reach tens of microseconds when verbose lines are formatted in that interval. A pause anchor runs at rate 0, so its source time has no effect.
- **Servo integral (4.8.2).** The integral gains (*P* × Δ) ÷ *Ti* with Δ and *Ti* both in nanoseconds: *P* times Δ first, then one division by 8,000,000,000. Converting Δ to seconds first, or dividing in another order, can change the last bit of a rate write. The reference servo of 9.4 item 5 uses the same order.
- **Out-of-range media times (4.8.2; video question 9).** `MP_NOPTS_VALUE` and non-finite values are invalid. A finite `pts` whose nanosecond value does not fit in an int64 (|`pts`| above about 9.22 × 10⁹ s) is valid and saturates to the largest or smallest int64. Every value inside the range converts as 4.8.2 says, negative times included (−0.0 gives 0).
- **Ideal frame duration below 1 ns (4.8.3).** The display-synced duration is used when `ideal_frame_duration` in seconds is positive. If it then truncates to 0 ns, *d* is 0 and the frame is an unusable duration: no estimate, the stored sample unchanged, and no fallback to `vo_frame.duration`.
- **Fast-window tolerance (4.8.3; video question 2).** The test that empties the fast window compares *r* with the window's own ratio, its media-step sum divided by its duration sum before the new step is added. The tolerance is 4% of that ratio, not of *r* or of the nominal rate.
- **Readiness wait (4.10).** The first readiness check and the give-up test run as 4.10 says. After that, each round of the wait checks, in this order: readiness (proceed); the give-up moment (drop); whether the renderer needs recovery (run the throttled recovery, and drop if it still needs one). Only then does it sleep 1 ms. After a recovery that leaves the renderer healthy, readiness is checked again at once, without a sleep. The wait recorded for the pacing summary lasts until the wait returns.
- **Adoption of a speed change (4.10, 9.4 item 3; video question 1).** Frame *k* below is the *k*-th frame whose `vo_frame.duration` reflects the new speed.
  - A change above 4% with a new frame duration under 500 ms is adopted on frame 3. Frame 1 is a discontinuity, or, when its duration step stays inside the 250 µs gate, a near-nominal step still measured against the old duration; frames 2 and 3 fill the fast window. The averaging window never produces a blended adoption here.
  - With a new frame duration of 500 ms or more, a change above 4% is adopted on frame 2: the discontinuity at frame 1 has emptied both windows, and frame 2's single step, too few for the fast window, fills the averaging window on its own, which gives the estimate.
  - A change of more than 1% and at most 4% with frames of 500 ms or more is also adopted on frame 2, since each such frame completes the averaging window by itself. The 520 to 580 ms and 710 ms figures in 4.10 apply to shorter frames.
  - If the adoption frame does not reach the timebase step (dropped, or paused), its estimate is discarded (4.8.3). With frames under 500 ms both windows were emptied, so adoption moves to frame 5, or frame 7 after two such losses. With frames of 500 ms or more the fast window still holds frame 2's step, so frame 3 adopts, or frame 4 after two losses.
- **Pacing summary (4.18).** A 5 s window's summary is emitted when at least one of these is non-zero: readiness waits, deadline drops, anchors, rate writes or the largest phase error. A window whose only event is a recovery emits nothing. The largest phase error is sampled only on frames that reach the phase-error test of 4.8.2 (a valid anchor, neither playback nor the timebase marked paused, and no nominal-rate change on that frame), so a frame that anchors because the nominal rate has just changed does not count, while a frame whose error is above the 50 ms limit after a valid anchor does (13.1). The first window opens at the start of the first `flip_page`. Extra fields, such as a recovery count or the longest wait, are allowed.
- **Subtitle sample due but not enqueued (4.9 step 5; video question 6).** A subtitle sample is due when subtitles are on the separate layer and the pending mark is set once that flip's subtitles have been rendered. Whenever a due sample is not enqueued, for any reason, change tracking is reset, so the next frame renders again, and the pending mark stays as it is. The reasons are: the subtitle sample could not be built (no canvas, no pool buffer, or a format description or sample failure); the video sample could not be built (a hardware frame without a buffer, an upload failure, or a format description or sample failure); the frame was dropped at the readiness deadline, by any of the three kinds of drop; or the subtitle layer was not ready, or is absent. Only the not-ready case logs its verbose line and counts a subtitle sample drop; a deadline drop counts only the video drop. The mark stays set unless a recovery in the same flip cleared it (next item).
- **Pending mark after a recovery (4.11; video question 7).** A recovery that runs, forced or allowed by the throttle, resets change tracking and clears the pending mark; one the throttle suppresses changes nothing. If the recovery runs during the readiness wait, after this flip's subtitle sample was built, and the frame then proceeds, that sample is still enqueued. If the frame is dropped instead, nothing is enqueued and the mark stays cleared. A pending clear is then lost: nothing is cached, so nothing renders again, and because the recovery flush keeps the displayed image, the subtitle layer can go on showing a subtitle that has ended until the next subtitle change. A subtitle that is still showing is unaffected: tracking was reset, so it renders again on the next frame. Keep this.
- **What a reset clears (4.13; video question 8).** `VOCTRL_RESET` clears the next frame's target host time (to 0), its media time (invalid) and its rate estimate (absent), and also the last media time, the anchor, the servo and the whole estimator, previous sample included, while leaving the nominal rate and the pause state as 4.13 says. No image is released, because none is held between flips. mpv runs `VOCTRL_RESET` at the top of the VO loop, never between `draw_frame` and `flip_page`, so before the next `draw_frame` the cleared values can show only in the media time of a recovery warning (which then falls back to the timebase, reading 0 after the media-mode reseed) and in the pause fallback for a non-numeric timebase, which never happens.

### 12.3 Video output: picture path and teardown

- **Core Image cannot wrap the frame (4.14.7).** When the Core Image fallback cannot wrap the video buffer as an image, it produces no composite and the frame goes out as decoded, without the subtitle, as today. It must never render the subtitle over an empty picture. On macOS, Core Image wraps none of `y416`, `v210`, `b64a`, `r408` and `v408`. FFmpeg asks VideoToolbox for `y416` for sources with alpha and more than 8 bits, such as ProRes 4444 with alpha, which Vivid decodes in hardware where the device can, so the case is reachable in Picture in Picture.
- **Core Image output format (4.14.7; video question 4).** Half float (`kCVPixelFormatType_64RGBAHalf`) is used only for `x420` and `xf20` sources (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` and `kCVPixelFormatType_420YpCbCr10BiPlanarFullRange`). Every other source gets `kCVPixelFormatType_32BGRA`, including the 10-bit 4:2:2 and 4:4:4 biplanar codes (`x422`, `xf22`, `x444`, `xf44`) and the 16-bit biplanar ones.
- **Blending once, in place (7.3 item 1).** The Picture in Picture YUV composite of a hardware frame is blended into the decoder's own buffer, with no full-frame copy. Before blending, the VO keeps the original pixels of the frame rows that the blend rectangle spans, in both planes, and writes them back only immediately before that same buffer is presented again. (Superseded wording: this said "before the same buffer is blended again or enqueued again". 4.14.9 and 13.1 give the rule: nothing is written when compositing switches off, and a same-buffer redraw builds its composite away from the buffer and writes only the rows that change.) So each displayed image carries the current cue exactly once, a sample enqueued with compositing off carries none, and the blend still runs once per image. This is the "keep the original pixels and restore them first" choice that 7.3 item 1 allows. All its guarantees hold, and its last bullet (a copy's buffer comes from a pool) no longer applies to these composites, because nothing is copied.
- **Bounding box (4.14.5).** For each drawn part, the left (`x`), top (`y`), right (`x` + `dw`) and bottom (`y` + `dh`) edges, with the defaulting rule, are each clamped to the canvas on their own, and the union is then taken over the clamped rectangles, including any that came out empty. A part lying wholly outside the canvas therefore still pulls the box out to the canvas edge beyond which it lies. On the separate layer this only changes the area cleared next time. In frame space it matters when every drawn part lies off the frame, on different sides: the box is then not empty, the YUV blend runs and changes nothing, and the decoder's frame goes out untouched, Dolby Vision included, where a box built by intersection would be empty and send the frame to Core Image.
- **CoreGraphics part sizes (4.14.5; video question 5).** The CoreGraphics path draws each part into the rectangle built from its raw `dw` and `dh`. A `dw` or `dh` of 0 gives an empty rectangle, so nothing is drawn, while the path choice and the bounding box still count that 0 as `w` or `h`, so the box covers an area left blank. A negative size is standardised by CoreGraphics, so the part is drawn at |`dw`| × |`dh`| in the box that ends at the part's (`x`, `y`) corner, above and to the left of its usual place: an 8 by 6 part at (10, 5) with `dw` −4 and `dh` −3 covers columns 6 to 9 and rows 2 to 4. This is unreachable in practice (libass parts always have `dw` equal to `w`), but keep it.
- **Path choice (4.14.5).** Only parts that are drawn (with a bitmap and a positive width and height) count when choosing between the direct and CoreGraphics paths; a skipped part never sends its object to CoreGraphics.
- **Core Image context and Metal device (4.14.7, 4.14.9; video question 10).** Both are created together, on demand, the first time the fallback is reached, and kept across resets, reconfigurations, resizes, failed composites and every other control. They are released only in an option refresh in which the Picture in Picture compositing flag changed and is now off (after the subtitle cache is cleared and before the subtitle layer is flushed and synced, as 4.14.9 step 3 orders it), and at teardown, after the pools, the cached format description and the subtitle layer are gone and before the host layer reference is dropped. If the context cannot be made, the Metal device is dropped with it, so both are created again at the next attempt.
- **Pool buffer attachments (4.3, 4.6, 4.14.7; video question 3).** Buffers taken from any of the VO's pools are neither seeded nor cleared. The VO then adds exactly what earlier sections say: uploads add primaries, transfer, matrix and a derived colour space; the pixel-aspect step adds or removes its attachment on every enqueued buffer; YUV copies, where one is made, and Core Image outputs get the metadata copy of 4.14.7 (an RGB output also loses the matrix and gains a derived colour space if it has none); subtitle buffers get nothing from the VO, which is what 4.6 means. On macOS, CoreVideo hands out pool buffers, fresh or recycled, carrying one propagating attachment of its own (a horizontal disparity adjustment of 0), as VideoToolbox's buffers do, and nothing set on a buffer survives its return to the pool. iOS and tvOS are unverified (device check 59).
- **Layers released on main at teardown (4.16.5, 4.16.6; coordinator decision).** The VO's last references to the host layer and the subtitle layer are released on main, which keeps either layer from being deallocated on another thread. The release is queued to main asynchronously after teardown's synchronous hops, and teardown does not wait for it, so the synchronous hops of 4.16.6 are unchanged.

### 12.4 Decoder

**Frame attachments (replaces 5.7; decoder questions 5, 6 and 9).** Vivid's decoder runs with frame threading: mpv opens VideoToolbox with `hwdec-threads` at its default of 4, and Vivid keeps that. Under frame threading, today's engine runs no Dolby Vision specific step at frame output, so every VideoToolbox frame, `dvh1` included, gets pristine FFmpeg's attachments. 5.7 now requires exactly that, at every thread count. From the frame's own colour fields, that step:

- sets primaries, transfer and matrix from the VUI, or removes them where the VUI leaves them unspecified;
- sets the chroma location from the frame (left by default for 4:2:0 HEVC, top-left when signalled);
- sets the pixel aspect from the sample aspect ratio, or removes it when that is unknown;
- removes gamma;
- derives a colour space from the result on iOS, and removes any colour space on tvOS, where pristine FFmpeg compiles the derivation out.

`DolbyVisionRPUData` and VideoToolbox's other keys are left alone. Consequences:

- Profile 5 (VUI colour unspecified, the normal case): FFmpeg removes the PQ transfer VideoToolbox attached, and the VO's repair (4.4) puts it back, so the repair is load-bearing.
- Profile 8 whose VUI disagrees with the session's colour extensions (8.2 with an SDR BT.709 base, compatibility 0, 8.x with no VUI colour description, or 8.4 whose VUI is not HLG): the frame tags follow the VUI, or are removed where it has none, and then only the VO's repair adds PQ. The colour extensions of 5.2 still describe the session; hazard D3 concerns them only.
- On Apple TV no VideoToolbox frame carries a colour space: HDR10, HLG and Dolby Vision alike.
- Nothing in Vivid reads a decoded buffer's attachments: Match Content, the display criteria and the format hint come from mpv properties. The attachments reach only the layer, through the buffer and the format description the VO builds from it (4.6).
- Questions about which session's flags apply during a restart, to frames in flight across a hwaccel re-initialisation, or to deriving a colour space for `dvh1` frames on tvOS no longer arise, because the output step does not depend on the session.
- Tests must cover 4 decoder threads as well as 1; a single-threaded test cannot show the difference.

**Accepted difference: no sample of RPUs alone (5.5 item 2; decoder question 4).** When a frame ends with its bitstream still empty (none of its slices reached the hwaccel and the packet carried no parameter set or SEI, for example after a reference-list failure on a corrupt stream, or an allocation failure), no RPU is appended and nothing is submitted, so the frame fails through pristine FFmpeg's invalid-data path, with no session restart. Today's engine appends the RPUs anyway; VideoToolbox (measured on macOS) then reports bad data with no image, which flags a restart, and later frames fail with missing references until the next keyframe. mpv sees one error for the frame either way; the new behaviour fails fewer frames afterwards (12.8).

**Other answers to the decoder implementer's questions.**

- A `dvh1` format description that cannot be created (question 3): session start fails with pristine FFmpeg's format-description error before any session is attempted, and there is no plain HEVC retry, which follows only a refused session. At hwaccel initialisation the hwaccel fails to open and decoding continues in software. On a restart that frame fails, and every later frame fails for want of a session, with no further restart attempt, until mpv's tolerance (6.1) falls back to software after two keyframes in the error run or 240 errors.
- The profile 7 NAL filter (question 7): today it filters only the slice path, by stream class, on `dvh1` and retried plain sessions alike. It never removes anything in practice, because hevcdec never routes type 62 or 63 NAL units to the hwaccel; RPUs reach VideoToolbox only through the end-of-frame forwarding, and the enhancement layer never does. Filtering the parameter-set path as well changes nothing.
- The HLG base (question 8): profile 8 with a compatibility id of exactly 4, read unmasked. An id of 20 is not HLG for the colour extensions, even though the atom writes it as 4. Profile 7 is never HLG; it is presented as compatibility 1.

**VideoToolbox facts for the device checks.** Measured on macOS, the same with both engines; iOS and tvOS may differ (device checks 62 and 63):

- VideoToolbox fails a `dvh1` frame whose RPU was stripped (no image), and FFmpeg then restarts the session. So an RPU skipped under 5.6 makes its frame fail at VideoToolbox's level, today as well; FFmpeg still submits the frame.
- VideoToolbox refuses a `dvh1` session for profile 8 with compatibility id 0 or 6 (bad data), so those streams take the plain HEVC retry. It accepts compatibility id 2, but then fails every frame (malfunction) when the RPUs carry 8.1 payloads.

### 12.5 libdovi

- **All six abort classes confirmed.** Each class in 5.13 was confirmed on CI by running unpatched 3.3.2 on its corpus entries, each in its own process.
- **Large counts depend on the platform.** Which very large Exp-Golomb counts make unpatched 3.3.2 abort depends on the platform's allocation behaviour, so a count that aborts on one host may not abort on another. The corpus must still show the class aborting on the test host, but an individual count value need not abort there. The patched build refuses every such count as a parse error (rule 5) on every platform.
- **A field holding the largest unsigned 64-bit value.** An Exp-Golomb code with 64 leading zeros parses to the largest unsigned 64-bit value, in a field that parsing only stores, so such an RPU parses. Unpatched 3.3.2's writer cannot encode that value: it first emits about 512 MiB of zero bits and then fails. Vivid's patch refuses to write such a field up front, before reserving anything. The result is the same write failure, so in FFmpeg's conversion the RPU is skipped with the stage and stripped warnings as today, only without the memory; the error text may differ (rule 3). libplacebo never writes, so its sequence is unchanged.
- **The header rule and conversion mode 4.** The header rule of 5.13 item 2 (no header when the display-management query would fail although the header says that data is present) changes a result on input that does not abort in one case only: an RPU without display-management data that has been converted with mode 4. Neither caller does that: FFmpeg converts with mode 2, and libplacebo does not convert. So rule 3 holds for both callers, and the comparison tests of 9.4 leave that case out.

### 12.6 Build and tests

- libdovi is built from source as the eleventh framework, `Libdovi`, with a pinned stable Rust toolchain (1.98.0). That toolchain ships a standard library for every slice's target, tvOS included, so neither a nightly toolchain nor a standard-library build is needed (8.4). The header, the pkg-config name and the exported functions are unchanged.
- The symbol closure and the app-style test link of 8.5 run on every slice. They found the missing CoreFoundation string helper that 2.11 describes, since fixed.
- An end-to-end test of the hardware decode error tolerance (6.1) through mpv needs host builds of libplacebo and libass from source. The libass host test now builds libass, FreeType, FriBidi and HarfBuzz for the build host (13.4), but nothing builds libplacebo for it yet, so the test is still deferred; device check 36 covers the behaviour meanwhile.

### 12.7 Device checks added to 9.5

59. **Pool buffer attachments** (12.3): in a debug session on iPhone and Apple TV, print the attachments of an upload buffer, a Core Image composite output and a subtitle buffer, both fresh and recycled. Expect only what 12.3 lists, plus at most CoreVideo's own disparity attachment, and nothing left from a buffer's earlier use.
60. **First feed against the loader** (12.1): high-bitrate E-AC-3 (near 6 Mb/s, with Atmos if available) from 0:00 and after seeks, over HDMI and over AirPlay, side by side with today's build: no `loader requested offset` error and no fallback at start. Compare the loader request lines, the `item status` lines and the `compressed clock engaged after` times with today's build.
61. **Dolby Vision frame attachments** (12.4): in a debug session of today's app, read `hwdec-threads` (expect 4). Then, in both builds, on profile 5, 7 FEL, 7 MEL, 8.1 and 8.4 titles and an 8.x title with a missing or SDR VUI colour description, print a decoded buffer's attachments where the VO enqueues it. They must match, including the chroma location and, on Apple TV, the absence of a colour space.
62. **Profile 8 sessions by compatibility id** (12.4): profile 8 with compatibility id 0, 2 and 6 on Apple TV and iPhone. Record whether the `dvh1` session is accepted, refused (one retry warning, then plain HEVC) or accepted with failing frames, and compare with today's build.
63. **Frames without their RPU** (12.4, 5.6): if a profile 7 title with an RPU that libdovi rejects without aborting is available, record whether VideoToolbox fails that frame and the session restarts, and compare with today's build.
64. **Picture in Picture on frames Core Image cannot wrap** (12.3): ProRes 4444 with alpha, with subtitles, in Picture in Picture on iPhone and iPad. The picture stays while a cue shows (the cue itself is missing, as today), and nothing else differs from today's build.

### 12.8 Accepted differences found after implementation

These are accepted in addition to 7.3. Everything else must still match today's engine.

| Area | Today | Now | Why accepted |
| --- | --- | --- | --- |
| Audio output: the asset or item cannot be created at `start` (12.1) | No check: no item, every feed step does nothing, and audio stalls until a later `reset` and `start` | A fatal line and a fallback to PCM | Unreachable in practice, and the new path plays audio |
| Decoder: the frame's bitstream is empty at frame end (12.4) | The RPUs are submitted alone; VideoToolbox reports bad data and the session restarts | Nothing is submitted; the frame fails without a restart | An error path only; mpv sees one error for the frame either way, and fewer frames fail afterwards |

## 13. Amendments after the fix rounds and the library work

Recorded after the video output's two further fix rounds and their behaviour re-checks against today's engine, the integration of the audio output, video output and decoder work into the pipeline (`10faa2a` on `experiment/lucid-engine-build`, CI run 38400124717), a parity check of those integrated binaries against today's engine, the libass work (`experiment/lucid-engine-libass` at `6884b24`) and the libraries built from upstream source (`experiment/lucid-engine-libs` at `ac945ce`). As in section 12, everything here is behaviour and decisions. Where this section differs from an earlier one, section 12 included, this section wins.

### 13.1 Video output

**Pacing summary (4.8.2, 4.18, 12.2).**

- The largest phase error is sampled only on frames that reach the slew decision of 4.8.2: a frame with a valid media time and a valid anchor, with neither playback nor the timebase marked paused, and whose nominal rate did not change on that frame. It is sampled before the 50 ms test, so a frame whose error is above the re-anchor limit after a valid anchor still counts.
- So these are never sampled: the first frame after creation, a reset (every seek), a resume or a recovery; every frame while paused, paused redraws included; and the frame that adopts a new nominal rate.
- A first implementation sampled every frame that kept its nominal rate. That put the media position (seconds to minutes) into the figure of every window with a start, seek, resume or recovery, and a paused redraw's error into others. Trial traces only, but the figure is meant to be the servo's real error, so the rule above is required.
- Recoveries alone never trigger the summary line. A window whose only event is a recovery, for example the forced presentation-resume recovery in host mode on tvOS, logs nothing; the same window with one deadline drop logs one line. The line may report a recovery count as an extra field (12.2).
- A timebase marked paused while playback is not cannot happen (pausing sets both marks, and every other step sets the timebase mark from playback's), but such a frame counts as paused.

**Switching Picture in Picture compositing off (4.14.9, V15).** The rewrite composites hardware frames into the decoder's own buffer and keeps the original pixels of the rows it changes (12.3).

- An option refresh that turns compositing off does what 4.14.9 step 3 lists and nothing more. It writes no video buffer, so the displayed decoder buffer keeps its burned-in cue, as today, until the next frame or redraw.
- The kept rows are written back only immediately before that same buffer is presented again (the next redraw while paused, for example), so that sample shows the decoded picture with no cue.
- If a different buffer is presented first, or the VO is torn down, the kept rows are released and the composited buffer is not written.
- Off, then on again, then a redraw with the same cue blends the cue exactly once and writes no row.
- The kept rows of a buffer are freed whenever they are written back or let go. The VO holds a reference to the last composited decoder buffer until a frame with a different buffer is presented, or teardown; this adds no memory in practice, because the display layer holds that buffer while it is on screen or queued.
- A first implementation wrote the kept rows back at the switch, into the buffer on screen, where the system may pick up the write at once, part way or not at all. Today never writes there. The rule above is required.

**Same-buffer redraw with compositing on.** When the buffer to present is the one the VO last composited into (a paused redraw, a cue change while paused, a resize while paused):

- The VO builds the new composite away from the buffer: in scratch memory covering the union of the old and new blend rectangles (its corner rounded down to even coordinates), starting from the kept original rows, blended once with the arithmetic of 4.14.7.
- It then writes into the buffer only the rows whose bytes change, each once. An unchanged cue writes no row.
- Every presentation therefore equals the current cue blended once over the decoded picture, and the displayed picture never passes through a state without its cue.
- The rewrite writes the luma and then the chroma rows that gain the new cue first, and then the luma and then the chroma rows that only lose the old one. For a moment a row can carry the new cue's luma with the old chroma: accepted (13.8).
- This replaces 12.3's wording "writes them back before the same buffer is blended again or enqueued again".

**Order against the readiness wait.** The composite, including a redraw's rebuild, is still made before the readiness wait, as today. A redraw that is then dropped leaves the decoder buffer with the new cue blended once, where today leaves the new cue over the old composite.

**Error paths (accepted, 13.8).**

- **Core Image fallback on a buffer that carries the previous composite.** When the YUV composite cannot be made (the decoder buffer or the subtitle canvas cannot be locked, the scratch or kept-row store cannot grow, there is no canvas, the drawn box is empty, or the blend rectangle maps to nothing), the rewrite first writes the kept rows back, so the buffer shows the decoded picture. It then takes the Core Image fallback from that clean picture; if Core Image cannot be used either, the sample is the decoder buffer with no cue. Today renders Core Image over the buffer as it stands (the old cue under the new one), or sends the old cue alone. On these error paths only, the displayed picture can be without its cue for a moment: on a Mac, the write-back plus the Core Image render took 10.5 to 11.3 ms at 4K, before the readiness wait and display latency.
- **A decoder buffer that cannot be locked for writing.** Today falls back to a pool copy with the YUV blend; the rewrite goes to Core Image (RGB output). A failed kept-row allocation does the same. Lock failures on IOSurface-backed buffers do not occur in practice.
- **Kept rows that cannot be written back** because the buffer cannot be locked: the rewrite logs an error (4.18, wording free) and leaves the cue in the buffer, where a later composite blends over it, as today's would.

**Other harmless differences (13.8).**

- The rewrite logs the missing-layer line (`wid` −1) at verbose while mpv is autoprobing video outputs and at error otherwise; today always logs it at error. Vivid always sets `vo=avfoundation` together with `wid`, so mpv never probes and the line never appears. Error level throughout would be exact parity.
- The rewrite closes a pacing window at the end of `flip_page`, after that flip's frame is presented, so the frame presented in a window's closing flip counts in that window; today it counts in the next one.
- Two microsecond-scale races in the readiness wait. A renderer that becomes ready just after the wait's first readiness check, microseconds before its first give-up test, can proceed at once today, and proceeds after one more 1 ms poll in the rewrite. When a recovery inside the first pass runs past the deadline and the layer is then not ready, the two may log different drop kinds ("already past" against "reached while waiting"), and a frame that proceeds after such a recovery without a sleep may be counted as a ready-wait in one and not the other. Drop counts are the same.
- Production code holds a per-row observer hook (a null check per written row) and a Core Image state accessor, for host tests only; the output sets no observer.

**What the re-checks measured** (host comparisons with today's code, on a Mac):

- Timing: the estimator (800,000 fuzzed frames), speed-change adoption frames, per-frame anchors, rate writes, sample times and phase-error sampling are identical to today's; readiness decisions, drop counts, drop kinds, recovery logs and times are identical.
- Pixels: 11,744 picture-path checks identical. The rewrite's blends and uploads are bit-identical to today's (exhaustive libass and BGRA blend sets, 20,000 fuzzed blends and 3,000 fuzzed uploads) and faster: 1.4 to 4.8 times for the blends and up to 11% for the uploads.
- A first composite of a new frame costs about 1.1 to 1.25 times today's in-place blend (0.63 to 0.69 ms against 0.55 to 0.57 ms for a 2000 by 250 cue at 4K). The cost of a same-buffer redraw and its memory are in 13.8.
- Similarity: the fix rounds' code is independent of today's.

### 13.2 Decoder: a Dolby Vision configuration that cannot be added

- **The line.** The rewrite's FFmpeg Dolby Vision patch logs one line at `AV_LOG_ERROR` (5.9) when it cannot add the Dolby Vision configuration to the decoder specification of a `dvh1` session. Its wording is free and currently reads "Could not add the Dolby Vision configuration to the decoder specification". The app receives it with the prefix `ffmpeg/video`, after the codec name (`hevc: `), at level `error`, in Release and trial builds alike. It contains no fault substring of 2.8, so the adapter records nothing, and nothing else in Vivid reacts to it.
- **When.** At most once per failed Dolby Vision session start: hwaccel initialisation, re-initialisation after a parameter change, or a pristine restart, at any decoder thread count. The only way to reach it in practice is a failed allocation of the 24-byte configuration record while a session starts, for HEVC with a usable profile 5, 7 or 8 record (5.1). iOS and tvOS normally end an app under memory pressure long before an allocation that small fails.
- **What follows.** Pristine FFmpeg's own decoder specification error (also `AV_LOG_ERROR`); the session start then fails before any format description or session is made. There is no plain HEVC retry, which follows only a refused session (5.3).
  - At hwaccel initialisation, pristine FFmpeg's hwaccel set-up error follows, the hwaccel fails to open and mpv continues in software (`hwdec-current` `no`), as 12.4 already says for a format description that cannot be created.
  - At a restart, that frame and every later one fail for want of a session, without another restart, until mpv's tolerance (6.1) falls back to software.
- **Today.** Today's engine leaves the configuration atom out silently in the same situation and attempts the `dvh1` session without it. What VideoToolbox then does was not measured. Inferred: a refused session takes today's plain HEVC retry for profiles 7 and 8 and goes to software for profile 5; an accepted one decodes without the configuration. Accepted difference (13.8): unreachable in practice, and an error path in both engines.
- The patch's own description now says it logs two error lines in this case.
- **Test** (host, behavioural, not yet written): inject a failure of that allocation for profile 5, 7 and 8 records, at hwaccel initialisation and at a forced restart, at 1 and 4 decoder threads. Per failed start expect exactly the new line once and then the specification error once, both at `AV_LOG_ERROR`; no format description and no session creation; no plain HEVC attempt; at initialisation the hwaccel fails to open, at a restart later frames fail without another start; and no line on this path contains a fault substring.

### 13.3 Integrated parity

The integrated binaries at `10faa2a` (all four slices, eleven frameworks) were compared with today's engine: its LGPL reference builds of Libmpv and FFmpeg for the two device slices, and today's shipped package for libass, dav1d, libdovi and the simulator slices. Host comparisons drove both sides' sources or binaries through the same scenarios. No regression was found.

| Area | Verdict |
| --- | --- |
| Configuration and symbols | Matches today, apart from the expected and cosmetic differences below. All four slices pass the symbol closure and the dead-stripped test link. FFmpeg's configuration string, licence strings and component sets equal today's LGPL device engine's. On tvOS, every FFmpeg and Libmpv object outside the rewritten and dropped parts has today's code and constants, including the kept E-AC-3 carrier rate, output-chain wake and hevcdec log levels. |
| Audio output | Matches today. The same 30 scenarios on an iOS-like and a tvOS-like host build: after normalising the lines whose wording 2.9 leaves free, 25 (iOS) and 22 (tvOS) are identical, and the rest differ only as listed below. |
| Decoder and Dolby Vision | Matches today in Vivid's configuration (4 decoder threads): across 49 scenarios against real macOS VideoToolbox, every session creation, property, sample, decode call, callback, libdovi call, frame count and per-frame attachment is identical; only free-wording FFmpeg lines differ, with equal counts. At 1 thread Dolby Vision frames differ by design (12.4). The VO's pixel-aspect and Dolby Vision repair steps give identical buffers and format descriptions in all 21 combined scenarios. |
| Video output | Matches today, apart from deliberate difference 7.3 item 1 and the accepted error paths of 13.1: timing and pacing 0 differences, picture path 11,744 checks with 0 mismatches. |
| libass | Pixel-identical on the parity corpus (23,280 renders, and 8,410 in Vivid's configuration), but unpatched upstream reported static content as changed on every frame and repeated font fallback on every frame. Since resolved by the libass series (13.4). |

The CI run passed 265 checks per slice, which include the binary checks of 8.5 and items 1 to 4 of 8.6. Its test steps and jobs passed alongside: the 140 audio vectors, the decoder suites (534, 199,060 and 3,921 checks), 1,920 video output cases (in the `ios-arm64-simulator` job) and the libdovi corpus (its own host job).

Differences it saw, all decided or harmless:

- **Expected (7.1, 7.4):**
  - no `moltenvk` meson option or feature, and `-Dgpl=false`; against the shipped package, FFmpeg without its GPL, version 3, OpenSSL and `delogo` parts;
  - libavfilter's audio frame pools as upstream (FFmpeg 0020 dropped);
  - no spdif refusal in `ao_audiounit`, no `sub-video-rect-aspect` and no MoltenVK context;
  - no `list_devs` on iOS and tvOS;
  - version strings and the source paths in FFmpeg's assertion texts.
- **Accepted (12.8):** the AO's fatal line and PCM fallback when the item cannot be created.
- **Harmless:**
  - On tvOS the option table registers `ao-avfoundation-max-lookahead` last instead of first. The order cannot be observed.
  - The block-refusal line's wording, which 2.9 leaves free: same level, same position, no fault substring.
  - Bounded tvOS PCM: the order of calls inside one AO-queue block, extra calls that stop the renderer requesting data (bounded mode never uses readiness callbacks), and no synchroniser created when a replacement renderer cannot be created. No log line, rate change, enqueue, read, reload or notification outcome differs.
  - Zero-length or already complete loader requests are finished before the window and write-head checks, the reverse of 3.4.4's order, so such a request below the window or beyond the write head succeeds silently, where today refuses it (an error line with a fault, or a verbose line). Believed unreachable, because AVFoundation is not known to send zero-length requests. Optional fix: test the window base and the write head first.
  - The bounded tvOS PCM code is compiled into the iOS slices too, and is unreachable there because `max-lookahead` does not exist on iOS. All 25 frozen formats are in every slice's Libmpv, where today's iOS Libmpv lacks the five bounded-PCM lines.
  - The compressed asset URL is one fixed URL per format, with a scheme and host of the rewrite's choosing (12.1).
  - libavcodec's AV1 and VP9 VideoToolbox hwaccel objects differ in constant data only, with the total size unchanged. Inferred, not proven: the recorded size of the shared VideoToolbox context, which the Dolby Vision patch extends.
  - The link set needs Core Image again (the VO) and Security (Secure Transport), and no OpenSSL.
  - Cosmetic: module maps now end with a newline; prefix paths in FFmpeg's `config.h`; `8.0.1` instead of `n8.0.1` in FFmpeg's version header; libass's public header differs from today's, which today's patches change; Libmpv holds an empty CoreAudio properties object; Libdav1d records SDK 26.5 instead of 17.5. A `-Wundef` compiler warning in mpv's `ao_coreaudio_chmap.c` is shared with today's build.
- **Not covered by host comparison** (the device checks remain the test): real AVFoundation behaviour (item readiness, loader request patterns, AirPlay clock parking, HDMI passthrough, route changes, the audio session), iOS and tvOS VideoToolbox, real display layers and Picture in Picture, long-session memory, device fonts and libass cost on devices, and anything in the background.
- **Evidence the comparison did not keep** (low risk): cost and memory figures for the same-buffer composite at that commit (13.1 and 13.8 give the re-checks' figures); the decoder configuration sweep and the malformed-RPU corpus spliced into streams, last run before the 12.4 rework; section comparisons for the iOS and simulator slices and for duplicate-named FFmpeg objects; the local link exit codes; the raw traces behind the decoder log-line counts (equal counts do not prove equal levels; a scan of the patched sources shows the levels of 5.9). The subtitle comparison has not been re-run against FreeType, FriBidi and HarfBuzz built from source (13.5).

### 13.4 libass

**Today's library.** Today's libass is upstream 0.17.5 with three third-party patches (7.1). What it does, observably:

- an event without time-dependent overrides reports no change from frame to frame while it stays on screen, including a sign with a vector clip and a SubRip line in Vivid's background-box style (`BorderStyle` 4);
- font fallback for such an event is searched once, not on every frame, including characters no font covers and characters whose suggested font file cannot be opened;
- symbol fonts (Webdings, Wingdings, Wingdings 2 and 3) given text beyond their symbol range fall back to another font, as upstream master has since commit `057a5334`;
- when an event's first render gives up on characters whose suggested font cannot be opened, and a later character of the same render adds a face that covers them, it keeps the missing glyphs for that event's life; a later event with the same text is laid out afresh and is correct;
- it renders on every CPU by default, and its output is byte-identical with threading on and off.

**Unpatched upstream** (0.17.4, 0.17.5 and master alike) draws the same pixels on the parity corpus, but:

- It reports a change on every frame for a static vector-clipped sign and a static boxed SubRip line, because it rebuilds their images into new buffers every frame. Through the VO that is a re-render, and on the separate layer a new subtitle sample, on every frame. Measured on a Mac with the new VO: a boxed line costs 0.11 ms per frame median (0.65 ms p99) at 1080p and 0.31 ms (2.29 ms) at 4K on the separate layer, and 0.64 ms and 2.48 ms extra in Picture in Picture; a vector-clipped sign costs less in every mode; today's cost is about 0.001 ms. An Apple TV 4K (A15) is estimated at two to four times those figures.
- It searches font fallback again on every frame for every character without a usable font: about 0.11 ms per uncovered code point and about 0.4 ms per CJK character answered with a font file the process cannot open. On a Mac, where the PingFang files cannot be opened, that is 2.2 ms per frame for a mixed CJK SubRip line under Vivid's default font, 6.6 ms with Vivid's font set to PingFang SC, and 18 to 44 ms for authored files whose styles name PingFang or Hiragino; with mixed CJK text, 116 of the 180 font families Vivid's picker offers there repeat the search. Whether tvOS can open those files is unknown (device check 65).
- The repeated messages are libass warnings (its level 2), which mpv logs at `info`: trial builds receive them, Release builds do not, and the adapter ignores them either way.
- It differs from today's symbol-font behaviour (0.17.5 lacks `057a5334`), and in the CJK case above it shows the real glyphs from the event's second frame.

No upstream release or merged commit changes the first two points; upstream treats false change reports as acceptable.

**The series built now** (decided under blurbery's permission; 8.2):

1. `0001`: upstream libass commit `057a5334` ("ass_font: improve symbol font base offset", merged with upstream pull request #946, in no release yet), unchanged, with its upstream attribution. A symbol-encoded font's base offset is worked out from its character map instead of always being 0xF000, so symbol fonts given text beyond their range behave as today's.
2. `0002`: upstream libass pull request #951 ("render: cache rendered events") at its head commit `f96a521`, unchanged, with its upstream attribution; it was open, not merged, when taken. Events that do not depend on time (no `\move`, `\fad`, `\fade`, `\t`, karaoke or scrolling effect) are rendered once, and their finished images reused while nothing they depend on changes. The key is the event's text, style and margins plus an exact snapshot of the renderer's settings and the track's state. Entries are evicted least recently used beyond a 32 MiB budget, and dropped when the renderer is reconfigured or freed. So static events report no change and repeat no font search.
3. `0010`: Vivid's own patch (ISC), on top of `0002`, changing only that cache:
   - **Unresolved glyphs are kept per event.** A glyph is unresolved when no face provides a printable character after the fallback search. Output with an unresolved glyph is never shared between events: another event with the same text renders its own text once, with the faces that exist then, and never inherits a missing glyph.
   - **A face addition re-renders affected events once.** When any font gains a fallback face, each event whose cached output has an unresolved glyph is rendered once more, on its next frame, or on the same frame if it is rendered after the face was added. Glyphs the new face covers then appear when unpatched upstream shows them: in the CJK case above, from the event's second frame, where today keeps them missing. This costs at most one extra render, and one extra change report, per added face, and nothing while no face is added. A glyph that still cannot be resolved is not searched for again on later frames. Output without unresolved glyphs stays shared and unchanged, since a new face is appended and glyphs that were found keep their face.
   - **Effect is part of the key**, so an event with a Banner or Scroll effect never reuses the static output of an earlier event with the same text and stands still.
   - **Cloned images copy their type** from the image they clone (`0002` leaves it unset; mpv never reads it).
   - **The cache is emptied on every state-generation change**, that is whenever the snapshot of settings and track state changes (the shaper, line spacing, margin use, or the track's styles or header, for example), as well as on reconfiguration and when the renderer is freed, because entries of an older snapshot can never match again. The 32 MiB budget still bounds it in between.

   Everything else behaves as `0002` does: unchanged static output reports no change, and every real change reports the same value as before.
4. Rendering stays on one thread; no threading change is carried.

**Required outcomes.** Any implementation meeting these is acceptable; they are what the series was built and is tested against:

1. An unchanged static event keeps identical images (geometry, colours and bitmap bytes) from frame to frame and reports no change, while nothing it depends on changes (renderer settings, frame and storage size, track header, styles, fonts). This includes vector clips, inverse vector clips, rectangle clips and border-style-4 boxes.
2. Every real change is still reported, with today's value (0, 1 or 2) per render: moves, fades, transforms, karaoke, scrolling, animated clips and box colours, fading boxes, events appearing and leaving, and collision shifts. No render ever reports no change when its images differ from the previous render's.
3. For static events, font selection runs once per appearance: the characters that resolve, the faces chosen and the glyphs drawn equal today's on the first frame, and an unresolvable search is not repeated while the event is unchanged on screen.
4. A reused render never outlives a change in the faces available to it (the face-addition rule above), and two events with identical text never share a missing glyph.
5. Memory stays bounded and is released on reset and on settings changes.
6. Animated events behave as unpatched upstream (and today) do, including repeating an unresolvable font search on every frame.
7. A static event with unresolved glyphs searches for them once per appearance, plus once per added fallback face, whatever the cache pressure (below).

**Acceptance tests.** The libass host test job (`lucid.py test-libass`) builds libass for the build host five ways (upstream; `0001` only; `0001` and `0002`; the whole series; the whole series under AddressSanitizer), against FreeType, FriBidi and HarfBuzz at today's versions built for the host, and renders each scenario through every build:

- **Steady:** an opaque-box and a background-box SubRip line, signs with a vector clip, an inverse vector clip and a rectangle clip, an outlined line with a shadow, a drawing, a plain line, and all of them together, 240 frames each at 1920x1080 and 3840x2160. The patched build reports no change after the first render and repeats its images (the second render's, when a face was added at the first). Upstream must report a change on every frame for the background box and the vector clips.
- **Dynamic:** moves, fades, transforms, karaoke, animated clips and box colours, collision shifts, events appearing and leaving, and Banner and Scroll effects: upstream's change value on every frame.
- **Mixed** static and animated events: a change whenever the frame looks different.
- **Pixels:** styles, override tags, clips and drawings, 3D transforms, vertical Japanese, Arabic and Hebrew, emoji, wrapping styles, recurring lines, the same text with different effects, a code point no font has, layers and collisions, at 1080p and 2160p: upstream's drawing on every frame.
- **Symbol fonts** with Latin, Cyrillic, Greek, CJK and Arabic text: what `0001` alone draws.
- **Fallback:** a script whose suggested font file cannot be opened, a face added later in the same render and by a later or an earlier event, recurring lines with and without a face added between them, and a font file that appears while a line is shown: upstream's drawing on every frame (except while a newly appeared file is not yet added as a face); one search per unresolved glyph; one extra change report per added face and none after; a recurring line renders its own text.
- **Memory:** 400 distinct boxed lines at 2160p, resets and settings changes: the cache peaks between 24 and 40 MiB, its extra memory over upstream stays bounded and does not grow, and it is empty after every reset and settings change.
- **Every scenario:** every build finishes; the AddressSanitizer build gives exactly the patched build's results; a frame that looks different reports a change; a frame that reports no change repeats the previous images; every image has a valid type where no background box is drawn. Wherever no fallback search failed (and apart from the different-effects scenario), the patched build gives exactly the results of `0001` plus `0002`, so `0010` changes nothing else.
- **Result** on the libass branch (CI run 38433199206): 72 scenarios through all five builds, 8,862 frames per build, 9,532 checks, all passed.

The comparison with today's library itself needs today's binary, so it is the dirty side's review. It checks: every composite of the parity corpus and of the three-size, two-parse-mode run identical to today's (the `type` field ignored), except renders after an event's first render had missing glyphs, which must equal upstream 0.17.5's; every change report equal to today's, apart from one extra right after a fallback face is added; 240 steady frames per static case at 1080p and 4K; no false negatives; for every font family, today's output with Latin text on every frame, and with mixed CJK text today's first frame and upstream's last; symbol fonts equal to today's; per-frame cost of static lines with unresolved characters within 0.01 ms of today's; and through the new VO, no repack, render or subtitle enqueue after the first frame for a static boxed line or vector-clipped sign, at 1080p and 4K, on the separate layer and in Picture in Picture.

**Review against today's library.** The series at `6884b24`, built for a Mac host, was compared with today's library rebuilt from source, which reproduces today's shipped binary render for render:

| Item | Verdict | Numbers |
| --- | --- | --- |
| 1. Pixels | Matches today, with the allowed exception only | The Vivid-configuration corpus (8,410 renders) and the three-size, two-parse-mode run (23,280 renders) are byte-identical to today's, change reports and image types included. In the CJK corpus (9,730 renders) 147 renders differ from today's, every one equal to upstream 0.17.5's (the missing-glyph exception). |
| 2. Change reports | Matches today, with the allowed extras only | 0 differences in the first two corpora. CJK corpus: 3 extra changes, each on the render right after a fallback face was added and each a real content change. Acceptance file: identical to today's at 1080p and 4K (720 renders each, all ten segments). The branch's own 72 scenarios: 10 extra changes, each right after a face was added and each a real change. |
| 3. Steadiness, false negatives and fonts | Matches today, with one condition that could regress (below) | 12 steadiness runs of 240 frames: every frame equal to the first, or to the second when a face was added, with no change and no font message after frame 2. No false negative in about 67,000 renders. All 180 font families: with Latin text equal to today's on every frame; with mixed CJK text equal to today's on the first frame and to upstream with the symbol-font change on the last, with no font message after frame 2. A recurring CJK line shows its real glyphs (area 79,070 at 4 s, as today and upstream). |
| 4. Cost | Matches today; could regress under the same condition | Static fallback cases: median 0.000 ms per frame after the first frame, against today's 0.000 to 0.003 ms; the one-off re-render on frame 2 after a face is added costs up to 9.7 ms on a Mac, which upstream pays on every frame. Animated CJK with fades: 43.42 and 43.68 ms against today's 43.90 and 43.94 ms (1080p and 4K). Through the new VO: no repack, VO render or subtitle enqueue after the first frame for a boxed line, a vector-clipped sign and an outlined line, at 1080p and 4K, on the separate layer and in Picture in Picture. |
| 5. The implementer's choices | Effect in the key: matches today. Cloned image types: match today. Emptying the cache on every state-generation change: harmless and better than `0002` alone (it only releases memory; mpv's unchanged per-frame settings do not move the generation, so steady playback never empties it). Re-rendering after any face addition: harmless, the allowed extra. A font file appearing on disk while a line shows: harmless, every frame equals today's or upstream's output. Memory: harmless (below). Eviction of the shared record that marks output with unresolved glyphs: could regress (below). | |
| 6. Similarity of `0010` with today's patches | Independent | 0 of 78 lines of 20 or more characters shared; 7 of 124 winnowing fingerprints (5.6%), of which only 1 is not upstream code (a forward declaration dictated by upstream's signature); no token run of 20 or more tokens, where the independently written upstream pull request #951 has 13, up to 60 tokens, against the same reference; no shared comment apart from libass's ISC licence text. No rewording is needed. |

**Required: unresolved glyphs are searched once, whatever the cache pressure.** The review found one behaviour the series must change. When more than about 32 MiB of static images is on screen at once (four full-frame translucent drawings at 4K, for example), the cache budget evicts, at the start of every frame, the shared record that marks output with unresolved glyphs, although the event's own images are still in use. A static event with unresolved glyphs is then rendered and searched again on every frame: 1, 3 and 39 font messages and 0.11, 0.36 and 4.3 ms per frame on a Mac for an unassigned code point, an emoji line and CJK under a font that cannot be opened, where today logs nothing after the first frame and costs 0.003 to 0.004 ms. Change reports and pixels stay correct. The case is rare, but it repeats on every frame while it lasts. The rule the series must meet:

- A static event with unresolved glyphs searches for them once per appearance, plus once per added fallback face, whatever the cache pressure. Its reuse must not depend on bookkeeping that the cache budget can evict while the event's own images are in use.

Test (host, behavioural): render at 3840x2160 with storage 3840x2160, 120 frames at 24 fps, four static full-frame drawings (on a 1920x1080 script) with alpha `&HE0&` and no border or shadow, plus one static plain line containing U+0378. Expect no fallback message after frame 2; a per-frame median within 0.01 ms of the same run without the U+0378 line; no change after frame 2, and at most one change on frame 2, only when a fallback face was added on frame 1. Repeat with an emoji line instead, and with a CJK line whose style names a family whose font file cannot be opened.

**Accepted differences from the review** (13.8):

- **Missing glyphs replaced from frame 2**, as upstream does (above): 147 renders and 3 extra changes in the CJK corpus, and 112 of 180 families with mixed CJK text. It costs one extra change report and one repeated search on frame 2.
- **Face additions by other events.** After another event adds a fallback face, each event holding unresolved glyphs is rendered once more. For a boxed or clipped event this can report one change with nothing visible changing, and it repeats the failed search once per added face. Bounded.
- **Symbol fonts with several events.** The first frame equals today's single-threaded result, which is one of the outcomes today gives; today's own first frame varies from run to run with its render threads.
- **Memory.** About 11 to 14 MB more than today with boxed lines, because the cache keeps past events' box images, and about 1 MB or less with plain lines; bounded and flat, not growing. The cache's own accounting peaked at 34.4 to 36.6 MB in film-length runs. No leaks, and no AddressSanitizer report in 82 scenario runs.
- **The type of background-box images** is left indeterminate by upstream libass, and the series copies it as it is. mpv never reads it.
- **Log volume.** 1,191 lines against today's 1,171 in the Vivid-configuration corpus: the emoji file's search on frame 2.
- **Also harmless:** two renderers drawing the same track could share, or keep resetting, the per-event bookkeeping, which mpv never does; and a glyph that draws nothing but that the font lacks (a variation selector or a joiner, for example) counts as unresolved, so its event's output is not shared and is re-rendered after face additions, with no visible effect.

**Threading (open, 11.2).** Measured on a Mac with synthetic heavy karaoke and typesetting: single-threaded libass costs at most 4.3 ms per frame at 4K (fully animated karaoke), against 1.5 ms for today's library on six threads. With the series, static-heavy typesetting costs what today's library costs on one thread. At 4K the VO's own canvas work costs more than libass in both engines. Estimated for an Apple TV 4K (A15), animated 4K karaoke: about 8.3 ms for libass against 2.9 to 5.1 ms today, with 14 to 27 ms of VO canvas work in both. Device check 46 decides.

### 13.5 Libraries built from upstream source

- **What changed.** The eleven libraries that today come from the previous third-party build (FreeType 2.12.1, FriBidi 1.0.12, HarfBuzz 8.1.1, libunibreak 6.1, libplacebo 7.351.0, Little CMS 2.17, MoltenVK 1.4.1, shaderc 2025.5, uavs3d 1.2, libbluray 1.4.0 with libudfread 1.2.0, and uchardet 0.0.8) are now built by Vivid's pipeline from their upstream sources for all four slices, at today's versions and with today's options, features, flags, assertions, optimisation and per-library deployment targets (`experiment/lucid-engine-libs`, CI runs 38425539055 and 38434702061). None of them comes as a prebuilt binary any more.
- **Reached in Vivid's playback:** FreeType, FriBidi, HarfBuzz and libunibreak (libass, so every text subtitle); libplacebo (its CPU colour utilities, and the Dolby Vision metadata path through libdovi, 5.13); uchardet (text subtitles that are neither UTF-8 nor marked by a byte-order mark); uavs3d (AVS3 video, decoded in software). Little CMS, MoltenVK, shaderc and libbluray are linked but not reached, although MoltenVK's and glslang's static initialisers run at launch.
- **Kept as today, because they decide output:**
  - the exact versions;
  - FreeType without PNG, brotli, bzip2, HarfBuzz integration and mmap, and with the system zlib, so colour bitmap emoji do not render in subtitles and WOFF2 fonts do not load, as today;
  - HarfBuzz with every optional backend off and its built-in Unicode data;
  - assertions on in HarfBuzz, libplacebo, Little CMS and libunibreak, and off in the CMake builds and MoltenVK; libunibreak unoptimised;
  - libplacebo with libdovi and Dolby Vision support;
  - uavs3d with 10-bit decoding and its arm64 assembly;
  - the pkg-config names and versions consumers resolve, including `vulkan` 1.4.334 and the combined shaderc library;
  - the frameworks' names, module maps, header layout and Info.plist values, apart from the identifier prefix.
- **Vivid's own patches**, each under its library's licence:
  - **libbluray `0001`** (LGPL-2.1-or-later), needed to build for iOS and tvOS, with today's two effects there. There is no DiskArbitration lookup: the mount point of a block device is not looked up and none is found, and only CoreFoundation is linked. The Java home lookup never starts a helper process and behaves as if process creation had failed, so it finds no Java home. macOS builds are unchanged.
  - **uavs3d `0001`** (BSD-3-Clause): uavs3d's version header is fixed for tag 1.2 without Git history, so its build number, version (`1.2.1`), release type and pkg-config version are today's. The commit id in the start-up line uavs3d prints to standard output is uavs3d's own commit for the tag, instead of today's third-party build identifier.
  - The other nine are built unpatched. Today's build fix for libplacebo's code generator (an upstream commit with no effect on the generated code) and today's edits to SPIRV-Tools command-line tools that are not built are not needed.
- **MoltenVK.** Built with its SDK-gated feature paths compiled out, as today. Today's build never detects Apple GPU family 9; the new build detects it as upstream does. Accepted: Vivid never creates a Vulkan instance, so this is unreachable.
- **Checks** (683 per slice): each library against what today's build of it ships (form, minimum OS, Info.plist, module map and headers; defined global symbols by visibility, which equal today's exactly; weak definitions and imports, with the recorded toolchain differences; pkg-config files; the configuration read back; the per-library facts above). Vivid's own libraries built against these are byte-for-byte identical to those built against today's library binaries.
- **Accepted differences:**
  - **Toolchain:** Xcode 26.6 and its SDKs instead of Xcode 15.4 and SDK 17.5. Exported symbol sets equal today's. Weak-definition counts differ for HarfBuzz, shaderc and libplacebo, and a few imports differ, all libSystem or libc++ functions the app links anyway (for example libbluray calls `free` where today it read libxml2's free pointer). libplacebo's and Little CMS's floating-point results can differ in the last bit between compilers.
  - **Version strings:** libplacebo reports `v7.351.0` instead of `v7.351.0 (v7.351.0-dirty)`, which shows in mpv's version and log output; MoltenVK's revision string and SPIRV-Tools' description in shaderc differ (Vulkan and shaderc only, not reached); uavs3d's commit id differs (above).
  - **HarfBuzz optional headers:** the cairo and GObject headers and their feature macros are absent; nothing uses them.
  - **Assertion paths:** source paths in assertion messages differ, seen only if an assertion fails.
  - Smaller build details with no effect on the libraries: libunibreak is configured from its release tarball with the host name that tarball knows, and shaderc's command-line compiler is not built (it is not part of the combined library).
- **Bundle identifiers.** Every framework the pipeline builds, all 21, uses the prefix `com.blurbery.vivid.lucid.` instead of the previous package's prefix (blurbery's decision; 11.2 item 4). They are static frameworks, so the identifiers do not reach the app.
- **Package.** `blurbery/lucid-engine`, a Swift package of binary targets that serves the pipeline's frameworks. Vivid's app pins its release `0.1.0`.

### 13.6 Names

This document no longer names the previous third-party package, its build repositories or the third-party app from which Vivid's old player bridge was derived. "Today's engine", "today's shipped engine" and "the previous third-party package" mean the engine Vivid's app links on `main`, and "the previous third-party build of these libraries" means the eleven library binaries that package links today. The read rules of 1.4 keep their meaning: nothing from that package, the build repositories behind it and its libraries, forks of them, or that app may be read.

### 13.7 Device checks added to 9.5

65. **Font fallback on devices** (13.4). On Apple TV 4K (A15, and an A12 model if available) and an iPhone, in a trial build (libass's font messages arrive at mpv's `info` level, which only trial builds receive), side by side with today's build, play: a SubRip file with mixed Japanese, simplified and traditional Chinese and Korean lines under Vivid's default appearance; the same file with Vivid's subtitle font set to PingFang SC, and to Hiragino Sans; and an ASS file whose styles name PingFang SC and Hiragino Sans. After an event's first frame, look for libass saying a font cannot be opened (upstream's `Error opening font`) or that no fallback was found (upstream's `fontselect: failed to find any fallback`). With the series neither may repeat while an event stays on screen. Record which families open on tvOS, the VO's subtitle performance summary and dropped frames. Glyphs must match today's on the first frame; a glyph today leaves missing may appear from the second frame.
66. **Static subtitles at 4K** (13.4). A SubRip line in Vivid's background-box preset and a static vector-clipped ASS sign, at 4K, on the separate layer and in Picture in Picture, on Apple TV 4K and an iPhone: `frame-drop-count`, `vo-delayed-frame-count` and the VO's subtitle performance summary (renders, skipped renders, subtitle enqueues, render time) against today's build. Renders and subtitle samples happen only when a cue changes, not on every frame.
67. **Emoji in subtitles** (13.4, 13.5). SubRip and ASS lines with emoji, static and animated, side by side with today's build: the same drawing as today's (colour bitmap emoji do not render, because FreeType is built without PNG), and no font search repeated on every frame for a static line.
68. **Uncovered code points** (13.4). A static SubRip line with code points no font covers (unassigned or private-use), on screen for at least a minute, in a trial build: the same drawing as today's (missing-glyph boxes), one fallback search per event, and no growth in render time from frame to frame.
69. **Libraries reached in playback** (13.5). A text subtitle file in a legacy encoding without a byte-order mark (Windows-1252 or Shift_JIS, for example): the same detected encoding and text as today's. An AVS3 sample, if one is available: plays in software, as today. (Checks 26 to 29 cover libplacebo's Dolby Vision metadata path.)

### 13.8 Accepted differences found after the fix rounds and the library work

These are accepted in addition to 7.3 and 12.8. Everything else must still match today's engine. Figures are from a Mac (Apple M5 Pro) at 4K unless stated, not from devices.

| Area | Today | Now | Why accepted |
| --- | --- | --- | --- |
| Video output: cost of a same-buffer redraw with compositing on (13.1) | One blend over the buffer as it stands: about 0.55 to 0.57 ms for a 2000 by 250 cue, 9.1 to 9.5 ms for a full-frame cue | The composite is rebuilt away from the buffer and the changed rows written: 1.2 to 1.5 times today's for a cue changed in place or unchanged (0.69 to 0.82 ms), 2.1 (8-bit) and 3.3 (10-bit) times for a cue moved between bottom and top (1.21 and 1.87 ms), 1.2 to 1.6 times for a full-frame or full-width top-and-bottom cue (up to 13.0 ms) | Only same-buffer presentations take this path, in practice paused redraws. The worst case adds about 1.3 ms for a typical cue and 3.8 ms for a full-frame cue, and the result is correct where today blends the cue twice |
| Video output: transient memory of a same-buffer redraw (13.1) | None (an in-place blend) | Scratch of twice the union of the old and new blend rectangles, freed before the call returns: about 1.5 MiB (8-bit) or 2.9 MiB (10-bit) for a 2000 by 250 cue, 11.2 or 22.3 MiB when it moves between bottom and top, 23.8 or 47.5 MiB for a full-frame cue. Kept rows (also held at a first composite): 0.8 or 1.5 MiB for a typical cue, 11.9 or 23.8 MiB for a full-frame cue, until written back or let go | Only with compositing on and a changed cue on the same buffer. The worst case is about two decoded 4K 10-bit frames for a moment, while the decoder and display already hold several. Whether tvOS's allocator keeps the freed scratch cached was not checked |
| Video output: the YUV composite fails on a buffer that carries the previous composite (13.1) | Core Image over the old composite (old cue under the new), or the old cue alone | Kept rows written back first, then Core Image from the clean picture, or the picture with no cue; the displayed picture can be without its cue for a moment | Error paths only, and the sample is correct |
| Video output: row write order during a redraw (13.1) | The displayed buffer changes progressively for the length of the blend (0.55 to 9.5 ms), ending with the cue blended twice | Rows written plane by plane, each changed row once (0.02 to 1.13 ms); for a moment a row can carry the new cue's luma with the old chroma | Neither is atomic; the new window is shorter and its end state correct |
| Video output: a decoder buffer that cannot be locked for writing (13.1) | A pool copy with the YUV blend | Core Image (RGB output) | Does not occur on IOSurface-backed buffers |
| Video output: missing `wid` while mpv autoprobes (13.1) | Error | Verbose while probing, error otherwise | Vivid never makes mpv probe |
| Video output: other items of the two re-checks (13.1) | As 13.1 describes | Pacing window evaluated after the flip's frame; two microsecond-scale readiness races; a new error line when kept rows cannot be written back; a reference to the last composited decoder buffer held until a different buffer is presented; test-only hooks | No observable effect in Vivid |
| Audio output: zero-length or already complete loader requests below the window or beyond the write head (13.3) | Refused, with an error line and a fault below the window, or a verbose line beyond the write head | Finished successfully, with no log line | Believed unreachable; an optional fix would test the window base and the write head first |
| Decoder: the Dolby Vision configuration cannot be added to the decoder specification (13.2) | Silent; the `dvh1` session is attempted without the configuration (outcome inferred, not measured) | Two error lines; the session start fails, with software decoding after an initialisation failure; no plain HEVC retry | Reachable only through a failed 24-byte allocation; an error path in both engines |
| libass: memory (13.4) | Only what is on screen | About 11 to 14 MB more with boxed lines, about 1 MB or less with plain lines | Bounded by the 32 MiB budget and flat |
| libass: other review items (13.4) | As 13.4 describes | One re-render, possibly with no visible change, and one repeated search per face added by another event; symbol fonts with several events give today's single-threaded first frame; background-box image types copied as upstream leaves them; 20 more log lines in the Vivid-configuration corpus | Bounded, or no effect in Vivid |
| libass: CJK fallback within an event's first render (13.4) | The missing glyphs stay for the event's life | The real glyphs from the event's second frame, with one extra change report per added face | Upstream's behaviour and correct; everything else matches today's |
| Libraries: toolchain, version strings, HarfBuzz optional headers, assertion paths, MoltenVK and Apple GPU family 9 (13.5) | Xcode 15.4 builds from the previous third-party build of these libraries | Xcode 26.6 builds from upstream source | Exported symbol sets equal today's; the rest is unreached or cosmetic |
| Framework bundle identifiers (13.5) | The previous package's prefix | `com.blurbery.vivid.lucid.` | blurbery's decision; the identifiers do not reach the app |
