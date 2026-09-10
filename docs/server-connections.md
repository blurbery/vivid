<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Server Connections</h1>
<p align="center">How Vivid connects to your media.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid owns its interface, browsing behaviour and playback experience. Each media server supplies authentication, library data, playback sources and user state through its own API.

## Current support

<table width="100%">
  <thead>
    <tr><th align="left">Provider</th><th align="left" width="10000">Status</th></tr>
  </thead>
  <tbody>
    <tr><td>Silo</td><td>Implemented in the current client</td></tr>
    <tr><td>Emby</td><td>Available on iPhone, iPad and Apple TV; documented feature limits apply</td></tr>
    <tr><td>Jellyfin</td><td>Planned; no native connection implementation yet</td></tr>
  </tbody>
</table>

> [!NOTE]
> Silo and Emby are available; see the [Emby core](cores/emby.md) for implemented behaviour and verification gaps. Jellyfin remains planned. Keep each provider’s requests and credentials separate.

## Saved accounts on Apple TV, iPhone and iPad

A fresh installation first checks the user’s private iCloud account vault. When it contains a usable saved session, Vivid restores the matching server account; otherwise the app opens the provider selector with Vivid branding and three 16:9 provider cards. Silo opens native server/account setup. Emby opens the same form with native Emby authentication on mobile and Apple TV. Jellyfin remains Coming Soon.

The first-run marker belongs to the installation. Removing the app removes its sandbox, preferences, caches and downloads. Keychain can outlive an uninstall, so the next clean Vivid installation clears Vivid’s local Keychain audience before it restores anything from iCloud. An ordinary app update keeps the existing Keychain data. This cleanup is limited to Vivid’s storage identity.

Settings lists circular saved-account cards and Add Profile. Here, a **profile card is a saved server account**, identified by server and user; it is distinct from a Silo viewing profile within that account. Add Profile signs in another Silo or Emby account. A ring highlights the signed-in account on both mobile and Apple TV. Selecting an inactive saved account switches sessions, while selecting the active card opens its account settings.

<table width="100%">
  <thead><tr><th align="left">Action</th><th align="left" width="10000">Behaviour</th></tr></thead>
  <tbody>
    <tr><td>Cold launch with one account</td><td>Resume Home after startup unless the account is signed out or protected by an optional Vivid PIN.</td></tr>
    <tr><td>Cold launch with multiple accounts</td><td>Show the saved-account selector. Selecting a signed-in card reuses its stored session.</td></tr>
    <tr><td>Return after fifteen minutes in the background</td><td>Show the selector through the Vivid animation when multiple accounts exist, or require entry for a PIN-protected account. Shorter returns keep the current account.</td></tr>
    <tr><td>Manual Sign Out</td><td>Keep the card, clear its saved session, and return through the animation to selection. That signed-out state syncs through iCloud, so the account requires credentials on its next sign-in on other devices too.</td></tr>
    <tr><td>Delete Profile</td><td>Long-press a saved profile in Settings, choose Delete Profile from the native menu, then confirm. Remove that Vivid account connection across iCloud devices, signing out locally if it is active. Remove its saved server only when no other saved account uses it. The actual server, server user and media library are not deleted.</td></tr>
    <tr><td>Update Login</td><td>Validate the current server username/password and update the saved session for the same server user identity. It does not change the username or password on the server.</td></tr>
    <tr><td>First sign-in</td><td>Resolve the primary Silo viewing profile and enter it directly. There is no separate profile-choice step. An existing server PIN is still enforced.</td></tr>
  </tbody>
</table>

First sign-in uses the Vivid startup animation while Home is prepared, with “Getting ready”, “Almost done” and “Welcome to Vivid” shown for at least three seconds each. Normal cached startup does not repeat those setup messages. The saved-account selector uses a black background, a centred silver V and “Who’s watching?”.

Manage Servers and Add Profile share the registered server list. Selecting or adding a Silo connection through either flow keeps it available to the other. Silo and Emby can be added on mobile and Apple TV; Jellyfin remains planned. Setup and QR/manual sign-in use black backgrounds and the shared Vivid footer.

An account can have an optional four-digit Vivid PIN. Its salted digest is kept in Keychain, with a thirty-second delay after five incorrect attempts. PIN-protected cards remain locked if their PIN record cannot be read. This local account lock is separate from the server's viewing-profile PIN and must not bypass its verification proof.

Account metadata is stored locally and session tokens are kept in Keychain; the entered password is not retained. Restoring an account uses the HTTP identity-transition gate, cancels outgoing requests and clears active response/profile caches. Access and refresh tokens are captured together with the matching viewing-profile proof. A server can still revoke or expire a session, in which case fresh authentication may be necessary.

Long-press a saved profile to enter wobble editing. On Apple TV, left/right moves the selected profile; press centre to save, or press down to highlight its round glass X and centre to request deletion. On iPhone and iPad, hold and drag to reorder, then tap the glass Done pill above the row to save. Round glass X buttons request deletion confirmation. Reordering stays local to the editor until saved. Visible profile selector and Settings cards refresh iCloud every ten seconds while active and editing is closed. Wobble honours Reduce Motion. These controls manage saved Vivid connections, not accounts on the media server.

## Private iCloud account sync

When iCloud is available, Vivid stores saved server accounts, login sessions and optional Vivid PIN records in one encrypted-values record in the user’s private CloudKit database. The same vault is used on iPhone, iPad and Apple TV. Sync runs during startup, when the app becomes active, and after account authentication, sign-out, PIN, profile-order or deletion changes. If iCloud is unavailable, the local account continues to work and Vivid tries again later.

Deleting a saved account on mobile or Apple TV writes a dated tombstone, whether the account is currently signed in or signed out. Every device applies that tombstone before uploading its local accounts, which prevents a stale iPhone, iPad or Apple TV from adding the deleted account back. The saved server remains when another saved account still references it. Deletion reaches another device at its next successful iCloud sync; an offline device may retain the card until then. Only entering credentials again after the deletion can deliberately restore that same server/user identity. Removing the app does not delete the private CloudKit vault or accounts from the user’s other devices; it removes data held by that installation.

This sync is limited to connection and login memory. Downloads, metadata and artwork caches, Home and player preferences, TMDb/Seerr settings and local playback data do not move through this account vault. Watched and resume state continues to sync through the selected media server’s own API. Detail-page watched/unwatched changes refresh the local Home immediately after a successful write. A visible, foreground Home also reloads every ten seconds to reconcile posters, Continue Watching and next-episode state changed on another device; hidden or inactive Home pages do not keep polling.

The implementation lives in <a href="../iosApp/iosApp/tvOS/Profiles/TVSavedAccountStore.swift">TVSavedAccountStore</a> and <a href="../iosApp/iosApp/tvOS/Profiles/TVSavedAccountViews.swift">TVSavedAccountViews</a>. On mobile, the account cards and editor are in `IOSSettingsOverview.swift`, using the same store. Servers remains a separate Settings category for registered connections. Mobile Sign Out is in the account editor, not Servers. Saved Emby sessions additionally preserve the native user ID; the Emby adapter implements its API translation. Saved-account storage alone does not establish provider compatibility.

## Optional Seerr requests on Apple TV, iPhone and iPad

Settings → Seerr appears below Servers with Seerr’s official icon rendered as a monochrome vector. Enter a URL, username and password. Local Seerr accounts use their email address; imported Jellyfin/Emby accounts use their username. Plex-only sign-in is not supported by this form.

Vivid validates the login before enabling Search’s “Available to request” section. The connection is scoped to the saved server account and viewing profile, with credentials in the current-user Keychain and an isolated ephemeral cookie session. Disconnect removes the saved connection. Redirects are rejected; configure the final URL, including any reverse-proxy base path. A saved password can only be reused when both URL and username are unchanged.

Search and request details use Seerr’s `/api/v1` endpoints. Movie requests use the default non-4K destination; series requests ask for all seasons. Permissions, quotas and destination configuration remain enforced by Seerr. Without a configured connection, request results are hidden. The mobile app uses this same account-scoped Seerr connection.

Run `scripts/ci/check-seerr-client.sh` for offline authentication, URL validation, response mapping, session renewal and request-body checks. A live configured Seerr instance is still needed to verify its deployment-specific login and download automation.

The settings icon uses the main silhouette from [Seerr’s official SVG](https://github.com/seerr-team/seerr/blob/develop/public/os_icon.svg), with colour highlights removed for template rendering.

## Existing connection code

These shared files retain Silo behaviour and dispatch to Emby when its provider identity is active. Emby-specific ownership is listed in the [Emby core](cores/emby.md).

<table width="100%">
  <thead>
    <tr><th align="left">Owner</th><th align="left" width="10000">Responsibility</th></tr>
  </thead>
  <tbody>
    <tr><td><a href="../iosApp/iosApp/Networking/ServerRegistry.swift">ServerRegistry</a></td><td>Remembered servers, active server and transitions</td></tr>
    <tr><td><a href="../iosApp/iosApp/Networking/ServerIdentityResolver.swift">ServerIdentityResolver</a></td><td>Read the server&#x27;s advertised display name</td></tr>
    <tr><td><a href="../iosApp/iosApp/Screens/Auth/AuthService.swift">AuthService</a></td><td>Setup checks, login, session installation and profiles</td></tr>
    <tr><td><a href="../iosApp/iosApp/Networking/HTTPClient.swift">HTTPClient</a></td><td>Requests and request-identity boundaries</td></tr>
    <tr><td><a href="../iosApp/iosApp/Networking/VividAPI.swift">VividAPI</a></td><td>Typed library and app-facing API calls</td></tr>
    <tr><td><a href="../iosApp/iosApp/Networking/ResponseCache.swift">ResponseCache</a></td><td>Cached responses</td></tr>
    <tr><td><a href="../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift">PlaybackSessionBridge</a></td><td>Server playback sessions</td></tr>
  </tbody>
</table>

The Silo adapter currently probes `/api/v1/auth/setup`, signs in through `/api/v1/auth/login`, and resolves the server name through `/api/v1/theme/branding` with a legacy health fallback. Keep these wire paths intact while changing Vivid's branding.

The server's display name labels that connection. It must not replace Vivid's app identity. Manual and QR sign-in and profile flows are provider-specific unless verified otherwise.

## Playback reporting

VividKit supplies playback state and engine observations. Vivid owns reporting that state to the selected server; upgrading the engine does not replace the app’s session bridge.

For Silo, `PlayerViewModel` runs a periodic progress report every ten seconds. `PlaybackSessionBridge` posts position and pause state to `/api/v1/playback/{session_id}/progress`, sends Protocol V3 route events, and flushes final progress before stopping the session. The Silo server owns playback persistence and watch history; its backend handlers do not belong in the Apple app. Vivid has no in-app diagnostics-report capture or upload.

The progress request fields match `blurbery/silo-server` at `d91fd15194d126cf67c85db1e908ddb163fee62d`. This is a source-contract check, not an end-to-end device test of that server revision. Preserve the existing client reporting when changing branding, and keep Emby reporting separate when extending either provider or adding Jellyfin.

Emby uses native PlaybackInfo negotiation and Sessions/Playing reporting, with tick conversion and authenticated VividKit inputs. Its local settings, subtitle wiring, download limits and device-check status are documented in the [Emby core](cores/emby.md). This does not change the Silo reporting contract.

## Adding a provider

The Emby adapter applies the following boundaries; they also govern future providers:

- Identify the provider before selecting its login and API flow.
- Keep provider, server and user identity attached to tokens, requests, caches and playback sessions.
- Translate provider metadata, images, resume positions and playback sources into Vivid's UI and player inputs.
- Represent capabilities explicitly. A provider without a feature should not receive unsupported requests or expose a misleading control.
- Cancel and invalidate obsolete work when the provider, server or user changes. A late response must not overwrite the new selection.
- Handle each provider's realtime events and progress reporting separately. Do not assume the same endpoints, credentials, profiles or event schema.
- Preserve the existing Silo connection while developing and testing another provider.

Before advertising support, verify login/logout, library browsing, artwork, resume/progress, subtitles, playback, server switching and relevant failure cases against that provider. Keep the same physical-device browsing checks for every provider.
