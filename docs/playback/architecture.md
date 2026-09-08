<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Playback Architecture</h1>
<p align="center">Engine ownership, server sessions and media state.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

How the [Vivid player core](../cores/vivid.md), VividKit and each server core share playback responsibilities. The [Silo server core](../cores/silo.md) and [Emby server core](../cores/emby.md) are available; Jellyfin remains planned.

## Ownership

<table width="100%">
  <thead>
    <tr><th align="left">Owner</th><th align="left" width="10000">Responsibilities</th></tr>
  </thead>
  <tbody>
    <tr><td>Vivid</td><td>Controls, queues, resume/Next Up, selection preferences, downloads, server sessions, progress, local player stats and presentation</td></tr>
    <tr><td>VividKit</td><td>Source reads, probing, demux/decode, media routing, buffers, track extraction, seek execution and media presentation</td></tr>
    <tr><td>Server adapter</td><td>Provider authentication, playback-plan negotiation, source headers, renewal, realtime commands and progress reporting</td></tr>
  </tbody>
</table>

Library playback uses VividKit through the video and audio controllers. The active application pipeline opens media directly from the selected provider source, without a source proxy or local loopback route. A tvOS-only DTS-to-HLS bridge experiment remains in source but is disabled by `VividEngine`; it is not the path used by the confirmed DTS playback.

The existing adapter implements Silo's Protocol V3. That is a provider contract, not Vivid's universal server API. A new provider should map its own session and source information into the player inputs without pretending to speak Protocol V3.

## VividKit pipeline

Files and direct HTTP media use VividNetwork → FFmpeg demux → bounded video/audio packet queues → VideoToolbox or FFmpeg decoding → Apple sample-buffer renderers. The shared render synchronizer owns presentation time. Automatic targets about 20 seconds of packet read-ahead; manual choices target 30 or 40 seconds, with independent byte caps and small decoded queues. Startup does not wait for the read-ahead target. Resume readiness also accounts for Apple's renderer queue capacity, avoiding a startup deadlock when that capacity is smaller than the preferred time buffer. These targets do not replace AVPlayer’s server-HLS buffering.

Supported AAC, MP3, AC-3 and E-AC-3 audio can use Apple’s compressed-audio renderer. Other supported formats, including DTS, decode to PCM through FFmpeg. Software PCM buffers reuse their format description until sample rate, sample format or channel layout changes. Their presentation times follow the sample-accurate end of the previous frame when packet timestamps repeat, move backwards or contain tiny rounding differences; real forward gaps remain. This avoids repeated format allocation and tiny PCM gaps/overlaps behind the reported DTS crackle. Apple TV opts into multichannel output support; iPhone/iPad retain default route negotiation. A native-audio renderer failure still permits one PCM rebuild. This does not establish DTS:X object preservation or every receiver/output layout.

On tvOS, automatic audio flush and output-configuration notifications first attempt audio-only recovery using retained samples that have not finished playing. The replay queue is bounded to 16 MiB/512 samples and cleared on seek or cancellation. Replay uses the renderer worker’s lock and the same synchronizer clock; it does not seek or reset video. If replay is unavailable, recovery can rebuild at the current position, with at most three recovery attempts in thirty seconds. Audio enqueue allowance accounts for the output route’s latency, and the synchronizer rate is only assigned when it changes. iOS retains its existing route behaviour.

Seeking interrupts old queue work, reuses the demux session, seeks to a preceding keyframe and decodes forward to the requested timestamp. Generation checks prevent outgoing frames and cues from reaching a newer seek or media item.

Server HLS uses AVPlayer. Direct container playback uses AVSampleBufferDisplayLayer, including VideoToolbox-decoded pixel buffers. External video playback is advertised only for receiver-fetchable native HLS. Subtitles use native text and bitmap cues, with libass for ASS/SSA styling. Preview extraction is separate, bounded work.

VividKit playback has been tested on iPhone 16 Pro Max and Apple TV 4K (3rd generation). Broad remux coverage, Dolby Vision output, Atmos object preservation, interlaced content, external playback, long network stalls and older Apple TV hardware require their own media/device verification; passing the focused synthetic tests does not establish that coverage.

## Loads and lifecycle

- Keep one clear owner for the engine and its observations.
- Generation-fence loads, session staging, callbacks and recovery. A cancelled or replaced load must not publish into a newer item.
- Keep session/progress identity aligned with the committed source. Stop stale staged sessions on failure or supersession.
- Map server, source and presentation positions through the existing timeline mapper. Do not treat them as interchangeable seconds.
- Renew or replan through the current session bridge and load-spec path. Cancellation is not a playback failure; rate limiting must not trigger an immediate retry loop.
- Preserve pause intent, resume position, seek completion and exactly-once end/episode-handover work across recovery.

## Apple TV presentation

The same Vivid surface remains mounted as playback moves between full screen and Next Up preview geometry. Next Up owns only the preview bounds and action layout; it must never create a second player or restart the current item. Its top-right preview and bottom-left actions are constrained to the actual viewport. The countdown and Play Now depend on an available next episode; absence of a next episode must show an explicit end/error state instead.

Vivid’s custom timeline is shared by native and software engine routes. On Apple TV, the Info pill retains the existing tabbed HUD. Loading dots are decorative and non-focusable, use a bounded animation cadence, and respect Reduce Motion. No AVPlayerViewController integration is enabled by this UI change.

## Mobile presentation

The mobile shell shares account restoration, IntroDB, personal-TMDb and Seerr stores with tvOS. Home’s metadata fetch writes the same per-server/profile disk cache used by the Metadata page. Movie and series detail artwork stays attached to the card edge during scrolling; Home retains its separate parallax and fade-to-black treatment.

Mobile controls remain Vivid-owned. Quality, Audio, Subtitles and Chapters use scrollable anchored popovers. An open popover pins the controls; their presentation host remains mounted during buffering and quality reloads so taps, scrolling and sheets retain a live owner. Rotate, Lock, PiP and AirPlay each keep a round glass button. Transport chrome hides during loading without tearing down that owner. The mobile Next Up layout preserves the player surface. Playback failures and retry actions use the shared dark glass design on mobile and Apple TV. See [App Design](../app-design.md#iphone-and-ipad-layout) for navigation and verification.

## Account storage and sync

Local account metadata lives in Vivid defaults and session/PIN material lives in Vivid’s Keychain audience. `VividCloudAccountSync` merges those records through encrypted CloudKit fields in the user’s private `iCloud.com.blurbery.vivid` container. It fetches before writing, retries record-change conflicts and applies deletion tombstones before local snapshots. A tombstoned server/user identity can return only after an explicit later authentication. The cloud vault does not contain downloads, metadata caches or player preferences.

Fresh-install detection uses an app-container marker. A missing marker with no existing Vivid defaults clears the local Vivid Keychain audience before cloud restoration; an upgrade seeds the marker without clearing the current session. Account sync is best effort when iCloud is unavailable and must not block a working local account.

## Tracks, subtitles and previews

Use the engine’s actual track identities. A dense server ordinal is not necessarily an engine stream ID; stream zero remains valid. Initial selection uses existing provider metadata to prefer a compatible same-language audio alternative while preserving explicit manual choices. For original-file and offline sources, VividMediaSession resolves the ordinal against the audio inventory from its first demux open. An explicit source stream ID takes precedence. This path must not introduce a preliminary probe or second source open. See [audio selection](README.md#audio-selection-and-startup) for the policy and its limits.

Chapters come exclusively from FFmpeg’s media-container chapter entries. Embedded subtitle tracks discovered by VividKit are the player’s subtitle inventory; selection and disabling happen locally without a Silo replan. Playback requests disable server subtitle processing, and load specifications ignore server subtitle artifacts and sidecars. External subtitle files, search and AI translation are not currently exposed. Text, ASS/SSA and bitmap decoding remain part of VividKit. Playback and subtitle preferences are stored on the device in the existing profile partitions, without server settings synchronization.

Scrub previews use the existing bounded request owner and VividKit frame extractor. Late images from an old source or gesture must not paint over a new selection.

## Downloads and external playback

Keep downloaded sources and their metadata independent of an online server's current response and out of the iCloud account vault. The detail action observes registration and transfer state directly from `DownloadManager`, while Downloads reads the same records for progress, transfer rate, storage totals and locally stored poster artwork. Series-scoped requests use the parent series artwork. Accept authenticated artwork only as a relative path or a same-origin absolute URL; normalise it before constructing the server request. Validate offline resume, seeking, tracks and teardown explicitly.

Final playback progress is reported before session stop/cleanup. A successful write posts the refresh signal immediately so Home and detail views can request current resume state while teardown finishes. Successful watched/unwatched writes from detail pages use the same account/profile-scoped Home refresh signal. Home queues refreshes that arrive during an older fetch and rejects stale results on both iOS and tvOS. While Home is visible, active and not covered by detail/playback navigation, it also refreshes every ten seconds to pick up changes made on another device. This is provider-backed polling, not iCloud watch-state sync or a realtime push guarantee. Preserve the fallback refresh when the final playback write fails, and do not send the same final progress twice.

PiP, AirPlay, HDR and audio-format behaviour depend on the exact engine route, device and source. In particular, a receiver cannot be assumed to reproduce the sender's private authentication headers. Do not widen an advertised capability based only on a package upgrade or a successful build.

## Diagnostics and dependencies

- Keep development logs local, redacted and bounded. Vivid does not capture or upload in-app diagnostics reports. Do not expose credentials, source URLs, paths or subtitle contents in logs.
- Classify typed failures using stable kinds, with an unknown fallback, rather than matching localized error text.
- Read the local engine dependency from [project.yml](../../iosApp/project.yml), the FFmpeg pin from [VividKit/Package.swift](../../VividKit/Package.swift), and resolved package revisions from the tracked `Package.resolved` file. Subtitle/font binary provenance is recorded in `VividKit/Vendor/NOTICE`.
- Keep the existing package graph and media-framework notices intact during documentation or branding work.
- Follow [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) for dependency licensing, corresponding source and binary provenance. Inspect the actual archive and its source mapping before distributing a new binary.
- Validate temporary media caches, data protection, cleanup and backup exclusions when changing storage or engine versions.

## Verification

For relevant changes, record the source commit, engine/package revisions, build, device, OS, server/provider, media sample and observed result. Cover:

- startup, pause/resume, seeking, stopping and consecutive episodes;
- source/session expiry, cancellation, reconnection and server/user switches;
- audio and subtitle selection, including embedded stream zero and local selection after seeking;
- offline playback and app lifecycle transitions;
- route-specific HDR, surround audio, PiP and AirPlay where supported;
- diagnostic redaction and signed-archive contents before distribution.

State passed, failed, pending and not-run checks separately. Retain measured results under their original builds. Neither old audits nor this guide establish current format support or certify a release.
