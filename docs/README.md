<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Documentation</h1>
<p align="center">Build, design and maintain Vivid.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Guides for building Vivid, connecting media servers and maintaining the app on Apple devices. The [mobile layout guide](app-design.md#iphone-and-ipad-layout) covers the current iPhone/iPad navigation, spotlight, saved lists, settings and validation limits.

<table width="100%">
  <thead>
    <tr><th align="left">Guide</th><th align="left" width="10000">What it covers</th></tr>
  </thead>
  <tbody>
    <tr><td><a href="../CONTRIBUTING.md">Build and contribute</a></td><td>Xcode setup, local signing and validation</td></tr>
    <tr><td><a href="server-connections.md">Server connections</a></td><td>Saved accounts, private iCloud sync, deletion rules, profile PINs and server integration status</td></tr>
    <tr><td><a href="app-design.md">App design</a></td><td>Shared appearance, downloads, components and accessibility</td></tr>
    <tr><td><a href="apple-tv-browsing.md">Apple TV browsing</a></td><td>Discovery spotlight, native catalog menus, detail pages, trailers, similarity, Settings and startup</td></tr>
    <tr><td><a href="apple-tv-focus.md">Apple TV focus</a></td><td>Focus ownership and navigation rules</td></tr>
    <tr><td><a href="playback/README.md">Playback</a></td><td>VividKit, compatible audio, embedded subtitles, chapters, controls, downloads, resume updates and verification</td></tr>
    <tr><td><a href="branding/README.md">Branding</a></td><td>Vivid&#x27;s silver logo, documentation headers and Apple app icons</td></tr>
    <tr><td><a href="release/versioning.md">Releases</a></td><td>Semantic versions and GitHub release format</td></tr>
    <tr><td><a href="release/distribution.md">Device distribution</a></td><td>TestFlight preparation, signing blockers and device coverage</td></tr>
    <tr><td><a href="../THIRD_PARTY_NOTICES.md">Third-party libraries</a></td><td>FFmpeg, subtitle/font libraries, licences and exact source</td></tr>
    <tr><td><a href="../TRADEMARK.md">Brand policy</a></td><td>Use of the Vivid name, byline and logo</td></tr>
  </tbody>
</table>

## Cores

Vivid is the shared player core. Each server has a separate server core that supplies its connection, data and playback sources. VividKit is a local Swift package; the server cores are responsibility boundaries within the app, not separate provider packages.

| Core | Documentation |
| --- | --- |
| [Vivid core](cores/vivid.md) | Shared player, controls and IntroDB integration |
| [Player engine core](cores/player-engine.md) | VividKit mini cores, shared responsibilities and audio/video support |
| [Silo server core](cores/silo.md) | Current Silo connection and its boundary with the player |
| [Emby server core](cores/emby.md) | Emby implementation, provider boundaries and verification gaps |
| [Jellyfin server core](cores/jellyfin.md) | Planned connection; no implementation yet |

> [!NOTE]
> Silo and Emby are available on iPhone, iPad and Apple TV. Emby still has the feature limits listed in its guide; Jellyfin remains planned. Use the source and resolved package revisions to check what a build implements.

> [!IMPORTANT]
> Documentation changes require blurbery’s prior, explicit approval, including wording, formatting, new pages, renames and deletions. See the [documentation ownership policy](../CONTRIBUTING.md#documentation-ownership).
