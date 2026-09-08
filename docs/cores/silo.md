<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Silo server core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../server-connections.md">Server connections</a></p>

---

The Silo server core connects Vivid to a Silo server. It supplies server data and playback sources to the [Vivid core](vivid.md); it does not own a separate player or duplicate Vivid’s controls.

Silo is one of the implemented server connections, alongside Emby. “Core” describes its responsibility in the app; the existing source still contains Silo-specific models and calls in shared code, so this documentation does not claim the separation is already complete.

## Server ownership

The Silo server core handles Silo discovery/setup, manual/QR login, account and viewing-profile identity, authenticated requests, library metadata, playable versions and track metadata, playback-session negotiation, renewal and Silo-specific realtime events. It translates playback progress and watched state into Silo requests; the server persists those records.

Silo Protocol V3 is a Silo contract. Other server cores should map their own APIs into Vivid’s player inputs, without having to implement Silo’s protocol. Credentials, caches and session identities must stay scoped to the selected server and account.

## Shared player boundary

Vivid owns the controls, focus, seeking, loading UI, resume/next-episode presentation and track-selection experience. The Silo core provides the source, metadata and server operations those features need. Player fixes belong to Vivid unless the defect is in Silo’s data or protocol translation.

IntroDB marker lookup belongs to Vivid. The Silo connection supplies series IMDb identity and episode numbering, but its intro/credits fields and realtime marker updates no longer control Vivid’s skip ranges. No Silo server configuration is changed by that client behaviour.

Vivid reads chapters and embedded subtitle tracks from the opened media. Silo subtitle sidecars, server appearance settings, live subtitle generation and server skip markers do not supply the player’s subtitle or chapter inventory. Phone-assisted Apple TV setup and its Bonjour discovery are removed. Existing manual/QR account login and the TV remote-playback receiver remain distinct active paths.

## Current implementation

- [AuthService](../../iosApp/iosApp/Screens/Auth/AuthService.swift): Silo authentication and viewing-profile flows.
- [ServerRegistry](../../iosApp/iosApp/Networking/ServerRegistry.swift): registered server identity and selection.
- [HTTPClient](../../iosApp/iosApp/Networking/HTTPClient.swift) and [VividAPI](../../iosApp/iosApp/Networking/VividAPI.swift): current authenticated requests and typed API operations.
- [PlaybackSessionBridge](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift): Silo playback sessions and reporting.
- [Server connections](../server-connections.md): account storage, wire contracts, reporting and provider status.

The source names above are retained implementation identifiers. Defining the core in documentation does not rename or refactor these files.

The iPhone/iPad saved-account flow now uses the same Silo session-restoration path as TV. Saved Silo accounts and sessions can move through Vivid’s private iCloud vault, while the server password, downloads, preferences and metadata caches stay out of it. Home metadata is cached locally per server/profile. Server artwork is displayed without Silo-configured poster-overlay pills. Emby has its own adapter; Jellyfin remains planned. These client features do not alter Silo’s production configuration.

[Documentation](../README.md)
