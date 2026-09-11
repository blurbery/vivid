<p align="center">
  <img src="docs/branding/vivid-mark-silver.png" width="180" height="180" alt="Vivid silver logo">
</p>

<h1 align="center">Vivid™</h1>
<p align="center"><strong>Your media. Vivid.</strong></p>
<p align="center">An open-source media app for iPhone, iPad and Apple TV.</p>
<p align="center">
  <img src="https://img.shields.io/badge/Apple-iOS%20%C2%B7%20tvOS-555555?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="Apple: iOS and tvOS">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white" alt="Built with Swift and SwiftUI">
  <a href="https://github.com/blurbery/vivid/releases"><img src="https://img.shields.io/badge/releases-SemVer-3B82F6?style=flat-square" alt="Releases use semantic versioning"></a>
  <img src="https://img.shields.io/badge/status-in%20development-D29922?style=flat-square" alt="In development">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-555555?style=flat-square" alt="Licence: Apache-2.0"></a>
</p>
<p align="center">
  <a href="CONTRIBUTING.md#local-setup">Build</a> ·
  <a href="docs/README.md">Documentation</a> ·
  <a href="https://github.com/blurbery/vivid/releases">Releases</a> ·
  <a href="docs/branding/README.md">Branding</a> ·
  <a href="#support">Support Vivid</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

I’m building Vivid as an open-source media app for iPhone, iPad and Apple TV. Connect your own media server and browse and watch your library across your Apple devices.

> [!NOTE]
> Vivid is still in development. The source is public, and beta access is offered through the [TestFlight link](https://testflight.apple.com/join/Ycb8t685), subject to available places and device eligibility. There is no public App Store release yet.

## Server support

Vivid connects to your existing media server for your library, artwork and playback.

<table width="100%">
  <thead>
    <tr><th align="left">Server</th><th align="left" width="10000">About</th><th align="left">Status</th></tr>
  </thead>
  <tbody>
    <tr><td><strong>Silo</strong></td><td>A self-hosted server for films, series and other media.</td><td><a href="docs/cores/silo.md">Available</a></td></tr>
    <tr><td><strong>Emby</strong></td><td>A personal media server for organising and streaming your collection.</td><td><a href="docs/cores/emby.md">Available</a></td></tr>
    <tr><td><strong>Jellyfin</strong></td><td>A free, open-source media server for your own library.</td><td>Planned</td></tr>
  </tbody>
</table>

Saved server accounts, login sessions, optional Vivid PINs, profile order, shared preferences and configured TMDb/Seerr credentials can sync through the user’s encrypted private iCloud vault across iPhone, iPad and Apple TV. Deleting a saved account records that deletion so an older device cannot add it back. Downloads, artwork caches and player preferences stay on the device; watched and resume state remains owned by the connected media server.

## Apple TV

I’ve built the TV experience around a configurable Home spotlight, local Home metadata caching, separate movie and series libraries, and saved server accounts with optional profile PINs. Search uses seven posters across the available width, and TV cards share consistent title and year captions. Detail pages include optional personal-TMDb trailers, server-only More Like This, compact playback selections and a Start Over menu when you long-press Resume. The [Apple TV guide](docs/apple-tv-browsing.md) covers the current behaviour and validation status.

## iPhone and iPad

The mobile app uses a configurable glass tab bar, a looping Home spotlight and local Home metadata caching. For You combines Watchlist, Favourites and Collections. Search and Settings are full-screen portrait pages with slide-up/down transitions; detail cards stay above Search during playback. Movie and series pages show aligned video/file and audio information. The player offers five quality choices with a one-time lower-bitrate reload for the capped modes. The [app design guide](docs/app-design.md#iphone-and-ipad-layout) covers the layout and device-testing limits.

## Playback

Apple TV uses [AetherEngine](AetherEngine) behind Vivid’s player, with native Apple playback and an automatic software fallback. iPhone and iPad use [VividKit](VividKit). Vivid keeps its own controls, episode countdown, subtitles and optional intro, recap and credits skips. See the [playback guide](docs/playback/README.md) for audio preferences and current device coverage.

> [!IMPORTANT]
> Yes, I use AI to help develop Vivid. I design the app and all of its development, and use AI to assist me.

## Updates

Updates on `main` get a semantic version. Release titles are just the version number, with dot points underneath saying what changed. The full rules are in the [release docs](docs/release/versioning.md).

## Support

I'll add GitHub Sponsors once I've finished setting it up. For now, testing the app and reporting issues helps a lot.

## Licence

Vivid and VividKit source use Apache-2.0. AetherEngine retains LGPL-3.0 with its Apple Store / DRM Exception; FFmpeg and other dependencies retain their own licences.

[Apache-2.0](LICENSE) · [Third-party libraries](THIRD_PARTY_NOTICES.md) · [Brand policy](TRADEMARK.md)

Vivid™ and the logo are my brand. Forks and other projects need my written permission to use them; otherwise, use your own name and logo. See the [brand policy](TRADEMARK.md).
