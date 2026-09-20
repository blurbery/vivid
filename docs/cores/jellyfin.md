<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Jellyfin server core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../server-connections.md">Server connections</a></p>

---

Jellyfin has its own server core. Its provider card opens Vivid's existing server and username/password forms on iPhone, iPad and Apple TV. The connection supplies metadata and playable sources to Vivid's shared player; it does not use Silo Protocol V3 or the Emby adapter.

## Ownership and authentication

`JellyfinProvider.swift` owns Jellyfin discovery, authenticated transport and catalogue mapping. `JellyfinPlayback.swift` owns playback negotiation and reporting. `JellyfinDownloads.swift` and `JellyfinLocalPreferences.swift` keep download records and client preferences separate from other providers. Shared Vivid code selects the provider and presents its results. Silo and Emby wire implementations remain unchanged.

Server identities use a `jellyfin:` prefix. Native user IDs and access tokens remain scoped to that server account in Keychain. Requests capture their account identity and reject results after a session switch. Authentication uses Jellyfin's MediaBrowser authorisation header. Credentials are not placed in generated image, subtitle or media URLs, and API redirects are rejected. Custom server base paths are preserved without adding `/emby` or `/jellyfin`.

## API mapping

The core follows the [official Jellyfin API specification](https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json).

| Vivid operation | Jellyfin endpoint |
|---|---|
| Server discovery | `GET /System/Info/Public` |
| Login / logout | `POST /Users/AuthenticateByName`, `POST /Sessions/Logout` |
| Libraries | `GET /UserViews` |
| Browse, search, favourites and history lists | `GET /Items` with native filters |
| Item details | `GET /Items/{id}` |
| Home rows | `GET /UserItems/Resume`, `/Shows/NextUp`, `/Items/Latest` |
| Seasons / episodes | `GET /Shows/{id}/Seasons`, `/Shows/{id}/Episodes` |
| Filters / similar titles | `GET /Items/Filters`, `/Items/{id}/Similar` |
| Artwork | `GET /Items/{id}/Images/{type}` |
| Playback negotiation | `POST /Items/{id}/PlaybackInfo` |
| Original stream | `GET /Videos/{id}/stream` |
| Session reporting | `POST /Sessions/Playing`, `/Sessions/Playing/Ping`, `/Sessions/Playing/Progress`, `/Sessions/Playing/Stopped` |
| Watched / favourite changes | `POST` or `DELETE /UserPlayedItems/{id}`, `/UserFavoriteItems/{id}` |
| Offline progress | `POST /UserItems/{id}/UserData` |

Jellyfin 12 moved several user-scoped routes. An HTTP 404 on a mapped route retries its corresponding older Jellyfin route under `/Users/{userId}` once. This also includes missing-item 404 responses; the client does not distinguish a missing route from a missing resource. Authentication failures do not trigger fallback, and no fallback selects another provider. Older Jellyfin server versions still need live verification.

## Playback and limits

Jellyfin maps source IDs, media streams, chapters and tick-based progress into Vivid's models. PlaybackInfo supplies direct-play or transcoded sources. Vivid retains its shared controls, engine, subtitle inventory and next-episode behaviour. A short, unqualified preview is retired with Jellyfin's `Failed` stop flag so it does not reset resume progress or mark a title watched. Qualified playback reports start, progress and stop normally. Overlapping playback starts use an attempt identity so an older Jellyfin response cannot replace a newer session. Progress reporting and retirement are serialised during Jellyfin replacement. Validation failure before retirement preserves the previous session; cancellation after retirement leaves no stopped session referenced by the bridge. PlaybackInfo uses `AutoOpenLiveStream=false`, so cancelled or superseded negotiations are discarded locally without sending a stop that could clear current server playback.

Library browsing requests card metadata without cast, media sources, streams or chapters; detail and playback requests retain the full fields. Native library-ID mappings are reused for five minutes, partitioned by server, Jellyfin user and login epoch. Watched state, favourites and pagination remain in browse responses. A bounded check of two 60-title movie pages reduced response size by about 91% and measured 3.4–4.4 seconds instead of about 7 seconds; these are individual server/network observations, not an on-device performance guarantee.

Season metadata retains Jellyfin watched and unplayed counts. Episode detail mapping retains watched flags and tick-based resume positions. Continue Watching carries the tapped episode ID through the iOS and tvOS season loader. When Jellyfin groups multiple versions under a different representative ID, the core fetches the requested episode alongside the season list and substitutes its exact ID, progress and media sources into that episode row. Earlier unwatched episodes do not override an explicit resume selection; Next Up retains the server’s ordering. On iPhone, initial episode-rail positioning does not replace Jellyfin’s requested resume episode; a user scroll can change the selected episode.

Jellyfin series discovery cards use portrait posters on iOS and tvOS, including newly added episodes or seasons. Series posters request the main series artwork rather than episode or season artwork. Continue Watching and Next Up retain the same card sizing and layout as Emby and Silo, using the episode preview image for episode cards. Episode stills remain separate for the episode lists inside detail pages.

Home supports a Jellyfin-specific option to combine Continue Watching and Next Up. The shared Apple TV six-row cap applies after combining rows. Spotlight presents the combined Continue Watching choice too, interleaving resume and Next Up items within its ten-slide limit. iPhone, iPad and Apple TV support four saved server-account cards. Person IDs map to Vivid navigation IDs within the Jellyfin account, including crew. More Like This uses Jellyfin’s similar-items endpoint on iOS and tvOS.

Original-file downloads respect the account's download permission. Converted downloads, Emby Sync jobs, automatic series downloads and server administration are not implemented. Watchlists, row dismissals and client preferences are local and account-scoped. Row dismissal does not change Jellyfin watched state. Collection browsing is supported; collection editing and Jellyfin realtime events are not implemented. Jellyfin users are server accounts, not Silo household viewing profiles.

## Apple TV Top Shelf

Top Shelf loads Continue Watching and Next Up directly from this provider’s native endpoints, independently of the in-app combined-row setting. It preserves the exact episode ID and resume progress, uses the main series poster for episodes, and keeps the existing detail and direct-play actions. Credentials come from the selected native Apple TV user’s saved account; the account, native user and credential epoch are checked again before returning the response. Silo retains its existing Top Shelf request path. Personalised content requires a single signed-in, unprotected saved account and the existing viewing-profile policy. Multiple accounts show static Vivid artwork; account changes request a system refresh.

Focused native Top Shelf request/mapping checks and the tvOS extension build passed. A read-only Jellyfin check returned both rows and a credential-free series poster URL returned HTTP 200. Live Emby Top Shelf responses and presentation on the Apple TV Home Screen still need device verification. These changes have not been uploaded.

## Verification

Jellyfin 12.1.0 live checks passed for authentication, library views, full catalogue fields, resume and next-up rows, latest items, filters, movie details, similar titles, seasons, episodes and PlaybackInfo negotiation. A direct-play stream returned an authenticated HTTP 206 response for a bounded 4 KiB read. These checks did not submit watched-progress changes.

- Fifteen focused Jellyfin XCTest cases and six extracted Home/Spotlight tests passed using the production provider sources and wire models in a temporary macOS harness. Host services were stubbed.
- Fifty-four deterministic lifecycle checks execute the complete production start, stop and progress methods with instrumented server/settings boundaries. They cover overlapping starts, cancellation, pending-start invalidation, progress ordering, validation failure and completion after a failed stop. Removing either production start/stop invalidation caused a runtime test failure. These checks do not exercise the media engine or real network timing.
- The [full iOS simulator test suite and tvOS simulator build](https://github.com/blurbery/vivid/actions/runs/35497384531) passed for application revision `04910755d2f6c0f22ff2b8976ba6b7eb58b074fe`, including the final review fixes. Focused playback end/recovery, early-display, auth-refresh and native-profile checks also passed.
- The signed iPhone Debug build was installed in place on iPhone 16 Pro Max, with app/extension versions, signing, provisioning and the patched media-library marker verified. After testing the integration and follow-up UI/browsing fixes, blurbery accepted it for review. The later concurrency review fixes passed automated checks but have not been installed on that phone.
- iOS/iPadOS and tvOS 0.14.3 (33) were distributed through TestFlight. Subsequent device feedback identified a multi-version Continue Watching mismatch on both platforms. The follow-up exact-episode fix passed 20 provider tests and 17 extracted request-routing assertions; a read-only live check resolved the affected episode’s exact ID, progress and audio/subtitle metadata. These checks do not establish on-device UI performance, and the follow-up fix has not been uploaded.
- Full on-device settings coverage, saved-account switching, native Apple TV user switching, live tvOS playback and older Jellyfin server versions still need verification.


For an iOS Debug test launch, `VIVID_SHOW_SERVER_SETUP=1` opens the provider chooser before account restoration. This launch-only switch does not sign out saved accounts or reset Keychain/iCloud data. Ordinary launches retain their existing behaviour.
