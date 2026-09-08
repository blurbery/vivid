<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">App Distribution</h1>
<p align="center">Local device builds and future Apple distribution.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

I’m preparing Vivid for TestFlight. The app has been tested through local Xcode installations, but there is no Vivid App Store Connect record or registered release signing setup yet. No build has been uploaded to Apple. GitHub currently publishes [source releases](versioning.md).

## What is ready

| Area | Current state |
| --- | --- |
| App targets | `Vivid` for iPhone/iPad and `VividTV` for Apple TV, generated from `iosApp/project.yml` |
| Supported OS versions | iOS/iPadOS 18 or later; tvOS 26 or later. Mac and Vision Pro distribution are disabled. |
| Build tools | Local Xcode 26.6. Apple currently requires the iOS/iPadOS 26 and tvOS 26 SDKs or later for uploads. |
| Branding | Vivid display names, graphite app icons, the TV App Store layer stack and Top Shelf artwork are included. |
| About | Version/build, contact, privacy information, TMDb attribution and bundled open-source notices are present. |
| iCloud | Private CloudKit account sync is implemented for iPhone, iPad and Apple TV. The release container and production schema still need registration and deployment in Apple’s account. |
| Local device coverage | iPhone 16 Pro Max on iOS 26.6.1 and Apple TV 4K (3rd generation) on tvOS 26.6. These are development installations, not distribution archives. |
| iPad coverage | Focused simulator layout checks exist. Physical iPad playback, rotation and multitasking still need checking. |
| Apple upload tooling | Vivid has no configured uploader, signing automation or App Store Connect credentials yet. |

Check [Apple’s submission requirements](https://developer.apple.com/app-store/submitting/) when making the archive; an SDK requirement is different from the app’s minimum supported OS.

## Set up Vivid in Apple’s account

1. Confirm Apple Developer Program membership and register the configured Vivid bundle identity. Register the main app and its extensions under that team, then create Vivid in App Store Connect with the intended iOS and tvOS platforms. The bundle ID must match the uploaded build. [Apple’s distribution preparation guide](https://help.apple.com/xcode/mac/current/en.lproj/dev91fe7130a.html) explains why this needs to be settled before the first upload.
2. Map all five targets: `Vivid`, `VividNotificationService`, `VividDownloadsActivity`, `VividTV` and `VividTVTopShelf`. Each extension needs its own identifier and provisioning profile. Configure the intended App Group, shared Keychain access, push capability and `iCloud.com.blurbery.vivid` CloudKit container; check the tvOS user-management entitlement as well. [Deploy the `VividAccountVault` record schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema) to CloudKit’s production environment before a TestFlight build relies on account restoration.
3. Register and provision the matching release identifiers in the signing configuration, entitlements, Info.plists and `SharedStorage`. The committed app defaults use `com.blurbery.vivid`, with `group.com.blurbery.vivid` for shared defaults and `com.blurbery.vivid.shared` for Keychain access. Extensions use the matching app prefix. These identifiers and the production iCloud container have not yet been registered with Apple. The ignored `Signing/Local.xcconfig` retains the development app bundle IDs. A clean install removes local preferences, metadata caches and download storage. On its first launch it clears any surviving Vivid Keychain entries, then can restore saved accounts and sessions from the user’s private iCloud vault. Watch history saved on the media server stays there.
4. Set an explicit marketing version matching the source release and an unused build number in every shipped target. The committed development baseline is still 0.6.0 (1). Check the version shown in the finished archive rather than relying on the Git tag alone.

The first Vivid upload can use Xcode Organizer after these steps. New Fastlane upload automation is optional and must use Vivid’s registered app identity. Keep credentials and signing material out of this repository.

## Check the distribution archive

Archive Release builds for both platforms from the exact source revision intended for testing. Validate them in Xcode Organizer before upload. Check the embedded extensions, signed frameworks, icons, minimum OS, entitlements and version/build values in the archive. Development build success does not prove distribution signing or Apple validation will pass.

Generate and review the archive’s privacy report. The app, notification service and Top Shelf have privacy manifests; verify the final embedded dependencies and required-reason API declarations too. Review App Store Connect’s privacy answers for the server, account, profile and session data Vivid stores through CloudKit; Apple’s [App Privacy guidance](https://developer.apple.com/app-store/app-privacy-details/) distinguishes data collected by the app through Apple frameworks from data Apple collects itself. Both app Info.plists currently declare `ITSAppUsesNonExemptEncryption = NO`. Confirm that answer against the finished build and complete any questions Apple presents; see [export compliance for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/).

Keep [third-party notices](../../THIRD_PARTY_NOTICES.md) matched to the exact packaged libraries. Vivid and VividKit are Apache-2.0; that does not relicense FFmpeg or FriBidi. FFmpeg frameworks are dynamic, while the subtitle/font frameworks include static libraries. Before external distribution, verify the corresponding-source and replacement/relinking materials available to recipients. Links into a private app repository alone do not establish that access.

## TestFlight information

The website source now includes app privacy information at `/privacy`, alongside the existing website policy. Publish and check that page before using `https://vividapp.co/privacy` as the beta’s privacy URL. Editing the repository does not update the live site.

Use `admin@vividapp.co` for feedback. A starting beta description is:

> I’m building Vivid for watching your own media on iPhone, iPad and Apple TV. Connect to Silo or Emby, browse your library and continue watching across your server accounts. VividKit handles playback, with subtitles and chapters from your media and optional IntroDB skips. Jellyfin is planned.

For What to Test:

> Please check account setup and switching, iCloud account restore and cross-device deletion, Continue Watching and Next Up, episode selection, startup, seeking, repeated audio selection, embedded subtitles and chapters. On Apple TV, check swipe seeking and Match Frame Rate/Match Dynamic Range. On iPhone and iPad, check download progress and artwork, the Search keyboard, same-tap player controls and closing landscape playback. Please report the device, OS, server type, codec and steps when something fails. Do not include passwords or private server addresses in feedback.

Start with an internal group, then invite external testers after the selected build passes the relevant checks. Supply Apple’s review contact details privately in App Store Connect. For external review, provide a working review server/account with authorised sample media and any required PIN; a media-client login screen alone does not let Apple exercise playback. Do not put those credentials in Git or public release notes. Apple documents the [test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/) and [external testing review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/) requirements.

Known limits for this beta include physical iPad verification, live two-device iCloud restoration/deletion, older Apple TV hardware, broad HDR/audio-format coverage and provider-specific features listed in the [Emby guide](../cores/emby.md). The compatible AC-3 fallback was confirmed; the original silent TrueHD track has not been confirmed fixed. TestFlight processing and any required Beta App Review remain pending until a real archive is uploaded.

## GitHub and unsigned sideload builds

The active release workflow creates GitHub source releases only. The Apple regression and sideload workflows remain disabled. Do not enable paid runner capacity as part of this setup.

The retained Fastlane lanes are `ios ipa_ios_unsigned` and `ios ipa_tvos_unsigned`. They build unsigned IPAs for later re-signing; they do not manage Keychains, read Apple API credentials or upload to TestFlight. The root Ruby/Fastlane pins remain because those lanes use them. An unsigned IPA is not directly installable and cannot be uploaded to TestFlight. Re-signing must handle embedded extensions and matching entitlements; missing App Groups prevent shared extension features such as Top Shelf from working.

The disabled sideload workflow still uses a separate build-tag and release-title format that does not match Vivid’s [source release rules](versioning.md). Adapt that publishing step before enabling it; it must not replace the version-only title and bullet-only source release notes.
