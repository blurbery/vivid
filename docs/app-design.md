<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">App Design</h1>
<p align="center">A consistent interface across Apple devices.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid's interface should stay clear, consistent and responsive on Apple devices. Artwork provides the visual variety; the surrounding controls use restrained colours and readable contrast.

## Design ownership

> [!IMPORTANT]
> **Only blurbery approves Vivid’s design.** Do not change the app’s visual or interaction design, branding, animations or documentation layout without blurbery’s prior, explicit approval. Contributors and AI tools must preserve the approved design.

Follow the [design ownership policy](../CONTRIBUTING.md#design-ownership). Reference the owner’s approval in any PR that changes the design; unapproved design changes must not be merged.

## Source of truth

<table width="100%">
  <thead>
    <tr><th align="left">Area</th><th align="left" width="10000">Current implementation</th></tr>
  </thead>
  <tbody>
    <tr><td>Colours</td><td><a href="../iosApp/iosApp/Theme/Colors.swift">Colors.swift</a></td></tr>
    <tr><td>Layout and motion tokens</td><td><a href="../iosApp/iosApp/Theme/VividTheme.swift">VividTheme.swift</a></td></tr>
    <tr><td>Type</td><td><a href="../iosApp/iosApp/Theme/Typography.swift">Typography.swift</a></td></tr>
    <tr><td>Button styles</td><td><a href="../iosApp/iosApp/Theme/VividButtonStyles.swift">VividButtonStyles.swift</a></td></tr>
    <tr><td>First-run components</td><td><a href="../iosApp/iosApp/DesignSystem/Aurora/AuroraStyle.swift">AuroraStyle.swift</a></td></tr>
    <tr><td>Vivid identity</td><td><a href="branding/README.md">Branding guide</a></td></tr>
  </tbody>
</table>

`Aurora` is an existing source name. Use the current tokens and components instead of copying values from another app, platform or old mockup. Renaming code symbols is separate implementation work.

## Appearance

- Keep the content, selected action and current focus easy to distinguish.
- Use charcoal and black where appropriate, with readable foreground contrast. Vivid's approved logo has light- and dark-background treatments.
- Theme-aware documentation assets do not mean the entire app supports automatic light/dark appearance. Apple TV setup uses the silver Vivid mark and neutral controls; startup assembles that mark from stars on black.
- Preserve aspect ratios, truncation rules and stable layout as artwork loads.
- Reuse spacing, corner radius, typography and motion tokens from the implementation.
- Support readable text, meaningful accessibility labels and Reduce Motion.

## Apple TV layout

Home uses the discovery spotlight and standard media rows described in [Apple TV Browsing](apple-tv-browsing.md). The experimental tvOS layout uses rounded, horizontally sliding cards with neighbouring cards peeking in, retaining the 580-point height and left-positioned logo and metadata. Server artwork uses subject-aware cropping; TMDB is used only for trailers. The owner-approved sliding cards use Home’s gradient artwork edge, a soft shadow and a 1.5% focus lift, disabled by Reduce Motion. The layout remains 580 points high. The revised focus treatment awaits device confirmation. Root tab pages use a slim glass bar with Search and Profile dividers, without a separate corner logo.

Movies, Series and For You are independent pages with sub-tabs. Settings opens categories as separate pages on black. Account settings uses a full-width black backdrop and labelled fields, while profile selection uses circular account cards. Home poster size remains local to Home. TV captions use one local server/profile setting across Search, Home, Movies, Series, For You, Continue Watching and series episode cards: Title & Year, Title Only or Artwork Only. Titles use 20-point text and secondary captions use 18-point text, both left aligned; episodes substitute episode details for the year. Search keeps seven columns across the safe-area width with reduced spacing below its result tabs.

Detail pages keep their credit, playback-readout and action rows at fixed baselines through loading and episode changes. Long-pressing a movie or series Resume button opens Start from Beginning in a native context menu. Episode resume progress is outside the focused button and its context-menu content so watched/completion updates can redraw without moving focus. Use the shared glass-style artwork edge, small green watched badge and equal-width icon readouts. Long descriptions open separately; they must not push the action row down. Movie and series pages replace the old Details row with Media Information: separate Video & File and Audio glass panels. Video & File uses at most five equal-width columns; each audio track uses at most four. Column count shrinks for sparse panels, but an incomplete final row retains the same column alignment. Settings headings remain white at 40 points, with the shared “© 2026 Vivid™” footer.

The player retains Vivid’s controls across both platform engines. On Apple TV, its slim timeline has an Info pill above it, remaining time below, and no separate rewind/play/forward button cluster. Loading uses four staggered white bouncing dots at screen centre, with static dots for Reduce Motion. Next Up has a top-right mini-player, bottom-left actions and no On Deck shelf on Apple TV.

## iPhone and iPad layout

The mobile app shares the TV feature owners, with touch layouts. Home, Libraries, For You, Downloads and Settings use black page backgrounds. Movie and series details retain their artwork-colour surface. Browsing cards use Home’s title size with left-aligned titles and years directly underneath the rendered title, without reserving an empty second title line. The shared Captions setting offers Title & Year (the default), Title Only and Artwork Only across Home, Search, Movies, Series and For You; episode cards retain episode information instead of a year. The Downloads page uses glass storage and transfer cards, live byte and speed progress, and locally fetched movie or main-series posters. Mobile headings use 30-point rounded bold text and smaller section labels; TV headings stay at 40 points.

### Navigation and saved lists

The bottom bar is one continuous glass capsule, centred and capped at 420 points so it does not stretch across iPad. Icons occupy fixed, evenly spaced slots with a white selected pill; they do not expand into text labels or scroll sideways. Search and the signed-in profile sit outside the main destinations, separated by dividers. The bar hides on downward scrolling and returns when scrolling upward. Tab Bar configuration uses the same component and icon definitions, provides a grey “Swap Search and Profile” button, and includes a Downloads visibility control. Downloads appears immediately when enabled, without waiting for a server capability response. Download permissions still apply when the page opens.

Search and Profile/Settings are full-screen black pages that slide up from the bottom and slide down when closed. Each has one round glass X at the top left; dragging down from the top also closes the page. Both pages remain portrait on iPhone and iPad. Search opens its keyboard only after the search bar is tapped and resigns it as dismissal begins. Movie and series results still open as detail cards above the retained search page. Playback opens from that card immediately; closing playback leaves the card and previous search results in place without dismissing and reopening Search. Settings retains its own navigation stack. Accounts use manual server setup and QR/manual sign-in.

For You switches in place between Watchlist, Favourites and Collections. Watchlist and Favourites combine movies and series in one view, with outlined blue Movie pills and purple Series pills using strongly tinted, darkened translucent material and muted coloured outlines for readability on bright posters on iOS and tvOS. The secondary tabs scroll with each list, including Collections. Collections combines personal collections with movie, series and mixed-library collections without a library dropdown. Cached collection sections appear first; library requests run together and publish each completed result instead of leaving the page empty for the slowest response. Recommendations are not a For You section. Libraries opens its catalog directly, with native library-selection, Sort and Filter menus and an A–Z menu at the right of the same control row.

Search and Libraries keep three posters per row on iPhone and in compact iPad windows. Wider iPad grids use the available width for additional columns. Search uses smaller, readable result captions with truncation for long titles; this does not change Home poster preferences. Poster widths fit their grid cells so orientation and Split View do not overlap cards. Watchlist and Favourites use three columns at compact width and five at regular iPad width. Collections and the profile emoji picker also fit the current window.

### Home spotlight

Home uses full-width artwork from the configured spotlight sections. Sharp artwork reaches the top; there is no separate top blur or sampled-colour band. The logo is bottom-aligned above centred rating/year metadata, with Movie added for films and no description. The logo and metadata sit just above the page indicators near the first row heading. The background scrolls more slowly than the foreground using the shared detail artwork component. An opaque blurred artwork layer sits beneath the sharp image, which blends into it over a broad transition near the logo. The softened colour extends behind the first row before a gradual uneven fade reaches black. It does not tint the entire page.

The whole spotlight slide opens the featured movie or series detail page when tapped, including the artwork around the logo. Swiping still pages the carousel; the indicator buttons select slides separately. The carousel wraps in both directions using duplicate boundary pages and an unanimated reset after the transition. Its active indicator expands and fills over six seconds, matching TV timing. Reduce Motion disables automatic rotation and progress animation. Continue Watching has no play icon in its heading. Watched artwork badges use green circles with white ticks across Home, catalog and episode views. Continue Watching and Emby Next Up show `S01 E03 – Episode title` beneath the main title. Partly watched Home thumbnails and series-detail episode cards share an inset white resume bar on a grey track.

### Mobile player

Quality, Audio, Subtitles and Chapters each have a separate round glass button above the playback bar and open scrollable anchored popovers. An open popover pins the controls, and the mobile presentation host stays mounted during buffering and quality reloads. Quality changes use the existing position-preserving reload path. Chapters and subtitles come from the media; chapter ticks are absent from the timeline. Rotate, Lock, PiP and AirPlay remain separate round buttons. All control groups appear together on tap; PiP keeps its place while disabled during source preparation. There are no brightness or volume edge gestures. Player unlock uses physical orientation when available. Closing landscape playback restores portrait browsing without rotating the outgoing player. iPad retains its ordinary browsing policy except while Search or Settings requires portrait.

Next Up uses a top-right preview and bottom-left episode information and actions. Play Now is a fixed-width white pill with the countdown beside it, followed by Keep Watching and Back. The updated menus were device-tested on iPhone 16 Pro Max. iPad layout and route-specific PiP/AirPlay operation have not been separately verified for this change.

### Settings and startup

Settings groups are General, Playback, Subtitles, Servers, Seerr, Metadata and About, with connected menu rows and shared icons. General contains Home Screen spotlight selection, Home Sections, Trailers, Poster Configuration, Tab Bar and mobile Downloads settings. Poster size affects Home; captions apply across the shared browsing cards. These preferences remain scoped per server/profile. Native switches use green; section labels and secondary actions use neutral grey while titles stay white. IntroDB remains a native toggle. Playback offers Auto, Original Quality and three capped choices with a one-time buffering fallback; see [Quality controls](playback/README.md#quality-controls). Descriptions stay on one line inside the open picker, not beneath the closed Quality row. Existing Original and custom preferences are preserved. Reset Playback Settings and account Sign Out are centred. Skip Intros and Skip Credits explicitly describe automatic skipping.

Subtitles contains embedded-track language and behaviour preferences plus an appearance preview. Device Accessibility settings can control caption selection and appearance; local overrides expose size, colour, background and position. Preferences remain on the device for the current profile. External subtitle search, files and translation are not offered. Servers contains registered connections and Manage Servers; Sign Out remains in account settings. About sits directly below Metadata in the main Settings selection on mobile and TV, and opens its own page with the circled-info SVG, Vivid mark, version/build, Open Source Licenses, Privacy Policy, Contact and TMDb attribution. Mobile Contact prepares a message for Mail; Apple TV offers an email QR code. No logs or account data are attached automatically. The footer is “© 2026 Vivid™”.

The signed-in account has a ring around its saved-account avatar on mobile and Apple TV. Saved account cards, login sessions and optional Vivid PIN records share a private iCloud vault across the three platforms. Sign Out clears the saved session while retaining its card. Long-press a saved profile to enter wobble editing. On Apple TV, left/right moves the selected profile; press centre to save, or press down to highlight its round glass X and centre to request deletion. On iPhone and iPad, hold and drag to reorder, then tap the glass Done pill above the row to save. Round glass X buttons request deletion confirmation. Reordering stays local to the editor until saved. Visible profile selector and Settings cards refresh iCloud every ten seconds while active and editing is closed. Wobble honours Reduce Motion. Both surfaces use the same saved order, which syncs through iCloud. Deletion removes the saved connection across iCloud devices and removes its saved server only when no other profile uses it. It does not delete the actual media-server account or library. Saved profile order, Home sections, spotlight choices, card captions and sizes, navigation, metadata and download preferences, and TMDB/Seerr credentials travel through the encrypted private vault. Playback and subtitle settings remain device-specific, as do downloaded media and metadata caches. Fresh installs wait for the initial vault fetch; a failed fetch offers retry instead of assuming no profiles exist. One saved profile opens directly when its session is valid and no PIN is required; multiple profiles retain the saved selector order. Server-backed preferences reconcile after the matching session is restored. Changes sync after local edits and on foreground entry; delivery depends on iCloud and server availability. Home metadata is stored on disk per server/profile, with up to 20 items per row and 10 spotlight candidates. Metadata shows cache state and clear controls. Hiding a Home row removes its row-cache entry, while that section remains eligible for spotlight selection.

Watched/unwatched changes from details refresh Home after the server write succeeds. Home coalesces refreshes that arrive during an older fetch and rejects stale responses. Visible foreground Home pages also refresh every ten seconds for server-backed changes made on another device, including watched posters, resume rows and the next episode. This does not use the private iCloud account vault.

### Detail pages and validation

Cast and crew pages use Home-sized filmography posters (three columns on iPhone and compact iPad) and the shared, left-aligned title/year caption settings. Cached person metadata appears on reopening while fresh metadata and filmography load concurrently. First-time missing metadata still depends on server enrichment.

Movie and series detail pages place personal-TMDb Trailers and server-only More Like This before Cast & Crew, which sits directly above Media Information on iOS and tvOS. The panels show the selected file’s available technical metadata, not invented values; series identify the selected episode. Video/file bitrates display in Mbps, with Silo’s kbps and Emby’s bps normalised before formatting. Audio retains kbps for sub-Mbps values. Movie and series detail logos on iPhone and iPad align to the bottom of their artwork area, directly above the metadata, matching Home across different logo proportions. Compact iPhone movie and series details retain the blurred artwork background while sharp artwork moves upwards at roughly half the metadata’s speed. Pulling down keeps artwork attached to the card’s top. Reduce Motion disables parallax and Reduce Transparency disables the blurred artwork surface. Home retains its separate parallax. Playback readouts remain compact equal-width glass pills. Long descriptions open separately; mobile movie and series pages have no extra More button. Downloads retain their progress rings and main-series artwork. Retry states use the shared glass treatment; cancelled or stale detail requests do not flash an error while closing.

The earlier VividKit migration checks are recorded through `v0.13.0` (`2ee9005c`). Device validation on 8 September 2026 covered the completed Search/Settings transitions, Media Information layout, quality controls, audio/buffer fixes, Home refresh, profile deletion and Emby season labels on iPhone 16 Pro Max (iOS 26.6.1) and Apple TV 4K, 3rd generation (tvOS 26.6). Both were local development builds, version 0.6.0 (1), from `fix/search-details-playback-quality`. Thirty-four focused Home/profile tests also passed on the iPhone. These checks are not an all-format playback certification, a benchmark or physical iPad coverage.

### Responsive layout validation

The [complete iOS CI suite](https://github.com/blurbery/vivid/actions/runs/34210945327) passed at `d6f5eef`: 836 tests passed, two optional live-fixture tests skipped, zero failures. The [tvOS simulator build](https://github.com/blurbery/vivid/actions/runs/34209587128/job/102007142684) passed at `ed4734b`; the application source is identical between those revisions. CI required explicit numeric/collection conversions for Xcode 26.3 and corrections to two stale test expectations, without changing the tested behaviour. The skipped checks require `VIVID_LIVE_FIXTURE_PATH` and `VIVID_EMBEDDED_FIXTURE_URL`; their absence is not playback coverage. The isolated TMDb checks passed too. Later documentation-only commits reuse these results rather than rebuilding unchanged app code.

The mobile platforms share features and styling, with additional grid columns and the existing source-aware detail paging where iPad has room. Full-screen Search/Settings pages, the detail-card container, Downloads and the player use their available container size. Horizontal Home and detail shelves intentionally scroll; they are not full-page grids.

The spotlight tap-area fix, three-column iPhone Search and Home-only poster settings were build-checked, installed over the existing iPhone app and launched. Their installation is not a claim that the owner completed every interaction check.

Four `MobilePosterLayoutTests` checks passed on an iPad Pro 13-inch (M5) simulator running iOS 26.5. The focused checks exercise actual SwiftUI poster-card sizing across 320–1366-point widths, compact and regular grid densities, all poster scales, and width changes: 240 poster configurations and 40 tab-bar configurations. The tab bar remains at most 420 points wide and tightens its spacing when a narrow window requires it. An unconstrained-card control reproduces the narrow-window overflow that fitted widths prevent. These checks do not establish authenticated, end-to-end verification of every page.

No physical iPad verification is recorded for this revision. Real-device browsing, rotation, multitasking, playback and external routes remain unverified; earlier observations do not validate the current revision. The simulator layout checks cover mobile sizing only; Apple TV results are recorded in the [TV guide](apple-tv-browsing.md#validation).

## Interaction

Use native touch, keyboard and Siri Remote behaviour for each platform. Keep focus targets stable while images load or leave memory. Prefer existing component ownership over adding another gesture or focus handler.

For TV layout, read [browsing guidance](apple-tv-browsing.md) and [focus guidance](apple-tv-focus.md). Exercise slow clicks, rapid movement, reversals and return navigation on a physical Apple TV when changing those paths.

The design is Vivid's. Server names identify connections and capabilities, not the app's branding.

On iPhone, iPad and Apple TV, long-pressing a season opens its native watched/unwatched menu. Series More menus include whole-series and current-season watched actions. Season writes reuse the existing optimistic episode updates and rollback on failure. On tvOS, browsing episodes leaves the main resume target unchanged. The More menu no longer includes Show Series Info. Episode advancement waits for an unloaded season rather than skipping it, and the movie page responds to the remote Play/Pause button.
