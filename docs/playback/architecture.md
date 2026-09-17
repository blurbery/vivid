<p align="center">
  <img src="../branding/vivid-mark-silver.svg" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Playback Architecture</h1>
<p align="center">Engine ownership, server sessions and media state.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

How the [Vivid player core](../cores/vivid.md), Lucid Engine and each server core share playback responsibilities. The [Silo server core](../cores/silo.md) and [Emby server core](../cores/emby.md) are available; Jellyfin remains planned.

## Ownership

<table width="100%">
  <thead>
    <tr><th align="left">Owner</th><th align="left" width="10000">Responsibilities</th></tr>
  </thead>
  <tbody>
    <tr><td>Vivid</td><td>Controls, queues, resume/Next Up, selection preferences, downloads, server sessions, progress, local player stats and presentation</td></tr>
    <tr><td>Lucid Engine (iOS and tvOS)</td><td>Source reads, probing, demux/decode, media routing, buffers, track extraction, seek execution and media presentation</td></tr>
    <tr><td>Server adapter</td><td>Provider authentication, playback-plan negotiation, source headers, renewal, realtime commands and progress reporting</td></tr>
  </tbody>
</table>

Library playback uses Vivid’s existing playback controller. Lucid Engine opens sources through its media core, with compressed AC-3/E-AC-3 output through Apple’s resource loader and decoded PCM through sample-buffer audio. No loopback HLS producer or second reservoir sits in front of it. iPhone/iPad use the same Lucid Engine adapter.

The existing adapter implements Silo's Protocol V3. That is a provider contract, not Vivid's universal server API. A new provider should map its own session and source information into the player inputs without pretending to speak Protocol V3.

## Apple TV pipeline

Lucid Engine’s `VividMPVPlayer` adapter maps playback state, resume, tracks, subtitles and the existing SwiftUI surface onto the media core. The Apple bridge respects Match Content. `PlaybackTrialTrace` records source-free timing events and numeric audio and buffer diagnostics. See the [Lucid Engine guide](../cores/player-engine.md) for the output architecture and device checks.

Lucid Engine uses a 256 MiB forward packet buffer limit and a 16 MiB back buffer. Credential updates use Vivid’s existing reload boundary.

## iPhone and iPad pipeline

The iOS target uses the same pinned media package and Lucid Engine adapter as
tvOS. It exposes the sample-buffer layer through the existing PiP coordinator,
forwards PiP compositing state and honours the background-playback preference.
The iOS bridge retains its media-time presentation path; the tvOS host-clock
presentation configuration remains platform-specific.

Credential changes use Vivid’s reload boundary on both platforms.

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

Vivid’s custom timeline drives Lucid on both platforms. On Apple TV, a round subtitle shortcut immediately left of the sliders control opens a glass subtitle selection menu, with Off, embedded tracks and OpenSubtitles search. Subtitle pickers on both platforms omit settings shortcuts; general Settings owns language and appearance preferences. The sliders control opens the remaining tabs in a Home-style glass bar. Closing either presentation restores focus to its shortcut. The HUD panel is capped at 300 points high, with three-column information and stats layouts; long descriptions, chapters and track lists remain scrollable. Loading dots are decorative and non-focusable, use a bounded animation cadence, and respect Reduce Motion. AVPlayerViewController hosts the native route, with its transport UI hidden. The same persistent host survives episode handoff; Lucid Engine uses `VividMPVHostView` on tvOS.

## Mobile presentation

Settings only allows the outer pull-to-close gesture while its overview is visible; submenu navigation keeps its own back behaviour. Routine iCloud saved-account imports preserve the current iOS screen tree, so metadata refreshes cannot discard Settings or playback. Active-account changes, deletion and session invalidation still reset that tree. The mobile shell shares account restoration, IntroDB, personal-TMDb and Seerr stores with tvOS. Home’s metadata fetch writes the same per-server/profile disk cache used by the Metadata page. Movie and series detail artwork stays attached to the card edge during scrolling; Home retains its separate parallax and fade-to-black treatment. On iPhone and iPad, pulling down to refresh uniformly zooms the complete spotlight artwork background and keeps its top attached to the scroll viewport. The stretch measures against the fixed parent viewport, including the top safe area. Home triggers its existing refresh action on release after a 90-point pull, using a dots-only Liquid Glass pill and an accessibility Refresh action. Light haptics signal reaching the pull threshold and starting a user-triggered Home refresh on supported iOS devices; background refreshes do not trigger them. Larger white dots sit over dark-tinted Liquid Glass for clearer contrast. It does not attach the native refresh control, whose active inset can clip the poster at the status bar. It follows the pull distance back to zero without changing the refresh action or scaling the title and controls.

Mobile controls remain Vivid-owned. Quality, Audio, Subtitles and Chapters use scrollable anchored popovers. An open popover pins the controls; their presentation host remains mounted during buffering and quality reloads so taps, scrolling and sheets retain a live owner. Rotate, Lock, PiP and AirPlay each keep a round glass button. The transport buttons sit at the centre of the player. Visible controls remain mounted during seeking and buffering; each transport tap restarts a five-second auto-hide timer, and tapping the surrounding picture dismisses them. Open menus and sheets suspend auto-hide. iOS Skip Intro and Skip Credits use the same translucent Liquid Glass as other player buttons and retain a fixed gap above the measured bottom control stack when controls hide. The mobile Next Up layout preserves the player surface. Playback failures and retry actions use the shared dark glass design on mobile and Apple TV. See [App Design](../app-design.md#iphone-and-ipad-layout) for navigation and verification.

## Account storage and sync

Local account metadata lives in Vivid defaults and session/PIN material lives in Vivid’s Keychain audience. `VividCloudAccountSync` merges those records through encrypted CloudKit fields in the user’s private `iCloud.com.blurbery.vivid` container. It fetches before writing, retries record-change conflicts and applies deletion tombstones before local snapshots. A tombstoned server/user identity can return only after an explicit later authentication. The encrypted private iCloud vault syncs saved accounts, sessions, optional Vivid PINs, profile order, shared browsing/navigation/metadata/download preferences and configured TMDb, Seerr, MDBList and OpenSubtitles credentials. Playback and subtitle preferences, downloaded media and metadata/artwork caches remain device-local. Watched and resume state belongs to the connected media server. Optional MDBList imports add local watched indicators without overwriting server history or resume positions; watchlists can sync additions and removals through MDBList.

Fresh-install detection uses an app-container marker. A missing marker with no existing Vivid defaults clears the local Vivid Keychain audience before cloud restoration; an upgrade seeds the marker without clearing the current session. Account sync is best effort when iCloud is unavailable and must not block a working local account.

## Tracks, subtitles and previews

Use the engine’s actual track identities. A dense server ordinal is not necessarily an engine stream ID; stream zero remains valid. Initial selection uses existing provider metadata to prefer a compatible same-language audio alternative while preserving explicit manual choices. For original-file and offline sources, the platform engine resolves the ordinal against the audio inventory from its first demux open. An explicit source stream ID takes precedence. This path must not introduce a preliminary probe or second source open. See [audio selection](README.md#audio-selection-and-startup) for the policy and its limits.

Chapters and embedded subtitle tracks come only from the engine’s media inventory, without server chapter fallbacks. Physical iPhones and iPads running Lucid advertise its original-file pipeline, including client-managed dynamic range and audio selection, so compatible MKV sources need not be remuxed just to normalise their container. Inventory notifications are delivered after the engine stores the updated lists, so menus read the latest chapters and tracks. Selection and disabling happen locally without a Silo replan. Both detail and player controls are labelled Subtitles on iOS and tvOS. They share Lucid’s embedded-track projection, ordering and OpenSubtitles access. Language and appearance preferences live in general Settings. The detail menu reuses a five-minute, account/content/file-scoped runtime inventory or opens a bounded metadata-only Lucid reader for the selected file. This reader has no audio or video output, submits no viewing progress and closes its temporary session after inspection or cancellation. Catalogue subtitle rows are never used as a fallback. Embedded choices made before playback are applied locally only to the same content and file. A detail-page download is held in memory for up to 30 minutes and consumed only by the matching account connection, content and file; starting another version cannot attach it. The optional OpenSubtitles plugin downloads user-selected SRT files to temporary device storage and registers only those files as selectable external tracks. The API key is never forwarded to subtitle download hosts. Downloads are capped at 5 MiB, guarded by playback generation and connection scope, and retained with their selection across successful replacement loads for the same item, including quality changes. They are removed on final player disposal or when another item loads. These temporary track IDs are not persisted as server subtitle preferences. AI translation is not exposed. Lucid Engine uses the media core’s renderer for embedded subtitles and Vivid’s overlay for external text subtitles. Primary and secondary selection, delay and styling remain scoped to the active playback session. Preferences remain device/profile-local.

Apple TV scrubbing shows the timeline and target time without a thumbnail overlay. Its preview provider remains inactive, so scrubbing starts no thumbnail reader, decoder or request worker. Seek commit/cancel behaviour, play/pause intent and the persistent Next Up player surface are unchanged. iOS thumbnail behaviour is unchanged.

iOS scrub previews use the existing bounded request owner and platform engine frame extractor. Late images from an old source or gesture must not paint over a new selection.

## IntroDB marker timing

The Intro & Credit Skipper toggle controls both IntroDB and TheIntroDB on iOS and tvOS. Valid markers supplied for the selected file are published first and survive provider failures; item-level markers from another edition are not used. IntroDB fills missing file markers and its results are published immediately. If intro, credits or recap is absent, an independent public TheIntroDB `/v3/media` lookup fills only missing kinds, preserving existing ranges. Errors leave the primary result intact, and cancellation, settings and session/content/file guards apply after each request. Neither lookup blocks playback. Each provider has a bounded one-hour in-memory cache and uses an ephemeral session without media-server credentials or API keys.

The fallback adapts milliseconds and nullable boundaries to the current prompt model: a null intro start means zero, and a null credits end resolves when finite media duration arrives. Invalid ranges are rejected. For multiple segments of one kind, only the earliest structurally valid range is used; ranges are never joined across scenes. Recaps use the same toggle, countdown and skip control on iOS and tvOS, labelled Skip Recap within the recap range. Intro and recap markers remain separate on the timeline. Preview and multiple prompts per kind are not included. Both services and TMDB are credited under About → Acknowledgements on iOS and tvOS. Open Source Licences remains separate. TMDB’s logo and attribution are in Acknowledgements; the duplicate About-page block has been removed on iOS and tvOS.

Vivid fetches IntroDB timestamps using the series IMDb ID and season/episode number, independently of the media engine. The request remains fenced to the active playback session, content and file. Prompts require IntroDB to be enabled, valid markers and a playhead inside the marker range.

Raw marker results are retained when the lookup finishes before media duration is available. Vivid reapplies them when a finite duration arrives, rather than permanently dropping a fast lookup. A new lookup, replacement load or cleanup clears the saved markers. This handles a duration-ordering race; missing IMDb metadata, absent provider markers and lookup failures remain separate reasons a prompt may not appear.

## Downloads and external playback

Fresh background downloads bind their destination and credential headers to one captured server account and profile. Manifest, artwork and initial status requests carry that same identity and reject a changed account/profile before dispatch. Account/profile changes discard pending pipeline results before starting a transfer, including on Silo; a refresh for the same account can still supply its updated access token. Existing paused transfers retain their resume data.

Reduced-quality downloads are a separate server operation from playback quality. Silo retains its prepared-download API. On iPhone and iPad, Emby registers the current installation as a native sync target, negotiates its advertised options and creates one conversion job per selected movie or episode. Both download and sync-transcoding permissions are required. Vivid polls the job until the complete file and its media metadata are ready, then downloads `/Sync/JobItems/{Id}/File` through the existing background session. Emby selects the source version for conversion. Completed transfers retain acknowledgement retries, and offline deletions retain hidden cleanup records. Reconciliation discards results after an account/profile generation change. Unavailable conversion leaves original-file capability intact; tvOS does not offer conversion downloads.

Downloads retain the configured server's HTTP or HTTPS scheme; an HTTPS configuration cannot be downgraded by the initial destination. Background transfers are managed by Apple's networking service, which follows redirects without calling the app's redirect delegate. Initial-origin checks therefore do not enforce redirect isolation. Preventing that requires a different transfer design or server support for URLs that do not carry reusable credentials. Vivid currently retains background transfers with this limitation.

Lucid Engine has no local HLS listener. Remote HLS is read by the media core’s FFmpeg transport.

Keep downloaded sources and their metadata independent of an online server's current response and out of the iCloud account vault. The detail action observes registration and transfer state directly from `DownloadManager`, while Downloads reads the same records for progress, transfer rate, storage totals and locally stored poster artwork. Series-scoped requests use the parent series artwork. Accept authenticated artwork only as a relative path or a same-origin absolute URL; normalise it before constructing the server request. Validate offline resume, seeking, tracks and teardown explicitly.

Movies and episodes require 60 seconds of actual viewing before resume updates begin. Pauses, buffering, seeks and background gaps do not count; playback speed does not shorten the minute. Silo uses zero-position session heartbeats before qualification, which its server excludes from saved progress. Emby uses its playback Ping endpoint until qualification, then starts normal playback reporting. Short Emby previews release transcoding without submitting a watched position. Partial resume progress uses the same viewing threshold offline. Completion is separate for every movie and episode: reaching 90% of the duration, reaching a valid credits marker, or a verified natural end marks the item watched even before a minute of viewing. Seeking does not add a from-start requirement. Completion latches for the current item without stopping playback or triggering Next Up. Selected-file credits are preferred; loaded fallback credits apply when available. Missing or invalid markers fall back to the percentage rule. Silo and Emby receive the actual playback position and a separate watched-state write, ordered after progress and final Stop; offline completion is also sent through the watched API on reconnect. This applies to the active server/profile, not cross-server watch-state replication. A premature stream end retains its observed position and does not count as a natural completion. Resume buttons show a short progress indicator and rounded-up minutes remaining, retaining the existing iOS colour. The series hero keeps its series-level season count, genres and facts when episode focus changes. Episode resume buttons on both platforms identify the playback target above the bar as S1 E46, without leading zeros. Home Continue Watching uses the same unpadded season and episode numbers. iOS episode cards follow the tvOS metadata order: episode number, title, overview and air date, with the runtime and white watched check in a dark pill beside the shorter in-artwork progress bar. Movie and episode cards place minutes remaining beside a shorter bar inside the artwork. Apple TV media cards share the series episode shelf’s 5% focus lift and artwork ring; the spotlight remains separate. Its independently updating progress layer uses the artwork’s existing scrim, avoiding a second rectangular layer during focus lift. On tvOS series shelves, the runtime/watched pill, shorter progress bar and remaining-time label share a row so they cannot overlap. Long-pressing a resumable detail button offers Start Over, using the existing restart action. Version selection is under the detail options menu, retaining Auto and individual files; on tvOS series pages this menu uses the three-dot More trigger. Audio and subtitle controls stay in the action row. Equal-width version, audio and subtitle readouts extend to the action row’s trailing edge. The series More menu offers watched actions in Episode, Season, Series order, targeting the episode used by Play/Resume. On tvOS these follow Favourites in the same menu. Season pages also expose that episode’s watched action. Automatic session recovery preserves the latest play/pause intent instead of always starting the replacement stream. Speed settings remain pending while paused and are applied on explicit Play, because a non-zero AVPlayer rate also starts playback. Qualified playback reports every ten seconds and on exit; reports are ordered so an older request cannot overwrite the final position. Final playback progress is reported before session stop/cleanup. A successful write posts the refresh signal immediately so Home and detail views can request current resume state while teardown finishes. Successful watched/unwatched writes from detail pages use the same account/profile-scoped Home refresh signal. Home queues refreshes that arrive during an older fetch and rejects stale results on both iOS and tvOS. While Home is visible, active and not covered by detail/playback navigation, it also refreshes every ten seconds to pick up changes made on another device. This is provider-backed polling, not iCloud watch-state sync or a realtime push guarantee. Preserve the fallback refresh when the final playback write fails, and do not send the same final progress twice.

PiP, AirPlay, HDR and audio-format behaviour depend on the exact engine route, device and source. In particular, a receiver cannot be assumed to reproduce the sender's private authentication headers. Do not widen an advertised capability based only on a package upgrade or a successful build.

## Diagnostics and dependencies

- Keep development logs local, redacted and bounded. Vivid does not capture or upload in-app diagnostics reports. Do not expose credentials, source URLs, paths or subtitle contents in logs.
- Classify typed failures using stable kinds, with an unknown fallback, rather than matching localized error text.
- Read the shared media dependency from [project.yml](../../iosApp/project.yml) and [project-ios.yml](../../iosApp/project-ios.yml), with exact revisions and provenance in the [third-party notices](../../THIRD_PARTY_NOTICES.md).
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

Lucid applies general subtitle appearance and delay preferences to its native plain-text renderer and to downloaded subtitle overlays. Authored ASS and bitmap subtitle styles stay intact. Automatic audio selection uses English when the requested language is unavailable, then the file default if English is also absent. Missing automatic subtitle language matches leave subtitles off. Playback settings show Automatic buffering and omit the unused lossless-audio toggle. The tvOS detail subtitle control uses the same anchored native menu as More, with the selected Play episode/file as its inventory context. Intro, recap and credits actions share fixed bottom-trailing clearance and Liquid Glass styling on each platform.
