<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Playback</h1>
<p align="center">Apple TV and iPhone/iPad playback integration.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses [AetherEngine](../../AetherEngine) on Apple TV and [VividKit](../../VividKit) on iPhone and iPad. The app owns controls, queues, user state and server integration; each platform engine owns media execution. Apple TV automatically chooses prepared native Apple playback or software fallback within one Aether session, with no player switch.

Read the [playback architecture](architecture.md) for current responsibilities and validation boundaries.

## Apple TV controls

Vivid supplies the player UI for every playback path. On Apple TV, the bar uses a slim timeline and an Info pill above its right end. Info opens the Info, Stats, Video, Audio, Subtitles and Chapters tabs when applicable; subtitle options depend on the tracks in the opened media. Embedded bitmap subtitles such as PGS end the previous display set when its replacement begins, preventing successive dialogue images from stacking. The time row includes remaining media time; the remote retains play/pause and seeking. The controls remain Vivid’s SwiftUI UI. On Apple TV, AVPlayerViewController hosts native playback with its transport bar hidden; Vivid’s dots provide loading presentation. Episode handoff retains this host and the existing countdown, accepting picture readiness only from the current item.

At the end of an episode, Next Up places the continuing mini-player at the top right and Play Now, Keep Watching and Back along the bottom left as applicable. The primary button keeps a fixed width, and the autoplay countdown remains beside it when active. The tvOS On Deck shelf is removed. Loading and next-episode transitions use four staggered white bouncing dots at screen centre; Reduce Motion keeps them still.

## iPhone and iPad controls

Mobile playback retains Vivid’s controls, remaining time and pause indicator. Four separate round glass buttons open scrollable anchored Quality, Audio, Subtitles and Chapters popovers. Quality shows the selected mode and compact one-line descriptions; choosing another mode uses the existing quality-change path and preserves position. The host stays mounted during buffering and reloads, and open popovers pin the controls. Chapters show names and start times; selection seeks and closes the popover, with no timeline chapter ticks. Audio and Subtitles select available tracks directly, including Off and supported secondary subtitles. External subtitles, search and translation are not exposed. Rotate, Lock, PiP and AirPlay remain separate round buttons. PiP stays in place but disabled while preparing. Loading uses four staggered white dots. There is no mobile Info pill or brightness/volume edge gesture.

Player unlock uses the phone’s physical orientation when a reliable sensor reading is available. Mobile Next Up places the continuing preview at the top right and episode information and actions at the bottom left. Play Now has a fixed-width white capsule, with the autoplay countdown beside it; Keep Watching and Back sit below. Preview sizing reserves room for the actions.

## Quality controls

Settings and the in-player controls offer five choices when the source supports quality changes:

| Choice | Behaviour |
| --- | --- |
| Auto (Recommended) | No selected bitrate ceiling; use the existing compatibility pipeline. |
| Original Quality | Preserve the source without transcoding; requires compatible playback and sufficient bandwidth. |
| 4K — 80 Mbps | Resolution/bitrate ceilings; one buffering fallback to a 20 Mbps ceiling. |
| 1080p — 10 Mbps | Resolution/bitrate ceilings; one buffering fallback to a 4 Mbps ceiling. |
| 720p — 4 Mbps | Resolution/bitrate ceilings; one buffering fallback to a 1.5 Mbps ceiling. |

The captions are compact single lines inside the open controls, such as “If buffering: up to 20 Mbps.” The closed Settings Quality row shows only the selection. These are ceilings, not promised output bitrates or forced encoding targets; the provider may choose a lower bitrate or resolution. This is pause-and-reload recovery, not seamless adaptive streaming.

The three capped modes are opt-in and local to the device/profile. After eight continuous seconds of eligible buffering with less than one second buffered ahead, a mode can request its lower ceiling once. Playback must already have started, and the active quality must match that mode. Startup, pause, seeking, scrubbing, offline/audio-only playback, errors, an in-flight quality replan and the last ten seconds of a known-duration item are excluded. Recovery or an ineligible phase cancels the timer. Source, position and selected tracks use the existing session/recovery path; the lower temporary ceiling does not overwrite the saved maximum. Original, Auto and older saved presets are not silently enrolled, and failed or rejected changes cannot trigger an unrelated fallback.

Playback preferences remain local per device/profile. iPhone and iPad retain Automatic (about 20 seconds), 30-second and 40-second packet read-ahead targets. Apple TV Automatic uses Aether’s ten-segment target, roughly 40 seconds beyond consumer requests. It also offers 1, 5 and 10 minutes and a disk-limited whole-file window; the existing 80-second selection is retained. Startup does not wait for the full target. Stats distinguish AVPlayer buffer from measured Read-ahead available; both Apple TV timeline bars show measured read-ahead when available and otherwise use the consumer buffer. Playback recovery still uses the consumer buffer. Prefer Lossless Audio sits below Buffer Ahead on Apple TV and defaults off: converted native-path audio normally uses E-AC-3 up to 5.1, while enabling it selects FLAC up to 7.1 for the next load. Lossless multichannel output needs a compatible route and can become stereo over some TV/ARC connections. IntroDB markers and the separate automatic intro/credit skip switches retain their existing roles.

## Direct-stream recovery

Eligible delivery interruptions first attempt bounded recovery on the same direct route. When playback is active, the reader needs more bytes and playable headroom shrinks during a sustained delivery stall, Vivid can reconnect while buffered media continues playing. Received, unread bytes are retained and the replacement request starts at the first missing byte, subject to HTTP range and content validation. Pauses and normal buffer backpressure do not qualify on their own. A longer outage can still interrupt playback.

Refreshed credentials are passed to the existing direct network reader for subsequent requests without replacing the player or its buffers. An in-flight 401 uses coordinated, bounded authenticated resumption. Reconstruction remains a fallback where in-place recovery is unavailable, including native HLS. Temporary delivery failures retain their network error codes rather than being treated immediately as decoder incompatibility.

These changes retain the existing buffer targets, startup thresholds and audio paths. The [architecture guide](architecture.md#direct-network-recovery) describes eligibility, retry limits and cancellation.

## Audio selection and startup

Before loading, Vivid uses track metadata already supplied by the provider to prefer a compatible audio track in the chosen language. AAC, AC-3, E-AC-3, MP3, ALAC, FLAC and PCM are eligible; commentary-labelled alternatives are excluded. An explicit manual choice wins. If no compatible same-language alternative exists, the original choice remains available to the decoder fallback. This is a selection policy, not a guarantee that every codec/profile will play.

Silo original-file and offline audio ordinals resolve to actual stream IDs inside the normal demux open, before decoder creation. Emby maps the selected ordinal to its native stream index during PlaybackInfo negotiation. Selecting an alternate track adds no separate media probe and does not wait for the read-ahead target to fill. Direct-file switching uses discovered tracks; packaged server routes depend on their negotiated track inventory. Software/sample-buffer changes run serially and keep the most recent selection, so a second choice made while the first rebuild is settling can still switch back.

Automatic compatible-audio selection and TrueHD 7.1 source playback have been verified in development builds. See the [player engine core](../cores/player-engine.md#audio-support) for supported formats and output limits. Ten focused physical-iPhone tests previously passed for the audio preference and embedded-media path, including a non-contiguous audio stream ID and exactly one source open. Physical iPad coverage and additional output routes remain separate checks.

### VividKit PCM continuity and earlier verification

The following records concern VividKit and earlier Apple TV builds, not validation of the new Aether route. The DTS crackle fix keeps software-decoded PCM timestamps continuous across container rounding and reuses the PCM format description until the audio format changes. Apple TV requests multichannel-output support; iPhone/iPad keep normal route negotiation. DTS uses the existing FFmpeg-to-PCM path, not a new native DTS decoder or a claim of DTS:X object output. The experimental tvOS DTS-to-HLS bridge is retained in source but disabled in Vivid.

Apple TV observes automatic audio-renderer flushes and output-configuration changes. It can replay retained, unplayed samples without restarting video or reopening the source. The replay queue is bounded to 16 MiB and 512 samples; a bounded seek fallback remains when replay cannot recover. AirPlay confirmation checks queued-audio progress as well as clock movement and retains flushes received during recovery. Recovery can introduce a pause; uninterrupted startup is not guaranteed. The separate HDMI stall-recovery component is enabled in Release only for a pure HDMI output route; Debug builds still require the existing launch argument. These audio recovery paths do not change HomePod, AirPlay or iPhone audio routes. See the [mini-core guide](../cores/player-engine.md#mini-cores) for exact policies.

During development, 35 focused quality tests passed on iPhone 16 Pro Max (iOS 26.6.1), covering simulated buffering, one-time recovery, cancellation eligibility, rejected choices, local settings, legacy quality pairs, recovery requests and Emby negotiation. On 8 September 2026, device checks confirmed the completed changes work on that iPhone and Apple TV 4K (3rd generation, tvOS 26.6). The TV checks included normal E-AC-3 playback and the Harry Potter DTS file through HomePod (2nd generation); both platforms were checked again after the final buffer update. These are functional device results, not measured startup benchmarks or universal codec/output certification. Deliberately throttled-network fallback, physical iPad behaviour, DTS:X object preservation and other receiver layouts remain outside the recorded checks.

## Downloads and resume updates

On iPhone and iPad, detail download actions show a live ring while the item is registering or transferring and settle into the completed state when the transfer finishes. The Downloads page uses glass storage and progress cards, shows transferred bytes and speed, and keeps the main series poster for episode, season and whole-series work. Artwork can arrive as a relative path or a same-server absolute URL; another origin is rejected rather than sent through the authenticated server client. Downloads and their artwork remain local to that device and do not sync through the iCloud account vault.

When playback closes, Vivid sends the final resume position before the remaining session teardown. Home and open detail state refresh as soon as that progress write completes, on mobile and Apple TV. The media server still owns the saved watch state and determines when Continue Watching advances or disappears.

## Source entry points

- [VividPlaybackController](../../iosApp/iosApp/Screens/Player/VividPlaybackController.swift): video engine ownership, loads, transport and events.
- [VividLoadSpec](../../iosApp/iosApp/Screens/Player/VividLoadSpec.swift): prepared online/offline source inputs.
- [PlaybackTimelineMapper](../../iosApp/iosApp/Screens/Player/ProtocolV3/PlaybackTimelineMapper.swift): server, source and presentation clocks.
- [PlayerViewModel](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift): app-facing playback state and behaviour.

Silo uses its existing playback protocol. The [Emby core](../cores/emby.md) maps native authentication, PlaybackInfo and session reports into the shared player on mobile and Apple TV. Jellyfin remains planned.

A successful compile does not verify format support, HDR, surround audio, PiP, AirPlay or hardware-specific behaviour. Record those results against the actual build and device.

The Apple TV Info pill uses a fixed custom focus treatment above the timeline. A small pause symbol appears below the timeline’s left edge while paused, beside elapsed time; remaining watch time stays on the right. The playhead is a horizontal oval with a thicker centre. Next-up artwork is a background layer constrained to the viewport so it cannot push Play Now or the countdown below the screen.

Select the timeline and swipe left or right to preview a seek. Repeated swipes move farther through the item; Select confirms and Back cancels. Directional button seeking remains available. Circular clockwise/counterclockwise seeking has been removed so it does not compete with horizontal swipes.

Apple TV requests the source frame rate and dynamic range through Apple’s display manager. Enable Match Frame Rate and Match Dynamic Range in the Apple TV system settings to allow the TV to switch modes. Closing playback releases Vivid’s preferred display criteria. The first start keeps a small decoded buffer ready; it does not wait for the full read-ahead target. Display matching and the improved startup were confirmed on Apple TV 4K (3rd generation).

### Vivid-owned intro and credits markers

Playback → IntroDB is a native toggle, enabled by default, with the description “Toggle on for native intro & credit skips.” An explicitly saved Off choice is preserved. IntroDB’s public `/segments` lookup is anonymous, so Vivid does not request an API key. The separate Skip Intros and Skip Credits switches control automatic skipping; available markers also feed the player’s skip buttons.

Vivid resolves the series IMDb ID and season/episode numbers, fetches timestamps directly and ignores server-supplied watch-detail/realtime markers. It does not change the Silo server configuration. Lookups do not delay stream startup, are cancelled when playback changes, validate episode identity and duration bounds, and cache successful results for one hour. Missing data, network errors and rate limits leave playback running without markers. IntroDB’s endpoint covers TV episodes, not movie credits; offline playback does not fetch markers.

The IntroDB client accepts a common episode identity and is independent of provider credentials. Silo and Emby supply common series metadata; Jellyfin still needs a connector. This is shared marker handling, while each provider retains the limits documented in its core guide.

Run `bash scripts/ci/check-introdb-client.sh` for request isolation, units, range bounds, caching, missing responses, rate limits and identity checks. Official API: https://api.introdb.app/ . IntroDB playback has been verified on Silo-backed Apple TV. Broader timestamp coverage, Emby/Jellyfin integration and iOS behaviour still need verification. See the [Vivid core](../cores/vivid.md) for ownership.
