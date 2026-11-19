<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Silo server core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../server-connections.md">Server connections</a></p>

---

The Silo server core connects Vivid to a Silo server.
It supplies server data and playback sources to the [Vivid core](vivid.md); it does not own a separate player or duplicate Vivid’s controls.

Silo is one of the implemented server connections, alongside Emby and Jellyfin.
“Core” describes its responsibility in the app; the existing source still contains Silo-specific models and calls in shared code, so this documentation does not claim the separation is already complete.

## Server ownership

The Silo server core handles Silo discovery/setup, username/password login, account and viewing-profile identity, authenticated requests, library metadata, playable versions and track metadata, playback-session negotiation, renewal and Silo-specific realtime events.
It translates playback progress and watched state into Silo requests; the server persists those records.
A realtime payload field read as a whole number is skipped when it isn't a finite number within the integer range, so a malformed payload can't crash the player.
A command whose `deadline_ms` isn't a whole number in range fails to decode and is ignored.

A Silo account with several viewing profiles can give each household member their own saved card, bound to that viewing profile.
Once Vivid has loaded a card's viewing profile, every Silo card, the primary profile's included, is labelled with that profile's name in Silo rather than the sign-in username.
Household → Search for Accounts adds the other profiles through Silo's device sign-in, approved by the signed-in session, so no password is needed.
See [Silo household profiles](../server-connections.md#silo-household-profiles).

Silo Protocol V3 is a Silo contract.
Vivid’s capped quality modes translate into its existing resolution and bandwidth-cap fields; local mode identifiers are not sent as server quality names.
A buffering fallback uses the existing replan operation at the current position with the selected tracks.
No production server deployment or configuration change is required for these client controls.
Other server cores map their own APIs into Vivid’s inputs.
Credentials, caches and session identities stay scoped to the selected server and account.

## Shared player boundary

Vivid owns the controls, focus, seeking, loading UI, resume/next-episode presentation and track-selection experience.
The Silo core provides the source, metadata and server operations those features need.
Player fixes belong to Vivid unless the defect is in Silo’s data or protocol translation.

Skip-marker selection belongs to Vivid.
Silo supplies the selected file's intro, credits and recap markers.
While the Intro & Credit Skipper is on, an episode's TheIntroDB markers take priority, preferring TMDb identity and falling back to IMDb; IntroDB fills any kind TheIntroDB lacks using series IMDb identity and episode numbering, and the selected-file markers fill only what neither has.
While it is off, only the selected-file markers are used.
The connection supplies those identifiers.
Item-level markers from other editions and realtime marker updates do not override the selected file.
See [marker timing](../playback/architecture.md#introdb-marker-timing).
No Silo server configuration is changed by that client behaviour.

Vivid reads chapters and embedded subtitle tracks from the opened media.
The optional OpenSubtitles plugin adds user-selected temporary SRT downloads through Vivid’s shared player.
Silo's external subtitle files (text files the playback plan lists with `source: external` and a sidecar URL) appear as player rows and in the detail-page subtitle menus.
Vivid fetches one only when it's chosen, with the account's bearer sent only to the API origin, and renders it locally; the choice is never sent to Silo, so it can't change the server's plan, and replacement loads of the same file re-apply it on the device.
A detail choice applies only while the catalogue and the plan list the same external files, checked by count, language, format and name.
Subtitles Silo stores for a file (downloaded from a provider, uploaded, or made by its AI, which the plan lists with `source: downloaded` after the file's own tracks) work the same way when they're text (SRT, WebVTT, ASS or SSA): player rows fetched only when chosen, never sent to Silo, and re-applied after replacement loads.
Silo pins each one's URL to its stored row with `downloaded_subtitle_id`, so Vivid finds a stored subtitle by that ID rather than by its index, which moves when an earlier one is removed.
The catalogue doesn't list them, so detail pages read them from `GET /api/v1/subtitles/{file}` (v2 `listStoredSubtitles`) and add them to the subtitle menu and the Auto preview after the file's own tracks, with the plan's label (release name and provider); a detail choice of one is applied only when the plan lists that stored ID.
When Silo finishes making a subtitle during playback, its `subtitle_ready` event adds the row straight away.
Stored bitmap files have no sidecar and aren't offered, and Vivid doesn't start translations.
Embedded text tracks still come from the media, not from Silo's extracted sidecars.
Server appearance settings, live subtitle translation and skip markers do not supply the player’s subtitle or chapter inventory.
Phone-assisted Apple TV setup and its Bonjour discovery are removed, and so is the QR sign-in screen: every platform uses the username/password form.
Manual account login and the TV remote-playback receiver remain distinct active paths.

On iPhone and iPad, AirPlay to a video receiver is offered only on native v2 Silo servers, and starts a separate v2 playback attempt for the receiver (see [AirPlay video](../playback/architecture.md#airplay-video)).
Its capabilities leave out `header_authenticated_media_v1` and `authorized_media_origins_v1` and offer only what the receiver plays: HLS with H.264 (up to 1080p) or HEVC (up to 2160p) video and AAC, AC-3 or E-AC-3 audio, or an original MP4, MOV or M4V file.
Dolby Vision and HDR10+ are transcoded to H.264 at up to 1080p, while HDR10 and HLG HEVC can be copied.
Silo then returns relative stream URLs carrying its signed stream reference (`st`), which Vivid resolves against the API base and hands to the receiver.
The reference isn't the account token: it only works for that playback session while the sign-in is active, for at most 24 hours, and stops working when the session stops.
Vivid never logs or stores these URLs, and keeps the receiver's plan with `st` removed.
Receiver subtitles are burned in only; external and stored subtitle files and OpenSubtitles downloads don't reach the receiver.
Silo replans aren't used during a hand-off, and a replan after an AirPlay route change waits until Vivid knows whether the receiver takes video.
blurbery checked the receiver attempt against a native v2 Silo server with an Apple TV 4K.

## Current implementation

Vivid's own sign-in, profile and error text follows Vivid's language; titles and other metadata come from Silo in the profile's metadata language (`catalog.metadata_language`).
See [Localisation](../localisation.md).

- [AuthService](../../iosApp/iosApp/Screens/Auth/AuthService.swift): Silo authentication and viewing-profile flows.
- [SiloProfileChoiceView](../../iosApp/iosApp/tvOS/Profiles/SiloProfileChoiceView.swift) and [SiloHouseholdSearch](../../iosApp/iosApp/tvOS/Profiles/SiloHouseholdSearch.swift): choosing a household member's viewing profile and Search for Accounts.
- [ServerRegistry](../../iosApp/iosApp/Networking/ServerRegistry.swift): registered server identity and selection.
- [HTTPClient](../../iosApp/iosApp/Networking/HTTPClient.swift) and [VividAPI](../../iosApp/iosApp/Networking/VividAPI.swift): current authenticated requests and typed API operations.
- [PlaybackSessionBridge](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift): Silo playback sessions and reporting, with the Protocol V3 capability check in [PlaybackV3CapabilityGate](../../iosApp/iosApp/Screens/Player/PlaybackV3CapabilityGate.swift).
- [Server connections](../server-connections.md): account storage, wire contracts, reporting and provider status.

Silo's Home rows send an episode's still as its backdrop.
On Home, Continue Watching and Next Up episode cards show the series background instead, so [HomeSeriesBackdrops](../../iosApp/iosApp/Components/HomeSeriesBackdrops.swift) asks Silo for each series' details once (one `/catalog/items/{series}` request per series in those rows, four at a time, started while Home is prepared) and keeps the background in Caches for the server and profile until an hour before its signed link expires, or a week for an unsigned one.
While a row is showing, a series' background is renewed 90 minutes before its link expires, a lookup that fails is tried again after ten minutes, and a series with no background is asked for again after an hour.
The Home spotlight uses the same background, and looks up the series of its own episode slides when it appears, so an episode from another row is looked up then.
Until a series is looked up its card and spotlight slide show the episode still.
On iPhone and iPad the slide switches when the lookup lands; on Apple TV a spotlight card keeps the artwork it was built with, so the series background shows the next time that card is built.
Movies already carry their own background.
A Silo server that sends `series_backdrop_url` with these items would be used directly, resolved against the server like the other artwork fields.

Theme music on detail pages needs a v2 Silo server; on a v1 server pages stay silent.
[SiloThemeMusic](../../iosApp/iosApp/Networking/SiloThemeMusic.swift) reads `themes` from the page's own v2 item detail, where Silo has already applied inheritance (season, then series), and picks the first song.
It plays only when the theme capabilities say `available` and don't refuse the profile, an answer kept for five minutes per account and profile.
The audio grant is asked for only when the song is about to play, listing the formats AVFoundation opens (Ogg and Opus are left out, so Silo converts those to AAC).
A converted stream has no length, which `AVPlayer` won't stream, so it's downloaded to a temporary file first, stopping as soon as it passes 32 MB, and the grant and download share one 20 second limit; an original plays straight from its short-lived URL, which is never logged or stored.
These optional requests never refresh the session, so a refusal, even a 401, only leaves the page silent.
Silo ignores symlinked theme files and symlinked `theme-music` folders, so themes must be regular files.

Scrub previews in the player also need a v2 Silo server, with seek previews turned on for the library.
Unless a file's version says `trickplay_available` is `false`, [SiloScrubPreviews](../../iosApp/iosApp/Screens/Player/ScrubPreviewSheets.swift) reads `GET /api/v2/watch/{id}/trickplay` for it once the load has opened; a 404 means no previews.
The sheet URLs carry their own authorisation and may be on the server's storage origin, so they are fetched with no account, profile or device headers.
The request never refreshes the session, and the URLs are asked for again when they are about to expire.
This has not been verified against a live Silo server.

The source names above are retained implementation identifiers.
Defining the core in documentation does not rename or refactor these files.

The iPhone/iPad saved-account flow now uses the same Silo session-restoration path as TV.
Saved Silo accounts and sessions can move through Vivid’s private iCloud vault, along with profile order, shared preferences and configured Seerr, MDBList and OpenSubtitles credentials.
Media-server passwords, playback/subtitle preferences, downloaded media and metadata caches stay out of it.
Home metadata is cached locally per server/profile.
Vivid resolves Silo v2’s signed, root-relative artwork URLs against the connected server in fresh responses and locally saved Home metadata.
Apple TV refreshes Silo Home while it remains visible so signed artwork URLs can renew.
Images that exhausted their retries are attempted again when the app returns to the foreground.
Server artwork is displayed without Silo-configured poster-overlay pills.
Vivid's interface settings (the `ui.*` and `nav.*` keys, such as the top menu, card size and captions, and library page state) stay in Vivid, the same as on Emby and Jellyfin: they're kept on the device and travel between your Vivid devices only through Vivid's private iCloud vault.
Silo shares those keys between every client of a device family, so reading them would let a menu or card size saved in Silo's own apps change Vivid's tabs and cards.
Vivid never reads or writes them on the server.
Home shows Silo's rows, but Vivid saves the order rows are first shown in, so reordering Home on the Silo server doesn't move them; new rows join the end.
Metadata language stays a Silo profile setting, because Silo translates overviews on the server.
Vivid doesn't offer Silo's on-view description translation or ask the server whether it's enabled, so a description shows in the language the server returns.
Emby and Jellyfin have their own adapters.
These client features do not alter Silo’s production configuration.
Apple TV Top Shelf retains its Silo Home request path, with shared saved-account privacy rules: it shows personalised rows for the current native user’s active saved profile and viewing profile, however many of either exist, when the saved profile is signed in, neither has a PIN, Vivid still remembers the viewing profile, the profile launch behaviour doesn't ask on every launch, its time-away lock hasn't expired and no profile choice is pending (the full rule is in [server connections](../server-connections.md)).
Anything else shows static Vivid artwork.
When Silo answers 401, the extension asks it for a fresh access token once, shares it with every request in that run and keeps it in memory only, leaving the app’s stored session untouched.
Top Shelf resolves v2’s root-relative artwork URLs against the server too, because tvOS loads shelf images itself.
See [server connections](../server-connections.md) for the eight-account limit and native-user isolation.

[Documentation](../README.md)
