<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Emby server core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../server-connections.md">Server connections</a></p>

---

Emby is available on iPhone, iPad and Apple TV. It connects to Emby and translates its library, media sources and user state into Vivid's screens and local player. Its current feature and verification limits are listed below.

> [!IMPORTANT]
> Emby playback and account switching have been device-tested on iPhone and Apple TV. The adapter still has the limits listed below. Physical iPad coverage and a complete format/transcoding matrix remain outstanding.

## Provider boundary

Emby uses its own server identity, native user ID, authentication headers, endpoints and playback reporting. Silo keeps its existing connection and Protocol V3 path. Shared networking and player code dispatch to Emby only for an Emby account; defaults for Silo remain unchanged. Address fallback, TMDb lookup, direct-play HDR options and download checks remain scoped to Emby.

Server addresses and account credentials are supplied at setup, not embedded in the build. Tokens remain in Keychain under Vivid's current storage identity and can be copied between the user’s devices through Vivid’s private iCloud account vault. The entered password is not retained. Account changes invalidate obsolete requests, and Emby credentials are not sent to TMDb or IntroDB.

## Setup and browsing

On iPhone, iPad and Apple TV, the Emby provider card opens the existing native server and login form. Setup probes `/System/Info/Public`; login uses `/Users/AuthenticateByName`. An explicitly entered HTTPS address keeps HTTPS during Emby discovery. Saved sessions retain the native Emby user ID.

<table width="100%">
  <thead><tr><th align="left">Area</th><th align="left" width="10000">Current implementation</th></tr></thead>
  <tbody>
    <tr><td>Home</td><td>Before Emby 4.10.0.4, read the user's legacy Home settings and load supported video sections in their configured order. Emby 4.9.0.23 and later use <code>/usersettings/{userId}</code>; older servers use DisplayPreferences. Newer servers use HomeSections with the appropriate display mode.</td></tr>
    <tr><td>Home rows</td><td>Continue Watching, Next Up, library-specific latest media, Collections and Recently Released Movies have legacy mappings. No fabricated Spotlight or generic Recently Added row is added. Those old rows are also excluded from the Emby cache; cached hero slides cannot recreate removed feed rows.</td></tr>
    <tr><td>Mobile hero</td><td>Emby artwork fits inside the carousel without the additional parallax crop. The metadata line beneath the logo, including rating and year, is hidden. Silo retains its existing presentation.</td></tr>
    <tr><td>Collections</td><td>The mobile Collections page shows Emby BoxSet poster cards. Opening one requests its direct members with recursion and automatic collection grouping disabled. A fresh first page replaces stale cached membership.</td></tr>
    <tr><td>Seasons</td><td>Season queries are nonrecursive and accept only Season records. Known season numbers display as Season 1, Season 2 and so on; zero displays as Specials. Custom Emby names such as Reacher’s Gone Tomorrow no longer replace the numbered label. Missing/invalid season numbers retain the supplied name. This is an Emby-only client mapping; server metadata and Silo naming are unchanged. Episode requests remain restricted to the selected season, and counts fall back to ChildCount when RecursiveItemCount is absent.</td></tr>
    <tr><td>Versions</td><td>MediaSources supply stable version IDs, tracks and technical metadata. Resolution labels consider width as well as cropped height: 3840×1606 is classified as 4K, and 1920×802 as 1080p. Original dimensions remain in the video-track data.</td></tr>
  </tbody>
</table>

Continue Watching and Next Up identify the episode beneath the series title. Continue Watching captions use unpadded `S1 E3 – Episode title` on mobile and Apple TV; other shared mobile episode captions can retain `S01E03 · Episode title`. Partly watched cards use the same inset white progress bar as episode cards on series details.

The Home endpoint listed in the 4.9 API schema is not sufficient evidence that the newer Home workflow is usable. Emby's own client gates it at 4.10.0.4. Legacy library-navigation tiles, audio and live-TV sections are not mapped into this video feed.

## Playback and settings

`EmbyPlayback` negotiates through `/Items/{id}/PlaybackInfo`, converts audio ordinals to Emby stream indices, and supplies direct-file or HLS inputs to Vivid’s platform engine. It sends start, progress and stop reports through `/Sessions/Playing`, `/Sessions/Playing/Progress` and `/Sessions/Playing/Stopped`. Positions convert between seconds and Emby ticks. Transcoded-session cleanup uses Emby's active-encoding endpoint.

Vivid’s Emby preferences are scoped per server and native user. Eligible shared preferences can sync through the private iCloud vault; playback and subtitle settings stay device-local. These are Vivid preferences, not a claim that Emby synchronises them between its own clients. The shared player exposes embedded subtitles and device-local caption preferences. Connecting OpenSubtitles in Plugins also enables manual subtitle search and temporary SRT downloads on iOS and tvOS. Arbitrary file imports and subtitle translation are not offered. The five shared [quality choices](../playback/README.md#quality-controls) feed native PlaybackInfo negotiation: Vivid’s kbps ceiling converts to Emby’s bps, and each mode keeps its resolution ceiling. An eligible one-time buffering fallback reloads the selected source at the current position through the same bridge. Auto and Original are not enrolled. Detail Media Information likewise converts Emby’s bps before display. This does not replace device/codec capability checks or establish live throttled-playback coverage.

TMDb remains an optional personal credential stored in Keychain. Emby provider IDs supply metadata identity; when a TMDb ID is absent, the Emby path can resolve an IMDb ID through TMDb. IntroDB and TheIntroDB use the common series IMDb ID and season/episode numbers through the shared Intro & Credit Skipper toggle and separate automatic-skip switches. Live Emby playback with these integrations still needs verification.

Original-file downloads use the existing download manager with native Emby authentication and the server's download policy. Their detail-page progress ring, poster artwork and Downloads cards use the shared mobile presentation. Transcoded downloads, season batches and monitoring are not implemented by the Emby adapter. The watchlist is stored locally in Vivid and can sync additions and removals through the optional MDBList connection. MDBList history imports add eligible local watched indicators without changing Emby history or resume positions. Eligible shared preferences and plugin credentials use the private iCloud vault, while native favourites and playback progress use Emby. See [plugin behaviour and import safeguards](../server-connections.md#plugins-on-iphone-ipad-and-apple-tv). Collection editing, realtime events and other unmapped features must not be advertised as complete.

In General → Home Screen, **Combine Next Up with Continue Watching** puts Emby resume items first, followed by Next Up episodes without duplicate content IDs. The combined row is titled Continue Watching and replaces the separate Next Up row while enabled. This Vivid setting is saved per server/profile, participates in the existing private iCloud preference sync, defaults to off and is available on iPhone, iPad and Apple TV only for Emby. Turning it off restores Emby’s usual rows. It does not change server watch history or resume positions.

On iPhone, iPad and Apple TV, Emby Movies and Series filter options come from Emby’s `/Genres` and `/OfficialRatings` endpoints, scoped to the selected library. These routes are confirmed in Emby 4.9.5.0’s own API schema; the obsolete `/Items/Filters` routes return 404 on that version. Genre, content rating, decade and watch status use native Emby queries; mixed libraries also offer media type. Different filter categories are combined with AND, with multiple values within a category matched with OR. Unsupported technical facets and the Match Any switch are not offered on this Emby path. A–Z uses Emby’s native name-prefix query, with # using its pre-A sort range and All removing the prefix. Silo filtering retains its existing behaviour. On 12 September 2026, the owner confirmed that both Movies and Series filter menus opened and genre filtering worked on Bedroom Apple TV. Both platform builds passed; the matching mobile endpoint change still needs device confirmation.

## Compatible audio

Initial audio selection uses Emby’s existing track metadata. Vivid prefers a compatible non-commentary track in the selected language, maps its ordinal to the source stream index, and then requests PlaybackInfo. It preserves an explicit manual choice and falls back to the original choice when no same-language alternative exists. No separate media probe is added.

Compatible AC-3 selection and TrueHD 7.1 source playback have been verified with Emby in development builds. See the [player engine core](player-engine.md#audio-support) for supported formats and output limits. This does not guarantee every channel layout or packaged audio-switching route. Emby Direct Play describes server delivery; local FFmpeg decoding to PCM can still be used.

## Validation

The app changes published through `v0.13.0` (`2ee9005c`) include the device-tested Emby setup and account selection, episode labels, resume bars, compatible-audio selection and serialised manual audio changes. Device checks covered the iPhone compatible-audio path, Next Up labels and shared episode-card changes. Apple TV checks confirmed account switching after the initial add-account crash was addressed. That confirmation does not prove the cause of the original crash or cover every account-transition failure.

Earlier automated checks covered Emby mapping, identity boundaries, local preferences, quality limits, Home-row filtering, collections, seasons and resolution labels. Separate TMDb and IntroDB checks covered request isolation and metadata mapping. Those checks passed on their recorded development revisions; they are not a new full-suite run against `v0.13.0`.

On 8 September 2026, read-only inspection confirmed that Reacher’s fourth season was stored as Gone Tomorrow with season number 4 in the connected Emby library. The adapter now labels it Season 4 on both platforms without altering the server. Four source-derived mapping checks passed for numbered seasons, Specials, missing numbers and unchanged episode titles. The existing season regression test also includes the Reacher case. Both device builds passed, were installed, and device checks confirmed the completed update on iPhone and Apple TV. This does not expand the untested integration and format coverage below.

Physical iPad testing, all audio layouts, transcoding routes and live Emby IntroDB/trailer coverage remain outstanding. Historical full-suite CI results and optional live-fixture skips are recorded in [App Design](../app-design.md#responsive-layout-validation); automated mapping tests do not replace those live checks. Use these limits when planning further TestFlight checks.

## Source ownership

- [EmbyProvider](../../iosApp/iosApp/Networking/EmbyProvider.swift): connection, API translation, Home, collections, seasons and metadata.
- [EmbyLocalPreferences](../../iosApp/iosApp/Networking/EmbyLocalPreferences.swift): account-scoped Vivid preferences.
- [EmbyPlayback](../../iosApp/iosApp/Screens/Player/EmbyPlayback.swift): source negotiation and session reporting.
- [EmbyDownloads](../../iosApp/iosApp/Downloads/EmbyDownloads.swift): original-file download registration and manifests.
- [EmbyAdapterTests](../../iosApp/Tests/EmbyAdapterTests.swift): focused regression cases.
