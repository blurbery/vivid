<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Vivid core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="../playback/README.md">Playback</a> · <a href="../server-connections.md">Server connections</a></p>

---

Vivid is the shared player core. It owns the playback experience used by every server core: the interface, controls, playback state and common player features. Silo, Emby and Jellyfin supply separate server connections and translate their data into the inputs Vivid needs. Each provider owns its authentication and wire contracts.

These cores describe responsibility boundaries. They are not a claim that the current source has already been split into separate Swift packages or that every provider offers the same features.

## Player ownership

Vivid owns playback controls and focus, play/pause and seeking, version/audio/subtitle selection, platform Info panels, loading presentation, resume, the episode countdown and playback reporting. Its capped quality modes can perform one lower-bitrate reload after sustained buffering; Auto and Original are not enrolled. Lucid Engine owns media execution on Apple TV, iPhone and iPad. Lucid Engine presents video in Vivid’s persistent surface, with Vivid’s own controls and Next Up integration.

Shared player fixes belong here so each server core uses the same behaviour. Server-specific authentication, requests, session negotiation and progress persistence belong behind the relevant server connection. A new server core should translate its data into the shared player rather than copy Vivid’s controls or implement a separate player.

## Inputs from a server core

Each server core must provide the available media sources and their required authentication, stable item and track identities, episode ordering, resume information and the metadata needed by shared features. It must translate Vivid’s progress and playback actions into that server’s API and report unsupported capabilities honestly.

The same controls should behave consistently when the server supplies the required capabilities. Equivalent behaviour still needs testing with each server; shared UI alone does not establish compatibility.

## Intro and credits skipping belongs to Vivid

The **Intro & Credit Skipper** toggle in Playback settings controls selected-file markers and public IntroDB/TheIntroDB lookups on iOS and tvOS. It defaults on and preserves an explicitly saved Off choice. Separate automatic-skip preferences control automatic skipping; valid markers also supply manual Skip Intro, Skip Recap and Skip Credits prompts. On iOS, prompts stay hidden during loading and buffering.

Valid markers for the selected file take priority. IntroDB fills missing ranges, then TheIntroDB can fill missing intro, credits or recap ranges. Item-level markers from another edition and realtime server marker updates do not override this selection. IntroDB uses the series IMDb ID; TheIntroDB prefers TMDb and falls back to IMDb. Both use the season and episode number. Requests run without media-server credentials or API keys and do not delay playback. Public lookups cover episodes; online movies can still use their selected-file markers. Offline playback does not load these skip markers.

See [marker timing](../playback/architecture.md#introdb-marker-timing) for ordering, caching, duration validation and cancellation. Earlier IntroDB playback was verified on Silo-backed Apple TV; that does not establish device coverage of the newer fallback and recap paths or every Emby route. Request and range checks live in [check-introdb-client.sh](../../scripts/ci/check-introdb-client.sh).

## Implementation references

- [Player engine core](player-engine.md): Lucid execution, output boundaries and audio/video support.
- [Playback architecture](../playback/architecture.md): engine ownership, lifecycle and source/session boundaries.
- [Playback guide](../playback/README.md): controls, IntroDB behaviour and validation.
- [PlayerViewModel](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift): shared playback state and marker application.
- [PlayerSettings](../../iosApp/iosApp/Screens/Player/PlayerSettings.swift): settings and the current Vivid IntroDB client.
- [Silo server core](silo.md): the implemented server connection.
- [Emby server core](emby.md): native integration and verification limits.
- [Jellyfin server core](jellyfin.md): native integration and verification limits.

## Mobile implementation

The iPhone/iPad shell shares the private iCloud account vault, first-run preparation, Home metadata caching, TMDb trailers, Seerr and IntroDB with TV. The encrypted private iCloud vault syncs saved accounts, sessions, optional Vivid PINs, profile order, shared browsing/navigation/metadata/download preferences and configured TMDb, Seerr, MDBList and OpenSubtitles credentials. Playback and subtitle preferences, downloaded media and metadata/artwork caches remain device-local. Watched and resume state belongs to the connected media server. Optional MDBList sync exports newly completed or explicitly marked watches after the server confirms them, and syncs watchlist additions and removals in both directions. It does not import either service’s existing watched history or replace server resume positions. Search and Settings use full-screen slide-up pages with round close buttons. Both retain portrait on iPhone and support portrait and landscape on iPad. Movie, series and actor details open full-screen on iPhone and iPad, remaining above Search during playback, and movie/series Media Information uses separate aligned video/file and audio panels on mobile and TV. See [mobile design and validation](../app-design.md#iphone-and-ipad-layout); shared code is not a claim of device or format parity.

[Documentation](../README.md)
