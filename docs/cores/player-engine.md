# Lucid Engine

## Apple playback

Lucid Engine powers iPhone, iPad and Apple TV playback. Both app targets use the same pinned MPVKit package and Vivid-owned `VividMPVPlayer` adapter. Vivid owns controls, queues, server negotiation, progress reporting, settings and presentation; Lucid owns media transport, demuxing, decoding, timing and embedded tracks. The obsolete standalone playback package has been removed.

Generate `iosApp/project-ios.yml` for iOS or `iosApp/project.yml` for tvOS with XcodeGen. Keep their package graphs separate. Source ownership and dependency provenance are recorded in the [third-party notices](../../THIRD_PARTY_NOTICES.md).

## Video and presentation

Lucid renders into Vivid’s persistent player surface. Changing controls, opening menus or presenting Next Up does not create a second player. Apple TV requests frame rate and dynamic range through Apple’s display manager, respecting Match Content. The iOS bridge retains its media-time presentation path; the tvOS host-clock presentation path remains platform-specific.

On Apple TV, the visible player disables the app's idle timer while Vivid is active, including during paused playback. Leaving the player or making the app inactive restores normal screen saver behaviour. Returning to the active player disables the timer again without changing the playback state.

Apple TV starts content matching as soon as mpv supplies a complete decoded
video-output snapshot and measured cadence, without waiting for audio startup.
If that information is unavailable, the first playback-ready snapshot remains
the fallback. Playback continues through the switch; Vivid adds no HDMI startup
pause. The TV's physical blackout can cover advancing playback. Final decoded
criteria are still reconciled at playback readiness, and stale snapshots cannot
change the display after a source ends. A separate commit lock serialises the
early and cached writes with source transitions without holding the property-cache lock. Consecutive episodes retain the existing
display-criteria reuse. Living Room testing confirmed the earlier switch; other
display routes and extended episode chaining remain unverified.

The iOS adapter exposes its sample-buffer layer to the Picture in Picture coordinator and honours background-playback preferences. Native AVAsset frame extraction supplies iOS scrub previews for formats Apple can read. Sources AVFoundation cannot play are excluded from image generation; timeline scrubbing remains available. Apple TV scrubbing does not start thumbnail extraction.

## Audio support

At normal speed, AC-3 and E-AC-3 use compressed output through the Apple AVPlayer resource loader. Other formats use decoded PCM through sample-buffer audio. Lucid owns scheduling; Vivid adds no second audio clock, fixed synchronisation offset or local HLS producer. Non-unit playback speed switches to PCM before applying the tempo change and restores compressed output on return to 1x.

An explicit audio choice wins. Automatic selection prefers the requested language, then English, then the file default when English is unavailable. Provider ordinals and discovered source stream IDs remain distinct. Track switches use the media inventory; server-packaged streams depend on their negotiated inventory.

Stats retain the selected source codec, bitrate and channel description, with the output format shown separately. The compressed carrier’s two channels are not labelled as stereo. An Atmos badge requires Apple’s reported Dolby Atmos rendering mode; an E-AC-3 source alone does not establish Atmos output.

## Buffering and quality

Lucid uses a 256 MiB forward demux packet limit and a 16 MiB back buffer. These are limits, not startup fill requirements. Settings shows Automatic buffering and omits the unused lossless-audio toggle.

Quality preferences remain device/profile-local. Vivid sends the selected resolution and bitrate limits to the server, then loads the returned original or transcoded stream through Lucid. Quality changes preserve position and track choices through the existing session boundary. Offline playback uses the downloaded file. See [quality and playback settings](../playback/README.md) for the bounded buffering-fallback modes.

## Subtitles and chapters

Chapters and embedded subtitles come from Lucid’s actual media inventory. The detail and in-player Subtitles menus share track labels, ordering and selection identities. The detail reader is bounded and scoped to the chosen account, content and file; it produces no audio, video or viewing-progress updates.

General Settings owns subtitle language and appearance. Automatic selection turns subtitles off when the requested language is absent. Plain-text styling and delay apply to native text rendering and downloaded-text overlays. Authored ASS and bitmap styles remain intact. Device checks of full external ASS styling remain outstanding.

Downloaded ASS sidecars retain their authored text and render through Lucid using temporary local files, removed when the load ends. Plain-text sidecars continue to use the app overlay. Full external ASS visual verification on devices remains outstanding. Detail selectors distinguish automatic preference, explicit Off, embedded choices and staged downloads.

OpenSubtitles is optional. On tvOS, search is a native submenu beside embedded tracks. User-selected downloads are temporary, context-checked and retained across replacement loads of the same item. See [track and subtitle ownership](../playback/architecture.md#tracks-subtitles-and-previews) for limits and cleanup.

## Builds and native audio patch

Both platform specs pin `edde746/mpv-build` at `c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6`, containing mpv 0.41.0 and FFmpeg 8.0.1. Device builds additionally require [the native audio recovery patch](../../patches/mpv/0001-avfoundation-resume-after-audio-eof.patch).

The [audio-driver workflow](../../.github/workflows/mpv-audio-driver.yml) applies that patch and rebuilds libmpv using the other pinned dependency binaries. Earlier workflow run 35028421151 produced iOS and tvOS slices with the EOF recovery fix only. Rebuild the current patch before testing the additional startup recovery change, then replace only the matching resolved artifact slice before linking: `ios-arm64/Libmpv.framework` for iOS or `tvos-arm64_arm64e/Libmpv.framework` for tvOS. Verify the marker `resuming compressed feed after audio EOF` in the linked app binary.

The current source patch also bounds the first compressed-audio seek-to-start recovery attempt to the existing two-second grace after minimum priming. Incoming packets retain the slow-source extension before PCM fallback, but cannot keep postponing that first recovery attempt while the audio clock is stopped. The driver also defers an opportunistic audio read when its input queue cannot satisfy the request and AVPlayer retains at least the existing one-second priming reserve. This prevents prefetch from being reported as an output underrun and pausing the whole player. Reads resume as input arrives or the reserve drains, preserving real starvation and EOF handling. Buffer capacities and minimum priming are unchanged. Both changes have focused transport-decision coverage. In the local 0.14.3 (30) Living Room build, blurbery confirmed that the prefetch change removed the pause after the switch. Earlier native artifacts do not contain it; iOS device validation and broader codec/route coverage remain outstanding.

A fresh Swift package resolution alone does **not** include that additional patch. Keep the source patch, exact native build inputs and matching binary available together. The [playback workflow](../../.github/workflows/mpv-experiment.yml) checks dependency pins, track translation and platform builds; it does not certify a stock package as identical to the patched device build. Publishing or changing dependency revisions requires separate authorisation.

Source headers are passed as a typed string list. `PlaybackTrialTrace` retains allowlisted timing and numeric audio/cache diagnostics; raw media-core messages and source URLs are excluded. The optional tvOS debug diagnostic records to `Library/Caches/MPVTrial.log`. The trial also records display-switch start/end notifications, numeric audio transport transitions and cache snapshots when buffering changes. Source-transition commit-lock wait and held durations are measured with a monotonic clock on the mpv event thread, before main-queue delivery. Switch notifications describe tvOS state, not a direct measurement of the television panel. Its internal diagnostic names do not select a different engine.

## Verification

On 16 September 2026, both signed device builds passed and were installed on iPhone and Living Room Apple TV. The linked binaries retained the audio EOF recovery marker. Twenty-six focused tests passed against the production language-selection logic. blurbery confirmed the installed playback and subtitle changes worked.

Earlier Living Room checks covered Dune 1, Dune 2, seeking and synchronised playback; Punisher testing covered Dolby Vision. These observations do not certify Atmos output, every codec or source, physical iPad behaviour, every PiP/AirPlay route or full external ASS styling. A successful build is separate from a device playback check.

On Apple TV, detail-screen subtitle discovery starts when the subtitle selector
receives focus for that file, rather than whenever a detail screen appears.
If the file changes while that selector retains focus, its subtitle list refreshes.
Ordinary Play therefore avoids opening a second server session and demuxer just
to populate an unused subtitle menu. Actual playback still records its embedded
tracks in the existing inventory cache. Device test builds can enable
`VIVID_P8_TRIAL` to record bounded startup, buffering and skip-activation traces.
The 256 KiB rolling trace retains recent events across title changes within the
app run, including native Select receipt, skip actions and seek completion.
