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

## IntroDB belongs to Vivid

Intro and credits skipping is a Vivid feature, independent of the server’s marker integration. Playback → IntroDB is an on/off toggle, enabled by default, labelled “Toggle on for native intro & credit skips.” Public timestamp lookups need no personal API key; IntroDB keys are for submissions.

Vivid uses the series IMDb ID, season and episode number supplied through the server core to request IntroDB timestamps. Valid ranges feed the existing Skip Intro and Skip Credits buttons. The separate automatic-skip preferences control whether Vivid skips automatically.

Vivid ignores Silo’s watch-detail and realtime markers. This does not disable or alter IntroDB on the Silo server itself. Lookups use a separate session without server credentials, validate identity and duration bounds, and do not block playback when data is unavailable. The endpoint covers TV episodes; movie credits and offline lookups are not provided.

IntroDB playback has been verified on Silo-backed Apple TV. The Emby core now supplies common episode identity, but IntroDB playback with Emby has not been verified. Jellyfin remains planned. Request and range checks live in [check-introdb-client.sh](../../scripts/ci/check-introdb-client.sh).

## Implementation references

- [Player engine core](player-engine.md): Platform engines, AirPlay/HDMI boundaries and audio/video support.
- [Playback architecture](../playback/architecture.md): engine ownership, lifecycle and source/session boundaries.
- [Playback guide](../playback/README.md): controls, IntroDB behaviour and validation.
- [PlayerViewModel](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift): shared playback state and marker application.
- [PlayerSettings](../../iosApp/iosApp/Screens/Player/PlayerSettings.swift): settings and the current Vivid IntroDB client.
- [Silo server core](silo.md): the implemented server connection.
- [Emby server core](emby.md): current integration work and verification limits.

## Mobile implementation

The iPhone/iPad shell shares the private iCloud account vault, first-run preparation, Home metadata caching, TMDb trailers, Seerr and IntroDB with TV. The vault syncs saved accounts, sessions and optional Vivid PIN records; downloads, caches and preferences stay local. Search and Settings use full-screen portrait slide-up pages with round close buttons. Detail cards remain above Search during playback, and movie/series Media Information uses separate aligned video/file and audio panels on mobile and TV. See [mobile design and validation](../app-design.md#iphone-and-ipad-layout); shared code is not a claim of device or format parity.

[Documentation](../README.md)
