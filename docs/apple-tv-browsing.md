<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Apple TV Browsing</h1>
<p align="center">Responsive navigation, artwork and series rails.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid's Apple TV Home uses a discovery spotlight above collection-based media rows on the selected app theme described in [App Design](app-design.md#appearance); with Theme Mode set to Spotlight Only and a spotlight on Home, Home's first screen sits on a backdrop in the current slide's colour and the theme returns below it.
With Adaptive, every root page sits on a backdrop in the colour of whatever last had focus.
The Library tab holds every library with Watchlist, Favourites and Collections, and each library opens on its own page.

## Home and discovery spotlight

- The spotlight contains at most ten unique items, drawn in turn from up to three selected Home rows.
  New selections start with the first three populated rows.
  Configure these separately from row visibility in Settings → General → Spotlight.
- The spotlight uses separate rounded cards and shows one at a time: the cards either side rest just off screen and only come into view while the carousel slides.
  Each slide is a native focus target in a horizontal scroll view, with a fixed decorative gradient outline and no focus enlargement, parallax or colour glow.
  The system owns directional focus and scrolling.
  Automatic rotation remains on a six-second timer; each automatic advance uses a 0.45-second transition, disabled by Reduce Motion.
  Rotation stops the moment a slide is pressed, and an advance already under way snaps back to the pressed card without animation, so the zoom leaves from and returns to the card that was chosen.
  It resumes once Back has landed on Home, or after two seconds if no page opened, and the card then gets its full six seconds.
  Each card's saved logo and backdrop record the slide they were drawn for, so a card whose slide has changed since never flies an older slide's artwork, and the flight back is dropped if Search or another page replaces the one that opened, or Vivid resets to Home, the profile picker or sign-in.
  Its layout height is 785 points, with no page dots under the cards.
  Each card instead carries a small pill in its bottom-right corner, 80 by 6 points and 48 points in from both edges, that fills over the card's six seconds, so it's clear the spotlight moves on by itself.
  It stops while rotation is paused and carries on from where it was, starts again from empty when the slide changes, and travels with its card.
  Cards before the current one show a full pill and cards after it an empty one, so moving forward the card leaving goes out full and the one arriving comes in empty; moving back, the card leaving empties as it goes.
  Each wait is one linear animation rather than a per-frame update.
  The pill is hidden when there is only one slide and while VoiceOver is on, since the spotlight doesn't rotate then.
  With Settings > General > Appearance > Theme Mode set to Spotlight Only (the default, Apple TV only), Home's first screen sits on an opaque backdrop in the current slide's colour instead of the theme: nearly black at the bottom left, rising to a dim shade of the colour at the top right, with a matte finish.
  The colour is the artwork's main colour rather than a plain average, which mixes hues into a muddy grey: a small copy of the artwork is sorted into 24 hue bins weighted by how colourful each pixel is, the strongest run of three neighbouring bins (about 45 degrees of hue) wins and only its pixels are averaged, and artwork with little colour leans back towards its average so black and white images stay neutral.
  The backdrop keeps that colour saturated all the way into the dark corner, lifts hues that look dim at the same brightness (blue, red and purple) by up to 30% so they match bright ones, and keeps the top right a soft lift rather than a sheen.
  A fixed, faint grain tile sits over it to give the matte look and break up banding; it doesn't animate and fades with the colour.
  A slide with no saved tint has it worked out once, off the main thread, by the same small image load the focus outline's tint uses (the outline uses this colour too), and the backdrop keeps the previous colour until it is ready.
  Tints saved by earlier versions are worked out again.
  A slide with no artwork, or whose tint can't be worked out, fades the backdrop out to the theme rather than keeping the last slide's colour.
  A new slide's colour fades in over the old one across 1.6 seconds (at once with Reduce Motion), and only opacity animates.
  The backdrop is part of the scrolling page: it is solid for the first 1,100 points and fades out over the next 520, which are off screen until Home scrolls, so the theme returns without an edge.
  Slide changes update only the backdrop, not the Home feed.
  Theme Mode is a row under Base Theme that opens an Off, Spotlight Only and Adaptive menu.
  Its one-line description follows the chosen mode: Off says the background stays on the Base Theme, Spotlight Only that it matches the Spotlight's colours, and Adaptive that it matches whatever has focus.
  It replaced an On and Off Spotlight Gradient row, and anyone who had that off starts on Off.
  Off shows the base theme and looks up no backdrop colour, though the focus outline's tint is still prepared for each slide; Adaptive is described below.
  A Home without a spotlight has no backdrop.
  The logo, the metadata line and the overview sit on the left of the card, all starting 100 points from the screen's left edge, the same as the detail pages' logo (their heading sits beside the poster), so the logo flies straight up when a title opens.
  They sit over a dark glow from the card's bottom-left corner that keeps them clear of bright artwork.
  The logo fits within 600 by 200 points with a soft shadow, and its transparent margins are trimmed when it loads, so logos with empty space in their image still sit right on the metadata line.
  A movie's or series' metadata line is the detail pages' heading: its type, up to two genres and the content rating in an outlined badge, with no year, runtime or score (a series doesn't show its season count, which the spotlight doesn't have).
  An episode's line keeps its own format: Episode, its episode code, title and runtime, then its content rating.
  Under them, the item's overview is left-aligned, 760 points wide and up to three lines.
  When the whole overview won't fit, the slide shows as many complete sentences as do, so a long overview ends at a full stop rather than mid-sentence.
  Only a first sentence too long for three lines on its own still ends in an ellipsis.
  An item without an overview shows none.
  Selecting a slide zooms its detail page out of that card, and Back zooms it back in; each carousel position is its own zoom source, so loop copies of a slide stay distinct.
  Over the zoom, the card's backdrop opens out to the full screen as its corners square off and its shading clears, the logo flies from the card to the page's logo corner, and the page's text, poster and buttons fade in once the backdrop is in place; Back runs the same in reverse.
  These are copies drawn above the app (`TVSpotlightLogoFlight`): the move takes about half a second and the backdrop copy then fades out over a quarter of a second, so they're on screen for about 0.8 seconds.
  They're moved by Core Animation so they keep pace with the system zoom while the page is being built, with the real card and page logos hidden while they're in the air.
  The tab bar fades out and back in with the transition.
  Other ways into a detail page, and Reduce Motion, keep the standard push.
  On Apple TV the spotlight artwork keeps to the image's middle band, moved only as far as keeping the subject's top in view needs, so the zoom into the full-screen detail backdrop barely moves the image.
- With Theme Mode set to Adaptive (Apple TV only), one full-screen backdrop sits behind every root page (Home, Library and Calendar) in the colour of whatever last had focus, with the same shading and grain as Spotlight Only, whose Home backdrop is then off.
  While the Spotlight has focus it takes the slide's saved tint and follows the slides as they turn; a poster, a Continue Watching or Next Up card (also when they're combined into one row) or a collection takes the main colour of the artwork the card shows, a landscape card's series backdrop or thumbnail included.
  Studios & Networks tiles and the tab bar don't change it, so moving from the Spotlight to Studios & Networks keeps the Spotlight's colour.
  The backdrop sits outside the pages, so changing tabs keeps the last colour until something new takes focus, and cards on pushed pages (detail pages, Search, studio pages) don't change it.
  A library page pushed from Library is the exception: it opens already in the colour on show instead of fading in from the base theme, and its posters drive the colour while it is the page on show.
  When Home shows and nothing has set a colour yet, such as just after Adaptive is turned on, it starts on the current slide's colour.
  Focus has to rest on a card for 200 ms before its colour is looked up, so moving quickly along a row does no colour work for the cards it passes; the look-up reads the bytes the card already downloaded, makes a 48-pixel thumbnail off the main thread, keeps nothing in the shared decoded-image cache, and is remembered for the session.
  Cards report focus with a plain call and only the backdrop observes the colour, so a focus move never rebuilds a page, row or card, and with Off or Spotlight Only the call returns before doing any work.
  A new colour fades in over the one on screen across 0.9 seconds (at once with Reduce Motion), and one that arrives mid-fade starts from the blend that's showing, so quick moves never snap.
  Only opacity animates.
  The colour is kept while the player is open and starts again from the theme for a new profile or sign-in.
- Each card is 785 points tall and 120 points narrower than the available viewport, with 60-point gaps that match the side margins, so no neighbouring card shows at rest.
  Server backdrops fill the card without stretching (for an episode, its series background when one is known, the same as Home's Continue Watching and Next Up cards; a card keeps the artwork it was built with), using the existing face/head, person and saliency detection to guide cropping.
  Wide framing can still trim the image, especially with multiple subjects; detection cannot guarantee perfect composition.
  There is no spotlight TMDB lookup or blurred neighbouring-image overlay.
  Configured TMDb access supports trailers and Emby IMDb-to-TMDb identity resolution; the spotlight makes no TMDb requests.
  The owner approved the sliding card design on Apple TV, and later the one-card-at-a-time layout, the countdown pill, Spotlight Only (first called Spotlight Gradient) and Adaptive in this form.
  The owner accepted the native focus conversion on Apple TV at `00177cf`.
- Selecting a slide opens its page.
  An episode with a known series and season opens its series directly on that episode, the same as its Continue Watching card, so the page doesn't open the episode first and then swap to the series.
  While the series loads, its page shows the background the card was showing: the series background, or on Silo the one Vivid looked up.
  On Emby that's the episode's backdrop, which is the series background unless the episode has one of its own.
  An episode missing its series or season opens its own page.

- Moving Up from the first row to the eagerly mounted spotlight uses native directional focus and scrolling, without a forced focus handoff or manual scroll animation.
  Explicit focus requests remain for tab-bar entry and detail returns.
  While a spotlight exists, the first row does not keep a high-priority default-focus preference.
  Remembered horizontal card selections do not invalidate the whole Home feed.
  The owner reported smoother navigation after the native `.card` conversion and accepted the resulting Home behaviour on Apple TV.

## Studios & Networks

- Home pins a Studios & Networks row directly under the spotlight, without a heading.
  With the spotlight turned off, the row tops Home and takes focus first.
  Six logo tiles span the spotlight card's width with 30-point gaps, and the row scrolls sideways to the rest, up to 20. Every tile is built up front, so focus can return to one scrolled out of view.
  Tile size is fixed.
  Without a signed-in account and profile, or when no brand has enough matches, the row is absent and the spotlight hands focus straight to the first row as before.
- Down from the spotlight lands on the row, returning to the last tile used; Up, Down and swipes out of the row use native focus, as between other Home rows: Down lands on the card below in the first media row and Up returns to the spotlight.
  With the spotlight turned off, Up from the row returns to the top menu.
  Returning from a brand page puts focus back on the tile that opened it.
  An earlier manual Down handler raced native focus on Siri Remote swipes and pulled focus to the remembered Continue Watching card, so the row no longer claims focus for vertical moves.
  It is not a Home section: it is excluded from the six-row limit, the Home Sections editor, Spotlight sources and Top Shelf.
- The catalogue covers Netflix, HBO, Apple TV, Disney+, Prime Video, Hulu, Peacock, Paramount+, Stan, BritBox, AMC, FX, Crunchyroll, Hallmark, Pixar, Marvel Studios, A24, Lucasfilm, DreamWorks, Studio Ghibli, Sony Pictures, Warner Bros., Universal, Walt Disney Pictures, DC and 20th Century Studios.
  TMDb supplies each logo, shown as a white silhouette; the lettering of Marvel's block and the Warner Bros. and DC shields is knocked out, the near-square shields and the 20th Century Studios logo may use a little more of the tile's height so they don't look smaller than the wide wordmarks, and Apple TV uses a wordmark in the system typeface because its TMDb logo carries the Apple mark.
  The wordmark is drawn once and scaled like the logos, so its letter spacing is the same on every tile size.
  Sony Pictures' one-line logo is redrawn from the full-size TMDb image with SONY stacked above PICTURES (scaled to the same width) beside its emblem, so it reads at tile size; if the logo ever stops splitting into an emblem and two words, it's shown unchanged.
  Saved results that predate a newly added brand are matched again on the next load instead of waiting for the daily refresh.
- Each brand reads up to 100 popular series and movies from TMDb discover, and a network reads 200 films.
  TMDb's weekly trending lists are read whole, about 10,000 series and 10,000 movies, once for every brand: a smaller brand's titles sit far down them.
  The relay answers them in 20 blocks of 500 titles each, cut down to what matching needs, four at a time.
  A list counts only when every block arrives, as a gap would move later titles up; otherwise each brand keeps its trending titles from the last refresh, and Vivid reads only the trending lists again when Home or a brand page next loads an hour or more later (at most once an hour after that) and matches them with the saved library, instead of waiting a day for a full refresh.
  Series come from the network or company, studio films from the company, and network films from the US streaming lists, which are the most complete.
  Stan only streams in Australia, so its films come from the Australian list.
  BritBox mostly streams BBC and ITV series, and TMDb credits it with only a handful of its own, so its series come from its streaming list as well, and so do Crunchyroll's, as TMDb credits it with only a handful of the anime it streams.
  A service with several plans counts all of them (Peacock Premium and Premium Plus; Paramount+ Essential and Premium), BritBox and AMC+ count their Amazon, Apple TV and Roku channels where TMDb lists them, Crunchyroll and Hallmark+ count their other channels TMDb lists, and AMC also counts its own app.
  Hallmark's series come from Hallmark Channel and its films from Hallmark+.
  Sony includes its Columbia Pictures, Sony Pictures Animation and TriStar labels, Walt Disney Pictures includes Walt Disney Animation Studios, DreamWorks includes DreamWorks Pictures, Warner Bros. includes Warner Bros.
  Animation and Warner Bros.
  Television, DC includes DC Films and DC Entertainment, and 20th Century Studios includes 20th Century Fox.
  Only titles in the library are kept, matched by TMDb ID when the server lists one and otherwise by exact title and year; Silo list results don't currently include TMDb IDs.
  A brand needs six matches to appear.
- All in Your Library has no cap.
  It holds every library title the server tags with the brand, plus every TMDb match the server doesn't tag, and the match counts and automatic picks count the same titles.
  Silo sends each title's networks and studios with the library list, and Emby and Jellyfin keep a series' network with its studios, so a network counts both and a studio counts studios only.
  Each brand has a fixed list of names, matched whole and ignoring case, accents and spaces around them, so Disney Channel never counts as Disney+.
  The list is TMDb's names for the brand's networks or companies, plus older names a server may still use, such as Apple TV+, Lucasfilm Ltd., DC Comics and Paramount+ with Showtime.
  HBO also counts HBO Max and Max, FX counts FXX, DreamWorks counts DreamWorks Pictures and its television arms as well as DreamWorks Animation, and Warner Bros. counts every name that starts with Warner Bros., such as its Animation, Television and regional studios.
  BritBox also counts the BBC and ITV channels, because servers tag its series with the channel that first showed them; BBC America doesn't count.
  Hallmark counts Hallmark, Hallmark Channel, its Mystery (formerly Movies & Mysteries), Drama and Family channels, Hallmark+ (formerly Hallmark Movies Now) and Hallmark Media, which makes its originals.
  Servers rarely tag films with a streaming service, so most of a network's films come from its TMDb streaming list, which is why that list is read 10 pages deep instead of five.
  A film the server does tag with the network's name, as a network or as a studio, counts as well.
  A series a network only streams still isn't included when TMDb and the server credit it to another channel.
- A brand page shows the logo, then Popular TV Shows and Popular Movies (up to 20 each, at the Home poster size), then the All in Your Library grid.
  A filter menu at the end of the grid's heading row shows All, Movies or TV Shows (offered when the brand has both), and has Sort and Genre submenus.
  Sort offers the libraries' keys (Title, Date Added, Release Date, Year, Runtime and Resolution), newest added first to begin with; choosing the current key again flips its order, and the current key shows its direction as in the libraries' Sort menu.
  Genre narrows to one genre.
  The button shows the type and any genre, and is highlighted while either narrows the grid.
  Titles without a value for the sort go last in either order, and changing the type drops a genre none of its titles have, so the grid never empties.
  The choice lasts while the page is open.
  The menu is native, in the library pill style, and its heading row is a focus section, so Down from any rail card lands on the filter and Down again reaches the grid.
  The rails use the same reusable collection row as Home.
  The grid's first row is built up front so Down from the filter always reaches it; the rest is the grid Library's lists and library pages use, which builds rows as they near the screen, prefetches nearby artwork and redraws only the row that changes.
  The page only redraws when that brand's own rows change, not while other brands load or refresh, and the daily library read and TMDb matching run off the main thread.
  Both rows lead with the brand's titles in this week's TMDb trending list, in trending order, and fill the rest from its popular titles: network rows from titles with episodes aired or a release in the past 12 months, falling back to all-time popular when fewer than six match, and studio rows from their all-time most popular, because studios release few films a year.
  TMDb's trending list is one worldwide list with no network, studio or region filter, so a trending title counts for a brand when it's one of the brand's library titles (anything All in Your Library lists, or a title from its past-12-months list).
  Some brands have fewer than 20 library titles trending anywhere in a given week, such as A24's series or Studio Ghibli, and their rows fill up from popular.
  The rows leave out talk shows (TMDb's Talk genre) and anime (Japanese animation, by original language or country of origin), except on Crunchyroll and Studio Ghibli; All in Your Library still lists them.
  Rows with fewer than six matches are hidden.
- Settings > General > Studios & Networks has a Show on Home toggle, a live preview and pick grids with match counts.
  Hold Select on a preview tile to pick it up.
  It keeps the normal card focus look while every preview tile wobbles and the others dim slightly, and focus stays on it, so left and right move it and centre places it.
  Press Play/Pause to remove it instead; Menu leaves arrange mode.
  The wobble honours Reduce Motion.
  Six to 20 brands can be picked.
  While Show on Home is on, Done stays dimmed until the required number are chosen (six, or every brand that matches when fewer than six do), and Menu shows an alert saying how many more to choose (or to turn off Show on Home) instead of leaving, as iPhone and iPad hide Back until then.
  The preview shows six at a time and scrolls sideways, keeping a picked-up tile in view as it moves.
  Tiles that can't be picked (20 are already chosen, or a brand has fewer than six matches) are dimmed but still take focus and do nothing when selected, so every pick grid stays reachable even when none of its brands can be chosen.
  The pick grids aren't lazy, so Down from the networks always reaches the studio tiles instead of skipping to Reset to Automatic, and each row aligns at the top.
  Picks default to the 20 brands with the most matches; a chosen set is kept as chosen, topped up only when it drops below six, saved per server and profile and synced through the encrypted private iCloud vault.
- The first load starts while Vivid prepares Home, and TMDb's lists download while the library is read, with up to 12 TMDb requests in flight plus four trending blocks.
  Movies and series are read side by side.
  For each, the first page gives its size and the rest load four pages at a time, so up to eight library requests run at once; a server that sends smaller pages than asked, or no total, has that type read one page at a time.
  After a sign-in or profile setup, Home waits up to two minutes for it, so the row is there when Home first appears; a failure never holds Home.
  Switching to a saved profile doesn't wait.
  Results and the library index are cached on disk per server and profile.
  Home shows the saved row instantly and refreshes in the background once a day, keeping the saved row while it works.
  Watched ticks on brand pages come from that saved data, so they can lag by up to a day.
  Silo signs artwork URLs for a few hours, far less than the saved data lasts, so shortly before the first saved poster URL expires (checked when Home or a brand page appears, including after the app has been left open) Vivid quietly re-reads the library and swaps fresh poster URLs into the saved results without matching with TMDb again.
  That read also brings in titles the server has tagged since, so on Silo new additions reach All in Your Library within a few hours instead of a day.
  The daily refresh doesn't reuse a library index whose posters have expired, or one saved before server tags were read.
  When the saved posters have expired or are about to by the daily refresh, they take the fresh library read's links as soon as it finishes, before TMDb is matched, so they don't stay blurred if matching is slow or fails.
  If the library read itself fails, the posters keep their links until a visit after the 15-minute cooldown reads the library again.
  Results matched by an earlier version are matched again on the next load, keeping the saved row while it works.
  Emby and Jellyfin poster URLs don't expire, so they skip this.
  Account removal deletes the profile's cached files.
  The first load reads the whole library once, which can take a minute or two on a large library (Home stops waiting for it after two minutes); the settings page shows live progress and asks to keep Vivid open.
  The library index is a SQLite database on the device, written a page at a time as the library is read, so the read's memory doesn't grow with the size of the library: on a simulated library of about 250,000 titles the whole app stayed under 200 MB throughout.
  A read only replaces the saved library once every page has arrived.
  Each page is saved with how far the read has got, so a read cut short (the app closed, or Apple TV restarted) carries on from there if it starts again within an hour of the read starting, and the new database only replaces the saved one once it's complete, so Search, brand pages and collection rows keep using the last complete read meanwhile.
  The read and the TMDb matching wait while the player is open and carry on when it closes.
  The saved results keep each brand's All in Your Library as title IDs; a brand page reads its titles from the database when it opens.
  Results are written to disk a brand at a time.
  Updating from a version that kept the library as JSON keeps the saved row on Home while the first load runs (unless its saved results are over 24 MB; if the app closes while they are read, they are dropped rather than read again), then removes the old files.
  If the new file can't be saved, the old results stay for the next launch to try again.
  If the system clears the database but not the results, the library is read again, at most every 15 minutes.
  If Vivid crashes or is closed while open during two loads in a row, as tvOS does when a very large library uses too much memory, Studios & Networks stops loading on its own so Vivid can still open.
  A saved row stays on Home; with no saved row, the settings page shows the load failed with Try Again, which starts it again.
  An app update also starts it again, and so does a day passing since the last one was cut short; if that one is cut short too, loads stop again.
  Only the process that was running the load counts, and a load cut short while Vivid is in the background (closed by the system or crashed there), or while the player is open (when the load is waiting), doesn't count.
- Search uses the saved library index too, matching titles on the device with typos, spacing and punctuation allowed, so the library is read even when Show on Home is off.
  Titles brand matching can't key, with neither a TMDb ID nor a year or whose keys another title already holds (such as a second copy of a film), are kept in it for Search.
  See [Search matching](server-connections.md#library-index).

Home applies the shared six-section limit to Jellyfin as well as the other providers.
Emby and Jellyfin each offer their own Combine Continue Watching and Next Up option.
When enabled, Spotlight’s Continue Watching choice includes both sources, interleaved within the ten-item limit; the Home row retains resume ordering and removes duplicate Next Up items.

## Collections row

- Home pins a Collections row below the last server row.
  Whenever it shows, it is the bottom row, and it sits outside the six-row limit.
  It holds up to 20 collections as posters at Home's Large size with the Home caption setting (the second line is the collection's title count), and selecting one opens the collection's page.
  Down from the last server row and Up back are native, and returning from a collection's page puts focus back on the card that opened it.
  The row reserves the same height as a poster row and uses the same nearby-row artwork window.
  It only appears on Home, and it is absent when Show on Home is off, nothing is chosen or the server has no collections.
  It also needs something else on Home: with every Home row hidden and no Spotlight, Home shows its empty state without it.
- The list is the server's own collections (what Library's Collections shows with Source set to Server) plus, on Silo, the profile's own personal collections (what Source set to Mine shows).
  Emby and Jellyfin return every box set in one request; Silo is read from each movie, series and mixed library, and a collection that appears in more than one library is shown once.
  The profile's own collections are read from its collections list; other profiles' shared collections are left out.
  A library the profile can't see (Silo answers it with Library not found) counts as having no collections.
  The list is cached per server and profile, so Home shows the row straight away.
  Saves, reads and deletions of that cache run in order, and removing an account deletes its cached list, so a save still under way can't bring it back.
  Home reads it again when it is 30 minutes old or a signed Silo poster is within 15 minutes of expiring, and pulling to refresh on iPhone and iPad or opening the settings page reads it at once.
  After a failed read it waits 5 minutes before another visit tries again, so a slow server isn't asked on every visit; pulling to refresh and the settings page still read at once.
  If the server turns down one of the list's posters (403, 404 or 410, as when a signed link has expired or the poster was replaced), Vivid reads the list again by itself, as pulling to refresh does, so the posters get new links instead of staying blurred.
  That happens at most once every 5 minutes, however many posters fail at once, and not for a link the last such read brought back unchanged.
  A read already under way counts as that read; if it fails, Vivid reads the list again, and if that fails too, the next refused poster after 5 minutes tries again.
  A timeout or rate limit doesn't count.
  If one Silo library or the personal list fails to load, the others still show, with the previous list's collections from what failed kept.
  That partial list isn't cached or treated as fresh, so the next Home visit reads the server again, and editing choices meanwhile keeps the ones from that library.
  Collections removed from the server drop out of the row.
- Settings > General > Collections has a Show on Home toggle, a live preview of the chosen posters, the collections A to Z, skipping a leading The, A or An, in carousels of 20 (on Silo, the profile's own collections come first, then the server's, each A to Z), and Reset to Automatic.
  Select a poster in a carousel to add it to the row or remove it; up to 20 can be chosen, and once 20 are chosen the others dim and do nothing.
  Hold Select on a preview poster to pick it up: every preview poster wobbles, left and right move it, centre drops it and Play/Pause removes it; Menu leaves arrange mode.
  The wobble honours Reduce Motion.
  The carousels show posters only; VoiceOver reads each name.
  They are built up front so Down always reaches the next carousel and then Reset, and each builds the posters near the screen as it scrolls.
  Posters load for the carousels around focus and stay loaded once shown, so scrolling back never blanks a row.
  Automatic shows the 20 server collections with the most titles, ties A to Z skipping a leading The, A or An, with Silo's smart collections (which have no count) last.
  The profile's own collections only show when chosen.
  Choices are saved per server and profile and synced through the encrypted private iCloud vault.
- On Emby servers before 4.10.0.4, the user's Emby Home settings can also add Emby's own Collections row, so two rows with that name can appear.
  Vivid doesn't hide the server's row.

## Device metadata cache

Settings → Metadata lists Spotlight and the enabled Home rows, including Continue Watching.
Each entry has a separate clear-cache button.
Only enabled Home rows are retained, capped at twenty items per row; the spotlight is capped at ten.
Disabling a row or receiving refreshed content removes obsolete entries and artwork references.

`TVHomeMetadataCache` stores versioned snapshots in the Apple TV cache directory, isolated by server and viewing profile.
A snapshot saved in another language isn't used, because it holds row titles Vivid named itself.
Cached rows, libraries and spotlight details hydrate the existing response cache before network refresh.
Artwork uses the local `VividImagePipeline` cache with bounded prefetching.
These are disposable caches: tvOS may reclaim them, and clearing them does not remove server media or watched history.

On iPhone, iPad and Apple TV, repeated artwork lookups reuse the last calculated server/account/profile cache key without changing its on-disk format.
Home snapshot saves combine queued updates for the same account; writes already running finish normally, and reads and account deletion preserve queue ordering.
No debounce delay is added, and in-memory Home updates remain immediate.
These changes reduce redundant work; app performance and playback still require device verification.

Cold launch and profile/login preparation read and decode the Home snapshot asynchronously on its serial I/O queue before routing to Home.
First paint still hydrates from memory and does not wait for fresh server content.
Concurrent preparation shares one read; an intervening activation, clear, deletion or profile change invalidates that result.
Direct callers outside these preparation paths retain the synchronous fallback so cached first paint remains available.
The snapshot format, size cap and Settings clear/save controls are unchanged.

Silo, Emby and Jellyfin artwork requests on iPhone, iPad and Apple TV share an in-flight transfer only when both the full URL and account/profile scope match.
Display, crop, palette and disk warming can reuse those bytes while retaining separate size-specific decodes.
Signed URL queries remain part of the key.
A cancelled consumer does not cancel consumers still using the transfer; cancelling the last consumer or explicitly clearing its account cancels the transfer.
Completed bytes use the existing HTTP cache, and retry budgets, download limits and file-URL handling are unchanged.

Home uses a vertical `VStack` of reserved-height `VividCollectionMediaRow` rails backed by CollectionHStack, with the full metadata cache, expanded artwork cache and nearby-row warming.
Row dimensions follow Home Sections visibility and the caption setting; Home posters are always Large.
The six-enabled-rail limit excludes Spotlight; empty enabled rows reserve a slot.
Row focus updates are isolated from the feed.
The owner accepted the cleanup and native card effects on Apple TV.

The tvOS discovery Home raises the decoded artwork cache budget to 320 MiB on Apple TVs with more than 3.5 GB physical memory, or 192 MiB on smaller models, with a 600-image count limit.
It warms one screenful of exact display-sized artwork for the focused row, the next three rows and the preceding row, each starting around that row's remembered card, using two concurrent requests.
It restores the normal cache budget and cancels queued warming when Home disappears, the app leaves the foreground or a memory warning arrives.
Existing memory-pressure and playback cache clearing remain.
These are cache budgets, not measured app memory or strict process limits.
Metadata and disk caching remain separate; layout and drawing still occur.
The owner reported smoother navigation, but peak memory and a controlled performance comparison have not been measured for the final source.

Home hydrates its snapshot immediately, then follows the provider-specific [Home refresh policy](server-connections.md#home-refresh).
Jellyfin polls every ten seconds while Home is visible and active; Silo refreshes every thirty minutes for signed artwork renewal; Emby has no periodic Home timer.
Final playback-progress writes and watched-state changes also request updates.
Hidden requests wait until return, and stale responses cannot replace newer state.
Continue Watching advances or disappears once the server response reflects the change.
Cached startup is intended to reduce waiting, but no before/after device benchmark is recorded for this revision.

## Tabs and catalogue pages

The tab bar hangs from the top edge of the screen like a notch and contains Search, Home, Library, Calendar and the profile/settings avatar as available.
Library replaces the earlier Movies, Series and For You tabs.
It is always shown and can't be hidden, because it is the only way to the libraries and the personal lists.
Calendar has its own show/hide eye in Settings > General > Tab Bar, outside the reorderable destinations, and when shown always sits just after Library.
It shares the profile setting with the iPhone and iPad Calendar tab.
Dividers separate Search and Profile.
While focus is below the bar it closes to Search, the selected tab's symbol in the highlight and the avatar.
Once the bar has focus the other tabs come back as their symbols, the same ones as on iPhone and iPad.
A tab shows its name only while it has focus, so opening and closing the bar change its width and nothing else.
Search opens from its magnifying glass to "Search" while it has focus, and the avatar gives way to "Settings", both inside the shared highlight.
One white highlight glides from tab to tab, the symbol fades out before the name fades in, and the whole bar follows focus on one spring animation (none with Reduce Motion).
Choosing a different tab closes the bar around it over 0.16 seconds and opens the page 0.19 seconds after the press, so the close doesn't stutter while the page is built; with Reduce Motion the page opens at once.
VoiceOver reads every tab's name.
Focusing a tab gives that individual control a lift.
The avatar opens Settings directly.
Root pages have no separate Vivid logo in the top-left corner.
The notch is dark glass with sides that flare out slightly where they meet the top edge, rounded bottom corners and a thin white outline along its sides and bottom that fades out into the top edge, so the notch grows out of the edge.
The selected or focused pill is a white outline with a faint fill rather than a solid white pill, and that one highlight glides between Search, the tabs and the avatar.
When Home, Library or Calendar is scrolled more than about 60 points from its top and the bar has no focus, the notch tucks down to just the current tab's symbol, slightly dimmed, keeping the faint selected fill but not the white focus outline, so it covers less of the page.
It opens again at the top of the page or when it takes focus, for example on Menu.
Home's spotlight, Library's row of libraries and Calendar's sub-tabs sit just under the notch (`VividTheme.Skyline.barTopInset` is 0).
On Home the gap between the notch and the spotlight is about 30 points, and the gaps between the spotlight and Studios & Networks and below Studios & Networks are 30 points.

Library opens on a row of library cards: every movie, series and mixed library, each once, as landscape cards the size of Home's Continue Watching cards.
Each card shows the library's own image, or its symbol on a plain tile when the server has none, with the library's name underneath as the server gives it, with nothing shortened.
Below the row are the Watchlist, Favourites and Collections sub-tabs the For You tab used to hold.
Selecting a library pushes a page with the library's name, the same native Sort, Filter and A–Z menus and the same seven-column poster grid the Movies and Series pages had, without the old category dropdowns or mixed Recommended/Browse landing page.
A mixed library such as Sports is one card, and its page shows movies and series together; it used to appear under both Movies and Series, filtered by type.
Movie and series libraries still ask the server for their own type; classification depends on the server's metadata.
A mixed library asks for every type, and its Filter menu adds a Type choice to narrow it to movies or series.
The library each Movies and Series page used to remember is no longer kept.

Holding Select on a library card starts arranging the row.
Every card rocks, Select picks a card up, Left and Right move it and Select drops it.
There is no save button: each move saves as it happens, and arranging lasts until Menu.
Each move starts from the saved order, not from the row as it was last drawn, so presses made faster than the row redraws each count.
While a card is picked up, Up does nothing.
Library cards draw their own focus: they grow and lift on a shadow with no system card platter, and a picked-up card grows a little more.
The other media cards keep the native card style.
The row's order is saved per server and profile and syncs through iCloud with the profile's other synced preferences, the same way as Home sections, so rearranging on one device rearranges the others, iPhone and iPad included.
Other devices pick it up on their next launch or when the app returns to the foreground, not live, and the last change wins.
A library added later appears at the end of the row.

Opening a library paints its saved first page straight away, then fetches that page again once and swaps the new one in behind the posters already showing.
The saved page is kept in memory until the app quits or the profile changes, and later pages are fenced to the time the first page loaded, so without this refetch a newly added title stayed hidden everywhere in the grid until the sort changed or the app restarted.
Coming back from a title or returning to Vivid with a grid on screen doesn't refetch, and once the grid has loaded past its first page it is left as it is, so your place in the list is kept; opening the library again, changing the sort or filter, or choosing a letter loads it fresh.

Sort, Filter and A–Z use native tvOS menus.
A–Z is available whatever the sort; choosing a letter switches that library to Title A to Z, as on iPhone and iPad.
Filters become available after their facets load, avoiding a partial menu that changes while open.
The menu owns focus while presented and restores it to its trigger on dismissal.
Up and Down between this control row and the grid use native focus, so Siri Remote swipes and clicks behave the same: Down from the row lands on the poster below, and entering the row returns to the last control used.
A pushed library page has no top menu above it, so it needs no boundary handler, and Menu goes back to Library.
An earlier version disabled the grid and sub-tabs while the row had focus and moved focus manually on clicks, which left swipes stuck on the row.

Below its library row, Library has Watchlist, Favourites and Collections sub-tabs, with no Sort control.
Each sub-tab has an independent native A–Z menu; choosing All restores the unfiltered list.
Collections has A–Z too: a name is filed by the same sort key that orders the grid, so a leading The, A or An is ignored, and "#" takes names that don't start with A to Z.
Watchlist and Favourites also have a native Filter menu left of A–Z (Show, Original Language and Anime), and Silo Collections has one in the same place (Source; Emby and Jellyfin have none), as described in [App Design](app-design.md).
Each sub-tab keeps its own filter and shows "Filter · n" when filters are on.
When Watchlist or Favourites has nothing to show and a filter or an A–Z letter is chosen, it says "No titles match these filters"; with neither, it says "Your watchlist is empty" or "Your favourites are empty".
Entering Library lands on the library row, on the library that last had focus or else the first; coming back from a library page leaves focus where the navigation stack restores it.
Up from the sub-tabs, Filter or A–Z moves to the library row natively, and Up from the library row hands off to the top menu.
With no libraries to show, entry lands on the current sub-tab and Up from the sub-tab row hands off to the top menu instead.
Up and Down between the sub-tab row and the posters use native focus, landing on the poster below and returning to the current sub-tab; only Up to the top menu is a boundary handler.
The sub-tabs and the Sort, Filter and A–Z pills, here and on Calendar, library pages and Studios & Networks, share one height and the top bar's dark glass with its outline; focus is the bar's white outline rather than a white fill.
A manual Down claim used to race native focus and made the grid jump to its first poster.
Collections combines movie and series collections, and on Silo adds this profile's own collections to User Collections, which comes first, above the server's Collections.
It paints cached per-library sections immediately, refreshes source libraries together and publishes each response as it arrives instead of waiting for the slowest library.
The library list is the account's, so it can include libraries the profile hides or isn't allowed; Silo answers those with Library not found, and they count as empty.
A library that fails to load leaves the others on screen, and the page only shows an error when nothing loads.
Posters load for the rows around the cards on screen; a card the lazy grid drops counts as off screen, so the window follows the scroll instead of staying on rows already passed.
When no card counts as on screen, as after returning from a collection, the window follows the remembered focus.
Catalogue grids use seven posters across, with deliberate space above the first row for focus enlargement.

Calendar is laid out like Library's lists, with Upcoming and Trending sub-tabs and a Calendar pill on the right where Library keeps Filter and A–Z.
Upcoming shows the same episodes as on iPhone and iPad (see [App Design](app-design.md)), as cards grouped by day, three across; choosing one opens the series.
Trending shows rails of series and movies coming soon with local date badges, and choosing a poster shows its date and overview.
The Calendar pill opens a month view of the page's window: on Upcoming, choosing a day with a dot scrolls to it; on Trending, it shows that day's releases with Show all to go back.

Search uses seven posters across the available safe-area width, without the previous extra horizontal insets or width cap.
The results sit closer to the Top Results, Movies and Series tabs.

### Siri search

A short press of the Siri Remote's Siri button anywhere in Vivid brings up Apple's dictation prompt.
Say what you want to watch and Vivid opens Search with those words in the field and the results showing, on Silo, Emby and Jellyfin alike.
Typing still works afterwards: the words can be edited in the search field like any other search.
Holding the button still opens Siri.

tvOS never gives apps the Siri button itself, so this uses App Intents' in-app search (`ShowInAppSearchResultsIntent`, tvOS 17.2 and later): tvOS runs `SearchVividIntent` with the spoken words, and Vivid hands them to its own `vivid://search?q=` link.
That link waits behind sign-in, profile selection and the background profile lock like a Top Shelf link, then Search replaces whatever screens were open, exactly as if Search had been picked in the top bar.
Back returns focus to the bar.
A playing video closes the way Menu closes it, so its progress is saved first.
Search resets to Top Results so an earlier Movies or Series filter can't hide the title.
A request with no words is ignored, so it can't close a video or the screens you're on.

Use a short tap.
A hold is handled by tvOS, which starts Siri; Vivid doesn't receive it.
There are no spoken phrases: an earlier build registered "Search Vivid" as an App Shortcut, but saying it to Siri on an Apple TV did nothing, so it was removed.

Validation so far: on 15 October 2026 the owner confirmed on an Apple TV 4K (3rd generation), tvOS 27.0, running a signed Release build of `83d8417`, that a short Siri press in Vivid brought up Apple's prompt and the spoken title opened Search with its results, and that "Search Vivid" spoken to Siri did nothing.
The tap still worked on a Release build of `6fa8bd8`, after the phrases were removed.
The `vivid://search` routing was also checked in the Apple TV 4K (3rd generation) simulator from Home, from an open Search, from a detail page, during playback and from a cold launch.
The prompt and speech recognition are Apple's, and depend on Siri and Dictation being available for the Apple TV's language and region and on Settings → General → Dictation.
Vivid receives only the resulting text. iPhone and iPad don't register the intent.

Library requests load seventy items at a time.
Artwork retention uses a moving ten-row window that follows visible rows, falling back to current focus before visibility is known.
It keeps a small look-behind and releases earlier decoded image references as scrolling advances.
Visible and upcoming posters are warmed before the look-behind, with two requests at a time; queue updates can refill evicted images.
Visible or focused catalogue cards always remain eligible to load, and distant cards release their image through the same image view without replacing its subtree.
Lightweight item metadata remains available for navigation; this is not a fixed total app-memory limit.
Seven-column catalogue grids request the next page with four rows remaining and recheck when a row becomes visible or a page arrives.
Native card controls, focus styling and layout are unchanged.
The owner confirmed that the installed scrolling follow-up resolved the Movies and Series focus/artwork issue.

Shared artwork loads retain a consumer for each visible image or prefetch request.
Cancelling one consumer preserves work needed elsewhere; cancelling the last consumer stops the shared transfer and skips any decode still queued.
Account changes continue to cancel outgoing work and prevent it from repopulating memory.
The same cancellation behaviour applies on iPhone and iPad.

Decoding older saved menus drops the retired Calendar entry while preserving supported destinations.
The Calendar tab described above isn't part of the saved menu: its own setting shows or hides it.
This does not modify any media-server backend.

## Startup and Settings

The removed marquee, legacy Browse/Recommended landings, music tab, pinned library shortcuts and tab dropdowns no longer run their former tvOS startup prefetch/cache paths.
Startup retains Home and profile warmup.
Home row artwork selection stays bounded, and already-warmed candidates are skipped before queuing.
Library and each library page load their own current-page caches when opened.

Cold startup uses Vivid’s two-piece Glide logo, with Reduce Motion and a static-logo fallback.
The pieces assemble once; when content is ready, the logo fades out before the destination fades in, following the [shared startup handoff](app-design.md#settings-and-startup).
Startup routing resolves local and private-iCloud account state, but does not wait for a full network population of Home.
A usable restored session can open Home, while no usable session returns to server selection instead of an old provider login.
Cached Home content can then appear while refresh continues.
Saved-account selection, iCloud deletion and PIN rules are described in [Server Connections](server-connections.md#saved-accounts-on-apple-tv-iphone-and-ipad).

Settings categories open separate native navigation pages with white headings and no repeated eyebrow.
Each Settings page shows its symbol in a tile before its heading, as on iPhone and iPad: category pages use their category's icon, and the other pages the symbol their iPhone page uses.
Section text and secondary actions use grey.
Diagnostics sits directly below Metadata and lists the reports kept on the Apple TV.
Send to Vivid sends them to the diagnostics relay, with a QR code as the fallback for emailing a summary; see [Diagnostics reports](app-design.md#diagnostics-reports).
About follows it as a main Settings category; it contains app version/build, the source commit, privacy, licences, Acknowledgements and Contact.
TMDb attribution is in Acknowledgements, without a duplicate About-page block.
Below its introduction, Acknowledgements also says that Vivid is independent and isn't made, endorsed or supported by Silo, Emby or Jellyfin; the line isn't focusable and sits above the cards, so it shows without scrolling.
The Contact page shows an email QR code.
Playback uses the same Intro & Credit Skipper toggle as mobile; Settings > Subtitles owns local subtitle language, behaviour and appearance.
The Episodes group also offers Hide Episode Spoilers, which covers episodes after the viewer’s position on the series and season pages as described in [Playback](playback/README.md).
The Audio group between Playback and Episodes holds Audio Language, Volume Boost, Boost Level (dimmed and skipped by focus while Volume Boost is off, like the custom subtitle appearance rows) and Enhanced Dialogue, as on mobile; see [Volume Boost and Enhanced Dialogue](cores/player-engine.md#volume-boost-and-enhanced-dialogue).
Playback and subtitle pages read Vivid’s local preferences without loading server-managed player settings.
On Who’s watching a ring around the saved-account avatar identifies the signed-in account, and Settings > Profiles ticks it.
Settings uses the selected app theme, neutral grey grouped panels, inset dividers and subtly outlined icon tiles.
The overview separates the joined Profiles panel from one joined category group; secondary pages use the same grouped treatment.
The TV retains its white focus highlight and existing control geometry.
General's Customise Tab Bar editor saves changes automatically and arranges only Home and Library with readable move controls, without a Pin Libraries section or Done button.
Home and Library always show and can't be hidden; Calendar keeps its own show and hide control below them.
The saved menu still keeps its Movies, Series and For You entries for other clients: moving Library before Home puts Home after all of them, and they keep their own order.
Its preview includes Search and Profile, which can swap ends without joining the main tab order, and Calendar in its fixed place.
The preview is the tab bar's own notch, drawn with the same views, playing on a loop: it opens, moves to the next tab, chooses it and closes around it.
With Reduce Motion it stays open on one tab.
Below the destinations, a Calendar section has its own eye, since Calendar isn't reordered with them; the crossed-out eye means Calendar is hidden.
Crash and problem reports are covered in Diagnostics.
Home timing/geometry capture is opt-in through a developer launch argument, as described in the focus guide; local player stats remain available.
The shared footer reads “© 2026 Vivid™”.
Privacy and open-source notices use matching scrollable panels with thin focus highlights; licence text is loaded off the main thread and split into readable focusable blocks.
Search inherits the same selected app theme.

## Detail pages

The tvOS movie and series pages retain the layout adapted from Apple's [media catalog sample](https://developer.apple.com/documentation/swiftui/creating-a-tvos-media-catalog-app-in-swiftui), with a curved, softly feathered material mask.
The native-only comparison (`ef2bc5d`) was reported smooth on Apple TV but lost the full-page transition.
The retained implementation uses the hero and shelf stopping positions, deriving the starting side from the native scroll context’s original target rather than a changing hero-visibility flag.
SwiftUI still supplies the scroll animation.
The owner approved this page lock on Apple TV; the complete approved design is saved at `checkpoint/tvos-approved-page-lock` (`bac9b7d`).
The blur boundary rises towards both sides and dips in the centre; the curved material boundary rises with native scroll progress until it covers the supporting shelves, and descends with the page on return.
The material no longer waits for a visibility-triggered fade.
The artwork remains fixed while the shelves scroll, and on the movie and series pages the logo stays fixed with it, as described under the series shelf below.
The earlier design let the main logo scroll away with its metadata and controls and faded a separate, smaller logo in at the top centre above the shelves; the owner confirmed that on Apple TV before replacing it.
Only the loading page still has that centred shelf logo: it fades in over 0.25 seconds once the page has scrolled past the hero logo, fades out over 0.08 seconds on the way back, and changes immediately under Reduce Motion.
The hero layout is described below; the loading layout matches it.
A broad elliptical contrast fade replaces the intersecting linear gradients rejected during Apple TV testing.
It moves upward and fades away with scroll progress, with extended-linear rendering intended to reduce banding.
Scroll-surface state is isolated from the content and focus state.
The loading page's shelf logo threshold follows the same position.
The previous pre-contrast design is preserved at Git tag `checkpoint/tvos-before-hero-contrast` (`6619b27`).
The owner approved this contrast and scroll-linked blur on Apple TV.
Apple's sample licence is retained in the source.
This is an adaptation of Apple's public sample, not the Apple TV app's private source.

The movie and series hero puts the title logo in the top-left corner, 100 points in from the top and left.
Logo images have their transparent margins trimmed when they load, so a logo's visible edge sits at that corner (the loading page's shelf logo is trimmed the same way).
The left edge is trimmed to where the logo turns solid (over half opaque), as long as that removes no more than 15% of its visible width, so a soft shadow or glow baked into the image doesn't push it in.
A logo with a deliberately faint left part keeps it, so its solid part sits a little in from the edge; the other edges keep anything more than faintly visible.
The poster sits under the logo, from the top of the heading line to the bottom of the action row, with the heading, synopsis, credit line, technical row and action row shifted right beside it.
The action row ends 100 points above the screen's bottom edge, matching the left margin.
A title without a poster keeps a plain tile in its place, and the poster's size is fixed rather than measured, so the details never move.
Pages with few shelves still scroll the whole hero away.

The action row (Play or Resume, Audio Tracks, Subtitles, Watchlist and More) shows one control wide with its label and the rest as circles, so the row keeps one width and nothing beside or above it moves.
The focused control is the wide one; the last control used stays wide while its menu is open and after Back, so opening a menu never swaps it for Play.
Play is wide when the page opens.
Icons stay fixed where they sit in the circle; a label is centred between the drawn edge of its symbol and the end of the pill.
The controls use the tinted glass of the iOS Play button with no fill, and the focused control adds that button's bright gradient rim at 2.5 points.

Series episodes form one native horizontal shelf across seasons.
On the movie and series pages the hero's logo stays fixed in its corner at the same size while the page moves between the hero and the shelves: the hero fades out under it and the shelves fade in below it.
Neither fades out completely, because the focus engine skips a fully transparent view and focus could no longer cross between them.
The logo leaves with the shelves once the page scrolls on past the first shelf (the episodes on a series).
Coming back up to the season selector returns the page to that same resting position, the fold, with the logo whole.
The system's focus scroll brings the page up.
When that scroll would stop less than 300 points below the fold, the fold snapping moves its stopping position to the fold.
When the page is already 200 points or less below the fold, the selector is on screen and focus doesn't scroll, so the page scrolls itself back to the fold.
Moving up onto the episode row alone leaves the page where it is.
On the movie page, coming back up to the first shelf settles on the fold through the same snapping.
Only the loading page still uses the smaller centred shelf logo, if it is scrolled before the title loads.
The season selector is the shown season's name (Season 4, or Specials) in large text, fixed at the top of the shelf under the logo.
Below it are the season's own title (when it has one), its episode count and year, and up to six lines of its synopsis.
It is the only season control and takes focus across the shelf's whole width, so focus reaches it from any episode and from anywhere on the action row.
Left and Right step to the previous and next season; two arrows after the name show which ways are open, and a bar sits under the name while it has focus.
The name reserves the width of the widest season name with the same number of digits, so the arrows sit close to the name, level with it, hold one place across the single-digit seasons and step out once for the two-digit ones.
A step shows the new season's name, synopsis and poster straight away, then selects the season and jumps the episodes after 150 milliseconds on the same season, so holding a direction doesn't load every season passed.
Stepping away and back to the season already being browsed selects nothing and leaves the episode row where it was.
Select opens a menu of every season with its episode count and a tick on the shown season; picking one jumps to it immediately.
The shown season's poster stands on the trailing side, 360 by 540 points, from near the top of the screen to the bottom of the season header.
It turns over to the next poster when the season changes (a plain swap under Reduce Motion), falls back to the series poster when the season has none, and never takes focus or opens anything.
The header's height is fixed, so the selector and the episode row never move with the synopsis length, and the next shelf's heading starts below the screen's bottom edge.
With Hide Episode Spoilers on, seasons after the one the viewer is up to show no synopsis.
The approved baseline before this layout is tagged `checkpoint/tvos-approved-detail-flow` (`a8ab50c`).
When focus first enters the shelf from the hero, the selector shows the Play target's season and the episode row opens on that episode.
The episode row aligns a card to its leading edge (`.viewAligned`), so landing on an episode never nudges the row to reveal part of the previous one.
The owner approved this layout on an Apple TV simulator and on an Apple TV 4K (3rd generation) with a development build.

Episode focus updates the shown season immediately.
During accelerated remote scrolling, scroll geometry keeps the shown season on the visible rail when the previously focused episode has moved offscreen, without changing playback selection or triggering season jumps.
The last shown season remains when focus moves down to the lower shelves.
Moving up to the action row prepares the shelf for entry again, so it shows the Play target's season.
Rapid boundary crossings still need confirmation on Apple TV.
Episode artwork shows a compact duration or minutes-remaining badge, watched state and an inset progress bar when applicable.
Focusing an episode updates the selected season.

The route warms remaining season metadata sequentially in nearby-season order, with only six stills per warmed season.
Missing pages retain a Load Season action.
Native `.card` buttons provide episode artwork focus; cards include episode number, title, summary and date, with watched/resume and context actions retained.
The old series page-scroll coordinator, viewport lock, season pager, transition timers and handoff helpers have been removed.
Separate episode and season detail pages retain their existing layouts.

The owner supplied an 89-second Apple TV reference recording.
It establishes the requested appearance and interaction; it does not measure Apple's internal rendering performance.
The owner approved the overall page flow on Apple TV.
The owner confirmed the season selector and the rail's movement on season changes on an Apple TV 4K (3rd generation); Reduce Motion, startup, memory and the full playback regression checks remain unverified.
No claim of matching Apple's frame timing is made.

Outside the continuous series shelf, TV card captions share 20-point titles and 18-point secondary text, aligned to the left.
The same caption setting applies to catalogue posters, Home, Continue Watching and series episode cards.
Long titles remain truncated.
Emby season selectors use numbered labels such as Season 4, with Specials for season zero; Silo’s season titles are unchanged.

The series hero always shows the main series plot, season count and genres; episode facts, playback selection and controls retain their existing behaviour.
Movie and series pages retain the credit line, playback readouts and action row within the lower hero.
Separate episode pages retain their existing positions.
Seeded movie and series loading screens share the loaded page’s hero and logo positions, including a placeholder tile in the poster's place with the details shifted beside it.
Header focus scrolls again snap to the top, and entry into the supporting shelves snaps to the hero boundary.
The snap thresholds are unchanged; only the source of the starting-page decision differs.
These opening-position refinements await Apple TV verification.
Movie and series details use a compact text heading with Series or Movie, the season or released episode count for series, separate genres and an outlined content rating.
The genres and season/episode count match the muted credit text.

Home cards use section payloads and artwork caches; focusing them starts no detail or playback preload.
Destination metadata loads after selection or explicit Play/Resume.
See [Home sections and background work](apple-tv-focus.md#apple-tv-home-sections-and-background-work) for the current request and cache boundaries.
Cached movie playback fields hydrate before the first render.

Play owns initial detail focus, with synopsis focus enabled only after Play has received focus.
Play stays focusable while the title loads and does nothing until it knows what to play, so focus starts on it rather than landing on another control and jumping back.
The main synopsis aligns with the other editorial text, is set at 22 points like the Home spotlight's overview, shows up to four lines on movie and series pages (three above Read more on the older layout that season and episode pages use; the loading page shows the same number of lines for each) and gains only a white focus ring, without a focused fill or shadow.
Selecting it opens a compact Liquid Glass panel sized to the description, with scrolling for longer text.
Starring retains its fixed baseline.
The bottom row shows year and runtime, white-filled resolution badges, including 1080P and 4K, with outlined dynamic-range, ATMOS and CC badges.
Once the file's video details load, the dynamic-range badge names its format as one badge (for example DV P8.1, DV P7, DV P5, HDR10+, HDR10, HLG or HDR), and an SDR file shows its video codec instead; until then the catalogue summary's DV or HDR mark is shown.
ATMOS appears only when the source default audio metadata identifies it, and CC indicates available subtitle tracks.
There are no Apple TV, Dolby or Atmos logos, SDH badges or AD badges.
These hero changes apply only to tvOS.

On both iOS and tvOS Home, episode thumbnails combine the watched tick and runtime in a bottom-left capsule, with resume progress alongside it, matching episode detail cards.
The iOS Home feed applies this through HomeStillCard, including Continue Watching and Next Up.
Main poster cards and movie thumbnails retain their existing watched indicator without a runtime capsule.

A single-season series retains the released episode count, excluding future air dates; undated entries count only when a file is available.
Movie and series skeletons share the loaded title, heading, synopsis, Starring and technical-row geometry.
Other detail pages retain twelve-point gaps between credits, readouts and actions.
Plots wrap within the action row width; Read more opens a separate scrollable Description panel.
Version selection lives in the detail options menu, with Auto and individual files.
On series pages this is the three-dot More menu, with Favourites followed by Episode, Season and Series watched actions.
Long-pressing the primary movie or series action opens a native menu with Start Over when it says Resume, and Shuffle on a series.
It uses the existing playback action and selected file without adding another button to the row.

On other detail pages, the equal-width Version and Audio playback pills use white icons, a translucent background and a thin glass-style edge.
Resolution is displayed as 4K, FHD for 1080, or HD below 1080; the file's dynamic range appears when present (for example DV P8.1, DV P7, HDR10+, HDR10, HLG or HDR), otherwise the video codec is shown.
Audio shows the source file’s default codec and channel layout.
Playback audio preferences and device compatibility are applied without changing this source readout.
There is no subtitle readout pill.
The audio and subtitle selectors remain available; with nothing picked, they show what playback will choose from Settings (see [Audio selection and startup](playback/README.md#audio-selection-and-startup)).
Quality badges render from the existing card/catalogue summary during opening, then use full source-track metadata when available; cached episode playback metadata is read on the first render.
Series file and audio choices appear from cached or newly received episode metadata without waiting for playback enrichment; a failed enrichment request preserves those choices.

Continue Watching carries the exact season and episode into the detail route.
That season takes priority over cached progress, and the episode carousel refreshes its selection when the requested episode changes.
Playback metadata for the selected episode loads its catalogue and watch requests together; cached movie pages begin refreshing watch metadata on open.
Uncached data still requires a server response.

Poster, collection, episode, trailer and cast cards use native `.card` focus without custom scaling or focus borders.
Trailer and cast captions sit outside the artwork buttons; cast portraits retain circular button borders.
Resume progress is part of the native artwork label and moves with it.
Watched mutations hide the bar immediately, with rollback on failure.
Watched artwork retains its green tick badge.
Episode buttons own the rail focus binding, accessibility description and context actions so focus-driven season updates, Play/Pause and VoiceOver activation address the same control.
Movie and series pages now end with Media Information for the selected file or episode: separate Video & File and Audio glass panels.
Video & File has up to five equal-width columns; audio has up to four.
Sparse panels use fewer columns, while incomplete final rows keep their column alignment.
Missing metadata is omitted.
Video/file bitrates use Mbps with provider-specific unit conversion; audio below 1 Mbps uses kbps.

Earlier Home profiling investigated gradient-stroke rendering on ordinary media cards; those cards now use native `.card`.
Spotlight retains its separate decorative outline.
Those manually driven recordings do not benchmark the final source.
The owner’s smoother-navigation reports are device feedback, not measured GPU frame timing.

## Trailers and More Like This

TMDb powers trailers, the TMDb rating, Studios & Networks and movie collection rows.
Requests go through Vivid's [TMDb relay](tmdb-relay.md), so there's no key to set up; Settings > Plugins > TMDb shows the connection status and TMDb's attribution.
Without a signed-in account and profile, trailer rows are hidden.
Detail-page requests select up to three unique YouTube trailers, preferring the main trailer and, for series, trailers for the latest season.
Results are cached; the physical Apple TV opens YouTube to play them.
The movie and series technical row ends with the TMDb user score after the quality badges, for titles TMDb matches and has votes for.

More Like This is independent of TMDb.
Emby and Jellyfin use their native similar-items endpoints on Apple TV.
Silo uses the active server/profile catalogue, filters by shared genres, studios or networks, and samples up to three hundred candidates across the matching catalogue after reading its count.
Genre overlap dominates ranking, followed by production and release era.
Ties use a stable title-independent order.
Up to ten results are shown, excluding the current item and wrong media types.
This is bounded metadata matching, not a full-library semantic recommendation engine; sparse metadata can produce few or no matches.
Its posters and loading placeholders use Home’s Large poster size.

## Source map

<table width="100%">
  <thead><tr><th align="left">Area</th><th align="left" width="10000">Entry points</th></tr></thead>
  <tbody>
    <tr><td>Home and spotlight</td><td><a href="../iosApp/iosApp/tvOS/Components/TVHomeDiscoveryFeed.swift">TVHomeDiscoveryFeed</a>, <a href="../iosApp/iosApp/tvOS/Components/TVHomeSpotlightPreferences.swift">Spotlight and Home card preferences</a>, <a href="../iosApp/iosApp/tvOS/Components/TVSpotlightBackdropImage.swift">Artwork framing</a>, <a href="../iosApp/iosApp/tvOS/Components/TVSpotlightLogoFlight.swift">Spotlight to detail flight</a></td></tr>
    <tr><td>Studios &amp; Networks</td><td><a href="../iosApp/iosApp/Components/StudiosNetworksStore.swift">StudiosNetworksStore</a>, <a href="../iosApp/iosApp/Components/StudiosNetworksCatalogue.swift">brand catalogue</a>, <a href="../iosApp/iosApp/Components/StudiosNetworksMatching.swift">matching</a>, <a href="../iosApp/iosApp/Components/StudiosNetworksSources.swift">library, TMDb and disk reads</a>, <a href="../iosApp/iosApp/Components/StudioNetworkLibraryFilter.swift">library filter</a>, <a href="../iosApp/iosApp/Components/StudioNetworkLogo.swift">logos</a>, <a href="../iosApp/iosApp/tvOS/Components/TVStudiosNetworks.swift">Apple TV row, pages and settings</a></td></tr>
    <tr><td>Collections row</td><td><a href="../iosApp/iosApp/Components/HomeCollectionsStore.swift">HomeCollectionsStore</a>, <a href="../iosApp/iosApp/tvOS/Components/TVHomeCollections.swift">Apple TV row and settings</a></td></tr>
    <tr><td>Local metadata</td><td><a href="../iosApp/iosApp/tvOS/Caching/TVHomeMetadataCache.swift">TVHomeMetadataCache</a></td></tr>
    <tr><td>Catalogue grids</td><td><a href="../iosApp/iosApp/tvOS/Screens/Catalogue/TVPosterGrid.swift">TVCatalogGrid</a>, <a href="../iosApp/iosApp/tvOS/Screens/Catalogue/TVPosterArtworkPrefetch.swift">artwork window</a>, <a href="../iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryPagingModel.swift">Library paging</a></td></tr>
    <tr><td>Library tab</td><td><a href="../iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryRootPage.swift">Library page</a>, <a href="../iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryCardRow.swift">library row</a>, <a href="../iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryPage.swift">pushed library page</a>, <a href="../iosApp/iosApp/Components/LibraryRowOrderStore.swift">row order</a></td></tr>
    <tr><td>Navigation and Settings</td><td><a href="../iosApp/iosApp/tvOS/Shell/AppleTVShell.swift">TVMainTabView</a>, <a href="../iosApp/iosApp/tvOS/Screens/Settings/TVGeneralPane.swift">General</a></td></tr>
    <tr><td>Siri search</td><td><a href="../iosApp/iosApp/tvOS/Siri/SearchVividIntent.swift">SearchVividIntent and search link</a>, <a href="../iosApp/iosApp/Screens/Search/SearchPage.swift">SearchView</a></td></tr>
    <tr><td>Startup</td><td><a href="../iosApp/iosApp/tvOS/Components/VividStartupView.swift">VividStartupView</a>, <a href="../iosApp/iosApp/Startup/StartupPrefetch.swift">StartupContentPrefetcher</a></td></tr>
  </tbody>
</table>

## Validation

On 12 September 2026, the owner accepted Home navigation, detail-card refinements and the iOS-style Settings palette on Apple TV using local Release `0.14.3 (18)` through `00177cf`.
The review follow-up `06ed084` changed episode button focus/accessibility wiring and invalid timestamp validation only; it did not replace that installed build.
Targeted date checks passed, and [CI passed the iOS tests and tvOS simulator build](https://github.com/blurbery/vivid/actions/runs/34695468089).
No focused VoiceOver/device check of that follow-up is recorded.
Documentation-only updates made straight after that run reused those results because application sources were unchanged.

The Library tab, its library row and rearranging, the pushed library pages, Adaptive on those pages, the restyled sub-tabs and pills, the tucking notch and the Home and Library tab bar editor were checked in the tvOS simulator only.
None of it has been checked on a physical Apple TV, and iCloud sync of the library order between devices has not been tested.

The results below belong to the stated development revisions.
For current TestFlight availability and source mappings, use App Store Connect.
The [recorded Apple builds](release/versioning.md#recorded-apple-builds) preserve historical validation only.

The 9 September 2026 UI revision (`594d1e1`) passed a signed VividTV Debug device build and was installed on the Apple TV 4K (3rd generation), tvOS 26.6, as 0.14.3 (1).
Signing and keychain identifiers were unchanged.
At that time, the focused-card resume-overlay revision still needed physical confirmation; the earlier overlay approach did not clear reliably while focused.
Installation and compilation do not establish that the updated behaviour passes.
Automated build and regression results for that source revision are recorded in [Player Regression CI](https://github.com/blurbery/vivid/actions/runs/34356358281).

The earlier app checks are recorded through `v0.13.0` (`2ee9005c`).
Device validation on 8 September 2026 covered Apple TV 4K (3rd generation), tvOS 26.6: smaller Search captions/year, Media Information, quality controls, normal and DTS audio through HomePod (2nd generation), the 20-second Auto buffer, Home refresh, profile deletion and Emby season labels.
This was a local development build, 0.6.0 (1), not TestFlight.
The paired iPhone checks are in [App Design](app-design.md#detail-pages-and-validation).
No measured benchmark, universal output-format certification or physical iPad check is recorded.

Before treating a revision as device-verified, record its exact commit, Apple TV model and OS, server version, and results.
Check cold/warm startup, multiple accounts, manual sign-out, optional PINs, spotlight cycling, Continue Watching returns, the Library row and its rearranging, library pages, sort/filter changes, paging beyond seventy items, reverse scrolling, cache clearing and Settings navigation.
The changed shared code also needs iOS validation; the current tvOS build does not cover those platforms.

Read [focus ownership rules](apple-tv-focus.md) before changing navigation.
Preserve series season/episode focus, context-menu restoration, and cancellation of obsolete artwork work.

Cast and crew filmography uses Home’s dense poster width and shared title/year captions.
Watchlist and Favourites no longer show Movie or Series pills on iOS or tvOS; the Filter menu's Show choice separates them instead.
Library’s secondary tabs scroll with Watchlist, Favourites and Collections.
Person details reuse the active profile’s response cache while refreshing in the background; filmography and filter availability load alongside the person request.
Missing biographies and photos still depend on server enrichment.

Movie and series detail pages order the supporting sections as Trailers, Cast & Crew, More Like This and Media Information, omitting unavailable sections.

The season selector's menu ends with Mark Season Watched or Unwatched for the shown season.
The series More menu has Shuffle after Start Over, and orders watched actions as Episode, Season, then Series, targeting the Play/Resume episode.
The main series Play button retains its initial resume/next episode while browsing other episodes or seasons; explicitly playing a card and playback completion can update that target.
Profile arrangement suppresses the large native button highlight and uses a ring around the selected avatar.
The owner confirmed these refinements on the device.

More Like This on tvOS movie and series details uses Home’s dense poster width at Home’s Large poster size, with the Home caption setting.

tvOS trailer thumbnails match the continuous series episode shelf at 400 × 225 points, with the title and secondary text left-aligned to the card.
