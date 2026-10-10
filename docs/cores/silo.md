<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Silo server core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../server-connections.md">Server connections</a></p>

---

The Silo server core connects Vivid to a Silo server. It supplies server data and playback sources to the [Vivid core](vivid.md); it does not own a separate player or duplicate Vivid’s controls.

Silo is one of the implemented server connections, alongside Emby and Jellyfin. “Core” describes its responsibility in the app; the existing source still contains Silo-specific models and calls in shared code, so this documentation does not claim the separation is already complete.

## Server ownership

The Silo server core handles Silo discovery/setup, manual/QR login, account and viewing-profile identity, authenticated requests, library metadata, playable versions and track metadata, playback-session negotiation, renewal and Silo-specific realtime events. It translates playback progress and watched state into Silo requests; the server persists those records.

Silo Protocol V3 is a Silo contract. Vivid’s capped quality modes translate into its existing resolution and bandwidth-cap fields; local mode identifiers are not sent as server quality names. A buffering fallback uses the existing replan operation at the current position with the selected tracks. No production server deployment or configuration change is required for these client controls. Other server cores map their own APIs into Vivid’s inputs. Credentials, caches and session identities stay scoped to the selected server and account.

## Shared player boundary

Vivid owns the controls, focus, seeking, loading UI, resume/next-episode presentation and track-selection experience. The Silo core provides the source, metadata and server operations those features need. Player fixes belong to Vivid unless the defect is in Silo’s data or protocol translation.

Skip-marker selection belongs to Vivid. Selected-file intro/credits markers take priority; IntroDB fills missing ranges using series IMDb identity and episode numbering; TheIntroDB prefers TMDb identity and falls back to IMDb. The connection supplies those identifiers. Item-level markers from other editions and realtime marker updates do not override the selected file. See [marker timing](../playback/architecture.md#introdb-marker-timing). No Silo server configuration is changed by that client behaviour.

Vivid reads chapters and embedded subtitle tracks from the opened media. The optional OpenSubtitles plugin adds user-selected temporary SRT downloads through Vivid’s shared player. Silo's external subtitle files (text files the playback plan lists with `source: external` and a sidecar URL) appear as player rows and in the detail-page subtitle menus. Vivid fetches one only when it's chosen, with the account's bearer sent only to the API origin, and renders it locally; the choice is never sent to Silo, so it can't change the server's plan, and replacement loads of the same file re-apply it on the device. A detail choice applies only while the catalogue and the plan list the same external files, checked by count, language, format and name. Embedded text tracks still come from the media, not from Silo's extracted sidecars. Server appearance settings, live subtitle generation and skip markers do not supply the player’s subtitle or chapter inventory. Phone-assisted Apple TV setup and its Bonjour discovery are removed. Existing manual/QR account login and the TV remote-playback receiver remain distinct active paths.

## Current implementation

- [AuthService](../../iosApp/iosApp/Screens/Auth/AuthService.swift): Silo authentication and viewing-profile flows.
- [ServerRegistry](../../iosApp/iosApp/Networking/ServerRegistry.swift): registered server identity and selection.
- [HTTPClient](../../iosApp/iosApp/Networking/HTTPClient.swift) and [VividAPI](../../iosApp/iosApp/Networking/VividAPI.swift): current authenticated requests and typed API operations.
- [PlaybackSessionBridge](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift): Silo playback sessions and reporting.
- [Server connections](../server-connections.md): account storage, wire contracts, reporting and provider status.

The source names above are retained implementation identifiers. Defining the core in documentation does not rename or refactor these files.

The iPhone/iPad saved-account flow now uses the same Silo session-restoration path as TV. Saved Silo accounts and sessions can move through Vivid’s private iCloud vault, along with profile order, shared preferences and configured TMDb, Seerr, MDBList and OpenSubtitles credentials. Media-server passwords, playback/subtitle preferences, downloaded media and metadata caches stay out of it. Home metadata is cached locally per server/profile. Vivid resolves Silo v2’s signed, root-relative artwork URLs against the connected server in fresh responses and locally saved Home metadata. Apple TV refreshes Silo Home while it remains visible so signed artwork URLs can renew. Images that exhausted their retries are attempted again when the app returns to the foreground. Server artwork is displayed without Silo-configured poster-overlay pills. Vivid's interface settings (the `ui.*` and `nav.*` keys, such as the top menu, card size and captions, and library page state) stay in Vivid, the same as on Emby and Jellyfin: they're kept on the device and travel between your Vivid devices only through Vivid's private iCloud vault. Silo shares those keys between every client of a device family, so reading them would let a menu or card size saved in Silo's own apps change Vivid's tabs and cards. Vivid never reads or writes them on the server; subtitle, metadata and other profile preferences still follow the Silo profile. Emby and Jellyfin have their own adapters. These client features do not alter Silo’s production configuration. Apple TV Top Shelf retains its Silo Home request path, with shared saved-account privacy rules: only the current native user’s sole signed-in, unprotected account with a single viewing profile can show personalised rows, subject to the viewing-profile policy. Multiple saved accounts or viewing profiles show static Vivid artwork. Top Shelf resolves v2’s root-relative artwork URLs against the server too, because tvOS loads shelf images itself. See [server connections](../server-connections.md) for the four-account limit and native-user isolation.

[Documentation](../README.md)
