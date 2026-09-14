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

Media cards across Home, Search, Movies, Series, For You and detail pages use SwiftUI’s native `.card` button style, including collection posters, episodes, trailers and cast. The system owns their focus lift, shadow and animation; cards add no custom focus scale, shadow or animated artwork border. Resume progress is inside the artwork button so it moves with the native effect. Trailer and cast captions sit outside the native card button; its effect follows only the thumbnail or circular portrait. More Like This uses the same poster size preference as Home, including its loading placeholders. Watched and current-episode indicators remain content status cues. Full Home metadata caching is retained. The spotlight presents its large slides as individual native buttons with a fixed-size, 1.5-point glass-like gradient outline, without enlargement, parallax or a blurred colour glow. The outline is a decorative stroke that ignores hit testing and accessibility, with no material, gesture handler or additional focus target. Its two soft colour stops reuse the section artwork’s cached tint, retaining white highlights and the original white gradient when no tint is cached. This lookup starts no image request or colour analysis and adds no observation callback. They sit in a horizontal scroll view, preserving the 60-point side margins, 22-point card spacing and neighbouring previews. The system moves focus and scrolls between cards. Automatic rotation runs only while Spotlight or the top menu owns focus; it pauses while browsing shelves. The carousel remembers its current card when returning from a detail page. Cold entry centres card 1 with the last card already visible on its left. Native focus handles left and right movement, including held directions across repeated loops. Physical positions continue in the direction of travel; crossing card 1 never assigns focus to another copy. A bounded window keeps three loops available on either side and recycles only distant positions before an edge approaches. The focused card retains its identity when that window shifts. For native focus movement, recycling compensates the exact horizontal offset when the position window changes, including partial movement between cards. A non-animated ScrollPosition update preserves native scroll velocity, so removing leading copies neither exposes empty distant cards nor cancels the current movement. The offset measurements are retained without invalidating the Home or artwork views on each frame. If native deceleration leaves a small alignment error after recycling, the carousel centres the same card once horizontal scrolling is idle, without changing focus or handling vertical input. Automatic movement while the top menu owns focus recycles after its horizontal animation finishes, reissuing the current card anchor in the same non-animated layout transaction. Native button targets are laid out eagerly so held movement cannot outrun lazy focus targets; artwork views are limited to the current card and its three neighbours on either side. The logical slide index and pill use the slide count independently of physical position. Startup, profile selection and login preparation must finish before the first six-second countdown can start on visible, authenticated Home. The current card must be centred and its mounted artwork ready. Initial presentation never rewrites a directional focus move. Artwork readiness belongs to each mounted physical card, expires when that view leaves, and cannot be replaced by a timeout. Known limitation: a terminal missing or failed image can leave automatic rotation paused indefinitely because the card never reports artwork readiness. Native manual card navigation remains available. The readiness guard is retained to avoid automatic movement onto unprepared artwork; terminal fallback presentation and recovery are not implemented or verified by the successful loop-boundary checks. The countdown pauses until the selected card actually reaches the centre. The top menu remains a native upward destination while browsing the spotlight, then resumes its row-boundary suppression when entering lower rows. Spotlight Up uses native movement without an additional manual menu-focus request. The whole top bar declares the selected page tab as its default focus destination for user-initiated entry, so Up returns to Home, Movies, Series or For You rather than whichever utility is closest. Movement within the bar remains native. Moving across the top menu only changes focus; Down returns to the currently selected page. A centre click selects and enters a different tab. Cache readiness alone cannot advance the carousel during initial placement. The rotation countdown resets only when the slide changes; temporary focus or scrolling pauses retain elapsed time, and returning focus to the same slide does not reset its counter. Visible loop copies keep stable identities throughout navigation. Each root owns its own sub-tab selection. A focus move within Movies must not change Series or For You. Keep card identities stable across paging and artwork eviction. Home's spotlight retains a fixed 580-point layout and focus height; the system owns directional movement. Down performs one explicit first-row handoff, preserving its remembered card independently of a moving Spotlight slide; explicit detail return restores the launching card when it still exists. Settings uses one navigation stack for pushed category/account pages; avoid nesting another stack in a pushed Settings page. The Home Sections editor retains hidden row definitions even when Emby skips their item requests, so reopening the editor always permits re-enabling those rows.

Home uses the discovery feed. Its visible rows reserve a stable card-strip height using the current Home card size and caption setting. Poster and landscape rows retain different artwork heights; missing metadata still reserves its caption line. Cards align at their top edge and row headings reserve one fixed line. The current diagnostic build uses a VStack with row heights reserved from the existing card and caption geometry, to compare against the lazy-row implementation. All normal Home rails use VividCollectionMediaRow with the same CollectionHStack revision as Swiftfin, UIKit cell reuse and continuous leading-edge scrolling. The proven single-rail experiment was extended to poster and episode/resume shelves without changing their Vivid cards or dimensions. Native card buttons own focus; the collection cells are not additional focus targets. This gives vertical focus exact row positions without a separate estimated-total-height frame. Off-screen rows do not start image requests; visible rows reuse the existing image cache and the nearby-row artwork worker continues preparing images ahead. Home Sections visibility and ordering are applied before layout, so hidden rows leave no empty space. This sizing is scoped to Home-style feeds and does not change detail rails, Spotlight or caching. The standalone recommendation route uses the same rows without a spotlight. The full-screen marquee and its focus callbacks and backdrop rendering have been removed. The independent Home spotlight retains its own artwork and metadata. Home retains its card appearance and full metadata cache. Each collection cell owns its own native focus binding. Horizontal focus only records the remembered item and reports row ownership; it does not publish a row-wide focus selection. Entry and Detail return issue a single-use request, consumed before writing focus. An off-screen target may consume it on mounting while its row still owns restoration. Changing the row owner immediately cancels the previous row's pending request through non-observable bookkeeping; any card focus in the row also cancels it. A 750 ms expiry is the backstop for targets that never mount. An unconsumed Spotlight handoff has one non-animated mount-and-request fallback if focus still belongs to Spotlight. Detail return and item removal do not retry, and leaving the row view cancels pending restoration. Removing the focused item requests the item now at the same index, or the preceding item when the last card was removed. An empty shelf leaves neighbour selection to the native focus engine. No delayed claims, polling, generation counters or normal-navigation focus retries are used by Home. The legacy MediaRow remains available to other surfaces. Row ownership is observed by the affected rows and a separate artwork worker, without making it a dependency of the entire feed. Startup warms row artwork without fetching the removed marquee’s first-item backdrop, logo or tint; landscape episode cards and the independent spotlight retain their artwork. tvOS startup no longer prefetches the former Recommendations feed, library-section landings, legacy Browse page or first Series detail. Current Movies, Series and For You pages load through their own caches when opened; Home and profile warmup remain active. Spotlight keeps its artwork and detail cache but no longer preloads series seasons or episode lists. Its full Home snapshot also retains versioned subject-crop decisions (including no detected subject) and sampled tint colours by artwork URL. tvOS prepares current Spotlight backdrops sequentially and shares in-flight analysis with visible slides. Preparation updates do not invalidate the Home view; removed artwork and Spotlight cache clearing discard associated records. Existing snapshots remain readable. Image decoding and GPU presentation still occur after a cold launch. tvOS Home hydrates its snapshot immediately and refreshes existing rows on first entry, after at least 60 seconds away, or when an item-change notification is pending. It does not poll every ten seconds while browsing. Changes received while Home is hidden are queued until return. Unchanged rows and snapshots are not republished or rewritten. The unused row warmer and unreachable personal-root shell have been removed. The tvOS bar supports Search, Home, Movies, Series, For You and Settings/Profile only. Music, library shortcuts, Recommended library landings and their dropdown focus machinery are removed, including their tvOS customisation options. Shared saved menu data remains compatible with other clients.

Local Home diagnosis can be armed with the `--home-scroll-diagnostics` launch argument. Adding `--home-scroll-diagnostics-autostart` starts one capture eight seconds after the feed arms, without requiring notification delivery. The `com.blurbery.vivid.home-diagnostics.start` Darwin notification starts a 60-second capture; the corresponding `.stop` notification ends it early. The capture records scroll geometry, row positions, collection-row body evaluations, focus indices, Spotlight phases/alignment/recycling, restoration requests/consumption/expiry/cancellation, display-link callback timing, CPU usage and process memory in `Library/Caches/vivid-home-navigation-diagnostics.json`. It does not record media titles, artwork URLs or account details. Display-link timing measures app callbacks, not GPU presentation time. Without the launch argument, the diagnostic observers remain inactive.

tvOS uses one static vertical charcoal gradient (`#101114` at the top to `#030405` at the bottom) behind `ContentView`, outside the routed subtree and tab transitions. Home, Search, library grids, For You, detail pages, Settings and profile pages inherit that canvas instead of drawing their own page fills. The background has no loading task, timer or artwork sampling; changing tabs does not remount it. Dark appearance, safe-area rules, native focus targets, artwork effects and the 200 ms tab content crossfade remain unchanged. Full-screen About reading pages and the saved-profile PIN presentation reuse the same opaque charcoal design because modal presentations have separate containers. Video retains its playback background. This change concerns the page canvas, not the existing data-loading and cache policy.

## Native catalog menus and detail controls

Sort, Filter and A–Z are real native menus. Do not restore the removed centred sort/filter panels or their directional interception. Load filter facets before enabling the menu. Dismissal belongs to the native menu and should return to its trigger without a delayed focus repair. For You keeps one A–Z selection per sub-tab.

Settings enters the first saved account directly through the row’s default focus. Holding a profile picks it up for reordering within the same row height. The picked-up card owns left/right movement; centre drops and saves, while Back cancels. The normal profile focus returns to that card afterward. Deletion belongs to the profile editor, outside the reorder row. Do not land on Add Profile and then redirect. Detail action geometry and loading placeholders share the same fixed baselines. The Description popup owns a separate scrollable set of text focus targets and closes with Back.

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

When the series hero action row has focus, prepare the continuous shelf on the Play/Resume episode’s season and scroll that episode into view. Keep native downward focus movement and the existing season click and swipe handlers; do not force episode focus or replace the playback selection when browsing.

Settings inherits the shared charcoal canvas, with lighter grey control groups, inset separators and a white focus highlight. The overview has a Profiles header above the existing circular profiles, without a surrounding filled panel, followed by a Settings header above separate category cards with 10-point gaps. Secondary controls retain joined rows. The 812-point column, page alignment, profile focus targets and editing controls remain in place.

Home Screen, Home Sections and Tab Bar editors push onto the existing navigation stack. Each has one white page heading; Home Screen and Home Sections retain their Done buttons and saved-value actions. About and its Privacy, Licences, Acknowledgements and Contact pages use the same charcoal app canvas. Privacy and Licences are full-page reading presentations, with no dark inset popup or parent-page bleed.

Option rows use SwiftUI `Menu` with the existing preference bindings and a checkmark on the saved choice. tvOS owns opening, dismissal and focus return; the old full-screen custom picker and its manual focus restoration are removed. Category back navigation still returns to its triggering category. Keep page surfaces non-interactive so they never enter the focus graph.

### Home navigation reference

The Home row container and refresh lifecycle follow [Swiftfin's PosterHStack](https://github.com/jellyfin/swiftfin/blob/bcb58ff59b41cac4aee043bc595883a785c77713/Shared/Components/PosterHStack.swift) and [ContentGroupViewModel](https://github.com/jellyfin/swiftfin/blob/bcb58ff59b41cac4aee043bc595883a785c77713/Shared/ViewModels/ContentGroupViewModel/ContentGroupViewModel.swift). Vivid keeps its own card views, actions, account-scoped metadata snapshot and artwork cache. CollectionHStack is pinned in `iosApp/project.yml`; its dependency licences are bundled with the app. These implementation changes still require remote-control verification for rapid vertical traversal, return from details, top-menu access and context-menu removal.

### Collection rollout validation

The one-row CollectionHStack comparison was reported as much smoother on Living
Room than the original MediaRow. The full Home rollout retains the same card
views, size preferences, progress bars, context actions, row ordering, visibility
gating and artwork warmup. Home metadata caching and background refresh are
unchanged; Spotlight is not part of this conversion. The next physical-device
check is held Right, Down, held Left, Down, Right, followed by exact-card Detail
return and removal of a focused Continue Watching item. A successful build does
not establish that those checks pass. Profile artwork only after those paths work.

On Living Room, blurbery reports that build 27's horizontal movement is now
perfect. The next controlled experiment uses a LazyVStack for the ordinary Home
rows, reserving each row's height from its existing heading, artwork size,
caption preference and vertical padding. Spotlight remains eagerly mounted.
Horizontal collections, focus bookkeeping, visibility gating and cache/warmup
behaviour are unchanged. Vertical traversal through 8–10 rows and exact-card
Detail return still need physical-device verification for this experiment.

Build 28 was reported as much smoother on Living Room after traversing the
feed, with cold first-traversal hitching still present. The next experiment
keeps the lazy vertical layout and collection navigation. Home warms the
remembered current card and neighbours, then the first screenful of the next
three rows, then remaining current/previous screenfuls. Row changes reprioritise
pending requests while retaining the two active requests; horizontal focus
updates do not restart warming. Display-size request arithmetic matches the
cards. Fixed-size Home artwork bypasses per-image geometry observation.
Decoded memory and persistent metadata/disk caches retain their existing
budgets and memory-pressure handling. No duplicate or hidden rails are mounted.
Cold first-descent improvement remains unverified until device testing.

Build 29 was reported as somewhat better on the first descent and much better
on the return ascent. The next diagnostic build changes only the vertical row
container back to VStack, retaining reserved heights, CollectionHStack rails,
artwork visibility gating and the revised warm queue. This tests eager real-row
construction against build 29; it is not a decision to retain eager layout.
Compare the immediate cold first descent and return ascent on Living Room.
A first-four-rows eager/lazy hybrid remains a possible follow-up after that test.

Build 30's slow reversals were reported as a dragging page transition with the
same card selected, for both directional clicks and touch swipes. A 60-second
Living Room capture showed unchanged row heights and total content height,
with monotonic scroll settling of about 0.9 seconds for a short transition and
over a second for larger transitions. It did not establish a second focus
claim or layout snap-back. The next experiment sets only the enclosing vertical
UIScrollView deceleration rate to fast. Focus destinations, horizontal scrolling,
Spotlight visuals and artwork handling are unchanged. Effect on focus-driven
scroll settling remains subject to physical-device verification.

Build 31's fast vertical deceleration was reported as worse on Living Room.
The override and its UIKit configuration bridge were removed, restoring the
build 30 scroll behaviour. The dragging focus/page transition remains unresolved;
the faster deceleration experiment is not retained.

The external invalidation review described the older MediaRow-based Home path.
Current Home uses VividCollectionMediaRow, per-cell focus storage and explicit
environment values; its ownership binding is read only in restoration callbacks.
The remaining artwork gate previously invalidated the collection row at each
visibility boundary. Home now passes a per-row gate reference into hosted card
leaves, where its enabled value is observed. Focus enables the current row,
one behind and two ahead; enabled rows remain available until more than four
rows away. Visibility is an enable-only fallback, and memory pressure disables
gates. This avoids leave/re-enter gate flips and collection updates caused by
reading the gate in the rail body. No item-ID-only equality shortcut or package
fork is used, so existing-item metadata and progress updates remain available.
Physical-device performance of this change still requires verification.

Build 33 was reported as a large improvement, with fast vertical traversal and
Spotlight/Continue Watching crossings still laggy. Unchanged collection rows
now skip parent-driven updates using full section data, restoration request
tokens, row index, dimensions and action availability. Passive remembered IDs
are consumed when a restoration token or section changes; they do not trigger
updates across every previously visited row at the Spotlight boundary. Row
index participates so reordered sections do not retain stale index callbacks.
Top-menu availability is observed inside the bar instead of the tab shell.
Rapid traversal enables only immediate row neighbours synchronously; ahead
preparation and distant disabling wait for a 150 ms pause. The existing bounded
window and memory-pressure behaviour remain. Warm request construction and queue
reprioritisation wait 120 ms after row changes, while initial snapshot warming
starts immediately. The scroll-visibility enable fallback is removed. These
pauses apply only to artwork preparation, never focus or scroll movement.
Device verification remains pending for the latest changes.

Build 34 was reported as a large performance improvement. A remaining race was
reported when leaving Spotlight during auto-advance: Continue Watching moved
horizontally and later traversal felt laggy. Spotlight now owns its focus state
locally, drops the mid-scroll visibility gate, and pauses rotation/pill updates
while shelves own focus. Auto-advance scrolls the slide first and synchronises
focus only when it is centred and focus still belongs to Spotlight. Down clears
pending rotation and hands off once to the remembered first-row card. Restoring
a collection's last focused card keeps its retained horizontal offset. Spotlight
visuals, cached artwork and ordinary shelf navigation remain unchanged.
Device verification must cover leaving during auto-advance, repeated crossings,
Detail return, manual left/right loops and reduced-motion auto-advance.

The requested final-card leading alignment permits trailing blank space. A
resolved breakpoint on UIScrollView.scrollRectToVisible(_:animated:) recorded
zero hits in the base implementation during a user-driven poster-row traversal
on Living Room with build 34. This does not exclude a collection-specific
override, so it does not yet validate or rule out the proposed subclass path.
Ordinary horizontal alignment remains unchanged pending a verified native
integration point; no competing focus-triggered scroll animation is added.

Build 35 was reported to fix the Spotlight/Continue Watching boundary; cold
first traversal still trails the warmed return pass. Home shelf artwork now
publishes arriving images without individual fade animations, identified by
the row-specific artwork gate so Spotlight and other surfaces retain their
presentation. tvOS decode operations use per-request QoS: utility for speculative
warming and user-initiated for display requests, with display work ahead of
pending low-priority decodes. The two-decode limit, HTTP connection limit,
rolling warm window and persistent caches remain unchanged. Existing Home
warmers already use exact display-size keys; raw disk bytes and differently
sized hero/detail decodes retain separate purposes. This is a bounded arrival-
and scheduling-cost experiment, not proof that all remaining cold hitching is
image work. Device performance of the change remains unverified.

Build 36 was reported as much smoother on Living Room, with persistent lag
sometimes triggered by fast Down followed immediately by Left or Right. The
latest bounded focus experiment removes the intermediate Spotlight focus reset
on Down and limits idle alignment correction to one attempt per selection with
a two-point tolerance. Residuals smaller than a card width snap without animation.
Row restoration is consumed before writing focus and is invalidated immediately
when ownership moves to another row, Spotlight or the menu. Any card gaining
focus in its row cancels pending restoration too. The 750 ms backstop leaves
time for off-screen Detail targets to materialise after scrolling. Consumption
also checks current ownership without observing it in the collection body. An unconsumed Spotlight handoff may scroll its target into
place and re-send once, only if the first row still owns restoration and Spotlight
still reports focus. The fallback cannot retry itself. Detail return and removal
retain a single attempt. The suspected focus/animation feedback has not been
established by a profile. Collection sizing and cache policy are unchanged.

Visible-but-unfocused Spotlight rotation is requested but deferred to a separate
device experiment so it does not confound this focus check. This build retains
rotation only while Spotlight or the top menu owns focus. Device checks must
cover the fast direction change, exact-card Detail return, removal of the focused
Continue Watching item and repeated Down during Spotlight auto-advance. Targets
that cannot consume restoration before expiry are left to native focus.
The optional diagnostic capture now distinguishes Spotlight phases, alignment
and recycling from outer-feed scrolling, and records restoration request,
consumption, expiry and cancellation events without media identifiers.

Build 37 passed the Release tvOS build and app/extension signature, version and
shared Keychain-group checks, and was installed in place on Living Room. A
temporary executable using the exact coordinator and ownership code passed
single-consumption, expiry, supersession, ownership cancellation, focus
cancellation and bounded-fallback checks. These are bookkeeping checks, not
proof of native focus restoration or device smoothness; remote testing is pending.

Build 37 was reported as dramatically improved on Living Room, with slight
vertical jitter still noticeable after a fast row-entry/horizontal move. The
next build changes only opt-in diagnostics: per-row body counts and automatic
capture startup. Focus bookkeeping remains unpublished, expiry is outside
SwiftUI state/equality, and fallback is ownership-checked and bounded. No
material, clipping, collection focus eligibility, artwork scheduling or memory
policy change is made without further evidence. The initial saved capture was
only armed and contained no samples, so it does not establish or exclude a
row-update fan-out.

Build 38 passed the Release tvOS build and app/extension signature, version and
shared Keychain checks. Its verified 60.05-second Living Room capture recorded
167 focus events, zero feed/collection-row body events, 826 outer scroll updates
and a stable 6059-point content height. Rapid vertical movement at 30–44 seconds
had 107 display-link callback intervals above 33.4 ms, with a maximum of 133.2 ms;
these are callback delays, not measured GPU frame presentation. After 46 seconds,
only frame/resource samples remained and mean process CPU was about 1%. The
capture does not support body-update fan-out or a continuing idle focus loop
in that run. blurbery reported poor movement during the diagnostic test;
diagnostic overhead is not isolated. Vivid was reopened without diagnostics
after retrieval. No rendering, focus or artwork-scheduling change is included.

With diagnostics disabled, blurbery confirmed the good baseline had returned:
only slight cold-start downward jitter remained and overall navigation was
reported as very good. The diagnostic run is therefore not treated as evidence
of a new navigation regression. Further rendering and idle-scheduling changes
are deferred; the working navigation and cache policy are retained.

Adding `--home-image-diagnostics` to the two capture launch arguments enables
aggregate image-pipeline accounting and omits per-row geometry observation.
In this mode, automatic capture waits for the first Home row to gain focus
and records for 90 seconds, instead of starting eight seconds after arming.
It retains outer scrolling, focus, row-body events and frame/resource samples.
No URLs, media identifiers, headers or account information enter the output.
The diagnostic helper holds single-use waiter tokens only; it never cancels or
reprioritises the actual task. Both decoded-image flights and Emby byte flights
are observed. Byte-flight awaiters are image jobs or raw-data consumers, so
an abandoned image job can still remain an active byte-flight waiter.

`image.*` counters are deltas since the previous sample, normally one second;
use event timestamps for rates if the main thread delays sampling. Absent delta
counters mean zero. `image.flight.active` and `image.dataFlight.active` contain
[flights, awaiters, flights with no awaiters]. Completed-abandoned means no
uncancelled waiter remained when the shared task completed, not that its cached
result can never be useful. Cancellation counters observe caller cancellation;
underlying shared-task cancellation policy is unchanged. Active-flight thresholds
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
A temporary executable enabled the same diagnostic accounting on macOS and
passed cancellation-once, unchanged shared work, abandoned completion, demand
joining utility, percentile and inactive-recording checks. Device results remain
pending. Navigation, appearance, two-connection/two-decode limits, persistent
caches and memory-pressure handling are unchanged.

Build 39 passed the Release tvOS build and app/extension signature, version and
shared Keychain checks. It was installed in place on Living Room, and the
automatic capture was verified in recording state with image-flight and decode
gauges present before requesting the remote-control workload. Memory hit/miss
counters cover pipeline image calls; direct image-view cache lookups bypass
those counters. Queue QoS gauges describe configured operation priorities, not
measurements of CPU-core placement or effective scheduler priority.

Build 39's initial timed capture contained only Spotlight activity and the initial
focus marker, so it missed the user's reported progressively laggy row traversal.
It is not used to accept or reject the image-contention hypothesis. The next
diagnostic build starts on actual first-row focus and records for 90 seconds
to align the capture with the user-controlled workload.

Build 40 passed the Release tvOS build and app/extension signing, version and
shared Keychain checks. The capture started on actual row-0 focus and recorded
90.08 seconds with 262 focus events. blurbery reported increasing lag across
rows and on the vertical return. Diagnostics were disabled by relaunching Vivid
after retrieval. This run recorded 169 decoded-image flights created/completed,
170 awaiter joins, no waiter cancellations, no abandoned completions and no
memory-warning events. The Emby-specific byte-flight layer had no activity in
this workload. There were 30 network transactions, all reported as HTTP/2, and
169 cache transactions; these are transactions, not disjoint request counts.
The largest one-second p95 decode queue waits were 0.09 ms for demand and
0.45 ms for utility. The largest one-second p95 decode durations were 54.45 ms
and 47.41 ms respectively. No concurrency change is justified by these waits.

During the warmed 30–60-second portion, there were no new image flights and all
sampled image-flight, byte-flight and decode-operation gauges were zero. Yet
there were 28 gate enables, 28 gate disables, 845 CachedAsyncImage body evaluations,
1690 VividLazyImage body evaluations, 425 non-nil lazy tasks and 420 nil tasks.
Only 12 collection cells appeared and 11 disappeared in that interval. Whole-feed
and whole-row updates remained rare over the entire run (two and one), with one
consumed restoration and no expiry. Process footprint rose from about 99.5 MiB
to a peak of 149.4 MiB, without a recorded memory warning. Callback timing was
worse during rapid warmed vertical movement, reaching a 49.8 ms p95 and a
105.2 ms maximum in the 30–45-second interval; these are not GPU presentation
measurements. Counters are sampled and diagnostic overhead remains possible.

The strongest next hypothesis is gate-driven leaf refresh and image replacement
while vertical scrolling is active, rather than download/decode backlog. A
controlled follow-up could defer distance-based disabling until vertical idle,
retaining immediate destination enabling, bounded idle retention and memory
pressure handling. That scheduling change is not part of this diagnostic commit.
No cancellation, concurrency, focus, Spotlight design or card-rendering change
has been made based on this investigation.

The next isolated experiment separates VividLazyImage's request identity from
permission to start a cache-miss load. A bitmap retained for the same request,
or synchronously found in memory, keeps the task key stable across gate changes.
A missing bitmap still changes eligibility when its gate changes, and the task
checks loading permission before calling the pipeline. The captured bitmap is
held through task setup, so a concurrent NSCache eviction cannot turn a gated
cache hit into a new decode. Retained images are matched to their request key;
a reused view cannot display a bitmap from its previous item. Disabled views
release their retained bitmap on a memory warning; active views keep displaying
available artwork while the existing global cache/gate handlers run.

CachedAsyncImage renders exact-size and warmed fallback images through one
Image branch. Home keeps its no-fade transaction, card dimensions and appearance.
The 150 ms gate settle, distance window, warming schedule, concurrency limits,
focus logic and Spotlight design are unchanged for this comparison. New
`image.lazy.gatedTask` counts valid requests prevented from loading; `lazy.nilTask`
continues to mean a nil request. The expected test is fewer task restarts and
stable image presentation on warmed gate toggles, not a guaranteed numerical
speed-up. Build 40's raw capture is retained locally for the matched comparison.

Build 41 compiled successfully with the same Release tvOS build command and
`CURRENT_PROJECT_VERSION=41`. The app and Top Shelf extension retained version
0.14.3, their existing bundle identifiers, signing team and shared Keychain
access. Signature verification passed before installation in place on Living
Room. Its input-triggered image capture ran for 90.04 seconds. blurbery reported
that lag still developed around the third-last row and remained afterwards.
Diagnostics were then disabled for a separate normal-use check. blurbery
confirmed that the lasting lag still developed without diagnostics, so it
cannot be dismissed as capture overhead.

The captured mechanism changed as intended, but the remaining lag is unresolved:

- Across the complete runs, non-nil lazy task starts fell from 750 in build 40 to
  164 in build 41; nil tasks fell from 646 to zero. Build 41 recorded 108 cell
  appearances, 40 gate enables and 38 disables. VividLazyImage body evaluations
  fell from 2,792 to 1,052. These totals are descriptive, not a controlled speed
  ratio: focus events differed (262 versus 210), and build 41 included an early
  vertical traversal before the across-row test started around 35 seconds.
- During build 41's warmed 79–85 second descent, four enables and four disables
  produced 116 CachedAsyncImage and 116 VividLazyImage body evaluations, but no
  new lazy tasks, image flights or cell appearances. Stable request identity
  removed the task restarts; gate-driven leaf invalidation still occurs.
- That warmed interval's display-link callback median/p95/maximum was
  21.25/39.96/48.80 ms. These are callback intervals, not GPU presentation times.
  The 85–90 second tail returned to 20.00/20.05/20.78 ms. No repeated restoration,
  Spotlight alignment or feed/collection-row body loop accompanied the later
  lag. This does not exclude leaf layout or rendering costs during movement.
- All 157 image flights completed, with no recorded abandoned completion,
  waiter cancellation or memory warning. Sampled active flights peaked at two.
  The worst one-second decode-queue p95 remained below 1 ms for both priorities.
  Sampled memory peaked at 132.8 MiB. There is still no evidence here for changing
  network/decode concurrency or adding cancellation to address warmed scrolling.

Gate timing remains a separate follow-up candidate, not a proven remaining
cause. The successful build and reduced task churn do not establish that the
user's persistent-lag reproduction is fixed. No new UI tests were added.

### Build 41 Instruments follow-up

The next review proposed releasing distant bitmaps at vertical idle and an
Animation Hitches capture. The two-line release sketch is not a valid isolation
test as written: clearing `loaded` still permits VividLazyImage's synchronous
memory-cache image and CachedAsyncImage's warmed fallback to render. Also, the
existing outer-feed phase callback is inside the diagnostics-only modifier;
production scheduling cannot depend on that callback without moving it. No
bitmap-release or gate-timing change was applied for this measurement.

An unchanged Release build 41 (`27aab10`) ran on Living Room with in-app
diagnostics disabled. After restoring Xcode/Instruments device discovery, a
bounded 90-second `xctrace` recording used **Animation Hitches** plus **Time
Profiler**. Process-specific attachment failed, so the capture used
`--all-processes` on that Apple TV; the analysis below filters to VividTV only.
blurbery reproduced the Down/Left/Right traversal and reported that lag remained.
The recording finished successfully and the local trace is retained for review.

- Instruments emitted 413 Vivid hitch records between 28.57 and 65.31 seconds,
  totalling 9.38 seconds of reported hitch duration. System-level duplicates
  were excluded. Of these, 364 were labelled only “Potentially expensive app
  update(s)”, one combined app-update/render/GPU warnings, two had render-only
  warnings, and 46 had no potential-issue label. These are Instruments' heuristic
  warnings, not proof that every hitch has exactly one cause.
- In the active 28–66 second interval, Time Profiler recorded 21.56 seconds of
  sampled Vivid main-thread weight. `_UIHostingView.layoutSubviews()` appeared
  in 14.40 seconds (66.8%), `CA::Transaction::commit()` in 15.69 seconds (72.8%),
  and `AG::Graph::UpdateStack::update()` in 14.17 seconds (65.7%). These are
  inclusive, overlapping stack weights; they must not be added together.
- The hosting-layout path leads through `ViewGraph.updateOutputs(at:)`,
  AttributeGraph updates and SwiftUI layout/display-list work. The samples also
  contain focus-effect geometry and ForEach graph updates. This establishes
  substantial SwiftUI hosting/graph work despite flat top-level body counters;
  it does not identify which particular root or hosted card causes that work.
- Main-thread sampled weight fell to 52 ms during 70–80 seconds and 45 ms during
  80–90 seconds. This again supports work during interaction rather than a queue
  continuously draining after input stops. Profiling overhead means these
  absolute timings are not a clean performance benchmark against prior runs.

The next investigation should isolate the hosting-layout invalidation path.
This trace does not justify declaring GPU texture volume, distant bitmap
retention, pill materials, or image concurrency the dominant cause. A correctly
bounded distant-artwork experiment remains possible, but it must suppress both
cache display paths and account separately for layout and rendering effects.
No runtime source, card design, Spotlight behaviour or cache policy changed in
this follow-up; no new build was needed, and the recorder is stopped.
