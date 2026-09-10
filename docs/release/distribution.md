<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">App Distribution</h1>
<p align="center">Local device builds and Apple beta distribution.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses TestFlight for Apple beta distribution. Its App Store Connect record includes iOS and tvOS, with registered identifiers, signing capabilities and internal builds. GitHub publishes the corresponding [source releases](versioning.md). TestFlight distribution is separate from public App Store submission.

## What is ready

| Area | Current state |
| --- | --- |
| App targets | `Vivid` for iPhone/iPad and `VividTV` for Apple TV, generated from `iosApp/project.yml` |
| Supported OS versions | iOS/iPadOS 18 or later; tvOS 26 or later. Mac and Vision Pro distribution are disabled. |
| Build tools | Local Xcode 26.6. Apple currently requires the iOS/iPadOS 26 and tvOS 26 SDKs or later for uploads. |
| Branding | Vivid display names, gradient app icons, the TV App Store layer stack and Top Shelf artwork are included. |
| About | Version/build, contact, privacy information, TMDb attribution and bundled open-source notices are present. |
| iCloud | The encrypted private account vault includes profile order, shared preferences and TMDB/Seerr credentials on iPhone, iPad and Apple TV. Playback and subtitle settings remain device-specific. The release container is registered; confirm the production schema and live restore on a second device before relying on it in an external beta. |
| Local device coverage | iPhone 16 Pro Max on iOS 26.6.1 and Apple TV 4K (3rd generation) on tvOS 26.6. These are development installations, not distribution archives. |
| iPad coverage | Focused simulator layout checks exist. Physical iPad playback, rotation and multitasking still need checking. |
| Apple upload tooling | Signed archives can be uploaded from the maintainer’s local Xcode configuration. Signing credentials remain outside Git and there is no committed TestFlight uploader. |

Check [Apple’s submission requirements](https://developer.apple.com/app-store/submitting/) when making the archive; an SDK requirement is different from the app’s minimum supported OS.

## Set up Vivid in Apple’s account

1. Confirm Apple Developer Program membership and register the configured Vivid bundle identity. Register the main app and its extensions under that team, then create Vivid in App Store Connect with the intended iOS and tvOS platforms. The bundle ID must match the uploaded build. [Apple’s distribution preparation guide](https://help.apple.com/xcode/mac/current/en.lproj/dev91fe7130a.html) explains why this needs to be settled before the first upload.
2. Map all five targets: `Vivid`, `VividNotificationService`, `VividDownloadsActivity`, `VividTV` and `VividTVTopShelf`. Each extension needs its own identifier and provisioning profile. Configure the intended App Group, shared Keychain access, push capability and `iCloud.com.blurbery.vivid` CloudKit container; check the tvOS user-management entitlement as well. [Deploy the `VividAccountVault` record schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema) to CloudKit’s production environment before a TestFlight build relies on account restoration.
3. Keep the registered release identifiers aligned across the signing configuration, entitlements, Info.plists and `SharedStorage`. The committed app defaults use `com.blurbery.vivid`, with `group.com.blurbery.vivid` for shared defaults and `com.blurbery.vivid.shared` for Keychain access. Extensions use the matching app prefix. The release identifiers and iCloud container are registered with Apple; confirm and deploy the production CloudKit schema before relying on account restoration in an external beta. The ignored `Signing/Local.xcconfig` retains development overrides. A clean install removes local preferences, metadata caches and download storage. On its first launch it clears any surviving Vivid Keychain entries, then can restore saved accounts and sessions from the user’s private iCloud vault. Watch history saved on the media server stays there.
4. Keep the current approved Apple marketing version for routine TestFlight updates and increment only the shared build number. Use that same number for iOS, tvOS and every embedded extension. Never reset the counter or copy a GitHub release version into the Apple version automatically. Changing the Apple marketing version requires explicit approval from blurbery. Record the exact pushed source commit and check both finished archives before upload. See [Versioning & Releases](versioning.md).

Uploads can use Xcode Organizer or the equivalent signed `xcodebuild -exportArchive` flow. New Fastlane upload automation is optional and must use Vivid’s registered app identity. Keep credentials and signing material out of this repository.

## Check the distribution archive

Archive Release builds for the authorised platforms from the exact source revision intended for testing. Validate them in Xcode Organizer before upload. Check the embedded extensions, signed frameworks, icons, minimum OS, entitlements and version/build values in the archive. Development build success does not prove distribution signing or Apple validation will pass.

Generate and review the archive’s privacy report. The app, notification service and Top Shelf have privacy manifests; verify the final embedded dependencies and required-reason API declarations too. Review App Store Connect’s privacy answers for the server, account, profile and session data Vivid stores through CloudKit; Apple’s [App Privacy guidance](https://developer.apple.com/app-store/app-privacy-details/) distinguishes data collected by the app through Apple frameworks from data Apple collects itself. Both app Info.plists currently declare `ITSAppUsesNonExemptEncryption = NO`. Confirm that answer against the finished build and complete any questions Apple presents; see [export compliance for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/).

Keep [third-party notices](../../THIRD_PARTY_NOTICES.md) matched to the exact packaged libraries. Vivid and VividKit are Apache-2.0. The tvOS AetherEngine package retains LGPL-3.0 with its Apple Store / DRM Exception. This does not relicense FFmpeg or FriBidi. FFmpeg frameworks are dynamic, while the subtitle/font frameworks include static libraries. Before external distribution, verify the corresponding-source and replacement/relinking materials available to recipients. Links into a private app repository alone do not establish that access.

## TestFlight information

The website source includes app privacy information at `/privacy`, alongside the website policy. Publish and verify that page before using `https://vividapp.co/privacy` as the beta privacy URL. Editing the repository does not update the live site.

Use `admin@vividapp.co` for feedback. A starting beta description is:

> I’m building Vivid for watching your own media on iPhone, iPad and Apple TV. Connect to Silo or Emby, browse your library and continue watching across your server accounts. Playback includes subtitles and chapters from your media and optional IntroDB skips. Jellyfin is planned.

For What to Test:

> Please check account setup and switching, iCloud account restore and cross-device deletion, Continue Watching and Next Up, episode selection, startup, seeking, repeated audio selection, embedded subtitles and chapters. On Apple TV, check swipe seeking and Match Frame Rate/Match Dynamic Range. On iPhone and iPad, check download progress and artwork, the Search keyboard, same-tap player controls and closing landscape playback. Please report the device, OS, server type, codec and steps when something fails. Do not include passwords or private server addresses in feedback.

Use an internal group first, then invite external testers after the selected platform builds pass the relevant checks. A tvOS-only update does not require an iOS upload. Supply Apple’s review contact details privately in App Store Connect. For external review, provide a working review server/account with authorised sample media and any required PIN; a media-client login screen alone does not let Apple exercise playback. Do not put those credentials in Git or public release notes. Apple documents the [test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/) and [external testing review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/) requirements.

The uploaded TestFlight build and current source are separate revisions. A merge or GitHub source release does not update an uploaded binary or its review. Assess beta capabilities against the selected build, not the latest documentation or local development installation.

Current source uses AetherEngine on tvOS and VividKit on iOS, as described in the [player engine core](../cores/player-engine.md). The tvOS native bridge defaults to compatible E-AC-3 conversion, with optional FLAC lossless bridging. HDMI output, AirPlay, HDR and Dolby Vision still depend on the source and route. Earlier VividKit HDMI stall-recovery verification does not validate the Aether route. Verify audible output and track switching on the selected TestFlight build.

The preference-sync extension retains the existing encrypted `VividAccountVault.payload` field and adds optional values inside its encoded payload, without adding CloudKit schema fields. Existing vaults remain readable. Merge checks cover independent edits, deletion markers, deterministic conflict resolution and profile ordering. Live two-device restoration, API-key removal and device-specific playback/subtitle isolation still require verification against the selected build. Apple describes encrypted record fields in [Encrypting User Data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data).

Remaining validation includes physical iPad behaviour, live two-device iCloud restoration/deletion, older Apple TV hardware, additional HDR/audio routes and the provider-specific limits in the [Emby guide](../cores/emby.md). External distribution requires the selected platform builds and any required Beta App Review to complete.

## GitHub and unsigned sideload builds

The source-release workflow creates GitHub source releases only. GitHub also lists player regression and sideload as active workflows; an active state is not proof that Apple distribution has been configured or validated. Use the existing standard runners for approved regression validation, without enabling paid capacity.

The retained Fastlane lanes are `ios ipa_ios_unsigned` and `ios ipa_tvos_unsigned`. They build unsigned IPAs for later re-signing; they do not manage Keychains, read Apple API credentials or upload to TestFlight. The root Ruby/Fastlane pins remain because those lanes use them. An unsigned IPA is not directly installable and cannot be uploaded to TestFlight. Re-signing must handle embedded extensions and matching entitlements; missing App Groups prevent shared extension features such as Top Shelf from working.

The sideload workflow still uses a separate build-tag and release-title format that does not match Vivid’s [source release rules](versioning.md). Adapt and validate that publishing step before dispatching it; it must not replace the version-only title and bullet-only source release notes.
