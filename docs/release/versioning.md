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

Routine TestFlight updates retain the current marketing version and increment only the build number. Changing the Apple marketing version requires explicit approval from blurbery before archiving or uploading. The approved Apple marketing version is `0.14.3`. The paired `0.14.3 (5)` archives were uploaded from source commit `450f8aafb4f3e993dc9595cdb548676c784c07eb`, using that previously reviewed version at blurbery’s request. Both build `5` releases are available to the external tester group. The earlier `0.15.0 (4)` pair was withdrawn from review after both replacements became available. The paired `0.14.3 (6)` archives were uploaded from source commit `2ef1fae89ebeb876b7efae05db4a94f6a9af208b` on `fix/icloud-setup-fallback`. This emergency fix keeps manual setup available after iCloud errors and adds optional restoration with Back on Apple TV. tvOS external testing was verified in App Store Connect; blurbery completed the iOS external submission. Both signed Release archives passed version and signature checks. Fresh-install restoration and Back behaviour still need device verification. The tvOS-only `0.14.3 (7)` archive was uploaded from source commit `4c40c302b4806d5aa82a12845c585e53afe8ed84` on `fix/tvos-pcm-channel-negotiation`. It adds bounded HDMI PCM channel negotiation and release diagnostics; Dolby Digital output with Auto and real AirPlay route switching still require tester confirmation. The [player regression run](https://github.com/blurbery/vivid/actions/runs/34459344249) passed, and the signed tvOS app and Top Shelf extension passed version, signature and production-entitlement checks. Apple processing completed and the build is available internally. External beta review has not been submitted; the prepared submission is awaiting approval. iOS remains on build `6`; no iOS archive was uploaded. The next upload uses build `8`. tvOS `0.14.3 (8)` from `4d8916ffdec9e088a0c376de1ac0044aa029c261` on `test/aether-playback` was built in Release configuration with Xcode 26.6 and installed in place on the paired Apple TV 4K running tvOS 26.6. The bundle ID, signing team, shared keychain group and user-independent keychain entitlement were verified before installation. The app was not uninstalled or launched, and nothing was uploaded to TestFlight. The [tvOS simulator build](https://github.com/blurbery/vivid/actions/runs/34477369346) passed; the iOS regression job and device playback comparison remain pending.

Apple requires TestFlight App Review for the first build of a version; later builds within that version may not need a full review. Keeping the version stable avoids introducing a new version for every beta update, but does not guarantee immediate approval. Returning to a previously reviewed marketing version does not guarantee that a new build will skip review; expiring another build does not provide that guarantee either. See [Apple’s TestFlight App Review guidance](https://developer.apple.com/help/glossary/testflight-app-review/).

Each paired iOS and tvOS upload uses the same positive build number, including every embedded extension. Increment that shared number for the next pair of uploaded binaries. The counter never resets, even after an approved marketing-version change. Continue from the highest previously uploaded build number across both platforms.

`iosApp/project.yml` is the committed source for the Apple marketing-version and build-number baseline shared by all shippable targets. TestFlight archives must retain that approved marketing version. The tag resolver in `scripts/ci/resolve-marketing-version.sh` remains available for source-tagged unsigned builds; it must not automatically select the marketing version for TestFlight. Unsigned lanes accept `BUILD_NUMBER` as `CURRENT_PROJECT_VERSION`. Check both finished archives and their extensions before upload.

The app does not query GitHub APIs at runtime. A local or simulator build must not claim to be an uploaded TestFlight build unless it was created with the exact released version and TestFlight counter.

## Release notes

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

The tests cover major/minor/patch rules, ordinary commit messages, empty ranges, curated bullets, duplicate notes, markup escaping and the version-only title. They validate release tooling, not the Apple app. App code changes still need the relevant builds, tests and device checks before they are pushed to `main`.

Dependencies are pinned in `package-lock.json`; the Node tools do not become app dependencies. The `VIVID_GIT_NOREPLY_EMAIL` repository variable must hold `blurbery`'s GitHub noreply address. The workflow uses its scoped `GITHUB_TOKEN` and does not publish an npm package or comment on issues/PRs.

GitHub currently lists the source-release, player-regression and sideload workflows as active. The source-release workflow runs on main updates; player regression supports pull requests and manual validation. Sideload publishing remains a separate, explicitly requested action and its legacy publishing format needs review before use. Do not enable paid capacity or change distribution settings as part of an ordinary source release. See [App Distribution](distribution.md).

The repository and its source releases are public. Apple beta distribution remains separate and limited to the testers invited through TestFlight.
