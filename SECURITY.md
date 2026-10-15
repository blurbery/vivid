<p align="center">
  <img src="docs/branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Security Policy</h1>
<p align="center">Reporting security problems privately.</p>
<p align="center"><a href="README.md">Home</a> · <a href="docs/README.md">Documentation</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Please report security problems in Vivid privately, not in a public issue, pull request or Discord message.

## Reporting a vulnerability

Use GitHub's private reporting: open the repository's **Security** tab and choose **Report a vulnerability**, or go straight to [the new advisory form](https://github.com/blurbery/vivid/security/advisories/new). The report is private: GitHub shows it only to you, people with admin or security manager access to the repository, and anyone blurbery adds to the advisory.

Include enough detail to reproduce the problem:

- what an attacker can do, and what they need first (for example a malicious server, a crafted media or subtitle file, a network position or access to the device);
- the steps to reproduce it, or a proof of concept;
- the platform (iPhone, iPad or Apple TV), the OS version and the Vivid version and build from Settings → About, with the source commit when it's shown;
- the server type (Silo, Emby or Jellyfin) when it matters.

Leave out real server addresses, usernames, passwords, access tokens and anything else private. Use placeholders such as `https://media.example.com`; if a real value turns out to matter, blurbery will ask for it in the advisory.

## What happens next

blurbery confirms whether the report is a vulnerability and, where needed, works on a fix in the advisory's temporary private fork. App fixes reach testers in a later TestFlight build; relay and website fixes apply once they're deployed. blurbery may then publish the advisory, crediting you unless you'd rather not be named. Vivid is maintained by one person in their own time, so there is no fixed response time.

## Scope

In scope:

- the Vivid app for iPhone, iPad and Apple TV, including its Top Shelf and downloads extensions;
- how Vivid handles media, subtitles and metadata from servers, including what it passes to Lucid Engine;
- Lucid Engine's build pipeline and Vivid's patches in `engine/`;
- how Vivid stores credentials and settings on the device and in iCloud;
- what Vivid sends to media servers and to the third-party services described in the [privacy policy](https://vividapp.co/privacy);
- the diagnostics relay in `diagnostics-relay/`, the website in `website/` and the release and CI tooling in this repository.

Out of scope:

- vulnerabilities in Silo, Emby, Jellyfin or Seerr themselves: report those to their own projects;
- vulnerabilities in TMDb, MDBList, OpenSubtitles, IntroDB or other services Vivid talks to: report those to the service;
- bugs in FFmpeg, mpv, libass or the other upstream libraries Lucid Engine builds, unless Vivid's patches cause them: report those upstream;
- problems that need a jailbroken device, or physical access to a device that is already unlocked.

## Supported versions

Fixes go into the latest source on `main` and a later TestFlight build. Older builds are not patched; update to the latest build first and check the problem is still there.
