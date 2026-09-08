<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Jellyfin server core</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="vivid.md">Vivid core</a> · <a href="../server-connections.md">Server connections</a></p>

---

Jellyfin is planned. Its provider card remains Coming Soon; there is no native Jellyfin login, library or playback adapter in the current app.

VividKit is shared playback infrastructure. Its container and codec support does not implement a Jellyfin server connection. A future adapter must supply Jellyfin authentication, library/source metadata, session negotiation and progress reporting without reusing Silo credentials or pretending to implement Silo Protocol V3. It should use Vivid’s existing player, embedded subtitles and chapters, and optional IntroDB integration.

No Jellyfin device verification is claimed.
