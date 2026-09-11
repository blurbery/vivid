<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Playback Architecture</h1>
<p align="center">Engine ownership, server sessions and media state.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

How the [Vivid player core](../cores/vivid.md), the platform engines and each server core share playback responsibilities. The [Silo server core](../cores/silo.md) and [Emby server core](../cores/emby.md) are available; Jellyfin remains planned.

## Ownership

<table width="100%">
  <thead>
    <tr><th align="left">Owner</th><th align="left" width="10000">Responsibilities</th></tr>
  </thead>
  <tbody>
    <tr><td>Vivid</td><td>Controls, queues, resume/Next Up, selection preferences, downloads, server sessions, progress, local player stats and presentation</td></tr>
    <tr><td>AetherEngine (tvOS) / VividKit (iOS)</td><td>Source reads, probing, demux/decode, media routing, buffers, track extraction, seek execution and media presentation</td></tr>
    <tr><td>Server adapter</td><td>Provider authentication, playback-plan negotiation, source headers, renewal, realtime commands and progress reporting</td></tr>
  </tbody>
</table>

Library playback uses the platform adapter through Vivid’s playback controllers. Apple TV uses one AetherEngine session: direct media can be prepared into local HLS for AVPlayer, server HLS can use its native bypass, and unsupported native video uses the software route automatically. iPhone and iPad continue opening provider sources through VividKit. Its retained DTS-to-HLS experiment is not the active tvOS implementation.

The existing adapter implements Silo's Protocol V3. That is a provider contract, not Vivid's universal server API. A new provider should map its own session and source information into the player inputs without pretending to speak Protocol V3.

## Apple TV pipeline

`VividAetherEngine` preserves Vivid’s session and reporting boundaries while Aether owns preparation, decoding and buffering. It resolves the initial audio ordinal during the existing probe, avoiding a separate source open. The default native audio bridge favours E-AC-3 compatibility; Prefer Lossless Audio selects FLAC instead. The persistent AVKit host owns native video and Now Playing integration, while Aether’s sample-buffer view handles software output. Vivid retains controls, loading dots, IntroDB and the episode countdown. Item identity guards prevent outgoing-frame callbacks from completing the next episode’s loading state.

Automatic read-ahead is ten segments. AVPlayer’s short loaded-range buffer and Aether’s prepared frontier are separate measurements; timeline presentation does not change playback recovery thresholds. Credential updates use the existing generation-fenced reload because Aether cannot replace request headers in place.

## VividKit pipeline (iPhone and iPad)

Files and direct HTTP media use VividNetwork → FFmpeg demux → bounded video/audio packet queues → VideoToolbox or FFmpeg decoding → Apple sample-buffer renderers. The shared render synchronizer owns presentation time. Automatic targets about 20 seconds of packet read-ahead; manual choices target 30 or 40 seconds, with independent byte caps and small decoded queues. Startup does not wait for the read-ahead target. Resume readiness also accounts for Apple's renderer queue capacity, avoiding a startup deadlock when that capacity is smaller than the preferred time buffer. These targets do not replace AVPlayer’s server-HLS buffering.

Supported AAC, MP3, AC-3 and E-AC-3 audio can use Apple’s compressed-audio renderer. Other supported formats, including DTS, decode to PCM through FFmpeg. Software PCM buffers reuse their format description until sample rate, sample format or channel layout changes. Their presentation times follow the sample-accurate end of the previous frame when packet timestamps repeat, move backwards or contain tiny rounding differences; real forward gaps remain. This avoids repeated format allocation and tiny PCM gaps/overlaps behind the reported DTS crackle. The retained earlier VividKit Apple TV implementation opts into multichannel output support; iPhone/iPad retain default route negotiation. A native-audio renderer failure still permits one PCM rebuild. This does not establish DTS:X object preservation or every receiver/output layout.

In the retained earlier VividKit tvOS implementation, automatic audio flush and output-configuration notifications first attempt audio-only recovery using retained samples that have not finished playing. The replay queue is bounded to 16 MiB/512 samples and cleared on seek or cancellation. Replay uses the session’s condition lock and the same synchronizer clock; it does not seek or reset video. If replay is unavailable or fails confirmation, recovery can seek within the existing session, with at most three notification-driven recovery attempts in thirty seconds. AirPlay confirmation requires both clock movement and queued-audio progress, and retains flush notifications received during recovery. Audio enqueue allowance accounts for the output route’s latency, and the synchronizer rate is only assigned when it changes. iOS retains its existing audio-route behaviour.

The separate [HDMI recovery policy](../cores/player-engine.md#hdmi-audio) is enabled in tvOS Release builds only for a pure HDMI output route. Debug builds retain the explicit `-VividHDMIAudioCore` launch-argument gate and require the same route. It detects blocked audio delivery, permits one audio-only reset per load and skips overdue samples during catch-up. It does not replace the shared renderer or alter normal startup, decoding or display matching. HomePod, AirPlay, Bluetooth, empty and mixed output routes bypass it. The [mini-core guide](../cores/player-engine.md#vividkit-mini-cores) defines these shared and route-specific responsibilities.

Seeking interrupts old queue work, reuses the demux session, seeks to a preceding keyframe and decodes forward to the requested timestamp. Generation checks prevent outgoing frames and cues from reaching a newer seek or media item.

Server HLS uses AVPlayer. Direct container playback uses AVSampleBufferDisplayLayer, including VideoToolbox-decoded pixel buffers. External video playback is advertised only for receiver-fetchable native HLS. Subtitles use native text and bitmap cues, with libass for ASS/SSA styling. Each new embedded bitmap display set ends the preceding set on the same track, while every rectangle belonging to the new set remains visible together. Preview extraction is separate, bounded work.

VividKit playback has been tested on iPhone 16 Pro Max and Apple TV 4K (3rd generation). Broad remux coverage, Dolby Vision output, Atmos object preservation, interlaced content, external playback, long network stalls and older Apple TV hardware require their own media/device verification; passing the focused synthetic tests does not establish that coverage.

## Direct-network recovery

The reader-level recovery below belongs to VividKit. tvOS Aether uses its own transport and Vivid’s outer reload boundary.

The demux boundary preserves the underlying network failure. Eligible transient failures include HTTP 500, 502, 503 and 504, timeouts, lost connections, connection failures, DNS failures and offline errors. A shared playback recovery budget permits two network retries and one same-route reload; reloading does not replenish that budget, and cancellation invalidates it. Normal compatibility fallback remains available when recovery cannot continue.

Proactive recovery requires active playback, a reader waiting for bytes, an unfinished request and no authentication recovery in progress. Delivery must remain stalled for at least three seconds while reported playable headroom drops by more than 0.1 seconds. Pausing or normal queue backpressure resets eligibility. Resumption retains unread bytes and requests the first missing byte, using a strong ETag or a conservative Last-Modified/Date validator. Range responses and content identity must validate; superseded request callbacks cannot modify the active reader.

Credential changes update the reader and controller snapshot in place. An in-flight 401 coordinates authenticated resumption with a six-second deadline, using newer credentials already available before requesting another refresh. Cancellation and request identity guard against late completions. Native HLS and unsupported recovery cases retain the reconstruction fallback. Debug probe recovery messages report error domain/code, outcome and buffer observations without URLs or credentials. These transport changes do not alter the HDMI or HomePod audio recovery policies.

## Loads and lifecycle

Final playback teardown releases shared audio only when that controller actually started an engine load. Discarded, unused SwiftUI player models and repeated stops cannot deactivate another player’s audio session or reset its display criteria. Replacement loads retain that ownership until the real final stop.

- Keep one clear owner for the engine and its observations.
- Generation-fence loads, session staging, callbacks and recovery. A cancelled or replaced load must not publish into a newer item.
- Keep session/progress identity aligned with the committed source. Stop stale staged sessions on failure or supersession.
- Map server, source and presentation positions through the existing timeline mapper. Do not treat them as interchangeable seconds.
- Renew or replan through the current session bridge and load-spec path. Cancellation is not a playback failure; rate limiting must not trigger an immediate retry loop.
- Preserve pause intent, resume position, seek completion and exactly-once end/episode-handover work across recovery.

## Apple TV presentation

The tvOS Next Up preview is 960 × 540 points, keeping its 16:9 ratio and the existing metadata and action positions. A 10-point gap separates the preview from its metadata. It resizes the same persistent player surface through the existing preview anchor; episode loading, first-frame gating and transport commands are unchanged.

The same Vivid surface remains mounted as playback moves between full screen and Next Up preview geometry. Next Up owns only the preview bounds and action layout; it must never create a second player or restart the current item. Its top-right preview and bottom-left actions are constrained to the actual viewport. The countdown and Play Now depend on an available next episode; absence of a next episode must show an explicit end/error state instead.

Vivid’s custom timeline is shared by native and software engine routes. On Apple TV, a round subtitle shortcut immediately left of Info opens the existing subtitle panel, including primary/secondary tracks, Off, delay and appearance controls. Info contains the remaining tabs. Closing either panel restores focus to its shortcut. The HUD uses a wider, screen-height-aware panel and compact TV stats spacing; long descriptions and track lists remain scrollable. Loading dots are decorative and non-focusable, use a bounded animation cadence, and respect Reduce Motion. AVPlayerViewController hosts the native route, with its transport UI hidden. The same persistent host survives episode handoff; software routes use AetherPlayerView.

## Mobile presentation

Settings only allows the outer pull-to-close gesture while its overview is visible; submenu navigation keeps its own back behaviour. Routine iCloud saved-account imports preserve the current iOS screen tree, so metadata refreshes cannot discard Settings or playback. Active-account changes, deletion and session invalidation still reset that tree. The mobile shell shares account restoration, IntroDB, personal-TMDb and Seerr stores with tvOS. Home’s metadata fetch writes the same per-server/profile disk cache used by the Metadata page. Movie and series detail artwork stays attached to the card edge during scrolling; Home retains its separate parallax and fade-to-black treatment. On iPhone and iPad, pulling down to refresh uniformly zooms the complete spotlight artwork background and keeps its top attached to the scroll viewport. The stretch measures against the fixed parent viewport, including the top safe area. Home triggers its existing refresh action on release after a 90-point pull, using a dots-only Liquid Glass pill and an accessibility Refresh action. Light haptics signal reaching the pull threshold and starting a user-triggered Home refresh on supported iOS devices; background refreshes do not trigger them. Larger white dots sit over dark-tinted Liquid Glass for clearer contrast. It does not attach the native refresh control, whose active inset can clip the poster at the status bar. It follows the pull distance back to zero without changing the refresh action or scaling the title and controls.

Mobile controls remain Vivid-owned. Quality, Audio, Subtitles and Chapters use scrollable anchored popovers. An open popover pins the controls; their presentation host remains mounted during buffering and quality reloads so taps, scrolling and sheets retain a live owner. Rotate, Lock, PiP and AirPlay each keep a round glass button. Transport chrome hides during loading without tearing down that owner. The mobile Next Up layout preserves the player surface. Playback failures and retry actions use the shared dark glass design on mobile and Apple TV. See [App Design](../app-design.md#iphone-and-ipad-layout) for navigation and verification.

## Account storage and sync

Local account metadata lives in Vivid defaults and session/PIN material lives in Vivid’s Keychain audience. `VividCloudAccountSync` merges those records through encrypted CloudKit fields in the user’s private `iCloud.com.blurbery.vivid` container. It fetches before writing, retries record-change conflicts and applies deletion tombstones before local snapshots. A tombstoned server/user identity can return only after an explicit later authentication. The encrypted private iCloud vault syncs saved accounts, sessions, optional Vivid PINs, profile order, shared browsing/navigation/metadata/download preferences and configured TMDb, Seerr, MDBList and OpenSubtitles credentials. Playback and subtitle preferences, downloaded media and metadata/artwork caches remain device-local. Watched and resume state belongs to the connected media server. Optional MDBList imports add local watched indicators without overwriting server history or resume positions; watchlists can sync additions and removals through MDBList.

Fresh-install detection uses an app-container marker. A missing marker with no existing Vivid defaults clears the local Vivid Keychain audience before cloud restoration; an upgrade seeds the marker without clearing the current session. Account sync is best effort when iCloud is unavailable and must not block a working local account.

## Tracks, subtitles and previews

Use the engine’s actual track identities. A dense server ordinal is not necessarily an engine stream ID; stream zero remains valid. Initial selection uses existing provider metadata to prefer a compatible same-language audio alternative while preserving explicit manual choices. For original-file and offline sources, the platform engine resolves the ordinal against the audio inventory from its first demux open. An explicit source stream ID takes precedence. This path must not introduce a preliminary probe or second source open. See [audio selection](README.md#audio-selection-and-startup) for the policy and its limits.

Chapters and embedded subtitle tracks come from the engine’s media inventory. Selection and disabling happen locally without a Silo replan. The optional OpenSubtitles plugin downloads user-selected SRT files to temporary device storage and registers only those files as selectable external tracks. The API key is never forwarded to subtitle download hosts. Downloads are capped at 5 MiB, guarded by playback generation and connection scope, and retained with their selection across successful replacement loads for the same item, including quality changes. They are removed on final player disposal or when another item loads. These temporary track IDs are not persisted as server subtitle preferences. AI translation is not exposed. iOS retains VividKit’s text, libass and bitmap path. tvOS maps primary and secondary selection, cues, delay and styling into Vivid’s subtitle overlay, with eager native subtitle preparation. For actual external native playback, the adapter hands a served primary text rendition to AVPlayer, keyed to item and track changes, then restores the local overlay when returning. Upstream can produce OCR text renditions from bitmap tracks; that is lossy and has not been verified across Vivid’s external routes. Secondary tracks and shifted sidecars do not gain equivalent native external presentation. ASS styling parity with VividKit is not promised. Preferences remain device/profile-local.

Apple TV scrubbing shows the timeline and target time without a thumbnail overlay. Its preview provider remains inactive, so scrubbing starts no thumbnail reader, decoder or request worker. Seek commit/cancel behaviour, play/pause intent and the persistent Next Up player surface are unchanged. iOS thumbnail behaviour is unchanged.

iOS scrub previews use the existing bounded request owner and platform engine frame extractor. Late images from an old source or gesture must not paint over a new selection.

## IntroDB marker timing

The Intro & Credit Skipper toggle controls both IntroDB and TheIntroDB on iOS and tvOS. Valid markers supplied for the selected file are published first and survive provider failures; item-level markers from another edition are not used. IntroDB fills missing file markers and its results are published immediately. If intro, credits or recap is absent, an independent public TheIntroDB `/v3/media` lookup fills only missing kinds, preserving existing ranges. Errors leave the primary result intact, and cancellation, settings and session/content/file guards apply after each request. Neither lookup blocks playback. Each provider has a bounded one-hour in-memory cache and uses an ephemeral session without media-server credentials or API keys.

The fallback adapts milliseconds and nullable boundaries to the current prompt model: a null intro start means zero, and a null credits end resolves when finite media duration arrives. Invalid ranges are rejected. For multiple segments of one kind, only the earliest structurally valid range is used; ranges are never joined across scenes. Recaps use the same toggle, countdown and skip control on iOS and tvOS, labelled Skip Recap within the recap range. Intro and recap markers remain separate on the timeline. Preview and multiple prompts per kind are not included. Both services and TMDB are credited under About → Acknowledgements on iOS and tvOS. Open Source Licences remains separate. TMDB’s logo and attribution are in Acknowledgements; the duplicate About-page block has been removed on iOS and tvOS.

Vivid fetches IntroDB timestamps using the series IMDb ID and season/episode number, independently of the media engine. The request remains fenced to the active playback session, content and file. Prompts require IntroDB to be enabled, valid markers and a playhead inside the marker range.

Raw marker results are retained when the lookup finishes before media duration is available. Vivid reapplies them when a finite duration arrives, rather than permanently dropping a fast lookup. A new lookup, replacement load or cleanup clears the saved markers. This handles a duration-ordering race; missing IMDb metadata, absent provider markers and lookup failures remain separate reasons a prompt may not appear.

## Downloads and external playback

Keep downloaded sources and their metadata independent of an online server's current response and out of the iCloud account vault. The detail action observes registration and transfer state directly from `DownloadManager`, while Downloads reads the same records for progress, transfer rate, storage totals and locally stored poster artwork. Series-scoped requests use the parent series artwork. Accept authenticated artwork only as a relative path or a same-origin absolute URL; normalise it before constructing the server request. Validate offline resume, seeking, tracks and teardown explicitly.

Movies and episodes require 60 seconds of actual viewing before resume updates begin. Pauses, buffering, seeks and background gaps do not count; playback speed does not shorten the minute. Silo uses zero-position session heartbeats before qualification, which its server excludes from saved progress. Emby uses its playback Ping endpoint until qualification, then starts normal playback reporting. Short Emby previews release transcoding without submitting a watched position. Partial resume progress uses the same viewing threshold offline. Completion is separate for every movie and episode: reaching 90% of the duration, reaching a valid credits marker, or a verified natural end marks the item watched even before a minute of viewing. Seeking does not add a from-start requirement. Completion latches for the current item without stopping playback or triggering Next Up. Selected-file credits are preferred; loaded fallback credits apply when available. Missing or invalid markers fall back to the percentage rule. Silo and Emby receive the actual playback position and a separate watched-state write, ordered after progress and final Stop; offline completion is also sent through the watched API on reconnect. This applies to the active server/profile, not cross-server watch-state replication. A premature stream end retains its observed position and does not count as a natural completion. Resume buttons show a short progress indicator and rounded-up minutes remaining, retaining the existing iOS colour. The series hero keeps its series-level season count, genres and facts when episode focus changes. Episode resume buttons on both platforms identify the playback target above the bar as S1 E46, without leading zeros. Home Continue Watching uses the same unpadded season and episode numbers. iOS episode cards follow the tvOS metadata order: episode number, title, overview and air date, with the runtime and white watched check in a dark pill beside the shorter in-artwork progress bar. Movie and episode cards place minutes remaining beside a shorter bar inside the artwork. Apple TV media cards share the series episode shelf’s 5% focus lift and artwork ring; the spotlight remains separate. Its independently updating progress layer uses the artwork’s existing scrim, avoiding a second rectangular layer during focus lift. On tvOS series shelves, the runtime/watched pill, shorter progress bar and remaining-time label share a row so they cannot overlap. Long-pressing a resumable detail button offers Start Over, using the existing restart action. Version selection is under the detail options menu, retaining Auto and individual files; on tvOS series pages this menu is labelled Watched with a checkmark. Audio and subtitle controls stay in the action row. Equal-width version, audio and subtitle readouts extend to the action row’s trailing edge. The series Watched menu offers watched actions in Episode, Season, Series order, targeting the episode used by Play/Resume. On tvOS these follow Favourites in the same menu. Season pages also expose that episode’s watched action. Automatic session recovery preserves the latest play/pause intent instead of always starting the replacement stream. Speed settings remain pending while paused and are applied on explicit Play, because a non-zero AVPlayer rate also starts playback. Qualified playback reports every ten seconds and on exit; reports are ordered so an older request cannot overwrite the final position. Final playback progress is reported before session stop/cleanup. A successful write posts the refresh signal immediately so Home and detail views can request current resume state while teardown finishes. Successful watched/unwatched writes from detail pages use the same account/profile-scoped Home refresh signal. Home queues refreshes that arrive during an older fetch and rejects stale results on both iOS and tvOS. While Home is visible, active and not covered by detail/playback navigation, it also refreshes every ten seconds to pick up changes made on another device. This is provider-backed polling, not iCloud watch-state sync or a realtime push guarantee. Preserve the fallback refresh when the final playback write fails, and do not send the same final progress twice.

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
