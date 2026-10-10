<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Plugins</h1>
<p align="center">Set up TMDb, MDBList and OpenSubtitles, and see what each one adds.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid works fine without plugins. Each one is an optional connection to a free service, using your own personal key, and adds something on top of your media server. This guide walks through setting each one up and what you get once it's connected.

<table width="100%">
  <thead>
    <tr><th align="left">Plugin</th><th align="left" width="10000">What you get</th><th align="left">What you need</th></tr>
  </thead>
  <tbody>
    <tr><td><a href="#tmdb"><strong>TMDb</strong></a></td><td>Trailers, TMDb ratings, Studios &amp; Networks on Home and movie collection rows</td><td>A free TMDb account and API key</td></tr>
    <tr><td><a href="#mdblist"><strong>MDBList</strong></a></td><td>Finished movies and episodes sent to MDBList, and your watchlist kept in sync both ways</td><td>A free MDBList account and API key</td></tr>
    <tr><td><a href="#opensubtitles"><strong>OpenSubtitles</strong></a></td><td>Subtitles searched and downloaded from a movie or episode page, or while you watch</td><td>A free OpenSubtitles.com account and API key</td></tr>
  </tbody>
</table>

## Before you start

> [!IMPORTANT]
> Sign in to your server and choose your profile before connecting a plugin. Each connection belongs to the server account and profile you're using, so another profile or saved account needs its own key.

To find the plugins:

- **iPhone and iPad:** tap your profile picture in the tab bar to open Settings, then choose **Plugins**.
- **Apple TV:** select your profile picture in the top bar to open Settings, then choose **Plugins**.

> [!TIP]
> Keys are saved in Keychain and sync through Vivid's encrypted iCloud vault to your other iPhone, iPad and Apple TV for the same server account and profile. Set a plugin up on your iPhone or iPad and it comes through to Apple TV once it syncs, so you don't need to type a long key with the remote.

## TMDb

TMDb (The Movie Database) adds trailers, ratings, Studios & Networks and collection rows to Vivid.

### Set it up

1. Create a free account at [themoviedb.org](https://www.themoviedb.org/signup) and sign in.
2. Open your account settings, choose [API](https://www.themoviedb.org/settings/api) and request an API key for personal use. TMDb asks a few short questions about how you'll use it.
3. Copy either the **API Key** or the **API Read Access Token**. Vivid accepts both.
4. In Vivid, open **Settings → Plugins → TMDb**.
5. Paste it into **API key or read access token** and choose **Save Connection**.
6. Vivid checks it with TMDb. Once it works, Status shows **Connected** with a green dot.

On Apple TV the field is called **Personal API key**. The 32-character API Key is much quicker to type with the remote than the longer read access token.

### What you get

<table width="100%">
  <thead>
    <tr><th align="left">Feature</th><th align="left" width="10000">Where it shows up</th></tr>
  </thead>
  <tbody>
    <tr><td><strong>Trailers</strong></td><td>A Trailers row on movie and series pages, just before Cast &amp; Crew. It shows up to three trailers with the official ones first, and series show trailers for their latest season. Episode pages show their series' trailers. On iPhone and iPad, trailers open in the YouTube app, or on youtube.com if the app isn't installed. On Apple TV they play in the YouTube app, so it needs to be installed.</td></tr>
    <tr><td><strong>TMDb rating</strong></td><td>TMDb's user score on movie and series pages, next to the other badges. It only appears when TMDb has votes for the title.</td></tr>
    <tr><td><strong>Studios &amp; Networks</strong></td><td>A row of studio and network logos pinned under the Spotlight on Home. Each one opens a page with Popular Series, Popular Movies and All in Your Library for that studio or network.</td></tr>
    <tr><td><strong>Collections</strong></td><td>On a movie that's part of a collection, a row such as "Scream Collection" with the films from it that are in your library, in release order. It appears when you have at least two of them.</td></tr>
  </tbody>
</table>

Studios & Networks turns on by itself once TMDb is connected. The first time, Vivid reads your library and matches it with TMDb, which can take a few minutes on a large library, so keep Vivid open until it finishes. After that it loads straight away and refreshes daily. It picks from Netflix, HBO, Apple TV, Disney+, Prime Video, Hulu, Peacock, Paramount+, Stan, Pixar, Marvel Studios, A24, Lucasfilm, DreamWorks, Studio Ghibli, Sony Pictures, Warner Bros. and Universal. A studio or network only shows once at least six titles in your library match it.

To choose your own, open **Settings → General → Home Screen → Studios & Networks**. From there you can:

- turn **Show on Home** on or off
- pick up to six from **Networks** and **Studios**
- use **Reset to Automatic** to go back to Vivid's picks

### Good to know

- TMDb features need your server to have identified the title. Silo needs a TMDb ID. Emby and Jellyfin can also use an IMDb ID, which Vivid looks up on TMDb.
- More Like This comes from your server and works without TMDb.
- **Disconnect** hides trailers, ratings, Studios & Networks and collection rows again. Nothing else changes.
- This product uses the TMDB API but is not endorsed or certified by TMDB.

### If something goes wrong

- **"TMDb could not validate this API key or read access token."** Copy the key again and check nothing is missing from either end.
- **"TMDb is unavailable right now. Please try again."** If your internet is working, check you're signed in to a server and have chosen a profile, then save again.
- **No trailers on Apple TV.** Install the YouTube app from the App Store.

## MDBList

MDBList keeps your watched history and a watchlist in one place that other apps can use too. Vivid sends your finished movies and episodes to it and keeps your watchlist in sync both ways.

### Set it up

1. Sign in at [mdblist.com](https://mdblist.com). It's free.
2. Open [Preferences](https://mdblist.com/preferences/) and copy your API key. If there isn't one yet, generate it there.
3. In Vivid, open **Settings → Plugins → MDBList**. On iPhone and iPad, **Get your free API key** opens the same page.
4. Paste it into **MDBList API key** (on Apple TV, **Personal API key**) and choose **Connect**.
5. Status shows **Connected** with a green dot, and the first sync starts straight away.

### What you get

<table width="100%">
  <thead>
    <tr><th align="left">Feature</th><th align="left" width="10000">How it works</th></tr>
  </thead>
  <tbody>
    <tr><td><strong>Watched history</strong></td><td>When you finish a movie or episode, or mark one as watched, Vivid sends it to MDBList once your server has saved it. Downloads you watch offline are sent once your server catches up.</td></tr>
    <tr><td><strong>Watchlist sync</strong></td><td>Movies and series you add to or remove from your watchlist in Vivid change on MDBList too, and changes made on MDBList come back to Vivid. The first sync combines both lists. Titles from MDBList are added when they're on the server you're using. On Emby and Jellyfin this is Vivid's watchlist, not your server favourites.</td></tr>
    <tr><td><strong>Background sync</strong></td><td>While Vivid is open it syncs about every ten minutes, and sooner after you finish something or change your watchlist. <strong>Sync now</strong> runs a sync straight away, and the MDBList page shows its progress.</td></tr>
  </tbody>
</table>

This works with Silo, Emby and Jellyfin on iPhone, iPad and Apple TV. The logos on the MDBList page are other apps that also work with MDBList. Vivid itself only connects to MDBList.

### What it doesn't do

- It doesn't bring history from MDBList into Vivid or your server. Watched status and resume points still come from your server.
- Marking a whole season or series as watched isn't sent. The individual episodes you finish are.
- Marking something unwatched doesn't remove it from MDBList.
- Disconnecting keeps your existing history and watchlist on MDBList.

### If something goes wrong

- **"Check your MDBList API key and try again."** Copy the key again from your MDBList Preferences.
- **"MDBList's request limit was reached. Sync will try again later."** Vivid waits an hour before trying again, and **Sync now** waits too.
- **"Sync finished. … watched items could not be matched or confirmed and will be retried."** Vivid matches watched items by their TMDb or IMDb ID (or TVDB for episodes), so titles your server hasn't identified stay unmatched and are tried again later.
- **A watchlist title from MDBList doesn't appear in Vivid.** Vivid only adds it when it finds the same title on your server by name and ID. If your server names it differently, it stays unmatched and is tried again later.

## OpenSubtitles

OpenSubtitles lets you search for and download subtitles when your server doesn't have the one you want.

### Set it up

1. Create a free account at [opensubtitles.com](https://www.opensubtitles.com) and sign in.
2. Open [API consumers](https://www.opensubtitles.com/en/consumers), create a new consumer (call it something like Vivid) and copy its API key.
3. In Vivid, open **Settings → Plugins → OpenSubtitles**. On iPhone and iPad, **Get your API key** opens the same page.
4. Paste it into **OpenSubtitles API key** (on Apple TV, **Personal API key**) and choose **Save Connection**.
5. Status shows **Connected** with a green dot.

Vivid only needs the API key. It never asks for your OpenSubtitles username or password.

### What you get

<table width="100%">
  <thead>
    <tr><th align="left">Where</th><th align="left" width="10000">How to use it</th></tr>
  </thead>
  <tbody>
    <tr><td><strong>Player on iPhone and iPad</strong></td><td>Tap the Subtitles button and choose <strong>Find on OpenSubtitles</strong>. Check the title, enter a two-letter language code such as <code>en</code> or <code>fr</code>, then tap <strong>Search</strong>. Pick the release that matches your file and Vivid downloads it and switches to it. It shows in the subtitle list as "OpenSubtitles · file name".</td></tr>
    <tr><td><strong>Player on Apple TV</strong></td><td>Open the Subtitles menu and choose <strong>Find on OpenSubtitles</strong> at the bottom. Vivid searches straight away in your subtitle language from Settings → Subtitles, or English. Use <strong>Language</strong> to search in another language, then choose a result.</td></tr>
    <tr><td><strong>Movie and episode pages</strong></td><td>The Subtitles selector also has <strong>Find on OpenSubtitles</strong>. The subtitle you pick is used when you start playing.</td></tr>
    <tr><td><strong>Next time you watch</strong></td><td>Vivid remembers the subtitle you chose for each title (your 40 most recent), so it comes back when you resume. It stays until you choose another subtitle, Off or Auto, or disconnect. Apple TV may clear these to free up space.</td></tr>
  </tbody>
</table>

This works with Silo, Emby and Jellyfin on iPhone, iPad and Apple TV.

### Good to know

- Each download counts towards OpenSubtitles' download limit. Vivid connects with the API key only and doesn't sign in to your OpenSubtitles account, so account allowances don't apply.
- Searches use the title, plus the season and episode for episodes. They don't match your exact file, so choose a release that matches yours. If the timing is still off, use **Subtitle Delay** in the player settings. It moves that subtitle up to 10 seconds either way and remembers the setting.
- Downloaded subtitles stay on your device. Nothing is uploaded to your server.

### If something goes wrong

- **"Check your OpenSubtitles API key. An account may be required by OpenSubtitles for this download."** Copy the key again from your API consumers page.
- **"OpenSubtitles' download or request limit has been reached. Try again after your quota resets."** You've used your downloads for now. Try again once OpenSubtitles resets your limit.
- **"Connect OpenSubtitles in Settings → Plugins before searching for subtitles."** This profile isn't connected yet. Each profile needs its own connection.
- **"The connection or playing item changed. Please search again." when saving the key.** Sign in to a server and choose your profile first, then save again.
- **"No subtitles found. Try another title or language."** Try the original title, or another language.

## More detail

[Server Connections](server-connections.md#plugins-on-iphone-ipad-and-apple-tv) covers how plugin keys sync, what's stored on each device and current verification limits. The in-app Privacy Policy under **Settings → About** explains what MDBList and OpenSubtitles receive.
