<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Playback</h1>
<p align="center">VividKit and Vivid’s player integration.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses the [local VividKit package](../../VividKit) for library video playback. The app owns its controls, queues, user state and server integration; the engine owns media execution.

Read the [playback architecture](architecture.md) for current responsibilities and validation boundaries.

## Apple TV controls

Vivid supplies the player UI for every VividKit playback path. On Apple TV, the bar uses a slim timeline and an Info pill above its right end. Info opens the Info, Stats, Video, Audio, Subtitles and Chapters tabs when applicable; subtitle options depend on the tracks in the opened media. The time row includes remaining media time; the remote retains play/pause and seeking. This is Vivid’s SwiftUI UI, not Apple’s AVPlayerViewController transport.

At the end of an episode, Next Up places the continuing mini-player at the top right and Play Now, Keep Watching and Back along the bottom left as applicable. The primary button keeps a fixed width, and the autoplay countdown remains beside it when active. The tvOS On Deck shelf is removed. Loading and next-episode transitions use four staggered white bouncing dots at screen centre; Reduce Motion keeps them still.

## iPhone and iPad controls

Mobile playback retains Vivid’s controls, remaining time and a pause indicator. Four separate round glass buttons sit above the right end of the transport bar: Quality, Audio, Subtitles, Chapters. Quality and Audio open native menus; Subtitles opens a native Liquid Glass popover with a scrollable list and the current selection checked. Chapters opens a matching anchored popover with a scrollable list of media chapter names and start times; choosing one seeks and closes the popover. The timeline has no chapter ticks. IntroDB skip controls remain available. Rotation, rotation lock, Picture in Picture and AirPlay each have their own round button. The transport, track controls and top controls appear together on tap and remain visible until the video is tapped again. PiP is present with the other controls while disabled during source preparation, avoiding a delayed layout change. Quality selects a streaming bitrate preset through the existing quality-change path, preserving playback position; it does not select a different media file. Audio and Subtitles select tracks directly. Subtitles offers Off and embedded tracks, with secondary subtitles when supported. Search, translation and external subtitle files are not offered. There is no mobile Info pill or brightness/volume edge gesture. Loading uses four staggered white dots. Detail pages use compact version/audio/subtitle readouts. Manual server setup and QR/manual sign-in remain.

Player unlock uses the phone’s physical orientation when a reliable sensor reading is available. Mobile Next Up places the continuing preview at the top right and episode information and actions at the bottom left. Play Now has a fixed-width white capsule, with the autoplay countdown beside it; Keep Watching and Back sit below. Preview sizing reserves room for the actions.

Playback settings expose Auto and capped quality presets; Original is no longer offered in the mobile settings picker. A previously stored Original preference moves to Auto when that page opens. This UI change does not remove original-file playback support from VividKit. Playback preferences are stored locally per device/profile. Buffer Ahead offers Automatic (about 10 seconds), 10, 20 and 30 seconds, subject to memory limits; startup does not wait for the target to fill. The obsolete Dolby Vision, Seek Cache, lossless-bridge and deinterlacing controls are removed; decoding is automatic. Skip Intros and Skip Credits each state that they automatically skip detected segments; choosing IntroDB supplies markers independently of those automatic-skip switches.

## Audio selection and startup

Before loading, Vivid uses track metadata already supplied by the provider to prefer a compatible audio track in the chosen language. AAC, AC-3, E-AC-3, MP3, ALAC, FLAC and PCM are eligible; commentary-labelled alternatives are excluded. An explicit manual choice wins. If no compatible same-language alternative exists, the original choice remains available to the decoder fallback. This is a selection policy, not a guarantee that every codec/profile will play.

Silo original-file and offline audio ordinals resolve to actual stream IDs inside the normal demux open, before decoder creation. Emby maps the selected ordinal to its native stream index during PlaybackInfo negotiation. Selecting an alternate track adds no separate media probe and does not wait for the read-ahead target to fill. Direct-file switching uses discovered tracks; packaged server routes depend on their negotiated track inventory. Software/sample-buffer changes run serially and keep the most recent selection, so a second choice made while the first rebuild is settling can still switch back.

I confirmed Dune starts quickly and has sound when Vivid automatically chooses its working AC-3 alternate. This does not establish that the original TrueHD track is fixed. Ten focused physical-iPhone tests passed for the audio preference and embedded-media path, including a non-contiguous audio stream ID and exactly one source open. The signed iOS and tvOS builds passed and were installed and launched; tvOS surround playback and physical iPad coverage remain separate checks.

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

Run `bash scripts/ci/check-introdb-client.sh` for request isolation, units, range bounds, caching, missing responses, rate limits and identity checks. Official API: https://api.introdb.app/ . I confirmed IntroDB works on the Silo-backed Apple TV setup. Broader timestamp coverage, Emby/Jellyfin integration and iOS behavior still need verification. See the [Vivid core](../cores/vivid.md) for ownership.
