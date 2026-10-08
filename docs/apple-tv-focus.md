<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Apple TV Focus</h1>
<p align="center">Stable focus and predictable Siri Remote controls.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Every interactive zone in Vivid needs exactly one focus owner. Let the tvOS focus engine own movement through a
stable graph of focusable controls, or build one custom focusable composite
control. Do not mix the two models.

## Focus Models

Use one of these patterns for a given control.

### Native Focus Graph

Use this for ordinary rows, grids, button groups, sheets, and menus where each
actionable item can be a real focus target.

- Render stable `Button`, `NavigationLink`, or `.focusable(true)` items.
  Every actionable element must be reachable by directional movement alone;
  tvOS has no Tab-key or pointer fallback.
- Use `.focusSection()` on a container so directional movement can enter it
  and land on its nearest focusable child, for example a sidebar column that
  does not line up with the grid beside it.
- Use `.focusScope(namespace)` together with `prefersDefaultFocus(in:)` and
  `resetFocus(in:)` to define where default focus lands inside that scope.
  `focusScope` does not affect directional movement; `focusSection` does.
- Use `@FocusState`, `prefersDefaultFocus`, `defaultFocus`, or `resetFocus` to
  seed or restore focus, not to fight the focus engine on every move.
  `defaultFocus` is evaluated when the view first appears and on automatic
  focus-state updates, not on user-driven moves, unless you pass
  `priority: .userInitiated`.
- Do not move focus programmatically in response to app state unless the
  focused item disappeared. Apple's Human Interface Guidelines say to avoid
  changing focus without the user's interaction; the one exception is moving
  focus to a neighbour when the focused item is removed.
- Rely on the system focus effect. Use `.focusEffectDisabled()` only when the
  control draws its own focus appearance, and keep that appearance visually
  consistent with the platform (scale, lift, highlight).
- Keep the focused subtree mounted and structurally stable while moving focus.
- Attach `onMoveCommand` only at intentional boundaries, such as "Up from the
  first card returns to the top menu." Do not intercept normal in-zone movement.
- Move focus geometry with layout (`padding`, `frame`, alignment), not
  `.offset`, because tvOS resolves focus from layout frames.

Player skip prompts claim initial focus after mounting when the transport is
hidden, so Select activates the skip directly. A directional move reveals and
focuses the timeline; during an intro countdown, Left/Right stays within the
Cancel/Skip row and Up/Down opens the timeline. Once controls are visible,
normal focus movement owns navigation. Revealing controls must not seed Skip
again, and skip focus sections must wrap the buttons rather than their
full-screen positioning frames. Visible skip prompts sit above the measured
transport stack with a 32-point gap, clearing the title, shortcuts and timeline.
The remote Play/Pause command remains owned
by the player shell. Skip and countdown Cancel use a native focusable view
that consumes Select once on press-down, including its release/cancellation.
Their glass labels are passive; there is no second SwiftUI Button gesture
waiting for release. Arrows and Menu continue through the native responder chain.

The custom touch-surface contact observer must set `allowedPressTypes = []`.
It only handles touch events; accepting the default Select press without
finishing its lifecycle can block the focused button's activation, even when
that button highlights and dims. See Apple's [tvOS gesture-recogniser note
111175673](https://developer.apple.com/documentation/tvos-release-notes/tvos-17-release-notes).
The observer remains non-preventing for touch gestures.

Good local examples:

- `TVCatalogGrid`
- `TVLibraryCollectionsView`
- `TVSavedAccountCards`

### Composite Focus Control

Use this when the visual control is one logical selector even though it renders
multiple highlighted rows or columns. A cascading selector is the main example.

- Make one container the real focus target with `.focusable(true)` and a single
  `@FocusState`. On tvOS the default `interactions` set already includes
  `.activate`, so `.focusable(true)` and
  `.focusable(true, interactions: .activate)` behave the same; use the
  explicit form only if the view is shared with iOS.
- Render rows as passive labels; do not make them `Button`s and do not attach
  per-row `.focused(...)` bindings.
- Store the highlighted row/column in ordinary `@State`.
- Handle all D-pad movement for the composite with one `onMoveCommand`.
- Commit the highlighted selection on Select, usually with `onTapGesture` on
  the focused container. Use `onExitCommand` for Menu/Back and
  `onPlayPauseCommand` for Play/Pause. Do not use `onKeyPress` for the Siri
  Remote; Apple documents it as hardware-keyboard input only.
- Add useful accessibility labels and button/selected traits to the composite
  or its rendered labels so VoiceOver still describes the action.

## Do Not Mix Models

The broken pattern is a hybrid control:

- row `Button`s participate in native focus,
- the same rows also use `@FocusState`,
- a parent or window-level handler manually changes that focus in response to
  directional presses.

That gives the same physical remote press to multiple owners. A single directional press can change the highlighted item several times, lose panel focus or reach the tab bar behind the panel.

When this happens, stop adding press interceptors. Decide which focus model the
control should use, then remove the other one.

## Current tab and Settings ownership

Home, Movies, Series and For You are direct root tabs. Movies and Series expose native library sub-tabs within their own page; For You exposes Watchlist, Favourites and Collections. The Profile control opens Settings directly. Do not restore the removed Movies/Series/For You/Profile dropdowns when fixing focus.

Media cards across Home, Search, Movies, Series, For You and detail pages use SwiftUI’s native `.card` button style, including collection posters, episodes, trailers and cast. The system owns their focus lift, shadow and animation; cards add no custom focus scale, shadow or animated artwork border. Resume progress is inside the artwork button so it moves with the native effect. Trailer and cast captions sit outside the native card button; its effect follows only the thumbnail or portrait poster. The Cast & Crew rail's group dividers are plain views with no focus target, so directional movement goes straight from one poster to the next and the first person in the first group stays the rail's default focus. More Like This uses the same poster size preference as Home, including its loading placeholders. Watched and current-episode indicators remain content status cues. Full Home metadata caching is retained.

The spotlight presents its large slides as individual native buttons with a fixed-size, 1.5-point glass-like gradient outline, without enlargement, parallax or a blurred colour glow. The outline is a decorative stroke that ignores hit testing and accessibility, with no material, gesture handler or additional focus target. Its two soft colour stops reuse the section artwork’s cached tint, retaining white highlights and the original white gradient when no tint is cached. This lookup starts no image request or colour analysis and adds no observation callback. They sit in a horizontal scroll view, preserving the 60-point side margins, 22-point card spacing and neighbouring previews. The system moves focus and scrolls between cards. Automatic rotation runs while Spotlight is on screen, independently of focus, and pauses when it leaves the vertical viewport. The carousel remembers its current card when returning from a detail page. Cold entry centres card 1 with the last card already visible on its left. Native focus handles left and right movement, including held directions across repeated loops. Physical positions continue in the direction of travel; crossing card 1 never assigns focus to another copy. A bounded window keeps three loops available on either side and recycles only distant positions before an edge approaches. The focused card retains its identity when that window shifts. For native focus movement, recycling compensates the exact horizontal offset when the position window changes, including partial movement between cards. A non-animated ScrollPosition update preserves native scroll velocity, so removing leading copies neither exposes empty distant cards nor cancels the current movement. The offset measurements are retained without invalidating the Home or artwork views on each frame. If native deceleration leaves a small alignment error after recycling, the carousel centres the same card once horizontal scrolling is idle, without changing focus or handling vertical input. Automatic movement while the top menu owns focus recycles after its horizontal animation finishes, reissuing the current card anchor in the same non-animated layout transaction. Native button targets are laid out eagerly so held movement cannot outrun lazy focus targets; artwork views are limited to the current card and its three neighbours on either side. The logical slide index and pill use the slide count independently of physical position.

Startup, profile selection and login preparation must finish before the first six-second countdown can start on visible, authenticated Home. The current card must be centred and its mounted artwork ready. Initial presentation never rewrites a directional focus move. Artwork readiness belongs to each mounted physical card, expires when that view leaves, and cannot be replaced by a timeout. A terminal missing or failed backdrop uses the existing background and text as its ready fallback, so it does not block rotation indefinitely. Cancellation does not mark artwork ready. The countdown pauses until the selected card actually reaches the centre.

The top menu remains a native upward destination while browsing the spotlight, then resumes its row-boundary suppression when entering lower rows. Spotlight Up uses native movement without an additional manual menu-focus request. The whole top bar declares the selected page tab as its default focus destination for user-initiated entry, so Up returns to Home, Movies, Series or For You rather than whichever utility is closest. Movement within the bar remains native. Moving across the top menu only changes focus; Down returns to the currently selected page. A centre click selects and enters a different tab. Cache readiness alone cannot advance the carousel during initial placement. The rotation countdown resets only when the slide changes; temporary off-screen or scrolling pauses retain elapsed time. Focus changes alone do not pause or reset the counter. Visible loop copies keep stable identities throughout navigation.

Each root owns its own sub-tab selection. A focus move within Movies must not change Series or For You. Keep card identities stable across paging and artwork eviction. Home's spotlight retains a fixed 580-point layout and focus height; the system owns directional movement. Down performs one explicit first-row handoff, preserving its remembered card independently of a moving Spotlight slide; explicit detail return restores the launching card when it still exists.

Settings uses one navigation stack for pushed category/account pages; avoid nesting another stack in a pushed Settings page. The Home Sections editor retains hidden row definitions even when Emby skips their item requests, so reopening the editor always permits re-enabling those rows.

Home uses the discovery feed. Its visible rows reserve a stable card-strip height using the current Home card size and caption setting. Poster and landscape rows retain different artwork heights; missing metadata still reserves its caption line. Cards align at their top edge and row headings reserve one fixed line. Current Home uses a VStack with row heights reserved from the existing card and caption geometry, with up to six enabled media rails plus Spotlight. All normal Home rails use VividCollectionMediaRow with the same CollectionHStack revision as Swiftfin, UIKit cell reuse and continuous leading-edge scrolling. The proven single-rail experiment was extended to poster and episode/resume shelves without changing their Vivid cards or dimensions. Native card buttons own focus; the collection cells are not additional focus targets. This gives vertical focus exact row positions without a separate estimated-total-height frame. Off-screen card views stop their own image requests when their artwork gate closes. Separate disk and nearby-row workers can still prepare off-screen artwork within the [background-work budgets](#apple-tv-home-sections-and-background-work). Home Sections visibility and ordering are applied before layout, so hidden rows leave no empty space. This sizing is scoped to Home-style feeds and does not change detail rails, Spotlight or caching. The standalone recommendation route uses the same rows without a spotlight. The full-screen marquee and its focus callbacks and backdrop rendering have been removed. The independent Home spotlight retains its own artwork and metadata. Home retains its card appearance and full metadata cache.

Each collection cell owns its own native focus binding. Horizontal focus only records the remembered item and reports row ownership; it does not publish a row-wide focus selection. Entry and Detail return issue a single-use request, consumed before writing focus. An off-screen target may consume it on mounting while its row still owns restoration. Changing the row owner immediately cancels the previous row's pending request through non-observable bookkeeping; any card focus in the row also cancels it. A 750 ms expiry is the backstop for targets that never mount. An unconsumed Spotlight handoff has one non-animated mount-and-request fallback if focus still belongs to Spotlight. Detail return and item removal do not retry, and leaving the row view cancels pending restoration. Removing the focused item requests the item now at the same index, or the preceding item when the last card was removed. An empty shelf leaves neighbour selection to the native focus engine. No delayed claims, polling, generation counters or normal-navigation focus retries are used by Home. The legacy MediaRow remains available to other surfaces.

Row ownership is observed by the affected rows and a separate artwork worker, without making it a dependency of the entire feed.

Startup warms row artwork without fetching the removed marquee’s first-item backdrop, logo or tint; landscape episode cards and the independent spotlight retain their artwork. tvOS startup no longer prefetches the former Recommendations feed, library-section landings, legacy Browse page or first Series detail. Current Movies, Series and For You pages load through their own caches when opened; Home and profile warmup remain active. Apple TV Spotlight uses the Home section payload and its artwork cache. It does not fetch full item details, seasons, episodes or playback data; a missing backdrop uses the section artwork fallback. Its full Home snapshot also retains versioned subject-crop decisions (including no detected subject) and sampled tint colours by artwork URL. tvOS prepares current Spotlight backdrops sequentially and shares in-flight analysis with visible slides. Preparation updates do not invalidate the Home view; removed artwork and Spotlight cache clearing discard associated records. Existing snapshots remain readable. Image decoding and GPU presentation still occur after a cold launch.

tvOS Home hydrates its snapshot immediately. [Home refresh](server-connections.md#home-refresh) defines entry, provider-specific timers and deferred updates while Home is hidden. Unchanged rows and snapshots are not republished or rewritten. The unused row warmer and unreachable personal-root shell have been removed. The tvOS bar supports Search, Home, Movies, Series, For You and Settings/Profile only. Music, library shortcuts, Recommended library landings and their dropdown focus machinery are removed, including their tvOS customisation options. Shared saved menu data remains compatible with other clients.

Local Home diagnosis can be armed with the `--home-scroll-diagnostics` launch argument. Adding `--home-scroll-diagnostics-autostart` starts one capture eight seconds after the feed arms, without requiring notification delivery. The `com.blurbery.vivid.home-diagnostics.start` Darwin notification starts a 60-second capture; the corresponding `.stop` notification ends it early. The capture records scroll geometry, row positions, collection-row body evaluations, focus indices, Spotlight phases/alignment/recycling, restoration requests/consumption/expiry/cancellation, display-link callback timing, CPU usage and process memory in `Library/Caches/vivid-home-navigation-diagnostics.json`. It does not record media titles, artwork URLs or account details. Display-link timing measures app callbacks, not GPU presentation time. Without the launch argument, the diagnostic observers remain inactive.

Settings → General → Themes saves the device-wide Graphite, Black or Native choice described in [App Design](app-design.md#appearance). Native uses the shared static mesh gradient on iPhone, iPad and Apple TV. The shared canvas sits behind `ContentView`, outside the routed subtree and tab transitions, and is available before profile selection. Theme changes preserve native focus targets, artwork effects and the 200 ms tab content crossfade. About reading pages inherit the selected theme through Settings navigation; the saved-profile PIN presentation reuses it in its separate modal container. Video retains its black playback canvas.

## Native catalog menus and detail controls

Sort, Filter and A–Z are real native menus. Do not restore the removed centred sort/filter panels or their directional interception. Load filter facets before enabling the menu. Dismissal belongs to the native menu and should return to its trigger without a delayed focus repair. For You keeps one A–Z selection and one Filter selection per sub-tab. Its Filter menu is a native menu in the sub-tab row, left of A–Z, on Watchlist and Favourites only; Up from it hands off to the top menu like the tabs and A–Z.

Settings enters the first saved account directly through the row’s default focus. Holding a profile picks it up for reordering within the same row height. The picked-up card owns left/right movement; centre drops and saves, while Back cancels. The normal profile focus returns to that card afterward. Deletion belongs to the profile editor, outside the reorder row. Do not land on Add Profile and then redirect. Detail action geometry and loading placeholders share the same fixed baselines. The Description popup owns a separate scrollable set of text focus targets and closes with Back.

The Apple TV “Who's watching?” picker initially focuses the first profile in display order, at the left of the first row. The remembered-profile badge does not change that target. After the populated row mounts and the startup overlay enables it, the picker waits for the scene to be active and account loading to finish, allows 150 ms for the enabled native controls to settle, then assigns its focus binding to the first profile. Each tile has one focus binding, and receiving profile focus marks the initial handoff complete. Refreshes do not repeat these requests, and PIN or sign-out overlays prevent them from taking focus. Profile activation and automatic-login preferences remain separate from this focus choice. The owner confirmed the initial profile focus and theme selection behaviour on Apple TV.

The playback timeline and Info/subtitle shortcuts share one directional boundary. Up from an idle timeline enters the shortcut row; Down returns to the timeline. Closing a panel restores its shortcut. An active scrub keeps ownership until committed or cancelled. Remote Play/Pause remains available without a separate on-screen transport cluster.

## References

- Human Interface Guidelines, Focus and selection (system focus effects, do
  not move focus without user interaction, every tvOS element must be
  reachable):
  https://developer.apple.com/design/human-interface-guidelines/focus-and-selection
- UIKit, About focus interactions for Apple TV (focus engine rules; only the
  engine moves focus directionally):
  https://developer.apple.com/documentation/uikit/about-focus-interactions-for-apple-tv
- SwiftUI Focus overview (focusable, FocusState, focusScope, focusSection,
  default focus, resetFocus, focus effects):
  https://developer.apple.com/documentation/swiftui/focus
- SwiftUI `focusSection()`:
  https://developer.apple.com/documentation/swiftui/view/focussection()
- SwiftUI `focusable(_:interactions:)`:
  https://developer.apple.com/documentation/swiftui/view/focusable(_:interactions:)
- SwiftUI `defaultFocus(_:_:priority:)`:
  https://developer.apple.com/documentation/swiftui/view/defaultfocus(_:_:priority:)
- SwiftUI `onMoveCommand(perform:)`, `onExitCommand(perform:)`,
  `onPlayPauseCommand(perform:)`:
  https://developer.apple.com/documentation/swiftui/view/onmovecommand(perform:)
- Focus Cookbook sample (WWDC23, "The SwiftUI cookbook for focus"):
  https://developer.apple.com/documentation/swiftui/focus-cookbook-sample

Episode cards bind the rail’s existing `FocusState` directly to their native button. The button also owns its accessibility description and context menu; separate captions do not hide or replace its activation action.

When opening a series from Continue Watching, keep the exact Play/Resume episode available during the downward handoff through the season row. On first entry into that row, seed its focus to the episode’s season before the existing dwell handler can select a spatially nearer, incorrect season. On first entry into the episode row, seed the exact episode, including late episodes that cannot align to the leading edge. Explicit season selection or episode browsing releases this entry preference; returning to the hero prepares it again. Keep the existing horizontal focus movement, season click and dwell behaviour, scrolling geometry and playback selection. An explicitly requested episode waits for its card instead of falling back to the first episode while loading.

Settings inherits the selected theme canvas, with lighter grey control groups, inset separators and a white focus highlight. The overview has a Profiles header above the existing circular profiles, without a surrounding filled panel, followed by a Settings header above one joined category group with inset dividers and continuous rounded corners. Secondary controls use the same grouped treatment. See [Settings and startup](app-design.md#settings-and-startup) for the shared layout. The 812-point column, page alignment, profile focus targets and editing controls remain in place.

Home Screen, Home Sections and Tab Bar editors push onto the existing navigation stack. Each has one white page heading; Home Screen and Home Sections retain their Done buttons and saved-value actions. About and its Privacy, Licences, Acknowledgements and Contact pages use the same selected app canvas. Privacy and Licences push full-page reading destinations onto the existing Settings navigation stack, like Acknowledgements. Earlier full-screen covers left the About content visible behind the reading text; the pushed destinations avoid that presentation. Back pops the reading destination and returns to About. The reading destination uses the saved theme, including the shared static mesh gradient for Native.

Option rows use SwiftUI `Menu` with the existing preference bindings and a checkmark on the saved choice. tvOS owns opening, dismissal and focus return; the old full-screen custom picker and its manual focus restoration are removed. Category back navigation still returns to its triggering category. Keep page surfaces non-interactive so they never enter the focus graph.

### Home navigation reference

The Home row container and refresh lifecycle follow [Swiftfin's PosterHStack](https://github.com/jellyfin/swiftfin/blob/bcb58ff59b41cac4aee043bc595883a785c77713/Shared/Components/PosterHStack.swift) and [ContentGroupViewModel](https://github.com/jellyfin/swiftfin/blob/bcb58ff59b41cac4aee043bc595883a785c77713/Shared/ViewModels/ContentGroupViewModel/ContentGroupViewModel.swift). Vivid keeps its own card views, actions, account-scoped metadata snapshot and artwork cache. CollectionHStack is pinned in `iosApp/project.yml`; its dependency licences are bundled with the app. The earlier six-row configuration has the historical device feedback recorded below; broader hardware, return-navigation and context-menu coverage should still be checked when those paths change.

## Home investigation outcome

Home retains eager vertical row geometry, CollectionHStack rails, stable image-request identities, bounded artwork preparation and a six-media-row cap, reserving a seventh slot for Spotlight even when hidden. Destination metadata loads after selection, rather than while browsing Home. The trial that forced faster vertical deceleration was removed after worse device feedback. Old MediaRow and lazy-row comparisons describe superseded Home implementations; they are not instructions to restore those paths.

Home's existing row artwork gate also controls decoded-image residency. Closing it clears the image request and warmed fallback, releasing the image held by the leaf without removing the row or its native focus controls. Ordinary disappearance preserves image state and cached decodes: opening detail also makes Home disappear, and must not empty its return viewport. Explicitly retired display and warm-fallback decodes are evicted from memory; compressed disk artwork and profile snapshots remain. Neighbouring rows prepare artwork around their remembered card, clamped to include a full final screenful, rather than restarting at the first card after horizontal traversal.

Earlier profiling found substantial SwiftUI hosting/layout work during remote traversal. It did not establish image-download concurrency, a safe-area callback loop or GPU texture volume as the sole cause. The owner later reported smooth traversal with six enabled media rails plus Spotlight. That supports the earlier capped configuration on the tested device, without proving a universal performance fix or establishing uncapped performance.

The [original investigation and per-build measurements](https://github.com/blurbery/vivid/blob/39a8f097ac3804a2fc503a9f0377e24f295afb15/docs/apple-tv-focus.md#collection-rollout-validation) remain in source history. Those local diagnostic build numbers are independent of TestFlight counters, and their results apply only to the recorded workloads and revisions.

### Image diagnostics

Adding `--home-image-diagnostics` to the two capture launch arguments enables
aggregate image-pipeline accounting and omits per-row geometry observation.
In this mode, automatic capture waits for the first Home row to gain focus
and records for 90 seconds, instead of starting eight seconds after arming.
It retains outer scrolling, focus, row-body events and frame/resource samples.
No URLs, media identifiers, headers or account information enter the output.
The diagnostic helper holds single-use waiter tokens only; it never cancels or
reprioritises the actual task. Both decoded-image flights and shared artwork byte flights
are observed. Byte-flight awaiters are image jobs or raw-data consumers, so
an abandoned image job can still remain an active byte-flight waiter.

`image.*` counters are deltas since the previous sample, normally one second;
use event timestamps for rates if the main thread delays sampling. Absent delta
counters mean zero. `image.flight.active` and `image.dataFlight.active` contain
[flights, awaiters, flights with no awaiters]. Completed-abandoned means no
uncancelled waiter remained when the shared task completed, not that its cached
result can never be useful. Cancellation counters observe caller cancellation;
a shared byte transfer is cancelled when its final consumer leaves. Decoded-image flights retain their existing cancellation policy. Active-flight thresholds
are retained for crossings of multiples of 32 and emitted with the next summary.

`image.decode.operations` contains [total, userInitiated, utility, executing].
`image.timing.*` contains [sample count, p50 milliseconds, p95 milliseconds],
with at most 512 durations per metric per interval and a dropped-sample counter.
`flightStartWait` measures shared-task scheduling; `dataWait` includes byte-flight
coalescing and data retrieval; `decodeQueue.demand/utility` and `decode.demand/utility`
measure the operation's enqueue-to-start and decode durations separately.
URLSession task metrics distinguish cache from network transactions and HTTP
versions. `taskToRequest` includes connection setup as well as queueing, not pure
connection-slot wait; DNS and connection durations are reported separately.
`requestToResponseEnd` measures the request/response interval. These summaries
are attributed when a stage or transport task completes, not a full per-request
trace, and cannot establish which operation caused an individual frame delay.

Leaf-body counts cover CollectionMediaCell, CachedAsyncImage, TVEpisodeArtwork,
VividLazyImage and ThumbhashImage. Lazy/episode task starts and cancellations,
cell appearance/disappearance, artwork-gate changes and actual memory-warning
notifications are counted separately. Their correlation distinguishes possible
causes without labelling every cancellation as recycling; it is not a guaranteed
one-to-one classification of gate versus disappearance cancellation.

### Apple TV Home sections and background work

Home allows six media rows on iOS and tvOS. A seventh slot is always reserved
for Spotlight, even when Spotlight is hidden. The pinned Studios & Networks row
sits outside this limit: at most six fixed logo tiles in one focus section,
with no poster artwork or prefetch window. It has not yet been measured on a
physical Apple TV alongside six media rows. Existing order and hidden choices
are retained. Each server/profile layout remembers which rows it has already
shown; refresh only hides newly appearing rows that would exceed the free
slots, and never switches off a row that was already showing. Layouts saved
before this tracking had their hidden rows reset once, returning to the first
six rows enabled, because the earlier refresh could hide rows the user never
switched off. Layout saves are written in a stable order and skipped when
nothing changed, so iCloud preference sync does not see unchanged layouts as
new values. Before applying the row limit, Home reloads the stored layout, so
a save cannot replace a Combine Next Up or row choice made on another device.
Both settings editors block enabling another row until a slot is freed. Empty
enabled rows remain in the editors so their reserved slots can be freed; Home
only displays them once they contain items. Hidden rows remain available in
Settings and can still supply Spotlight. The existing
per-server-row limit of 20 items is unchanged; combining Continue Watching and
Next Up can merge two such lists.

Apple TV Home uses section payloads for cards, badges and Spotlight labels.
Focusing a card starts no detail or playback preload. Continue Watching cards
also skip per-item detail enrichment. Spotlight no longer fetches or persists
full detail payloads, and older tvOS snapshots discard those payloads when read.
Detail navigation and explicit Play/Resume retain their normal loading paths.
Other screens keep their own caches and loading behaviour. iOS Spotlight retains
the metadata enrichment it uses for its visible year, genre and age rating labels.

These are configured budgets and task limits, not measured total memory use:

| Work or storage | Current code behaviour |
| --- | --- |
| Home metadata | Up to 20 items per server row, with up to six media rows displayed. The shared response cache and Home model retain the current response, which can also contain hidden row definitions and Spotlight sources. |
| Persistent Home snapshot | Enabled rows, up to 10 Spotlight slides from up to three sources, navigation library summaries and crop/tint records. Writes and reads reject snapshots over 8 MiB; this does not cap live memory. |
| Full Home artwork download | All unique enabled-row artwork URLs plus Spotlight artwork can queue for disk caching, including off-screen rows. This worker allows two requests at once. |
| Startup decoded artwork | Up to 28 Home images are queued through a shared worker with two active requests. |
| Nearby decoded artwork | A screenful from the current row, three following rows and one preceding row. A separate worker allows two active requests after a 120 ms row-change pause. |
| Shared decoded-image cache | While Home warms artwork, a 192 MiB target on devices with at most 3.5 GB physical memory, otherwise 320 MiB, and a 600-image count target. These NSCache targets exclude images retained directly by views. |
| Shared artwork disk cache | Up to 256 MiB per account/profile artwork scope. |
| Image decoding | Two decode operations at once. Visible image loads and Spotlight crop/tint preparation also use the pipeline, so prefetch-worker limits are not a global request limit. |
| tvOS Home refresh while visible | Jellyfin every 10 seconds; Silo every 30 minutes; Emby has no periodic Home timer. Entry and explicit refresh/mutation events can also refresh Home. |

The app shell also loads profiles, library names and presentation preferences for
the visible navigation and badges. It does not use those library summaries to
preload Movies, Series, For You or detail pages. Home-specific requests can fan
out by provider: Silo uses its Home endpoint, Emby loads required row contents,
and Jellyfin loads resume, next-up and latest-library rows.

Before this change, a 180 ms card-focus pause could fetch two payloads for a movie,
up to three for an episode, or four for a series (detail, seasons, one season's
episodes and watch data). Those responses entered a shared dictionary with no
TTL or count/byte limit. Home no longer populates that dictionary with speculative
destination responses. Removing this work does not by itself establish that
uncapped scrolling is smooth on physical Apple TV hardware.

### Earlier capped configuration

blurbery reported smooth cold launches and repeated fast horizontal/vertical
traversal on Apple TV after manually reducing Home to six media rails plus
Spotlight. This supports the smaller Home configuration on that device, without
proving that hosting-view count alone caused the earlier lag. Build 43 includes
the automatic limit and settings controls and was installed in place on Apple TV. blurbery subsequently confirmed that tvOS works well.

Validation: the signed Release VividTV device build and the iOS/tvOS CI run for
`a584044` passed. The later Add Profile loading presentation in `a584044` has not
yet been installed on Apple TV; the owner’s installed-build confirmation does
not establish device coverage of that change.

Spotlight retains its existing crop-before-display sequence, readiness gate, six-second rotation timing and native navigation. Shared image transport retries a temporary connection, DNS or timeout failure once, including Silo, and caps each resource transfer at 45 seconds. HTTP, decoding and cancellation failures are not retried. Regression checks cover recovery, persistent failure and cancellation; the subsequent all-poster stall was reproduced even after clearing artwork and Home metadata. Spotlight crop preparation now runs serially on a bounded Core Graphics thumbnail with CPU-only Vision requests, avoiding synchronous UIImage preparation alongside artwork decoding. A physical Apple TV check confirmed Silo → Emby → Silo artwork loading and playback on both providers with this crop change.

Window recognisers dedicated to remote buttons also set `allowedTouchTypes = []`,
so a Menu or arrow observer cannot cancel a focused button’s clickpad touch.
The scrubber pan bridge accepts indirect touches but no button presses.
