<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Apple TV Browsing</h1>
<p align="center">Responsive navigation, artwork and series rails.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid's Apple TV Home uses a discovery spotlight above ordinary media rows on a black background. Movies, Series and For You each keep their own page and sub-tab selection.

## Home and discovery spotlight

- The spotlight contains at most ten unique items, drawn in turn from up to three selected Home rows. New selections start with the first three populated rows. Configure these separately from row visibility in Settings → General → Home Screen.
- Slides advance every six seconds with a crossfade and a timed capsule indicator. Indicators expand and contract over 0.45 seconds; returning to Home restarts the timer. Spotlight focus uses a thin outline without enlarging the artwork.
- The artwork keeps a fixed spotlight size. Face and person detection guide cropping; detection is best effort and cannot guarantee perfect framing for every image. A dark fade protects the title logo, with a subdued colour fade around the edges. The internal fade uses eased stops and a subtle static dither to reduce banding; source artwork and display processing can still affect the result. Movie runtime is omitted from spotlight metadata.
- Continue Watching uses 16:9 thumbnails. Other rows retain their existing card shapes. Its heading aligns with the other row headings and has no play icon. Continue Watching and Emby Next Up show `S01 E03 – Episode title` beneath the main title. Partly watched thumbnails use an inset white progress bar on a grey track.
- Clicking Up from the spotlight returns to the tab bar; there is no separate upward-swipe override. Moving down from the spotlight enters the first Continue Watching card initially, then returns to the last card visited in that row. Returning from a detail page restores the launching card unless the user has moved elsewhere.
- Settings → General places Home Sections below Home Screen. Home Sections controls row visibility and ordering. Poster Configuration changes Home only, saves locally per server/viewing profile, and defaults to Large posters with Title Only captions. It does not change catalog or detail-page cards.

## Device metadata cache

Settings → Metadata lists Spotlight and the enabled Home rows, including Continue Watching. Each entry has a separate clear-cache button. Only enabled Home rows are retained, capped at twenty items per row; the spotlight is capped at ten. Disabling a row or receiving refreshed content removes obsolete entries and artwork references.

`TVHomeMetadataCache` stores versioned snapshots in the Apple TV cache directory, isolated by server and viewing profile. Cached rows, libraries and spotlight details hydrate the existing response cache before network refresh. Artwork uses the local `VividImagePipeline` cache with bounded prefetching. These are disposable caches: tvOS may reclaim them, and clearing them does not remove server media or watched history.

Visible, foreground Home refreshes every ten seconds and reconciles snapshots when data or preferences change. Closing playback sends final progress before the rest of the session teardown and triggers a refresh as soon as that write completes. Marking an item watched also refreshes without waiting for the loop. Continue Watching moves to the next episode or drops completed items once the server response reflects the change. Overlapping refreshes are coalesced, and older responses cannot replace newer watched/resume state. New content replaces stale cache contents after a successful refresh; there is no claim of an immediate server-push invalidation. Cached startup is intended to reduce waiting, but no before/after device benchmark is recorded for this revision.

## Tabs and catalog pages

The slim glass tab bar contains Search, Home, Movies, Series, For You and the profile/settings avatar as available. Dividers separate Search and Profile. Focusing a tab gives that individual control a lift. The avatar opens Settings directly. Root pages have no separate Vivid logo in the top-left corner.

Movies and Series use library sub-tabs above Sort and Filter, without the old category dropdowns or mixed Recommended/Browse landing page. Redundant leading words such as “Movies” or “TV Shows” are shortened in sub-tab labels; colliding labels retain the original library names. Each page keeps its own selection and filter scope. Movie and series queries filter content by type, including mixed libraries such as Sports; classification depends on the server's metadata.

Sort, Filter and A–Z use native tvOS menus. Filters become available after their facets load, avoiding a partial menu that changes while open. The menu owns focus while presented and restores it to its trigger on dismissal.

For You has Watchlist, Favourites and Collections sub-tabs, with no Sort or Filter controls. Each sub-tab has an independent native A–Z menu; choosing All restores the unfiltered list. Collections combines movie and series collections. It paints cached per-library sections immediately, refreshes source libraries together and publishes each response as it arrives instead of waiting for the slowest library. Catalog grids use seven posters across, with deliberate space above the first row for focus enlargement.

Library requests load seventy items at a time. Artwork retention uses a moving ten-row window, keeping a small look-behind and releasing earlier decoded image references as focus advances. Visible cards may retain their displayed image, and lightweight item metadata remains available for navigation; this is not a fixed total app-memory limit. Entering a newly loaded page must restart artwork requests without changing native card focus targets.

Calendar's client screens, models, requests and navigation entries have been removed. Decoding older saved menus drops the retired Calendar entry while preserving supported destinations. This does not modify any media-server backend.

## Startup and Settings

Cold startup shows Vivid's star-to-ribbon animation on black, with Reduce Motion and a static-logo fallback. The animation completes when the V forms; routing resolves local and private-iCloud account state, but does not wait for a full network population of Home. A usable restored session can open Home, while no usable session returns to server selection instead of an old provider login. Cached Home content can then appear while refresh continues. Saved-account selection, iCloud deletion and PIN rules are described in [Server Connections](server-connections.md#saved-accounts-on-apple-tv-iphone-and-ipad).

Settings categories open separate native navigation pages with white headings and no repeated eyebrow. Section text and secondary actions use grey. About is a main Settings category directly below Metadata; it contains app version/build, privacy, licences, Contact and TMDb attribution. The Contact page shows an email QR code. Playback uses the same IntroDB toggle and local embedded-subtitle preferences as mobile. Playback and subtitle pages read Vivid’s local preferences without loading server-managed player settings. A ring around the saved-account avatar identifies the signed-in account. The backdrop is black, with no ambient corner glow. General's Customise Tab Bar editor saves changes automatically, uses readable move/hide controls, and has no Pin Libraries section or Done button. Its preview includes Search and Profile, which can swap ends without joining the main tab order. The crossed-out eye means a tab is hidden. Vivid has no in-app diagnostics reporting; local player stats remain available. The shared footer reads “© 2026 Vivid™”. Privacy and open-source notices use matching scrollable panels with thin focus highlights; licence text is loaded off the main thread and split into readable focusable blocks. Search enters on an explicitly black surface.

## Detail pages

Search result captions use 20-point titles and an 18-point year beneath them, independently of Home poster preferences. Long titles remain truncated. Emby season selectors use numbered labels such as Season 4, with Specials for season zero; Silo’s season titles are unchanged.

Movie, series and episode pages share fixed positions for the credit line, playback readouts and action row. The loading screen reserves the same positions. Twelve-point gaps separate credits, readouts and actions. Plots wrap within the action row width; Read more opens a separate scrollable Description panel. Start Over lives in the More menu so resume state does not shift the buttons.

The equal-width playback pills use white icons, a translucent background and a thin glass-style edge. Resolution is displayed as 4K, FHD for 1080, or HD below 1080; HDR/DV appears when present, otherwise the video codec is shown. Audio shows codec and channel layout. Subtitles show the selected language or Off. The full selectors retain the detailed track choices.

Continue Watching carries the exact season and episode into the detail route. That season takes priority over cached progress, and the episode carousel refreshes its selection when the requested episode changes. Playback metadata for the selected episode loads its catalog and watch requests together; cached movie pages begin refreshing watch metadata on open. Uncached data still requires a server response.

Poster, collection, episode and trailer artwork share a thin edge highlight that becomes brighter on focus. Watched artwork uses a small green badge with a white tick. Episode thumbnails on series details use the same inset resume bar as Continue Watching. Trailer focus enlarges the card. Movie and series pages now end with Media Information for the selected file or episode: separate Video & File and Audio glass panels. Video & File has up to five equal-width columns; audio has up to four. Sparse panels use fewer columns, while incomplete final rows keep their column alignment. Missing metadata is omitted. Video/file bitrates use Mbps with provider-specific unit conversion; audio below 1 Mbps uses kbps.

## Trailers and More Like This

Settings → General → Trailers accepts a personal TMDb API key or read-access token. Without a configured connection, trailer rows are hidden. Detail-page requests select up to three unique YouTube trailers, preferring the main trailer and, for series, trailers for the latest season. Results are cached; the physical Apple TV opens YouTube to play them.

More Like This is independent of TMDb. It uses the active server/profile catalog, filters by shared genres, studios or networks, and samples up to three hundred candidates across the matching catalog after reading its count. Genre overlap dominates ranking, followed by production and release era. Ties use a stable title-independent order. Up to ten results are shown, excluding the current item and wrong media types. This is bounded metadata matching, not a full-library semantic recommendation engine; sparse metadata can produce few or no matches.

## Source map

<table width="100%">
  <thead><tr><th align="left">Area</th><th align="left" width="10000">Entry points</th></tr></thead>
  <tbody>
    <tr><td>Home and spotlight</td><td><a href="../iosApp/iosApp/tvOS/Components/TVHomeDiscoveryFeed.swift">TVHomeDiscoveryFeed</a>, <a href="../iosApp/iosApp/tvOS/Components/TVHomeSpotlightPreferences.swift">Spotlight and Home card preferences</a>, <a href="../iosApp/iosApp/tvOS/Components/TVSpotlightBackdropImage.swift">Artwork framing</a></td></tr>
    <tr><td>Local metadata</td><td><a href="../iosApp/iosApp/tvOS/Caching/TVHomeMetadataCache.swift">TVHomeMetadataCache</a></td></tr>
    <tr><td>Catalog grids</td><td><a href="../iosApp/iosApp/tvOS/Screens/Components/TVCatalogGrid.swift">TVCatalogGrid and artwork window</a>, <a href="../iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryGridViewModel.swift">Library paging</a></td></tr>
    <tr><td>Navigation and Settings</td><td><a href="../iosApp/iosApp/tvOS/Navigation/TVMainTabView.swift">TVMainTabView</a>, <a href="../iosApp/iosApp/tvOS/Screens/Settings/TVGeneralSettingsView.swift">General</a></td></tr>
    <tr><td>Startup</td><td><a href="../iosApp/iosApp/tvOS/Components/VividStartupView.swift">VividStartupView</a>, <a href="../iosApp/iosApp/Startup/StartupContentPrefetcher.swift">StartupContentPrefetcher</a></td></tr>
  </tbody>
</table>

## Validation

The earlier app checks are recorded through `v0.13.0` (`2ee9005c`). Device validation on 8 September 2026 covered Apple TV 4K (3rd generation), tvOS 26.6: smaller Search captions/year, Media Information, quality controls, normal and DTS audio through HomePod (2nd generation), the 20-second Auto buffer, Home refresh, profile deletion and Emby season labels. This was a local development build, 0.6.0 (1), not TestFlight. The paired iPhone checks are in [App Design](app-design.md#detail-pages-and-validation). No measured benchmark, universal output-format certification or physical iPad check is recorded.

Before treating a revision as device-verified, record its exact commit, Apple TV model and OS, server version, and results. Check cold/warm startup, multiple accounts, manual sign-out, optional PINs, spotlight cycling, Continue Watching returns, independent library sub-tabs, sort/filter changes, paging beyond seventy items, reverse scrolling, cache clearing and Settings navigation. The changed shared code also needs iOS validation; the current tvOS build does not cover those platforms.

Read [focus ownership rules](apple-tv-focus.md) before changing navigation. Preserve series season/episode focus, context-menu restoration, and cancellation of obsolete artwork work.
