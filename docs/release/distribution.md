<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">App Distribution</h1>
<p align="center">Local device builds and Apple beta distribution.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses TestFlight for Apple beta distribution. Its App Store Connect record includes iOS and tvOS, with registered identifiers and signing capabilities. App Store Connect is the source of truth for uploaded builds, processing, review and tester availability. Its beta description maps each available platform/version/build to its immutable source. The [dated build records](versioning.md#recorded-apple-builds) preserve earlier validation and are not a current upload ledger. GitHub publishes independent [source releases](versioning.md), which may include changes not yet uploaded to TestFlight. TestFlight distribution is separate from public [App Store submission](#app-store-submission).

## What is ready

| Area | Current state |
| --- | --- |
| App targets | `Vivid` for iPhone/iPad and `VividTV` for Apple TV, generated separately from `iosApp/project-ios.yml` and `iosApp/project.yml`, sharing `project-common.yml` |
| Supported OS versions | iOS/iPadOS 18 or later; tvOS 26 or later. The committed project disables Designed for iPad distribution on Mac and Vision Pro; earlier local Mac layout tests used a development override. |
| Build tools | Recent signed archives use local Xcode 27.0; the regression workflow selects Xcode 26.3. Check Apple’s current SDK requirements before each upload. |
| Branding | Vivid display names, gradient app icons, the TV App Store layer stack and Top Shelf artwork are included. |
| About | Version/build, source commit, contact, privacy information, service acknowledgements and separate bundled open-source licences are present. TMDb attribution appears in Acknowledgements. |
| iCloud | The encrypted private account vault includes profile order, shared preferences and Seerr, MDBList and OpenSubtitles credentials on iPhone, iPad and Apple TV. Playback and subtitle settings remain device-specific. The Production schema was deployed on 12 September 2026 and Apple TV restoration was confirmed. Check schema changes and live restoration separately from archive entitlements; see the dated build record. |
| Local device coverage | Historical development checks include iPhone 16 Pro Max on iOS 26.6.1 and Apple TV 4K (3rd generation) on tvOS 26.6. These records do not state the devices’ current OS or validate every later TestFlight build. |
| iPad coverage | Focused simulator layout checks exist. Physical iPad playback, rotation and multitasking still need checking. |
| Apple upload tooling | Signed archives can be uploaded from the maintainer’s local Xcode configuration. Signing credentials remain outside Git and there is no committed TestFlight uploader. |

Check [Apple’s submission requirements](https://developer.apple.com/app-store/submitting/) when making the archive; an SDK requirement is different from the app’s minimum supported OS.

## Verify Vivid’s existing Apple setup

1. Confirm Apple Developer Program membership and the existing Vivid app and extension registrations. Reuse the configured signing team, identifiers and existing iOS/tvOS App Store Connect record. The bundle ID must match the uploaded build. [Apple’s distribution preparation guide](https://help.apple.com/xcode/mac/current/en.lproj/dev91fe7130a.html) explains why this needs to be settled before the first upload.
2. Map all four targets: `Vivid`, `VividDownloadsActivity`, `VividTV` and `VividTVTopShelf`. Each extension needs its own identifier and provisioning profile. Configure the intended App Group, shared Keychain access and `iCloud.com.blurbery.vivid` CloudKit container; check the tvOS user-management entitlement as well. [Deploy the `VividAccountVault` record schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema) to CloudKit’s production environment before a TestFlight build relies on account restoration.
3. Keep the registered release identifiers aligned across the signing configuration, entitlements, Info.plists and `SharedStorage`. The committed app defaults use `com.blurbery.vivid`, with `group.com.blurbery.vivid` for shared defaults and `com.blurbery.vivid.shared` for Keychain access. Extensions use the matching app prefix. The release identifiers, iCloud container and current Production schema are registered with Apple. For future schema changes, inspect the Development-to-Production diff and obtain deployment authorisation; deployment does not copy saved records between environments. The ignored `Signing/Local.xcconfig` retains development overrides. Install maintainer device updates in place, preserving accounts, Keychain and app data. Do not uninstall, reset, change identifiers or clean retained incremental caches as an update step. A clean install removes local preferences, metadata caches and download storage. On its first launch it clears any surviving Vivid Keychain entries, then can restore saved accounts and sessions from the user’s private iCloud vault. Watch history saved on the media server stays there.
4. Keep the approved Apple marketing version (`0.14.3`) for routine TestFlight updates and set each platform’s build number to its latest upload in App Store Connect plus exactly 1, ignoring local test numbers. Paired uploads can use different build numbers when the platforms have different upload histories; every embedded extension must match its app. Never reset the counter or copy a GitHub release version into the Apple version automatically. Changing the Apple marketing version requires explicit approval from blurbery. Record the exact pushed source commit and check both finished archives before upload. See [Versioning & Releases](versioning.md).

Check that Production contains `VividAccountVault` with encrypted `payload`, separately from inspecting signed entitlements. Test restoration using an existing configured installation and another device. See [restore troubleshooting](../server-connections.md#restore-and-troubleshooting); do not uninstall the only populated copy to test sync.

Uploads can use Xcode Organizer or the equivalent signed `xcodebuild -exportArchive` flow. New upload automation is optional and must use Vivid’s registered app identity. Keep credentials and signing material out of this repository.

## Check the distribution archive

Archive Release builds for the authorised platforms from the exact source revision intended for testing. The pinned Lucid Engine package already contains Vivid's audio and video outputs, so archive with the package as resolved; see [Lucid Engine builds](../cores/player-engine.md#builds). The app pins release `0.1.0`, which Vivid's pipeline in `engine/` built from pinned upstream sources with Vivid's patches; the only prebuilt part is the Rust standard library inside libdovi, from the Rust project's pinned `rust-std` archives. A new engine release is built by the [Lucid Engine build workflow](../../.github/workflows/lucid-engine.yml) and published by hand from one green run with `engine/publish_package.py` (see [Publishing the package](../cores/lucid-engine-build.md#publishing-the-package)); publishing it and moving the app's pin are separate authorised steps, and an archive that should ship it is made only after the new pin is on a pushed commit. Validate the archives in Xcode Organizer before upload. Check the embedded extensions, signed frameworks, icons, minimum OS, entitlements and version/build values in the archive. Development build success does not prove distribution signing or Apple validation will pass.

Generate and review the archive’s privacy report. The app and Top Shelf have privacy manifests; the downloads Live Activity uses no required-reason API. Check every embedded executable, including Top Shelf, which compiles `iosApp/iosApp/Shared` and so can pick up required-reason APIs such as `systemUptime`. Verify the final embedded dependencies and required-reason API declarations too. Review App Store Connect’s privacy answers for the server, account, profile and session data Vivid stores through CloudKit, and for diagnostics reports people choose to send from Settings → Diagnostics, through the [diagnostics relay](../diagnostics-relay.md) or by email (crash, performance and other diagnostic data, a short log of recent app events and any note the person writes). Keep the data types and linked-to-identity answers in the privacy manifest, App Store Connect and the privacy policy the same; Apple’s [App Privacy guidance](https://developer.apple.com/app-store/app-privacy-details/) distinguishes data collected by the app through Apple frameworks from data Apple collects itself. Both app Info.plists currently declare `ITSAppUsesNonExemptEncryption = NO`. Confirm that answer against the finished build and complete any questions Apple presents; see [export compliance for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/).

Keep [third-party notices](../../THIRD_PARTY_NOTICES.md) matched to the exact packaged libraries. Vivid uses GPL-3.0-only with the [Apple distribution permission](../../LICENSE-APPLE-EXCEPTION). Lucid Engine’s third-party components retain their upstream licences; see the linked notices for exact sources and revisions. This does not relicense FFmpeg or FriBidi. At the pinned package revision, mpv, FFmpeg and the subtitle, font and rendering libraries are static libraries linked into the app executable; check the Release archive before describing relinking materials. Before external distribution, verify the corresponding-source and replacement/relinking materials available to recipients. Use immutable public source revisions matched to the delivered build; a moving `main` link alone does not identify the shipped source. Each build records its commit (Settings → About and the first Open Source Licences section), so archive only from a pushed commit with no local changes: a build marked `(modified)` doesn't have public source.

## Licence and source delivery

Use Apple's standard EULA for the Apple-delivered binary. App Store Connect
was checked on 12 September 2026 and showed Apple’s Standard License
Agreement in the app-wide information shared by all platforms. No Apple
metadata was changed during this licence update. Vivid's GPLv3
[additional permission](../../LICENSE-APPLE-EXCEPTION) accommodates Apple's
distribution restrictions without removing source rights. Do not paste the
GPL alone as a custom App Store EULA. Apple's [standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
and [custom EULA minimum terms](https://www.apple.com/legal/internet-services/itunes/dev/minterms/)
remain separate from the source licence.

Before conveying any new GPL-covered binary, including through TestFlight:

- Publish and retain the exact source revision, dependency sources and
  patches, build instructions and required replacement/relinking materials.
  For Lucid Engine that is `engine/` at the commit the pinned release was
  built from, which the package's README and NOTICE and the app's Open
  Source Licences name; keep that commit reachable on GitHub.
  Provide a no-charge source download matching each delivered binary under
  an applicable GPLv3 section 6 method; retain it for that method's required
  duration. A moving `main` URL alone is insufficient.
- Before enabling a build, update the TestFlight beta description with its
  platform, marketing version and build number, mapped to the exact public
  immutable source archive and media dependency sources/build instructions.
  Preserve the app introduction, localisations and mappings for all still-available
  builds. Check link access and read back the saved description. Keep What to
  Test limited to change bullets. If the description limit prevents preserving
  source access, obtain authority before creating a new public source index.
- Check the app's bundled Open Source Licences includes GPLv3, the Apple permission, applicable
  [Vivid attribution terms](../../ATTRIBUTION.md), earlier Apache notices and
  all packaged third-party licences. The bundled overview carries the full
  attribution terms; keep them aligned with `ATTRIBUTION.md`.
- Preserve LGPL rights independently. Vivid's Apple permission applies to
  its authorised code; it cannot waive conditions on FFmpeg, FriBidi or
  other third-party components. Keep their corresponding source and
  replacement/relinking materials available with the app sources.
- Verify the app's actual EULA setting and packaged notices before upload.
  The permission is a licensing provision, not an Apple approval or a
  guarantee of compliance with unrelated API, privacy or review rules.

## TestFlight information

The website serves the app and website privacy policy at [vividapp.co/privacy](https://vividapp.co/privacy). Keep it aligned with the in-app iOS and tvOS privacy text, including encrypted preference/credential sync, MDBList completed-watch exports and watchlists, OpenSubtitles, both timestamp services and on-device diagnostics reports. Website source is under `website/public`; publishing it is separate from a GitHub source push and an Apple upload. Run the existing website build and Wrangler commands from `website/`, because the custom build resolves `build.mjs` from that working directory. The homepage screenshots and clips in `website/public/media` are too large to build into the Worker, so Wrangler uploads them as Workers static assets and the Worker serves them through its `ASSETS` binding with the same security headers as every other page.

Use `admin@vividapp.co` for feedback. For an uploaded build containing the Jellyfin integration, a starting beta description is:

> I’m building Vivid for watching your own media on iPhone, iPad and Apple TV. Connect to Silo, Emby or Jellyfin, browse your library and continue watching across your server accounts. Playback includes subtitles and chapters from your media and optional intro, recap and credits skips.

For What to Test, use the [plain change-bullet format](versioning.md#testflight-note-format), with one blank line between bullets and no testing instructions or source links. Describe only changes present in that build and verify the saved line breaks in App Store Connect.

For example, when the uploaded build contains these changes:

```text
• Fixed saved plugin connections being lost when a local key was temporarily unavailable.

• Fixed interrupted MDBList syncs losing confirmed export progress.
```

Ask for the affected device, OS, server type and reproduction steps when useful. Do not request passwords or private server addresses in public feedback.

For each authorised upload, use the existing internal and external groups and verify availability separately, following the [test-group policy](versioning.md#testflight-test-groups). Do not create groups or invite new testers without separate approval. A tvOS-only update does not require an iOS upload. Supply Apple’s review contact details privately in App Store Connect. For external review, provide a working review server/account with authorised sample media and any required PIN; a media-client login screen alone does not let Apple exercise playback. Do not put those credentials in Git or public release notes. Apple documents the [test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/) and [external testing review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/) requirements.

The uploaded TestFlight build and current source are separate revisions. A merge or GitHub source release does not update an uploaded binary or its review. Assess beta capabilities against the selected build, not the latest documentation or local development installation.

Current source uses Lucid Engine on iOS and tvOS, as described in the [Lucid Engine guide](../cores/player-engine.md). Lucid Engine uses compressed AC-3/E-AC-3 at normal speed and decoded PCM for other formats. Verify HDMI output, AirPlay, HDR, Dolby Vision, audible output and track switching on the selected build and device route. Recorded device tests do not establish every output configuration.

The preference-sync extension retains the existing encrypted `VividAccountVault.payload` field and adds optional values inside its encoded payload, without adding CloudKit schema fields. Existing vaults remain readable. Merge checks cover independent edits, deletion markers, deterministic conflict resolution and profile ordering. Apple TV restoration was confirmed after the [Production schema deployment](versioning.md#production-icloud-restoration). Fresh iPhone restoration, API-key removal, deletion propagation and device-specific playback/subtitle isolation still need separate verification against the selected build. Apple describes encrypted record fields in [Encrypting User Data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data).

Remaining validation includes physical iPad behaviour, the remaining iCloud scenarios above, older Apple TV hardware, additional HDR/audio routes and the provider-specific limits in the [Emby guide](../cores/emby.md). External distribution requires the selected platform builds and any required Beta App Review to complete.

## App Store submission

Vivid has not been submitted to the App Store yet. TestFlight approval does not carry over to App Review, so check each item against the exact builds being submitted, on both platforms. Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) and [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/) are the source of truth; recheck them before each submission.

| Item | What to check |
| --- | --- |
| Build tools | Uploads need the SDK and Xcode versions Apple currently requires (Xcode 26 or later with the iOS 26 and tvOS 26 SDKs at the time of writing). |
| Privacy manifests | Review the archive's privacy report as described in [Check the distribution archive](#check-the-distribution-archive), and read any ITMS-91053 or ITMS-91061 email after upload. |
| App Privacy answers | Match App Store Connect's answers to the privacy manifest and the privacy policy. Data sent only to the person's own media server, their private iCloud database or a service they connect with their own key does not reach Vivid. |
| Privacy policy | Use [vividapp.co/privacy](https://vividapp.co/privacy) and paste the same text into the Apple TV Privacy Policy field. Update the website and in-app text together before submitting a build that changes how data is handled. |
| Support URL | Use [vividapp.co/support](https://vividapp.co/support), which has real contact details. |
| Age rating | Answer Apple's current age rating questions for what Vivid shows: TMDb artwork, ratings and trailer links, plus the person's own library. Vivid has no web browser, chat, advertising or user-generated content. |
| Content rights | Vivid shows TMDb metadata and artwork, YouTube trailer thumbnails, OpenSubtitles subtitles and IntroDB and TheIntroDB timestamps. Keep the terms that allow each one, and check that bundled server and service logos stay within each owner's brand policy (for Silo, see the [trademark notes](../../THIRD_PARTY_NOTICES.md#server-and-service-names)). |
| Export compliance | Both app Info.plists set `ITSAppUsesNonExemptEncryption` to `NO`. Lucid Engine's FFmpeg uses Apple's Secure Transport for HTTPS streams and includes no OpenSSL; confirm the exemption still applies and record why. |
| Screenshots | Show the app in use with media that is in the public domain or licensed for reuse, not a login screen on its own or artwork Vivid has no rights to. Provide iPhone, 13-inch iPad and Apple TV sets in the sizes App Store Connect asks for. |
| Licences and source | Check that Open Source Licences lists every library in the archive. The App Store has no beta description, so publish the matching source and build instructions for each App Store version and link them from the support or marketing page. See [Licence and source delivery](#licence-and-source-delivery). |
| EU trader status | Declare trader status before EU distribution. A trader's address, phone number and email appear on the EU product page. |

### Review server

App Review needs to sign in and play something; a login screen alone is not enough.

- Use a Silo, Emby or Jellyfin server reachable from the internet over HTTPS with a hostname, not a local address or VPN name. It must also work on IPv6-only networks.
- Use a review account that does not expire and has no PIN, or give the PIN in the review notes. Keep the server running until the review finishes.
- Load only media that is in the public domain or licensed for reuse: at least one film and one series with several episodes, with subtitles and chapters.
- Make sure the same account works on iPhone, iPad and Apple TV.
- Put the server address, username and password only in App Store Connect's sign-in fields and notes, never in Git, release notes or public text.

### Review notes

Start from this text and add the server details in App Store Connect:

> Vivid plays media from servers that people run themselves (Silo, Emby or Jellyfin). It doesn't sell or supply content, create accounts or offer in-app purchases. Please use the demo server and account provided to sign in, browse and play the sample titles, which are in the public domain or licensed for reuse.
>
> Plugins are optional connections to TMDb, MDBList and OpenSubtitles using the person's own free API key. They don't download or run code. Seerr is an optional connection to a request manager the person runs alongside their own server. Trailers open in the YouTube app, or the browser on iPhone and iPad; Vivid doesn't download them. Downloads are offline copies from the person's own server.
>
> Diagnostics reports stay on the device unless the person chooses Send in Settings → Diagnostics, where they can see exactly what is sent.

## GitHub workflows

The source-release workflow creates GitHub source releases only. The other workflows, listed under [release validation](versioning.md#validation), run checks or unsigned device builds; an active workflow is not proof that Apple distribution has been configured or validated. Use the existing standard runners for approved regression validation, without enabling paid capacity.

Vivid's Apple beta builds are distributed through TestFlight only. The unsigned sideload IPA builds and their Fastlane lanes were removed, along with the Ruby tooling they needed.
