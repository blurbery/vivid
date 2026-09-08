<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Emby server core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../server-connections.md">Server connections</a></p>

---

Emby is available on iPhone, iPad and Apple TV. It connects to Emby and translates its library, media sources and user state into Vivid's screens and local VividKit player. Its current feature and verification limits are listed below.

> [!IMPORTANT]
> I’ve tested Emby playback and account switching on iPhone and Apple TV. The adapter still has the limits listed below. Physical iPad coverage and a complete format/transcoding matrix remain outstanding.

## Provider boundary

Emby uses its own server identity, native user ID, authentication headers, endpoints and playback reporting. Silo keeps its existing connection and Protocol V3 path. Shared networking and player code dispatch to Emby only for an Emby account; defaults for Silo remain unchanged. Address fallback, TMDb lookup, direct-play HDR options and download checks remain scoped to Emby.

Server addresses and account credentials are supplied at setup, not embedded in the build. Tokens remain in Keychain under Vivid's current storage identity. Account changes invalidate obsolete requests, and Emby credentials are not sent to TMDb or IntroDB.

## Setup and browsing

On iPhone, iPad and Apple TV, the Emby provider card opens the existing native server and login form. Setup probes `/System/Info/Public`; login uses `/Users/AuthenticateByName`. An explicitly entered HTTPS address keeps HTTPS during Emby discovery. Saved sessions retain the native Emby user ID.

<table width="100%">
  <thead><tr><th align="left">Area</th><th align="left" width="10000">Current implementation</th></tr></thead>
  <tbody>
    <tr><td>Home</td><td>Before Emby 4.10.0.4, read the user's legacy Home settings and load supported video sections in their configured order. Emby 4.9.0.23 and later use <code>/usersettings/{userId}</code>; older servers use DisplayPreferences. Newer servers use HomeSections with the appropriate display mode.</td></tr>
    <tr><td>Home rows</td><td>Continue Watching, Next Up, library-specific latest media, Collections and Recently Released Movies have legacy mappings. No fabricated Spotlight or generic Recently Added row is added. Those old rows are also excluded from the Emby cache; cached hero slides cannot recreate removed feed rows.</td></tr>
    <tr><td>Mobile hero</td><td>Emby artwork fits inside the carousel without the additional parallax crop. The metadata line beneath the logo, including rating and year, is hidden. Silo retains its existing presentation.</td></tr>
    <tr><td>Collections</td><td>The mobile Collections page shows Emby BoxSet poster cards. Opening one requests its direct members with recursion and automatic collection grouping disabled. A fresh first page replaces stale cached membership.</td></tr>
    <tr><td>Seasons</td><td>Season queries are nonrecursive and accept only Season records, preventing episode names from becoming tabs. Episode requests are restricted to the selected season. Episode counts fall back to ChildCount when RecursiveItemCount is absent.</td></tr>
    <tr><td>Versions</td><td>MediaSources supply stable version IDs, tracks and technical metadata. Resolution labels consider width as well as cropped height: 3840×1606 is classified as 4K, and 1920×802 as 1080p. Original dimensions remain in the video-track data.</td></tr>
  </tbody>
</table>

Continue Watching and Next Up show `S01 E03 – Episode title` beneath the main title on mobile and Apple TV. Partly watched cards use the same inset white progress bar as episode cards on series details.

The Home endpoint listed in the 4.9 API schema is not sufficient evidence that the newer Home workflow is usable. Emby's own client gates it at 4.10.0.4. Legacy library-navigation tiles, audio and live-TV sections are not mapped into this video feed.

## Playback and settings

`EmbyPlayback` negotiates through `/Items/{id}/PlaybackInfo`, converts audio ordinals to Emby stream indices, and supplies direct-file or HLS inputs to VividKit. It sends start, progress and stop reports through `/Sessions/Playing`, `/Sessions/Playing/Progress` and `/Sessions/Playing/Stopped`. Positions convert between seconds and Emby ticks. Transcoded-session cleanup uses Emby's active-encoding endpoint.

Vivid’s Emby preferences are stored locally per server and native user. They do not synchronise through Emby settings or automatically follow the account to another device. The shared player lists subtitles embedded in the opened media; server sidecars, external files, subtitle search and translation are not offered. Language, behavior and appearance use local preferences or the device’s Accessibility caption settings. Quality limits feed Emby negotiation; the obsolete Dolby Vision and lossless-bridge settings are removed. Device and source capabilities still determine the decode/output route.

TMDb remains an optional personal credential stored in Keychain. Emby provider IDs supply metadata identity; when a TMDb ID is absent, the Emby path can resolve an IMDb ID through TMDb. IntroDB uses the common series IMDb ID and season/episode numbers, with the shared IntroDB toggle and separate automatic-skip switches. Live Emby playback with these integrations still needs verification.

Original-file downloads use the existing download manager with native Emby authentication and the server's download policy. Transcoded downloads, season batches and monitoring are not implemented by the Emby adapter. Watchlist and Vivid preferences are local; native favourites and watched state use Emby. Collection editing, realtime events and other unmapped features must not be advertised as complete.

## Compatible audio

Initial audio selection uses Emby’s existing track metadata. Vivid prefers a compatible non-commentary track in the selected language, maps its ordinal to the source stream index, and then requests PlaybackInfo. It preserves an explicit manual choice and falls back to the original choice when no same-language alternative exists. No separate media probe is added.

I confirmed that Dune’s alternate AC-3 track plays with sound and that automatic selection keeps startup fast. The silent TrueHD track itself has not been confirmed fixed. This result does not guarantee every 7.1 layout or packaged audio-switching route. Direct playback describes the server delivery route; local FFmpeg decoding to PCM can still be used.

## Validation

The app changes published in `v0.12.5` (`cb8c9490`) include the device-tested Emby setup and account selection, episode labels and resume bars. I confirmed the iPhone compatible-audio path and later confirmed Next Up labels and the shared episode-card changes. On Apple TV, I confirmed that switching to Emby worked after the initial add-account crash was addressed. That confirmation does not prove the cause of the original crash or cover every account-transition failure.

Earlier automated checks covered Emby mapping, identity boundaries, local preferences, quality limits, Home-row filtering, collections, seasons and resolution labels. Separate TMDb and IntroDB checks covered request isolation and metadata mapping. Those checks passed on their recorded development revisions; they are not a new full-suite run against `v0.12.5`.

Physical iPad testing, all audio layouts, transcoding routes and live Emby IntroDB/trailer coverage remain outstanding. The complete XCTest suite has not been rerun against the release. Use these limits when choosing the first TestFlight group.

## Source ownership

- [EmbyProvider](../../iosApp/iosApp/Networking/EmbyProvider.swift): connection, API translation, Home, collections, seasons and metadata.
- [EmbyLocalPreferences](../../iosApp/iosApp/Networking/EmbyLocalPreferences.swift): account-scoped Vivid preferences.
- [EmbyPlayback](../../iosApp/iosApp/Screens/Player/EmbyPlayback.swift): source negotiation and session reporting.
- [EmbyDownloads](../../iosApp/iosApp/Downloads/EmbyDownloads.swift): original-file download registration and manifests.
- [EmbyAdapterTests](../../iosApp/Tests/EmbyAdapterTests.swift): focused regression cases.
