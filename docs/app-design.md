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

Home uses the discovery spotlight and standard media rows described in [Apple TV Browsing](apple-tv-browsing.md). Keep its dark title fade, subdued artwork-colour edge fade, thin focus outline and fixed spotlight size. Do not add a focus scale to the spotlight. Root tab pages use a slim glass bar with Search and Profile dividers, without a separate corner logo.

Movies, Series and For You are independent pages with sub-tabs. Settings opens categories as separate pages on black. Account settings uses a full-width black backdrop and labelled fields, while profile selection uses circular account cards. Home card appearance preferences stay local to that page and must not change catalog or detail cards.

Detail pages keep their credit, playback-readout and action rows at fixed baselines through loading and episode changes. Use the shared glass-style artwork edge, small green watched badge and equal-width icon readouts. Long descriptions open separately; they must not push the action row down. Details use a single divided glass panel. Settings headings remain white at 40 points, with the shared “© 2026 Vivid™” footer.

The player retains Vivid’s controls across all VividKit playback paths. On Apple TV, its slim timeline has an Info pill above it, remaining time below, and no separate rewind/play/forward button cluster. Loading uses four staggered white bouncing dots at screen centre, with static dots for Reduce Motion. Next Up has a top-right mini-player, bottom-left actions and no On Deck shelf on Apple TV.

## iPhone and iPad layout

The mobile app shares the TV feature owners, with touch layouts. Home, Libraries, For You, Downloads and Settings use black page backgrounds. Movie and series details retain their artwork-colour surface. Mobile headings use 30-point rounded bold text and smaller section labels; TV headings stay at 40 points.

### Navigation and saved lists

The bottom bar is one continuous glass capsule, centered and capped at 420 points so it does not stretch across iPad. Icons occupy fixed, evenly spaced slots with a white selected pill; they do not expand into text labels or scroll sideways. Search and the signed-in profile sit outside the main destinations, separated by dividers. The bar hides on downward scrolling and returns when scrolling upward. Tab Bar configuration uses the same component and icon definitions, provides a grey “Swap Search and Profile” button, and includes a Downloads visibility control. Downloads appears immediately when enabled, without waiting for a server capability response. Download permissions still apply when the page opens.

Search and Profile/Settings open as large black slide-up cards. Search has no close X and can be dismissed by dragging down. Its search controller presents within the sheet and does not obscure Home when the keyboard rises. Settings retains navigation within its card. Accounts use manual server setup and QR/manual sign-in.

For You switches in place between Watchlist, Favourites and Collections. Watchlist and Favourites combine movies and series in one view, with Movie/Series pills on posters. Collections combines personal collections with movie, series and mixed-library collections without a library dropdown. Recommendations are not a For You section. Libraries opens its catalog directly, with native library-selection, Sort and Filter menus and an A–Z menu at the right of the same control row.

Search and Libraries keep three posters per row on iPhone and in compact iPad windows. Wider iPad grids use the available width for additional columns. Poster widths are fitted to the actual grid cells, including the selected artwork scale, so changing orientation or using Split View does not make cards overlap. Watchlist and Favourites use the same grid presentation on both mobile devices, with three columns at compact width and five at regular iPad width. Collections also fit their cards to the current window rather than assuming every iPad is full-screen. The profile emoji picker wraps to fit narrow windows while retaining its existing eight-column maximum.

### Home spotlight

Home uses full-width artwork from the configured spotlight sections. Sharp artwork reaches the top; there is no separate top blur or sampled-colour band. The logo is bottom-aligned above centred rating/year metadata, with Movie added for films and no description. The background scrolls more slowly than the foreground using the shared detail artwork component. A softened colour layer starts near the logo and extends behind the first row before an uneven fade reaches black. It does not tint the entire page.

The whole spotlight slide opens the featured movie or series detail page when tapped, including the artwork around the logo. Swiping still pages the carousel; the indicator buttons select slides separately. The carousel wraps in both directions using duplicate boundary pages and an unanimated reset after the transition. Its active indicator expands and fills over six seconds, matching TV timing. Reduce Motion disables automatic rotation and progress animation. Continue Watching has no play icon in its heading. Watched artwork badges use green circles with white ticks across Home, catalog and episode views. Continue Watching and Emby Next Up show `S01 E03 – Episode title` beneath the main title. Partly watched Home thumbnails and series-detail episode cards share an inset white resume bar on a grey track.

### Mobile player

Quality, Audio, Subtitles and Chapters each have a separate round glass button above the playback bar. Quality and Audio use native menus; Subtitles and Chapters use scrollable, anchored Liquid Glass popovers. Quality chooses a streaming bitrate rather than a media file. Chapters and subtitles come from the media, and chapter ticks are absent from the timeline. Rotate, Lock, PiP and AirPlay also use separate round buttons. The player has no brightness or volume edge gestures. Unlocking the player uses physical device orientation when available, including when iOS rotation lock is enabled. iPhone browsing stays portrait behind the player. Closing a landscape player restores that policy without animating the outgoing player through a rotation. iPad keeps its own orientation policy.

Next Up uses a top-right preview and bottom-left episode information and actions. Play Now is a fixed-width white pill with the countdown beside it, followed by Keep Watching and Back. I confirmed the updated menus on iPhone 16 Pro Max after installation. iPad layout and route-specific PiP/AirPlay operation have not been separately verified for this change.

### Settings and startup

Settings groups are General, Playback, Subtitles, Servers, Seerr, Metadata and About, with connected menu rows and shared icons. General contains Home Screen spotlight selection, Home Sections, Trailers, Poster Configuration, Tab Bar and mobile Downloads settings. Poster Configuration controls Home poster size and captions only. It uses the same per-server/profile Home preference owner as Apple TV and does not resize Search, library, collection or detail cards. Use Profile Default restores the Home default. Native switches use green when enabled. Settings section labels and secondary actions use neutral grey; page titles remain white. IntroDB is a switch labelled “Toggle on for native intro & credit skips.” Streaming has no Original quality option; opening Playback converts a stored Original preference to Auto. Skip Intros and Skip Credits explicitly describe automatic skipping.

Subtitles contains embedded-track language and behavior preferences plus an appearance preview. Device Accessibility settings can control caption selection and appearance; local overrides expose size, color, background and position. Preferences remain on the device for the current profile. External subtitle search, files and translation are not offered. Servers contains registered connections and Manage Servers; Sign Out remains in account settings. About sits directly below Metadata in the main Settings selection on mobile and TV, and opens its own page with the circled-info SVG, Vivid mark, version/build, Open Source Licenses, Privacy Policy, Contact and TMDb attribution. Mobile Contact prepares a message for Mail; Apple TV offers an email QR code. No logs or account data are attached automatically. The footer is “© 2026 Vivid™”.

The signed-in account has a ring around its saved-account avatar on mobile and Apple TV. Saved account cards, optional local PINs, direct first sign-in and staged first-run loading reuse the shared account implementation. Sign Out clears the saved session while retaining its card. Home metadata is stored on disk per server/profile, with up to 20 items per row and 10 spotlight candidates. Metadata shows cache state and clear controls. Hiding a Home row removes its row-cache entry, while that section remains eligible for spotlight selection.

### Detail pages and validation

Detail pages place Cast & Crew, personal-TMDb Trailers and server-only More Like This before the divided Details panel. Playback readouts use compact equal-width glass pills with symbols, abbreviated version/audio information and subtitle language. Tap a long description to open it separately; mobile movie and series pages have no extra More button. Series download sheets and their season/episode pickers use the same glass background. IntroDB, Seerr and metadata stores are shared with TV; shared source names beginning with TV do not imply a separate mobile copy.

The VividKit migration was built and installed on iPhone 16 Pro Max (iOS 26.6.1) and Living Room Apple TV 4K, 3rd generation (tvOS 26.6). I confirmed the Search keyboard no longer moves Home, player unlock follows physical orientation, and closing landscape playback leaves the detail page portrait without the player spinning. I also confirmed fast Dune playback after automatic compatible audio selection, account rings and the updated Home/detail episode indicators. These app changes are included in `v0.12.5` (`cb8c9490`). TV build/install/launch checks do not establish playback parity for all formats. No physical iPad verification is recorded; older layout checks below apply only to the revisions they tested.

### Responsive layout validation

The mobile platforms share features and styling, with additional grid columns and the existing source-aware detail paging where iPad has room. Native Search/Settings sheets, the detail-page container, Downloads and the player use their available container size. Horizontal Home and detail shelves intentionally scroll; they are not full-page grids.

The spotlight tap-area fix, three-column iPhone Search and Home-only poster settings were build-checked, installed over the existing iPhone app and launched. Their installation is not a claim that the owner completed every interaction check.

Four `MobilePosterLayoutTests` checks passed on an iPad Pro 13-inch (M5) simulator running iOS 26.5. The focused checks exercise actual SwiftUI poster-card sizing across 320–1366-point widths, compact and regular grid densities, all poster scales, and width changes: 240 poster configurations and 40 tab-bar configurations. The tab bar remains at most 420 points wide and tightens its spacing when a narrow window requires it. An unconstrained-card control reproduces the narrow-window overflow that fitted widths prevent. These checks do not establish authenticated, end-to-end verification of every page.

No physical iPad verification is recorded for this revision. Real-device browsing, rotation, multitasking, playback and external routes remain unverified; earlier observations do not validate the current revision. The simulator layout checks cover mobile sizing only; Apple TV results are recorded in the [TV guide](apple-tv-browsing.md#validation).

## Interaction

Use native touch, keyboard and Siri Remote behaviour for each platform. Keep focus targets stable while images load or leave memory. Prefer existing component ownership over adding another gesture or focus handler.

For TV layout, read [browsing guidance](apple-tv-browsing.md) and [focus guidance](apple-tv-focus.md). Exercise slow clicks, rapid movement, reversals and return navigation on a physical Apple TV when changing those paths.

The design is Vivid's. Server names identify connections and capabilities, not the app's branding.
