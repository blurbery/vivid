<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Playback</h1>
<p align="center">Apple TV and iPhone/iPad playback integration.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Apple TV, iPhone and iPad use **Lucid Engine**. Vivid provides the controls, queues and server integration. See the [Lucid Engine guide](../cores/player-engine.md) for output behaviour and device verification.

Read the [playback architecture](architecture.md) for current responsibilities and validation boundaries.

## Apple TV controls

Vivid supplies the player UI for every playback path. On Apple TV, the bar uses a slim timeline, with a subtitle shortcut beside a round sliders control above its right end. The sliders control opens a compact panel with Home-style tabs for Info, Stats, Video, Audio and Chapters when applicable. Chapters scroll vertically with remote focus. The subtitle shortcut opens a glass selection menu, with embedded tracks, Off and a native OpenSubtitles submenu; subtitle options include the opened media’s tracks and, when connected in Plugins, manual OpenSubtitles search and temporary SRT downloads. Embedded bitmap subtitles such as PGS end the previous display set when its replacement begins, preventing successive dialogue images from stacking. The time row includes remaining media time; the remote retains play/pause and seeking. The controls remain Vivid’s SwiftUI UI. Lucid Engine presents video in the existing persistent surface; Vivid’s dots provide loading presentation. Picture readiness comes from the active sample-buffer display layer.

Near the end of an episode, Next Up places the continuing 960 × 540-point player preview at the top right and Play Now, Keep Watching and Back along the bottom left as applicable. The primary button keeps a fixed width, and the autoplay countdown remains beside it when active. Before EOF, the countdown follows remaining media time. The tvOS On Deck shelf is removed. Loading and next-episode transitions use four staggered white bouncing dots at screen centre; Reduce Motion keeps them still.

## iPhone and iPad controls

Mobile playback retains Vivid’s controls, remaining time and pause indicator. While playing, controls dismiss after five seconds without interaction. Holding a control suspends dismissal and releasing it restarts the five seconds. Paused playback keeps controls visible until the viewer dismisses them. Four separate round glass buttons open scrollable anchored Quality, Audio, Subtitles and Chapters popovers. Quality shows the selected mode and compact one-line descriptions; choosing another mode uses the existing quality-change path and preserves position. The host stays mounted during buffering and reloads, and open popovers pin the controls. Chapters show names and start times; selection seeks and closes the popover, with no timeline chapter ticks. Audio and Subtitles select available tracks directly, including Off and supported secondary subtitles. With OpenSubtitles connected in Plugins, the subtitle picker also offers manual title/language search and temporary subtitle downloads. Translation is not offered. Rotate, Lock, PiP and AirPlay remain separate round buttons. PiP stays in place but disabled while preparing. Loading uses four staggered white dots. There is no mobile Info pill or brightness/volume edge gesture.

Player unlock uses the phone’s physical orientation when a reliable sensor reading is available. Mobile Next Up places the continuing preview at the top right and episode information and actions at the bottom left. Play Now has a fixed-width white capsule, with the autoplay countdown beside it; Keep Watching and Back sit below. Preview sizing reserves room for the actions.

## Quality controls

Settings and the in-player controls offer five choices when the source supports quality changes:

| Choice | Behaviour |
| --- | --- |
| Auto (Recommended) | No selected bitrate ceiling; use the existing compatibility pipeline. |
| Original Quality | Preserve the source without transcoding; requires compatible playback and sufficient bandwidth. |
| 4K · 80 Mbps | Resolution/bitrate ceilings; one buffering fallback to a 20 Mbps ceiling. |
| 1080p · 10 Mbps | Resolution/bitrate ceilings; one buffering fallback to a 4 Mbps ceiling. |
| 720p · 4 Mbps | Resolution/bitrate ceilings; one buffering fallback to a 1.5 Mbps ceiling. |

The captions are compact single lines inside the open controls, such as “If buffering: up to 20 Mbps.” The closed Settings Quality row shows only the selection. These are ceilings, not promised output bitrates or forced encoding targets; the provider may choose a lower bitrate or resolution. This is pause-and-reload recovery, not seamless adaptive streaming.

The three capped modes are opt-in and local to the device/profile. After eight continuous seconds of eligible buffering with less than one second buffered ahead, a mode can request its lower ceiling once. Playback must already have started, and the active quality must match that mode. Startup, pause, seeking, scrubbing, offline/audio-only playback, errors, an in-flight quality replan and the last ten seconds of a known-duration item are excluded. Recovery or an ineligible phase cancels the timer. Source, position and selected tracks use the existing session/recovery path; the lower temporary ceiling does not overwrite the saved maximum. Original, Auto and older saved presets are not silently enrolled, and failed or rejected changes cannot trigger an unrelated fallback.

Playback preferences remain local per device/profile. Lucid Engine uses a 256 MiB forward packet buffer limit and a 16 MiB back buffer. Settings shows Automatic buffering and omits the unused lossless-audio toggle. AC-3 and E-AC-3 use compressed output at normal speed; other formats use decoded PCM. Receiver output requires device verification. The Intro & Credit Skipper toggle controls marker loading, with separate automatic intro/credit skip switches.

## Direct-stream recovery

Lucid Engine owns media transport on both platforms. Vivid handles credential
renewal through its bounded reload boundary, preserving the current position.

## Audio selection and startup

Before loading, Vivid uses track metadata already supplied by the provider to prefer a compatible audio track in the chosen language. AAC, AC-3, E-AC-3, MP3, ALAC, FLAC and PCM are eligible; commentary-labelled alternatives are excluded. An unavailable preferred audio language falls back to English, then the file default when English is absent. An explicit manual choice wins. If no compatible same-language alternative exists, the original choice remains available to the decoder fallback. This is a selection policy, not a guarantee that every codec/profile will play.

Silo original-file and offline audio ordinals resolve to actual stream IDs inside the normal demux open, before decoder creation. Emby maps the selected ordinal to its native stream index during PlaybackInfo negotiation. Selecting an alternate track adds no separate media probe and does not wait for the read-ahead target to fill. Direct-file switching uses discovered tracks; packaged server routes depend on their negotiated track inventory. Lucid applies available embedded-track changes locally; quality changes negotiate a new server plan while retaining the playback position.

Audio selection uses Lucid’s discovered track inventory and the saved device/profile preference. See [audio support](../cores/player-engine.md#audio-support) for output behaviour and the limits of the current device checks.

## Downloads and resume updates

On iPhone and iPad, detail download actions show a live ring while the item is registering or transferring and settle into the completed state when the transfer finishes. The Downloads page uses glass storage and progress cards, shows transferred bytes and speed, and keeps the main series poster for episode, season and whole-series work. Artwork can arrive as a relative path or a same-server absolute URL; another origin is rejected rather than sent through the authenticated server client. Downloads and their artwork remain local to that device and do not sync through the iCloud account vault.

Movies and episodes qualify for partial resume updates after 60 seconds of actual viewing; pauses, buffering and seeks do not count. Completion is separate: 90%, a valid credits marker or verified natural end can mark even short content watched. See [reporting and completion](architecture.md#downloads-and-external-playback) for provider and offline behaviour.

When qualified playback closes, Vivid sends the final resume position before the remaining session teardown. Home and open detail state refresh as soon as that progress write completes, on mobile and Apple TV. The media server still owns the saved watch state and determines when Continue Watching advances or disappears.

## Source entry points

- [VividPlaybackController](../../iosApp/iosApp/Screens/Player/VividPlaybackController.swift): video engine ownership, loads, transport and events.
- [VividLoadSpec](../../iosApp/iosApp/Screens/Player/VividLoadSpec.swift): prepared online/offline source inputs.
- [PlaybackTimelineMapper](../../iosApp/iosApp/Screens/Player/ProtocolV3/PlaybackTimelineMapper.swift): server, source and presentation clocks.
- [PlayerViewModel](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift): app-facing playback state and behaviour.

Silo uses its existing playback protocol. The [Emby core](../cores/emby.md) and [Jellyfin core](../cores/jellyfin.md) each map their own authentication, PlaybackInfo and session reports into Vivid’s shared player on mobile and Apple TV. Jellyfin does not use Emby’s adapter or Silo Protocol V3. The media engine and shared controls retain their existing behaviour; provider-specific features and verification limits are listed in each core guide.

A successful compile does not verify format support, HDR, surround audio, PiP, AirPlay or hardware-specific behaviour. Record those results against the actual build and device.

The Apple TV round sliders control uses a fixed custom focus treatment above the timeline. A small pause symbol appears below the timeline’s left edge while paused, beside elapsed time; remaining watch time stays on the right. The playhead is a horizontal oval with a thicker centre. Next-up artwork is a background layer constrained to the viewport so it cannot push Play Now or the countdown below the screen.

Select the timeline and swipe left or right to preview the target time. Apple TV shows no thumbnail overlay and starts no thumbnail extraction workers. Repeated swipes move farther through the item; Select confirms and Back cancels. Directional button seeking remains available. Circular clockwise/counterclockwise seeking has been removed so it does not compete with horizontal swipes.

Apple TV requests the source frame rate and dynamic range through Apple’s display manager. Enable Match Frame Rate and Match Dynamic Range in the Apple TV system settings to allow the TV to switch modes. Closing playback releases Vivid’s preferred display criteria. The first start keeps a small decoded buffer ready; it does not wait for the full read-ahead target.

### Vivid-owned intro, recap and credits markers

Playback → Intro & Credit Skipper is enabled by default and preserves an explicitly saved Off choice. Valid selected-file intro/credits markers appear first. IntroDB fills missing ranges; TheIntroDB fills remaining intro, credits or recap ranges. Separate automatic-skip settings control automatic skipping, and valid ranges supply manual prompts.

Public requests use episode IMDb identity and numbering, without media-server credentials or API keys. Each provider has a bounded one-hour cache. Errors preserve markers already available, and requests are cancelled or ignored when the item, file or session changes. Movies can use selected-file markers, but public lookups are episode-only. Offline playback does not load skip markers. See [marker timing](architecture.md#introdb-marker-timing) for duration handling and exact precedence.

Run `bash scripts/ci/check-introdb-client.sh` for the focused request and range checks. Earlier IntroDB playback was verified on Silo-backed Apple TV. The newer fallback/recap paths and wider provider/device coverage still need verification.

Both subtitle menus use the same embedded-track inventory and ordering. General Settings owns subtitle language and appearance; the menus omit settings shortcuts. Missing automatic subtitle-language matches turn subtitles off. Plain-text appearance and delay reach the native renderer and downloaded-text overlay, while authored ASS and bitmap styles remain intact.

Intro, recap and credits buttons use Liquid Glass and retain their clearance above the controls. On Apple TV the focused skip button has a visible highlight, and Up or Down from the standalone prompt reveals the transport controls. Skip prompts are hidden while the settings HUD is open.
