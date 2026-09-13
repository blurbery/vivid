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

Media cards across Home, Search, Movies, Series, For You and detail pages use SwiftUI’s native `.card` button style, including collection posters, episodes, trailers and cast. The system owns their focus lift, shadow and animation; cards add no custom focus scale, shadow or animated artwork border. Resume progress is inside the artwork button so it moves with the native effect. Trailer and cast captions sit outside the native card button; its effect follows only the thumbnail or circular portrait. More Like This uses the same poster size preference as Home, including its loading placeholders. Watched and current-episode indicators remain content status cues. Full Home caching and card loading behaviour are unchanged. The spotlight presents its large slides as individual native `.card` buttons in a horizontal scroll view, preserving the 60-point side margins, 22-point card spacing and neighbouring previews. The system moves focus and scrolls between cards. Automatic rotation and ambient artwork tint remain active, and the carousel remembers its current card when returning from a detail page. Cold entry centres card 1 in a fixed strip of loop copies, with the last card already visible on its left. Native focus handles left and right movement. After crossing a loop boundary and finishing the scroll, the carousel aligns and focuses an equivalent copy of the same slide without animation. The logical slide index, active pill and countdown are unchanged by that repositioning. Cards are not inserted or removed during navigation. Initial placement is immediate. Startup, profile selection and login preparation must finish before the first six-second countdown can start on visible, authenticated Home, with the first card centred, focused and its artwork ready. Cache readiness alone cannot advance the carousel during initial placement. The rotation countdown resets only when the slide changes; temporary visibility or scrolling pauses retain elapsed time, and returning focus to the same slide does not reset its counter. Loop copies keep stable identities for the life of the carousel. Each root owns its own sub-tab selection. A focus move within Movies must not change Series or For You. Keep card identities stable across paging and artwork eviction. Home's experimental spotlight retains a 580-point layout height; its focus motion is controlled by the system. Down enters the first row's remembered card, using the first card before any visit. Settings uses one navigation stack for pushed category/account pages; avoid nesting another stack in a pushed Settings page.

Home uses the discovery feed. Its visible rows reserve a stable card-strip height using the current Home card size and caption setting. Poster and landscape rows retain different artwork heights; missing metadata still reserves its caption line. Cards align at their top edge and row headings reserve one fixed line. The feed also reserves the exact combined height of its displayed rows using those same dimensions, so off-screen lazy-stack estimates cannot change the vertical scroll range during navigation. Home Sections visibility and ordering are applied before layout, so hidden rows leave no empty space. This sizing is scoped to Home-style feeds and does not change detail rails, Spotlight or caching. The standalone recommendation route uses the same rows without a spotlight. The full-screen marquee and its focus callbacks and backdrop rendering have been removed. The independent Home spotlight retains its own artwork and metadata. Home retains its existing lazy row layout, artwork presentation and full metadata cache. Row ownership is observed by the affected rows and a separate artwork worker, without making it a dependency of the entire feed. Startup warms row artwork without fetching the removed marquee’s first-item backdrop, logo or tint; landscape episode cards and the independent spotlight retain their artwork. tvOS startup no longer prefetches the former Recommendations feed, library-section landings, legacy Browse page or first Series detail. Current Movies, Series and For You pages load through their own caches when opened; Home and profile warmup remain active. Spotlight keeps its artwork and detail cache but no longer preloads series seasons or episode lists. Its full Home snapshot also retains versioned subject-crop decisions (including no detected subject) and sampled tint colours by artwork URL. tvOS prepares current Spotlight backdrops sequentially and shares in-flight analysis with visible slides. Preparation updates do not invalidate the Home view; removed artwork and Spotlight cache clearing discard associated records. Existing snapshots remain readable. Image decoding and GPU presentation still occur after a cold launch. Home has one visibility-driven load loop on tvOS, skips publishing unchanged rows and writing unchanged snapshots, and retries missing artwork without queuing already-warmed startup card images. The unused row warmer and unreachable personal-root shell have been removed. The tvOS bar supports Search, Home, Movies, Series, For You and Settings/Profile only. Music, library shortcuts, Recommended library landings and their dropdown focus machinery are removed, including their tvOS customisation options. Shared saved menu data remains compatible with other clients.

Local Home diagnosis can be armed with the `--home-scroll-diagnostics` launch argument. The `com.blurbery.vivid.home-diagnostics.start` Darwin notification starts a 60-second capture; the corresponding `.stop` notification ends it early. The capture records scroll geometry, row positions, focus indices, display-link callback timing, CPU usage and process memory in `Library/Caches/vivid-home-navigation-diagnostics.json`. It does not record media titles, artwork URLs or account details. Display-link timing measures app callbacks, not GPU presentation time. Without the launch argument, the diagnostic observers remain inactive.

The tvOS native-background trial removes explicit black page fills from the root shell, Home, Search, library grids and For You. Shared page-backdrop views retain transparent, non-interactive layout surfaces where a stack needs its full-page extent. Dark appearance, safe-area rules, native focus targets and the 200 ms tab crossfade remain unchanged. Artwork tints, image masks and playback backgrounds retain their existing rendering. Settings uses a separate opaque slate canvas across its pages and About presentations to hide underlying content without a black screen. This isolates plain page fills; it does not establish a navigation performance improvement.

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

Settings uses an opaque, subtle slate gradient with lighter grey control groups, inset separators and a white focus highlight. The overview has a Profiles header above the existing circular profiles, without a surrounding filled panel, followed by a Settings header above separate category cards with 10-point gaps. Secondary controls retain joined rows. The 812-point column, page alignment, profile focus targets and editing controls remain in place.

Home Screen, Home Sections and Tab Bar editors push onto the existing navigation stack. Each has one white page heading; Home Screen and Home Sections retain their Done buttons and saved-value actions. About and its Privacy, Licences, Acknowledgements and Contact pages use the same opaque Settings canvas. Privacy and Licences are full-page reading presentations, with no dark inset popup or parent-page bleed.

Option rows use SwiftUI `Menu` with the existing preference bindings and a checkmark on the saved choice. tvOS owns opening, dismissal and focus return; the old full-screen custom picker and its manual focus restoration are removed. Category back navigation still returns to its triggering category. Keep page surfaces non-interactive so they never enter the focus graph.
