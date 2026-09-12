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
    <tr><td>Documentation, maintenance and other updates</td><td>Patch</td></tr>
    <tr><td>No new commits</td><td>No release</td></tr>
  </tbody>
</table>

The largest change since the previous version determines the increment. Tags use `v0.1.0`; the release title is `0.1.0` with no prefix, product name or extra wording.

Logo, branding, artwork, documentation and small visual polish updates are **patch changes**: increment the last number by one, for example `0.0.1` → `0.0.2`. Use `fix:`, `style:` or `docs:` as appropriate, not `feat:`. Reserve `feat:` for new functionality. Keep existing published versions; this policy applies to future releases.

Vivid’s source releases in this repository begin at `v0.6.0`.

## Version shown in the app

Settings → About displays `CFBundleShortVersionString` and `CFBundleVersion` as version (build). The Apple marketing version and GitHub source-release version are independent. Record the exact pushed source commit for each TestFlight upload; do not change the Apple marketing version to match a GitHub tag.

TestFlight marketing version stays `0.14.3` until blurbery explicitly approves changing it before archiving or uploading. Each authorised update uses that platform's latest uploaded App Store Connect build number plus exactly 1. iOS/iPadOS and tvOS advance independently, including paired uploads; never skip numbers just to make them match. The latest recorded uploads are build `19` for iPhone/iPad and build `18` for tvOS; these are historical records, not a substitute for checking App Store Connect. See [recorded Apple builds](#recorded-apple-builds).

Apple requires TestFlight App Review for the first build of a version; later builds within that version may not need a full review. Keeping the version stable avoids introducing a new version for every beta update, but does not guarantee immediate approval. Returning to a previously reviewed marketing version does not guarantee that a new build will skip review; expiring another build does not provide that guarantee either. See [Apple’s TestFlight App Review guidance](https://developer.apple.com/help/glossary/testflight-app-review/).

Check the uploaded history before each release, including builds still processing. Local development and device-test builds do not reserve TestFlight numbers, and GitHub release versions do not control them. A single-platform update leaves the other platform's uploaded build unchanged. Every embedded extension must match its containing app. If the latest uploaded number cannot be verified or the next number is unavailable, stop and report the conflict rather than guessing, reusing or silently skipping a number. Do not assume the committed baseline has been uploaded.

`iosApp/project.yml` is the committed source for the Apple marketing-version and build-number baseline shared by all shippable targets. TestFlight archives must retain that approved marketing version. The tag resolver in `scripts/ci/resolve-marketing-version.sh` remains available for source-tagged unsigned builds; it must not automatically select the marketing version for TestFlight. Unsigned lanes accept `BUILD_NUMBER` as `CURRENT_PROJECT_VERSION`. Check both finished archives and their extensions before upload.

The app does not query GitHub APIs at runtime. A local or simulator build is not an uploaded TestFlight binary, even when its version and counter match. Identify distribution by the actual uploaded archive and source revision.

## Release notes

### TestFlight test groups

Every user-authorised Vivid TestFlight upload includes distribution to the existing internal and external test groups for that platform, unless the user explicitly limits the audience. After processing, attach the exact uploaded build to those groups, save relevant What to Test notes, and submit for Beta App Review when required. Verify group assignment and actual availability separately; report processing, review or permission blockers as pending, never as distributed. Reuse existing groups and testers; do not create groups, invite new testers or change public-link settings without explicit permission. If the intended groups are ambiguous, ask before assigning. This standing distribution preference does not independently authorise a new upload.

### TestFlight note format

Use clean plain-text bullet blocks. Each bullet states the specific change and its user-visible effect. Directly underneath, add an indented `What to test:` line with the action to try and expected behaviour. Leave one blank line before the next bullet. Keep each change paired with its testing instructions, using concise natural Australian English and no em dashes, Markdown headings or bold markers. Describe only changes included in that build; do not invent validation results.

```text
• <What changed and how it affects users.>
  What to test: <What to try and what should happen.>

• <Next change and its user-visible effect.>
  What to test: <Relevant action and expected behaviour.>
```

This format applies to TestFlight notes only. GitHub release notes and App Store notes retain their separate writing preferences.

### GitHub release note format

An owner-requested housekeeping commit may include `[skip release]`. Such commits neither trigger a release nor contribute to the version calculation or notes in a later release. Ordinary commits retain the normal versioning rules.

Keep this format for every release, including documentation-only updates. Release bullets describe user-visible changes in plain language; implementation details and testing evidence belong in the contribution report.

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

## Recorded Apple builds

On 12 September 2026, iPhone/iPad `0.14.3 (19)` and tvOS `0.14.3 (18)` were archived from published main commit `9dcb3bb43dd778386c5231228685cf86222b39d1` using Xcode 26.6. App Store Connect upload history was checked first at iOS 18 and tvOS 17; every extension matches its containing app. These builds include the security fixes from PR #10, the owner-approved Settings/profile refinements and eligible mobile Emby download conversion. The [regression run](https://github.com/blurbery/vivid/actions/runs/34679676190) completed 961 iOS tests with two optional fixture tests skipped and no failures, and passed the tvOS build. Both signed Release archives and exported apps/extensions passed version, signature, existing identity and Production iCloud entitlement checks. The bundled engine source notice now points to the security revision. Apple accepted both uploads and completed processing. English (Australia) notes retain blank lines between change/test blocks and immutable source and dependency-rebuild links. Both builds are attached to the existing internal and external groups, with external Testing confirmed and automatic notifications enabled. Apple reported non-blocking missing dSYMs for bundled media libraries; signed archives and Vivid’s own symbols are retained. The owner tested the layout refinements on iPhone and Bedroom Apple TV before release; full Emby conversion, cleanup and offline playback still require an eligible-account device check. No new physical-device playback test was performed on these Release archives.

On 12 September 2026, iPhone/iPad `0.14.3 (18)` and tvOS `0.14.3 (17)` were archived from published main commit `e78d272c49ddfb952b60cad89322400e5434fb01`. This fixes missing local plugin keys being treated as disconnects, tightens matching-account access, preserves confirmed MDBList progress after interruptions and adds bounded OpenSubtitles download reuse. Relevant connection and in-app privacy docs were updated. The [regression run](https://github.com/blurbery/vivid/actions/runs/34667062561) passed the complete iOS suite and tvOS build for this exact revision. Both signed archives and distribution exports passed app/extension version, signature, existing Keychain/iCloud identity and Production iCloud entitlement checks. Apple accepted both uploads and completed processing; App Store Connect confirmed Testing for both existing internal and external groups. External notifications are enabled. English (Australia) notes contain seven plain-text bullets separated by blank lines, verified after reloading, plus immutable source and dependency-rebuild links. At upload, Production iCloud recovery had not been verified on devices; see the later [Production restore record](#production-icloud-restoration). Recovery after an in-place update still needs separate verification; keys already removed from every saved copy may need entering again. Existing MDBList imports/checkpoints remain local, and retries still read fresh remote snapshots. Apple reported non-blocking missing dSYMs for bundled media libraries, limiting their crash symbolication. Signed app archives and symbols are retained.

On 12 September 2026, iPhone/iPad `0.14.3 (17)` and tvOS `0.14.3 (16)` were archived from published main commit `416e56d95d56b92fcad38dfebe9291dac3423968`, using explicit `CURRENT_PROJECT_VERSION=17` and `CURRENT_PROJECT_VERSION=16` archive overrides respectively. Both retain `MARKETING_VERSION=0.14.3`; every extension matches its app. Apple accepted the uploads at 10:27 am and 10:30 am (Australia/Sydney). This includes the player and Emby changes from PR #9, legacy DiceBear removal, GPLv3 with the Apple distribution permission and updated bundled notices. The [regression run](https://github.com/blurbery/vivid/actions/runs/34660655057) passed the complete iOS suite, tvOS build and synthetic preview checks for identical application sources. Both signed Release archives and exported apps/extensions passed version, signature, existing identity and production iCloud entitlement checks. No new physical-device test was performed on these Release archives. Apple reported missing dSYMs for bundled media libraries, limiting their crash symbolication without blocking upload. Processing completed for both platforms. English (Australia) testing notes include immutable source and dependency-rebuild links. Both builds are available to the existing internal tester group and the 40-member external group; App Store Connect confirmed Testing for both external builds, with automatic notifications enabled. The project baseline at that point recorded iOS 17 and tvOS 16; these configuration and documentation updates do not change the archived application sources.

On 11 September 2026 at 10:52 pm (Australia/Sydney), iPhone/iPad `0.14.3 (16)` was uploaded from main commit `1b0f8098908c9b990e56beda9083dc5387897adc`. It contains the owner-approved iPad layout changes; iPhone layout paths are preserved and tvOS remains on uploaded build `15`. The signed Release archive and exported app/extensions passed version, signature, identity and production-entitlement checks. The [regression run](https://github.com/blurbery/vivid/actions/runs/34599633657) passed the complete iOS suite and tvOS build for the identical application sources in `f7c45d5`; the upload commit only changes the build baseline and docs. Apple processing completed, English (Australia) testing notes were saved and the existing internal tester group is attached. The upload reported missing dSYMs for bundled media libraries, limiting their crash symbolication without blocking distribution. External distribution for build `16` was not verified during this upload. A subsequent App Store Connect check confirmed iOS build `15` was already testing with the external group.

Local Mac builds `0.14.3 (16–19)` refine the iPad layout: full-screen movie/series details, adaptive poster grids, compact Search and For You controls, landscape Search, centred Settings subpages and a soft Home fade at the spotlight dots. Final build `19` passed signing and build checks, opened on the Mac as Designed for iPad and received owner acceptance. Launching without the Xcode debugger avoided the earlier startup stall. Physical iPad rotation remains unverified. None of these local builds was uploaded to TestFlight. These local numbers do not reserve TestFlight numbers. The iPhone/iPad TestFlight upload uses `0.14.3 (16)`, following uploaded build `15`.

On 11 September 2026, iOS/iPadOS and tvOS `0.14.3 (15)` were archived from main commit `7d4ac7f55b8f04c755bb330c8844f2023930b5c9` and accepted by Apple. This includes MDBList history and watchlist sync, OpenSubtitles, iCloud plugin connections, player fixes and updated in-app privacy text. Both signed Release archives and exported apps/extensions passed version, signature, existing identity and Production CloudKit entitlement checks. The [regression run](https://github.com/blurbery/vivid/actions/runs/34590133364) passed the iOS suite and tvOS build for the application logic in `d9f6d52`; subsequent app changes were verified as text-only, followed by the build-counter update. No new physical-device playback test was performed on these Release archives. Apple reported missing dSYMs for bundled media libraries, limiting their crash symbolication without blocking either upload. Processing completed for both platforms, testing notes were saved, and both builds are attached to the existing internal tester group. Neither build has been submitted to the external group in this upload.

After the build 14 upload, [PR #8](https://github.com/blurbery/vivid/pull/8) added MDBList and OpenSubtitles features to main. Its local development builds also used `0.14.3 (14)`; no new TestFlight upload was made for that work. Build `15` uploaded those changes with the same marketing version; see its record above.

These are historical records, not a live App Store Connect status feed. Pending checks refer to the stated revision and are not automatically satisfied by a later build. The latest recorded uploads are iPhone/iPad build 19 and tvOS build 18, as recorded above.

Both iOS/iPadOS and tvOS `0.14.3 (14)` were archived and uploaded from `24f992e24346b17f123c7a80d4360cb91e486869` on `fix/episode-card-resume-labels`. This includes the episode/resume labels, unused-controller audio-session ownership fix, larger tvOS Next Up picture and removal of tvOS seek thumbnails. Temporary transport diagnostics were removed before archiving. Both Release archives and exported apps/extensions passed signature, version, existing keychain and Production CloudKit entitlement checks. Apple accepted both uploads on 11 September 2026; bundled media-library dSYM warnings limit symbolication without blocking upload. Processing completed for both platforms, testing notes were saved, and both builds are attached to the existing internal tester group. blurbery subsequently confirmed completing external distribution. The [regression run](https://github.com/blurbery/vivid/actions/runs/34566248396) passed both the tvOS build and iOS test suite for the uploaded source revision. The latest pause fix and thumbnail removal still need sustained device verification.

### Production iCloud restoration

On 12 September 2026, a fresh TestFlight restore on Bedroom Apple TV failed with CloudKit `Invalid Arguments (12/2006): Cannot create new type VividAccountVault in production schema`. The signed Production entitlements were correct, but the record type had not been deployed. Archive entitlement checks did not detect this server-side omission.

With blurbery's approval, the `VividAccountVault` schema and its encrypted `payload` field were deployed to Production in `iCloud.com.blurbery.vivid`. CloudKit Console confirmed deployment and the record type was checked in Production. This deployed the schema only, without copying Development records or changing the app's private-database access. No new app binary was needed.

After an existing configured installation had an opportunity to sync, blurbery confirmed that restoration worked on Bedroom. This confirms that restore scenario on TestFlight tvOS `0.14.3 (17)`, not every iCloud feature. Fresh iPhone restoration, each plugin's connection state after restore, deletion propagation and isolation between different accounts still need separate confirmation against the selected build. See [restore troubleshooting](../server-connections.md#restore-and-troubleshooting). Preserve a configured installation while checking another device.

### Earlier builds

The paired `0.14.3 (5)` archives were uploaded from source commit `450f8aafb4f3e993dc9595cdb548676c784c07eb`, using that previously reviewed version at blurbery’s request. Both build `5` releases are available to the external tester group. The earlier `0.15.0 (4)` pair was withdrawn from review after both replacements became available. The paired `0.14.3 (6)` archives were uploaded from source commit `2ef1fae89ebeb876b7efae05db4a94f6a9af208b` on `fix/icloud-setup-fallback`. This emergency fix keeps manual setup available after iCloud errors and adds optional restoration with Back on Apple TV. tvOS external testing was verified in App Store Connect; blurbery completed the iOS external submission. Both signed Release archives passed version and signature checks. Fresh-install restoration and Back behaviour still need device verification. The tvOS-only `0.14.3 (7)` archive was uploaded from source commit `4c40c302b4806d5aa82a12845c585e53afe8ed84` on `fix/tvos-pcm-channel-negotiation`. It adds bounded HDMI PCM channel negotiation and release diagnostics; Dolby Digital output with Auto and real AirPlay route switching still require tester confirmation. The [player regression run](https://github.com/blurbery/vivid/actions/runs/34459344249) passed, and the signed tvOS app and Top Shelf extension passed version, signature and production-entitlement checks. Apple processing completed and the build is available internally. blurbery subsequently approved the external submission and confirmed availability. At that point iOS remained on build `6`; no iOS archive was uploaded for build `7`. Builds `8` to `11` below were local device builds. tvOS `0.14.3 (8)` from `4d8916ffdec9e088a0c376de1ac0044aa029c261` on `test/aether-playback` was built in Release configuration with Xcode 26.6 and installed in place on the paired Apple TV 4K running tvOS 26.6. The bundle ID, signing team, shared keychain group and user-independent keychain entitlement were verified before installation. The app was not uninstalled or launched, and nothing was uploaded to TestFlight. The [regression run](https://github.com/blurbery/vivid/actions/runs/34477369346) passed both the tvOS simulator build and iOS suite; broader device coverage was not established by those checks.

tvOS `0.14.3 (9)` from `d831dfd6ee352b9721bda978fb48ababf4c9cd91` on `test/aether-playback` was built in Release configuration with `CURRENT_PROJECT_VERSION=9` and installed in place on the paired Apple TV. This build adds the AVKit native host, subtitle handoff and episode-frame guards. The signed bundle, extension versions and existing keychain entitlements passed verification. The app was not uninstalled or launched, and no TestFlight upload was made. CI and device playback verification remain pending.

tvOS `0.14.3 (10)` from `eb343ca1fd89a03c999fbe14a11a1a8d33599dfc` on `test/aether-playback` was built in Release configuration with `CURRENT_PROJECT_VERSION=10` and installed in place on the paired Apple TV. It suppresses UIKit activity indicators inside the native playback host while retaining Vivid’s dots. The signed app, extension versions and existing keychain entitlements passed verification. The app was not uninstalled or launched, and no TestFlight upload was made. Visual confirmation of the loading indicator remains pending.

tvOS `0.14.3 (11)` from `fdb75eebfebe96f259fa2a136d3b284d1dc69b79` on `test/aether-playback` was built in Release configuration with `CURRENT_PROJECT_VERSION=11` and installed in place on the paired Apple TV. It adds the lossless-audio toggle to the actual tvOS playback pane and displays measured read-ahead in stats and both timeline bars. Build, signature, extension-version and existing keychain checks passed. The app was not uninstalled or launched, and no TestFlight upload was made. blurbery accepted this build after local testing and requested adoption on main. This does not establish every format or output-route combination. The local build and package caches are retained at blurbery’s request for incremental updates during this testing loop.

tvOS-only `0.14.3 (12)` was archived from `e6bda8c`, with identical application sources on merged main commit `21893b860db4eb553458d835efae275436283d25`. It retains build `11` playback code, with documentation and build-counter updates. The [player regression run](https://github.com/blurbery/vivid/actions/runs/34484833167) passed both the tvOS simulator build and complete iOS suite for `fdb75ee`. The Release archive and exported distribution app/Top Shelf passed signature, version and identity checks, including production CloudKit and the existing keychain audience. Apple accepted the tvOS upload on 11 September 2026 (Australia/Sydney); Processing completed, testing notes were saved, and App Store Connect confirmed Testing for both the existing internal and external groups after submission. The uploader reported missing dSYMs for bundled media frameworks, limiting symbolication for those libraries without blocking the upload. No iOS binary was included.

iOS/iPadOS and tvOS `0.14.3 (13)` were archived from main commit `afc3b738718177db641add93891a7445c3f0d250`, containing merged PR #6 and the shared build-counter update. The [regression run](https://github.com/blurbery/vivid/actions/runs/34554395313) passed the complete iOS suite and tvOS simulator build for the merged application sources. Both signed Release archives and exported apps/extensions passed version, signature and configured-entitlement checks, including production CloudKit and the existing keychain audience. Apple accepted both uploads on 11 September 2026 (Australia/Sydney). Processing completed for both platforms, testing notes were saved, and App Store Connect confirmed Testing for the existing internal and external groups after submission. This update includes separate one-minute partial progress and 90%/credits/natural-end completion, recap fallback, pause recovery, resume displays and Settings fixes. At upload, the completion changes had passed automated checks without recorded device verification. Bundled media-library dSYM warnings remain non-blocking and limit symbolication for those dependencies. Retained local caches support incremental fixes; the signed archives preserve the shipped app symbols.
