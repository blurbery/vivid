<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Versioning &amp; Releases</h1>
<p align="center">Semantic versions. Clear release notes.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses `semantic-release` to publish a GitHub source release after updates reach `main`. The workflow uses a standard Ubuntu runner, has a five-minute limit, and runs the release-rule checks before publishing. Apple signing and distribution are not part of this workflow.

## Version policy

<table width="100%">
  <thead>
    <tr><th align="left">Change</th><th align="left" width="10000">Version increment</th></tr>
  </thead>
  <tbody>
    <tr><td><code>feat:</code></td><td>Minor</td></tr>
    <tr><td><code>fix:</code>, <code>perf:</code></td><td>Patch</td></tr>
    <tr><td><code>!</code> after the type/scope, or a <code>BREAKING CHANGE:</code> footer</td><td>Major</td></tr>
    <tr><td>Documentation-only and housekeeping updates with <code>[skip release]</code></td><td>No release</td></tr>
    <tr><td>No new commits</td><td>No release</td></tr>
  </tbody>
</table>

The largest change since the previous version determines the increment. Tags use `v0.1.0`; the release title is `0.1.0` with no prefix, product name or extra wording.

Shipped logo, branding, artwork and small visual polish updates are **patch changes**: increment the last number by one, for example `0.0.1` → `0.0.2`. Use `fix:` or `style:` as appropriate, not `feat:`. Documentation-only changes use `docs:` with `[skip release]` and must not increment the version. Reserve `feat:` for new functionality. Keep existing published versions; this policy applies to future releases.

Vivid’s source releases in this repository begin at `v0.6.0`.

## Version shown in the app

Settings → About displays `CFBundleShortVersionString` and `CFBundleVersion` as version (build). The Apple marketing version and GitHub source-release version are independent. Record the exact pushed source commit for each TestFlight upload; do not change the Apple marketing version to match a GitHub tag.

TestFlight marketing version stays `0.14.3` until blurbery explicitly approves changing it before archiving or uploading. Each authorised update uses that platform's latest uploaded App Store Connect build number plus exactly 1. iOS/iPadOS and tvOS advance independently, including paired uploads; never skip numbers just to make them match. App Store Connect is the current upload history. The [recorded Apple builds](#recorded-apple-builds) below are historical evidence, not a maintained upload ledger.

Apple requires TestFlight App Review for the first build of a version; later builds within that version may not need a full review. Keeping the version stable avoids introducing a new version for every beta update, but does not guarantee immediate approval. Returning to a previously reviewed marketing version does not guarantee that a new build will skip review; expiring another build does not provide that guarantee either. See [Apple’s TestFlight App Review guidance](https://developer.apple.com/help/glossary/testflight-app-review/).

Check the uploaded history before each release, including builds still processing. Local development and device-test builds do not reserve TestFlight numbers, and GitHub release versions do not control them. A single-platform update leaves the other platform's uploaded build unchanged. Every embedded extension must match its containing app. If the latest uploaded number cannot be verified or the next number is unavailable, stop and report the conflict rather than guessing, reusing or silently skipping a number. Do not assume the committed baseline has been uploaded.

`iosApp/project-common.yml` is the committed source for the Apple marketing-version and build-number baseline shared by all shippable targets. TestFlight archives must retain that approved marketing version. The tag resolver in `scripts/ci/resolve-marketing-version.sh` remains available for source-tagged unsigned builds; it must not automatically select the marketing version for TestFlight. Unsigned lanes accept `BUILD_NUMBER` as `CURRENT_PROJECT_VERSION`. Check both finished archives and their extensions before upload.

The app does not query GitHub APIs at runtime. A local or simulator build is not an uploaded TestFlight binary, even when its version and counter match. Identify distribution by the actual uploaded archive and source revision.

## TestFlight-only updates

Build, validate, upload and distribute the authorised source through App Store Connect. Use archive-time `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` overrides, verifying the app and extensions. Do not commit counters, create a bookkeeping PR/tag/release, or add an upload record solely for TestFlight. Preserve signed archives and dSYMs; clean task-created regenerable caches after acceptance.

## Release notes

### TestFlight test groups

Every user-authorised Vivid TestFlight upload includes distribution to the existing internal and external test groups for that platform, unless the user explicitly limits the audience. After processing, attach the exact uploaded build to those groups, save relevant What to Test notes, and submit for Beta App Review when required. Verify group assignment and actual availability separately; report processing, review or permission blockers as pending, never as distributed. Reuse existing groups and testers; do not create groups, invite new testers or change public-link settings without explicit permission. If the intended groups are ambiguous, ask before assigning. This standing distribution preference does not independently authorise a new upload.

### TestFlight note format

Use simple plain-text change bullets, with one blank line between them. State what was fixed or changed and its user-visible effect, using concise Australian English. Do not add headings, bold markers, testing instructions, em dashes or source links to What to Test. Describe only changes included in the build; do not invent validation results.

```text
• Fixed slow media information when opening series details.

• Fixed skip buttons appearing while playback was loading or buffering.
```

Keep exact per-platform version/build source mappings and dependency build instructions in the beta description, following [source delivery](distribution.md#licence-and-source-delivery).

This format applies to TestFlight notes only. GitHub release notes and App Store notes retain their separate writing preferences.

### GitHub release note format

Documentation-only and housekeeping commits must include `[skip release]`. Preserve the marker in the final squash message. Such commits neither trigger a release nor contribute to the version calculation or notes in a later release. Ordinary commits retain the normal versioning rules.

Keep this format for every app release. Do not publish a release for documentation-only work. Release bullets describe user-visible changes in plain language; implementation details and testing evidence belong in the contribution report.

> [!IMPORTANT]
> Release titles contain only the version number. Bodies contain only flat update bullets, with no headings, dates, author names, commit hashes, comparison links or automated footer.

The default bullet is the commit subject with its Conventional Commit prefix removed.

For an update with several user-visible changes, add curated bullets to the commit message:

```text
feat: add a new browsing feature

Release-Notes:
- Add the new browsing feature.
- Improve keyboard navigation in the picker.
```

Keep each bullet on one line, directly after `Release-Notes:`. A blank line ends the list. Write specific changes in plain language; do not describe planned integrations as delivered. Internal commit bodies and AI attribution trailers are not copied into release notes.

## Validation

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run test:release
```

The tests cover major/minor/patch rules, ordinary commit messages, empty ranges, curated bullets, duplicate notes, markup escaping and the version-only title. They validate release tooling, not the Apple app. For app changes, report relevant builds, tests, device checks and gaps under the contribution policy; blurbery controls publishing and merge decisions.

Dependencies are pinned in `package-lock.json`; the Node tools do not become app dependencies. The `VIVID_GIT_NOREPLY_EMAIL` repository variable must hold `blurbery`'s GitHub noreply address. The workflow uses its scoped `GITHUB_TOKEN` and does not publish an npm package or comment on issues/PRs.

GitHub currently lists the source-release, player-regression and sideload workflows as active. The source-release workflow runs on main updates; player regression supports pull requests and manual validation. Sideload publishing remains a separate, explicitly requested action and its legacy publishing format needs review before use. Do not enable paid capacity or change distribution settings as part of an ordinary source release. See [App Distribution](distribution.md).

The repository and its source releases are public. Apple beta distribution remains separate and available through TestFlight invitations or the public beta link, subject to places, eligibility and review.

Each newly published source release also posts its version and update bullets to the Vivid Discord server's GitHub channel. The notification uses Vivid's silver-grey embed colour and ends with a direct link to the corresponding GitHub release. Its Discord webhook is stored only in the encrypted `DISCORD_RELEASE_WEBHOOK_URL` repository secret.

## Recorded Apple builds

These dated records preserve earlier source mappings and validation. Build availability and group membership describe the time of each entry, not current TestFlight status. Use App Store Connect and its beta description for newer builds; do not add bookkeeping commits merely to record uploads. Local diagnostic build numbers in other guides are independent of TestFlight counters.

On 13 September 2026, iPhone/iPad `0.14.3 (21)` and tvOS `0.14.3 (20)` were archived from merged main commit `a8d6d8099b49a905edf720715a08af1622d0aaf3` using Xcode 26.6 and explicit build-number overrides. Live App Store Connect history was checked at iOS 20 and tvOS 19 before advancing each platform by one. These builds include PR #13: removal of retired iOS navigation and unnecessary requests, the iPhone detail poster/shading swipe fix, and cached tvOS Spotlight artwork preparation with first-card startup, timer preservation and reverse wrapping. The [regression run](https://github.com/blurbery/vivid/actions/runs/34731051388) passed iOS tests and the tvOS build for the identical application tree before squash merge. Both archives passed app/extension version, signature and existing Keychain identity checks; distribution exports used Production CloudKit, and bundled licences and privacy manifests were checked against the previous uploads. Apple accepted both uploads. Both builds completed processing and have Localised testing notes with immutable source and dependency links. Both are Testing in the existing internal and external groups, with automatic tester notifications enabled. No new physical-device playback test was performed on these distribution archives. Release archives and symbols are retained. The subsequent build-counter and distribution-record commit uses `[skip release]` and does not create a GitHub source release or contribute TestFlight housekeeping to later release notes.

On 12 September 2026, iPhone/iPad `0.14.3 (20)` and tvOS `0.14.3 (19)` were archived from published main commit `96b5f339192c0a87f979717fa15aceb6efdaa4a7` using Xcode 26.6. Live App Store Connect history was checked at iOS 19 and tvOS 18 before advancing each platform by one. These builds include PR #12: native tvOS card focus, steadier Home layout, removal of obsolete navigation and prefetch work, iOS-style tvOS Settings and the shared Emby person-date fix. The full Home cache and current Spotlight remain. The [regression run](https://github.com/blurbery/vivid/actions/runs/34695468089) passed iOS tests and the tvOS build for the application sources; later changes only update documentation and build counters. Both Release archives and distribution exports passed app/extension version, signature and existing identity checks, with Production CloudKit verified on each host app. Bundled licences and privacy manifests were checked. Apple accepted both uploads. Both completed processing and have Localised testing notes with immutable source and dependency links; saved line breaks were verified after reloading. Both builds are Testing in the existing internal and external groups after beta submissions, with automatic tester notifications enabled. Existing bundled media-framework dSYM warnings did not block either upload; archives and Vivid symbols are retained. blurbery confirmed the native focus and Settings changes on Apple TV before release. No new physical-device playback or VoiceOver test was performed on these release archives.

On 12 September 2026, iPhone/iPad `0.14.3 (19)` and tvOS `0.14.3 (18)` were archived from published main commit `9dcb3bb43dd778386c5231228685cf86222b39d1` using Xcode 26.6. App Store Connect upload history was checked first at iOS 18 and tvOS 17; every extension matches its containing app. These builds include the security fixes from PR #10, the owner-approved Settings/profile refinements and eligible mobile Emby download conversion. The [regression run](https://github.com/blurbery/vivid/actions/runs/34679676190) completed 961 iOS tests with two optional fixture tests skipped and no failures, and passed the tvOS build. Both signed Release archives and exported apps/extensions passed version, signature, existing identity and Production iCloud entitlement checks. The bundled engine source notice now points to the security revision. Apple accepted both uploads and completed processing. Localised notes retain blank lines between change/test blocks and immutable source and dependency-rebuild links. Both builds are attached to the existing internal and external groups, with external Testing confirmed and automatic notifications enabled. Apple reported non-blocking missing dSYMs for bundled media libraries; signed archives and Vivid’s own symbols are retained. The owner tested the layout refinements on iPhone and Apple TV before release; full Emby conversion, cleanup and offline playback still require an eligible-account device check. No new physical-device playback test was performed on these Release archives.

On 12 September 2026, iPhone/iPad `0.14.3 (18)` and tvOS `0.14.3 (17)` were archived from published main commit `e78d272c49ddfb952b60cad89322400e5434fb01`. This fixes missing local plugin keys being treated as disconnects, tightens matching-account access, preserves confirmed MDBList progress after interruptions and adds bounded OpenSubtitles download reuse. Relevant connection and in-app privacy docs were updated. The [regression run](https://github.com/blurbery/vivid/actions/runs/34667062561) passed the complete iOS suite and tvOS build for this exact revision. Both signed archives and distribution exports passed app/extension version, signature, existing Keychain/iCloud identity and Production iCloud entitlement checks. Apple accepted both uploads and completed processing; App Store Connect confirmed Testing for both existing internal and external groups. External notifications are enabled. Localised notes contain seven plain-text bullets separated by blank lines, verified after reloading, plus immutable source and dependency-rebuild links. At upload, Production iCloud recovery had not been verified on devices; see the later [Production restore record](#production-icloud-restoration). Recovery after an in-place update still needs separate verification; keys already removed from every saved copy may need entering again. Existing MDBList imports/checkpoints remain local, and retries still read fresh remote snapshots. Apple reported non-blocking missing dSYMs for bundled media libraries, limiting their crash symbolication. Signed app archives and symbols are retained.

On 12 September 2026, iPhone/iPad `0.14.3 (17)` and tvOS `0.14.3 (16)` were archived from published main commit `416e56d95d56b92fcad38dfebe9291dac3423968`, using explicit `CURRENT_PROJECT_VERSION=17` and `CURRENT_PROJECT_VERSION=16` archive overrides respectively. Both retain `MARKETING_VERSION=0.14.3`; every extension matches its app. Apple accepted both uploads. This includes the player and Emby changes from PR #9, legacy DiceBear removal, GPLv3 with the Apple distribution permission and updated bundled notices. The [regression run](https://github.com/blurbery/vivid/actions/runs/34660655057) passed the complete iOS suite, tvOS build and synthetic preview checks for identical application sources. Both signed Release archives and exported apps/extensions passed version, signature, existing identity and production iCloud entitlement checks. No new physical-device test was performed on these Release archives. Apple reported missing dSYMs for bundled media libraries, limiting their crash symbolication without blocking upload. Processing completed for both platforms. Localised testing notes include immutable source and dependency-rebuild links. Both builds are available to the existing internal tester group and the existing external group; App Store Connect confirmed Testing for both external builds, with automatic notifications enabled. The project baseline at that point recorded iOS 17 and tvOS 16; these configuration and documentation updates do not change the archived application sources.

On 11 September 2026, iPhone/iPad `0.14.3 (16)` was uploaded from main commit `1b0f8098908c9b990e56beda9083dc5387897adc`. It contains the owner-approved iPad layout changes; iPhone layout paths are preserved and tvOS remains on uploaded build `15`. The signed Release archive and exported app/extensions passed version, signature, identity and production-entitlement checks. The [regression run](https://github.com/blurbery/vivid/actions/runs/34599633657) passed the complete iOS suite and tvOS build for the identical application sources in `f7c45d5`; the upload commit only changes the build baseline and docs. Apple processing completed, Localised testing notes were saved and the existing internal tester group is attached. The upload reported missing dSYMs for bundled media libraries, limiting their crash symbolication without blocking distribution. External distribution for build `16` was not verified during this upload. A subsequent App Store Connect check confirmed iOS build `15` was already testing with the external group.

Local Mac builds `0.14.3 (16–19)` refine the iPad layout: full-screen movie/series details, adaptive poster grids, compact Search and For You controls, landscape Search, centred Settings subpages and a soft Home fade at the spotlight dots. Final build `19` passed signing and build checks, opened on the Mac as Designed for iPad and received owner acceptance. Launching without the Xcode debugger avoided the earlier startup stall. Physical iPad rotation remains unverified. None of these local builds was uploaded to TestFlight. These local numbers do not reserve TestFlight numbers. The iPhone/iPad TestFlight upload uses `0.14.3 (16)`, following uploaded build `15`.

On 11 September 2026, iOS/iPadOS and tvOS `0.14.3 (15)` were archived from main commit `7d4ac7f55b8f04c755bb330c8844f2023930b5c9` and accepted by Apple. This includes MDBList history and watchlist sync, OpenSubtitles, iCloud plugin connections, player fixes and updated in-app privacy text. Both signed Release archives and exported apps/extensions passed version, signature, existing identity and Production CloudKit entitlement checks. The [regression run](https://github.com/blurbery/vivid/actions/runs/34590133364) passed the iOS suite and tvOS build for the application logic in `d9f6d52`; subsequent app changes were verified as text-only, followed by the build-counter update. No new physical-device playback test was performed on these Release archives. Apple reported missing dSYMs for bundled media libraries, limiting their crash symbolication without blocking either upload. Processing completed for both platforms, testing notes were saved, and both builds are attached to the existing internal tester group. Neither build has been submitted to the external group in this upload.

After the build 14 upload, [PR #8](https://github.com/blurbery/vivid/pull/8) added MDBList and OpenSubtitles features to main. Its local development builds also used `0.14.3 (14)`; no new TestFlight upload was made for that work. Build `15` uploaded those changes with the same marketing version; see its record above.

These are historical records, not a live App Store Connect status feed. Pending checks refer to the stated revision and are not automatically satisfied by a later build. The latest recorded uploads are iPhone/iPad build 21 and tvOS build 20, as recorded above.

Both iOS/iPadOS and tvOS `0.14.3 (14)` were archived and uploaded from `24f992e24346b17f123c7a80d4360cb91e486869` on `fix/episode-card-resume-labels`. This includes the episode/resume labels, unused-controller audio-session ownership fix, larger tvOS Next Up picture and removal of tvOS seek thumbnails. Temporary transport diagnostics were removed before archiving. Both Release archives and exported apps/extensions passed signature, version, existing keychain and Production CloudKit entitlement checks. Apple accepted both uploads on 11 September 2026; bundled media-library dSYM warnings limit symbolication without blocking upload. Processing completed for both platforms, testing notes were saved, and both builds are attached to the existing internal tester group. blurbery subsequently confirmed completing external distribution. The [regression run](https://github.com/blurbery/vivid/actions/runs/34566248396) passed both the tvOS build and iOS test suite for the uploaded source revision. The latest pause fix and thumbnail removal still need sustained device verification.

### Production iCloud restoration

On 12 September 2026, a fresh TestFlight restore on Apple TV failed with CloudKit `Invalid Arguments (12/2006): Cannot create new type VividAccountVault in production schema`. The signed Production entitlements were correct, but the record type had not been deployed. Archive entitlement checks did not detect this server-side omission.

With blurbery's approval, the `VividAccountVault` schema and its encrypted `payload` field were deployed to Production in `iCloud.com.blurbery.vivid`. CloudKit Console confirmed deployment and the record type was checked in Production. This deployed the schema only, without copying Development records or changing the app's private-database access. No new app binary was needed.

After an existing configured installation had an opportunity to sync, blurbery confirmed that restoration worked on Apple TV. This confirms that restore scenario on TestFlight tvOS `0.14.3 (17)`, not every iCloud feature. Fresh iPhone restoration, each plugin's connection state after restore, deletion propagation and isolation between different accounts still need separate confirmation against the selected build. See [restore troubleshooting](../server-connections.md#restore-and-troubleshooting). Preserve a configured installation while checking another device.

### Earlier builds

The paired `0.14.3 (5)` archives were uploaded from source commit `450f8aafb4f3e993dc9595cdb548676c784c07eb`, using that previously reviewed version at blurbery’s request. Both build `5` releases are available to the external tester group. The earlier `0.15.0 (4)` pair was withdrawn from review after both replacements became available. The paired `0.14.3 (6)` archives were uploaded from source commit `2ef1fae89ebeb876b7efae05db4a94f6a9af208b` on `fix/icloud-setup-fallback`. This emergency fix keeps manual setup available after iCloud errors and adds optional restoration with Back on Apple TV. tvOS external testing was verified in App Store Connect; blurbery completed the iOS external submission. Both signed Release archives passed version and signature checks. Fresh-install restoration and Back behaviour still need device verification. The tvOS-only `0.14.3 (7)` archive was uploaded from source commit `4c40c302b4806d5aa82a12845c585e53afe8ed84` on `fix/tvos-pcm-channel-negotiation`. It adds bounded HDMI PCM channel negotiation and release diagnostics; Dolby Digital output with Auto and real AirPlay route switching still require tester confirmation. The [player regression run](https://github.com/blurbery/vivid/actions/runs/34459344249) passed, and the signed tvOS app and Top Shelf extension passed version, signature and production-entitlement checks. Apple processing completed and the build is available internally. blurbery subsequently approved the external submission and confirmed availability. At that point iOS remained on build `6`; no iOS archive was uploaded for build `7`. Builds `8` to `11` below were local device builds. tvOS `0.14.3 (8)` from `4d8916ffdec9e088a0c376de1ac0044aa029c261` was built in Release configuration with Xcode 26.6 and installed in place on the paired Apple TV 4K running tvOS 26.6. The bundle ID, signing team, shared keychain group and user-independent keychain entitlement were verified before installation. The app was not uninstalled or launched, and nothing was uploaded to TestFlight. The [regression run](https://github.com/blurbery/vivid/actions/runs/34477369346) passed both the tvOS simulator build and iOS suite; broader device coverage was not established by those checks.

tvOS `0.14.3 (9)` from `d831dfd6ee352b9721bda978fb48ababf4c9cd91` was built in Release configuration with `CURRENT_PROJECT_VERSION=9` and installed in place on the paired Apple TV. This build adds the AVKit native host, subtitle handoff and episode-frame guards. The signed bundle, extension versions and existing keychain entitlements passed verification. The app was not uninstalled or launched, and no TestFlight upload was made. CI and device playback verification remain pending.

tvOS `0.14.3 (10)` from `eb343ca1fd89a03c999fbe14a11a1a8d33599dfc` was built in Release configuration with `CURRENT_PROJECT_VERSION=10` and installed in place on the paired Apple TV. It suppresses UIKit activity indicators inside the native playback host while retaining Vivid’s dots. The signed app, extension versions and existing keychain entitlements passed verification. The app was not uninstalled or launched, and no TestFlight upload was made. Visual confirmation of the loading indicator remains pending.

tvOS `0.14.3 (11)` from `fdb75eebfebe96f259fa2a136d3b284d1dc69b79` was built in Release configuration with `CURRENT_PROJECT_VERSION=11` and installed in place on the paired Apple TV. It adds the lossless-audio toggle to the actual tvOS playback pane and displays measured read-ahead in stats and both timeline bars. Build, signature, extension-version and existing keychain checks passed. The app was not uninstalled or launched, and no TestFlight upload was made. blurbery accepted this build after local testing and requested adoption on main. This does not establish every format or output-route combination. The local build and package caches are retained at blurbery’s request for incremental updates during this testing loop.

tvOS-only `0.14.3 (12)` was archived from `e6bda8c`, with identical application sources on merged main commit `21893b860db4eb553458d835efae275436283d25`. It retains build `11` playback code, with documentation and build-counter updates. The [player regression run](https://github.com/blurbery/vivid/actions/runs/34484833167) passed both the tvOS simulator build and complete iOS suite for `fdb75ee`. The Release archive and exported distribution app/Top Shelf passed signature, version and identity checks, including production CloudKit and the existing keychain audience. Apple accepted the tvOS upload on 11 September 2026; Processing completed, testing notes were saved, and App Store Connect confirmed Testing for both the existing internal and external groups after submission. The uploader reported missing dSYMs for bundled media frameworks, limiting symbolication for those libraries without blocking the upload. No iOS binary was included.

iOS/iPadOS and tvOS `0.14.3 (13)` were archived from main commit `afc3b738718177db641add93891a7445c3f0d250`, containing merged PR #6 and the shared build-counter update. The [regression run](https://github.com/blurbery/vivid/actions/runs/34554395313) passed the complete iOS suite and tvOS simulator build for the merged application sources. Both signed Release archives and exported apps/extensions passed version, signature and configured-entitlement checks, including production CloudKit and the existing keychain audience. Apple accepted both uploads on 11 September 2026. Processing completed for both platforms, testing notes were saved, and App Store Connect confirmed Testing for the existing internal and external groups after submission. This update includes separate one-minute partial progress and 90%/credits/natural-end completion, recap fallback, pause recovery, resume displays and Settings fixes. At upload, the completion changes had passed automated checks without recorded device verification. Bundled media-library dSYM warnings remain non-blocking and limit symbolication for those dependencies. Retained local caches support incremental fixes; the signed archives preserve the shipped app symbols.
