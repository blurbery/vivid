<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Vivid core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="../playback/README.md">Playback</a> · <a href="../server-connections.md">Server connections</a></p>

---

Vivid is the shared player core. It owns the playback experience used by every server core: the interface, controls, playback state and common player features. Silo and Emby supply server connections and translate their data into the inputs Vivid needs. Jellyfin is planned.

These cores describe responsibility boundaries. They are not a claim that the current source has already been split into separate Swift packages or that every server connection is implemented.

## Player ownership

Vivid owns playback controls and focus, play/pause and seeking, version/audio/subtitle selection, platform Info panels, loading presentation, resume, the episode countdown and playback reporting. Its capped quality modes can perform one lower-bitrate reload after sustained buffering; Auto and Original are not enrolled. AetherEngine owns media execution on Apple TV through one session with automatic native Apple and software paths. VividKit retains that role on iPhone and iPad. The tvOS AVPlayerViewController hosts native picture and system playback integration while Vivid keeps its own controls and persistent Next Up surface.

Shared player fixes belong here so each server core uses the same behaviour. Server-specific authentication, requests, session negotiation and progress persistence belong behind the relevant server connection. A new server core should translate its data into the shared player rather than copy Vivid’s controls or implement a separate player.

## Inputs from a server core

Each server core must provide the available media sources and their required authentication, stable item and track identities, episode ordering, resume information and the metadata needed by shared features. It must translate Vivid’s progress and playback actions into that server’s API and report unsupported capabilities honestly.

The same controls should behave consistently when the server supplies the required capabilities. Equivalent behaviour still needs testing with each server; shared UI alone does not establish compatibility.

## Intro and credits skipping belongs to Vivid

The **Intro & Credit Skipper** toggle in Playback settings controls selected-file markers and public IntroDB/TheIntroDB lookups on iOS and tvOS. It defaults on and preserves an explicitly saved Off choice. Separate automatic-skip preferences control automatic skipping; valid markers also supply manual Skip Intro, Skip Recap and Skip Credits prompts.

Valid markers for the selected file take priority. IntroDB fills missing ranges, then TheIntroDB can fill missing intro, credits or recap ranges. Item-level markers from another edition and realtime server marker updates do not override this selection. Lookups use the series IMDb ID, season and episode number, run without media-server credentials or API keys, and do not delay playback. Public lookups cover episodes; online movies can still use their selected-file markers. Offline playback does not load these skip markers.

See [marker timing](../playback/architecture.md#introdb-marker-timing) for ordering, caching, duration validation and cancellation. Earlier IntroDB playback was verified on Silo-backed Apple TV; that does not establish device coverage of the newer fallback and recap paths or every Emby route. Request and range checks live in [check-introdb-client.sh](../../scripts/ci/check-introdb-client.sh).

## Implementation references

- [Player engine core](player-engine.md): Platform engines, AirPlay/HDMI boundaries and audio/video support.
- [Playback architecture](../playback/architecture.md): engine ownership, lifecycle and source/session boundaries.
- [Playback guide](../playback/README.md): controls, IntroDB behaviour and validation.
- [PlayerViewModel](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift): shared playback state and marker application.
- [PlayerSettings](../../iosApp/iosApp/Screens/Player/PlayerSettings.swift): settings and the current Vivid IntroDB client.
- [Silo server core](silo.md): the implemented server connection.
- [Emby server core](emby.md): current integration work and verification limits.

## Mobile implementation

The iPhone/iPad shell shares the private iCloud account vault, first-run preparation, Home metadata caching, TMDb trailers, Seerr and IntroDB with TV. The encrypted private iCloud vault syncs saved accounts, sessions, optional Vivid PINs, profile order, shared browsing/navigation/metadata/download preferences and configured TMDb, Seerr, MDBList and OpenSubtitles credentials. Playback and subtitle preferences, downloaded media and metadata/artwork caches remain device-local. Watched and resume state belongs to the connected media server. Optional MDBList imports add local watched indicators without overwriting server history or resume positions; watchlists can sync additions and removals through MDBList. Search and Settings use full-screen portrait slide-up pages with round close buttons. Detail cards remain above Search during playback, and movie/series Media Information uses separate aligned video/file and audio panels on mobile and TV. See [mobile design and validation](../app-design.md#iphone-and-ipad-layout); shared code is not a claim of device or format parity.

[Documentation](../README.md)
